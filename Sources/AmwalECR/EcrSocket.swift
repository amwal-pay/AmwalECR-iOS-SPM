import Darwin
import Foundation

/// One TCP exchange with a terminal.
///
/// BSD sockets rather than `NWConnection`: the protocol is one request, one
/// response, one connection, with a connect timeout and a read timeout that
/// differ by two orders of magnitude — and a blocking socket expresses that in
/// a way a reader can check against the protocol document. It also gives
/// [cancel] something real to do: shutting the descriptor down makes a blocked
/// read return at once, which is how a cancel stops a till waiting two minutes
/// for a terminal it has given up on.
///
/// Not thread-safe beyond [cancel], which is the one thing another thread is
/// allowed to call.
final class EcrSocket {

    private var descriptor: Int32 = -1
    private let lock = NSLock()
    private var cancelled = false

    enum SocketError: Error {
        /// Nothing is listening, or the address does not resolve.
        case unreachable(String)
        /// Connected, but no answer within the read timeout.
        case timedOut(String)
        /// The peer closed part way through a message.
        case closed(String)
        /// The caller gave up.
        case cancelled
    }

    /// Opens a connection, waiting at most [timeout] for it to be accepted.
    ///
    /// Non-blocking connect plus `poll`, because a blocking `connect` cannot be
    /// bounded: the kernel's own SYN timeout is over a minute, and a till
    /// cannot make a cashier wait that long to learn the address is wrong.
    func connect(host: String, port: Int, timeout: TimeInterval) throws {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &info)
        guard status == 0, let resolved = info else {
            throw SocketError.unreachable(
                "\(host) could not be resolved (\(String(cString: gai_strerror(status))))"
            )
        }
        defer { freeaddrinfo(info) }

        var lastError = "no address answered"
        var candidate: UnsafeMutablePointer<addrinfo>? = resolved

        while let address = candidate {
            do {
                try connect(to: address.pointee, timeout: timeout)
                return
            } catch SocketError.unreachable(let message) {
                lastError = message
                candidate = address.pointee.ai_next
            }
        }

        throw SocketError.unreachable("\(lastError) (\(host):\(port))")
    }

    private func connect(to address: addrinfo, timeout: TimeInterval) throws {
        let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard fd >= 0 else {
            throw SocketError.unreachable("Could not open a socket (\(errnoText()))")
        }

        // No SIGPIPE: a write to a socket the terminal has closed must come
        // back as an error, not kill the host app.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let result = Darwin.connect(fd, address.ai_addr, address.ai_addrlen)

        if result != 0 {
            guard errno == EINPROGRESS else {
                let message = errnoText()
                Darwin.close(fd)
                throw SocketError.unreachable(message)
            }

            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&poller, 1, Int32(timeout * 1000))
            if ready <= 0 {
                Darwin.close(fd)
                throw SocketError.unreachable(
                    ready == 0 ? "The terminal did not accept a connection within \(Int(timeout))s"
                               : "Waiting to connect failed (\(errnoText()))"
                )
            }

            // poll() reporting writable is not the same as connected: a refused
            // connection is writable too, and the verdict is in SO_ERROR.
            var pending: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &length)
            if pending != 0 {
                Darwin.close(fd)
                throw SocketError.unreachable(String(cString: strerror(pending)))
            }
        }

        _ = fcntl(fd, F_SETFL, flags)

        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            Darwin.close(fd)
            throw SocketError.cancelled
        }
        descriptor = fd
    }

    /// How long a read may block before it is a timeout.
    func setReadTimeout(_ timeout: TimeInterval) {
        let whole = Int(timeout)
        var value = timeval(
            tv_sec: whole,
            tv_usec: Int32((timeout - Double(whole)) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    func write(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            while sent < data.count {
                let written = send(descriptor, base.advanced(by: sent), data.count - sent, 0)
                if written > 0 {
                    sent += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                throw cancelledOr(.closed("The terminal closed the connection while it was being sent the request"))
            }
        }
    }

    /// Reads exactly [count] bytes, or says why it could not.
    func readExactly(_ count: Int, what: String) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0

        while filled < count {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(descriptor, base.advanced(by: filled), count - filled, 0)
            }

            if read > 0 {
                filled += read
                continue
            }
            if read == 0 {
                throw cancelledOr(.closed("Terminal closed the connection while sending the \(what)"))
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw cancelledOr(.timedOut("No \(what) arrived before the read timeout"))
            }
            throw cancelledOr(.closed("Reading the \(what) failed (\(errnoText()))"))
        }

        return Data(buffer)
    }

    /// Gives up on the exchange from another thread.
    ///
    /// Shuts the descriptor down rather than closing it: a `close` would free
    /// the number for the next socket, and a read still in flight would then be
    /// reading somebody else's connection. `shutdown` makes the blocked read
    /// return immediately and leaves the descriptor valid until [close] runs.
    ///
    /// **This tells the terminal nothing.** A cardholder mid-PIN carries on and
    /// the payment may complete. What is cancelled is the waiting.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// A cancel is the truer account of a read that failed because we shut the
    /// socket down ourselves.
    private func cancelledOr(_ error: SocketError) -> SocketError {
        lock.lock()
        defer { lock.unlock() }
        return cancelled ? .cancelled : error
    }

    private func errnoText() -> String { String(cString: strerror(errno)) }
}
