import Foundation

/// How bytes reach a terminal, and nothing else.
///
/// Signing a request, checking the answer, and deciding what a response code
/// means all belong to `EcrTerminal` and are the same however the bytes travel.
/// A channel only has to carry one framed request and bring back one framed
/// answer.
public protocol EcrChannel {
    /// What to show an operator when this link fails.
    var endpoint: String { get }

    /// The address side of `EcrReachability`, for links that have one.
    ///
    /// A cable has no host and no port. It reports its own name and a port of
    /// zero rather than inventing an address, and callers that want something
    /// to print should read `endpoint`.
    var host: String { get }

    /// Zero when the link is not a socket.
    var port: Int { get }

    /// Whether the terminal can be reached, or why not.
    ///
    /// - Returns: `nil` when reachable, otherwise the reason.
    func probe(timeout: TimeInterval) -> String?

    /// Sends one request body and returns the answer body.
    ///
    /// Framing is the channel's to apply — see `EcrFrames` — because only the
    /// channel knows how its medium delivers bytes.
    ///
    /// - Throws: `EcrChannelTimeout` when the terminal did not answer in time.
    ///   Not a refusal: the payment may have completed and the terminal been
    ///   unable to say so.
    func exchange(body: Data, timeout: TimeInterval) throws -> Data
}

public extension EcrChannel {
    var host: String { endpoint }
    var port: Int { 0 }
}

/// The terminal did not answer in time. The transaction may still have run.
public struct EcrChannelTimeout: LocalizedError {
    public let errorDescription: String?

    public init(_ message: String) {
        errorDescription = message
    }
}

/// The terminal over TCP, on the shop's Wi‑Fi / LAN.
///
/// One connection carries one request and one answer, which is how POS ECR ports
/// behave: connect, send, wait for the cardholder, read the result, disconnect.
public final class TcpEcrChannel: EcrChannel {

    public let host: String
    public let port: Int
    private let connectTimeout: TimeInterval

    private let lock = NSLock()
    private var live: EcrSocket?
    private var cancelled = false

    public var endpoint: String { "\(host):\(port)" }

    /// - Parameters:
    ///   - host: Terminal address on the local network.
    ///   - port: ECR TCP port (default `EcrConfig.defaultPort`).
    ///   - connectTimeout: How long a connect may wait before the address is
    ///     treated as unreachable. Separate from the long response wait, which
    ///     includes a cardholder tapping a card.
    public init(
        host: String,
        port: Int = EcrConfig.defaultPort,
        connectTimeout: TimeInterval = 3
    ) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
    }

    public func probe(timeout: TimeInterval) -> String? {
        let socket = EcrSocket()
        defer { socket.close() }
        do {
            try socket.connect(host: host, port: port, timeout: timeout)
            return nil
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? String(describing: type(of: error)) : detail
        }
    }

    public func exchange(body: Data, timeout: TimeInterval) throws -> Data {
        let socket = EcrSocket()

        lock.lock()
        if cancelled {
            lock.unlock()
            throw EcrSocket.SocketError.cancelled
        }
        live = socket
        lock.unlock()

        defer {
            socket.close()
            lock.lock()
            live = nil
            lock.unlock()
        }

        do {
            try socket.connect(host: host, port: port, timeout: connectTimeout)
            socket.setReadTimeout(timeout)
            try socket.write(try EcrFrames.wrap(body))
            return try EcrFrames.readBody { count, what in
                try socket.readExactly(count, what: what)
            }
        } catch let error as EcrSocket.SocketError {
            switch error {
            case let .timedOut(message):
                throw EcrChannelTimeout(message)
            default:
                throw error
            }
        }
    }

    /// Gives up on an in-flight exchange from another thread.
    ///
    /// Only meaningful while `exchange` is blocked on this channel. The terminal
    /// is not told and does not stop: the outcome is unknown.
    public func cancel() {
        lock.lock()
        cancelled = true
        let socket = live
        lock.unlock()
        socket?.cancel()
    }
}
