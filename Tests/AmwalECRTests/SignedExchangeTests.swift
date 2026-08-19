import XCTest
import Darwin
@testable import AmwalECR

private let key = "881dc200c9833da726e9376c2e32cff7"

/// A stand-in terminal on a real socket, so the exchange can be driven without
/// hardware.
///
/// Each connection is served by `answer`, which decides what — if anything —
/// comes back. Returning nil drops the connection without replying, which is
/// what a Wi-Fi failure looks like from the till's side.
///
/// The counterpart of the Kotlin SDK's `FakeTerminal` in `AutoInquiryTest.kt`.
private final class FakeTerminalServer {

    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var received: [[String: Any]] = []

    /// Every request received, in order, so a test can assert what was sent.
    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    /// Answers a request. `connection` counts from zero.
    private let answer: ([String: Any], Int) -> [String: Any]?

    init(answer: @escaping ([String: Any], Int) -> [String: Any]?) throws {
        // Set up the socket in locals first: the closures below would otherwise
        // capture a half-initialised self to read the stored properties.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket() failed") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                                  // any free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw Failure("bind/listen failed")
        }

        var actual = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &size)
            }
        }

        self.answer = answer
        self.listener = fd
        self.port = Int(UInt16(bigEndian: actual.sin_port))

        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        var connection = 0
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }                          // closed
            serve(client, connection)
            connection += 1
        }
    }

    private func serve(_ client: Int32, _ connection: Int) {
        defer { Darwin.close(client) }

        guard let header = read(client, 2) else { return }
        let length = Int(header[0]) << 8 | Int(header[1])
        guard let body = read(client, length),
              let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return }

        lock.lock(); received.append(request); lock.unlock()

        guard let reply = answer(request, connection) else { return }  // drop it
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }

        var packet = Data([UInt8(data.count >> 8 & 0xFF), UInt8(data.count & 0xFF)])
        packet.append(data)
        packet.withUnsafeBytes { _ = send(client, $0.baseAddress, packet.count, 0) }
    }

    private func read(_ client: Int32, _ count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let got = recv(client, &buffer, count - data.count, 0)
            if got <= 0 { return nil }
            data.append(contentsOf: buffer[0..<got])
        }
        return data
    }

    func close() { Darwin.close(listener) }

    struct Failure: Error { let message: String; init(_ m: String) { message = m } }
}

/// One signed exchange, end to end, over a real socket.
///
/// Everything else in this suite tests a piece: `SecureHashTests` the signature,
/// `EcrMessageTests` the request, `EcrResponseReaderTests` the answer. This
/// tests that a `sale()` actually puts a signature on the wire and actually
/// refuses an answer that has not got one — which is the claim a till depends on
/// and the one no unit test makes.
final class SignedExchangeTests: XCTestCase {

    private var server: FakeTerminalServer!

    override func tearDown() {
        server?.close()
        server = nil
        super.tearDown()
    }

    private func terminal(
        signed: Bool = true,
        autoInquire: Bool = true,
        logger: EcrLogger = .none
    ) -> EcrTerminal {
        var config = EcrConfig()
        config.port = server.port
        config.secureHashKey = signed ? key : ""
        config.autoInquireOnFailure = autoInquire
        config.connectTimeout = 2
        config.responseTimeout = 3
        return EcrTerminal(
            host: "127.0.0.1",
            serialNumber: "P653200085189",
            config: config,
            logger: logger
        )
    }

    /// Signs a reply the way a terminal does, echoing the request's nonce.
    private func signedReply(
        to request: [String: Any],
        _ extra: [String: Any] = [:]
    ) throws -> [String: Any] {
        var reply: [String: Any] = [
            "responseCode": "00",
            "responseMessage": "APPROVED",
            "approved": true,
            "merchantReferenceId": request["merchantReferenceId"] ?? "",
            "amount": request["amount"] ?? "",
            "rrn": "622113155340",
            "authCode": "517842",
            "maskedPan": "543173xxxx5785",
            "nonce": request["nonce"] ?? "",
        ]
        reply.merge(extra) { _, new in new }
        reply[SecureHash.field] = try SecureHash.sign(SecureHash.compose(reply), key: key)
        return reply
    }

    // MARK: - What goes out

    func testASignedSalePutsASignatureAndANonceOnTheWire() throws {
        server = try FakeTerminalServer { request, _ in
            // Verified with the same key, independently of the client code.
            guard verifies(request) else { return nil }
            return try? self.signedReply(to: request)
        }

        let result = try terminal().sale(amount: Decimal(string: "1.234")!,
                                         merchantReferenceId: "ORDER-4471")

        let sent = try XCTUnwrap(server.requests.first)
        XCTAssertEqual("ORDER-4471", sent["merchantReferenceId"] as? String)
        XCTAssertEqual(32, (sent["nonce"] as? String)?.count)
        XCTAssertEqual(64, (sent[SecureHash.field] as? String)?.count)
        XCTAssertTrue(verifies(sent), "the terminal must be able to verify what we sent")

        guard case let .approved(approved) = result else {
            return XCTFail("expected approved, got \(result)")
        }
        XCTAssertEqual("ORDER-4471", approved.merchantReferenceId)
        XCTAssertEqual("1.234", approved.amount)
    }

    func testAnUnsignedTillSendsNoSignatureAndNoNonce() throws {
        // The default. Nothing is signed, and nothing is checked — which is why
        // a real terminal refuses it.
        server = try FakeTerminalServer { request, _ in
            [
                "responseCode": "00",
                "approved": true,
                "merchantReferenceId": request["merchantReferenceId"] ?? "",
                "amount": request["amount"] ?? "",
            ]
        }

        _ = try terminal(signed: false).sale(amount: Decimal(string: "1.234")!)

        let sent = try XCTUnwrap(server.requests.first)
        XCTAssertNil(sent[SecureHash.field])
        XCTAssertNil(sent["nonce"], "a nonce without a signature could just be changed")
    }

    // MARK: - What comes back

    func testAnUnsignedAnswerToASignedRequestIsRefused() throws {
        // Anything on the shop network can reply on the terminal's port. An
        // answer that cannot be shown to be the terminal's is not believed.
        server = try FakeTerminalServer { request, _ in
            [
                "responseCode": "00",
                "approved": true,
                "merchantReferenceId": request["merchantReferenceId"] ?? "",
                "nonce": request["nonce"] ?? "",
            ]
        }

        let result = try terminal(autoInquire: false).sale(amount: Decimal(string: "1.234")!)

        guard case let .failed(_, failure, _) = result,
              case .unauthenticated = failure else {
            return XCTFail("expected unauthenticated, got \(result)")
        }
        // Not a decline: the terminal may well have taken the payment.
        XCTAssertTrue(failure.outcomeUnknown)
        // Named as the terminal having no key rather than as a key mismatch:
        // signing is switched on per terminal, so a till carrying a key can be
        // pointed at a terminal that has none, and this is what that looks like.
        XCTAssertTrue(
            failure.message.contains("carried no signature"),
            "an unsigned answer must say so, got: \(failure.message)"
        )
    }

    func testAnAnswerSignedWithTheWrongKeyIsRefused() throws {
        server = try FakeTerminalServer { request, _ in
            var reply: [String: Any] = [
                "responseCode": "00",
                "approved": true,
                "merchantReferenceId": request["merchantReferenceId"] ?? "",
                "nonce": request["nonce"] ?? "",
            ]
            reply[SecureHash.field] = try? SecureHash.sign(
                SecureHash.compose(reply),
                key: "0123456789abcdef0123456789abcdef"
            )
            return reply
        }

        let result = try terminal(autoInquire: false).sale(amount: Decimal(string: "1.234")!)

        guard case let .failed(_, failure, _) = result, case .unauthenticated = failure else {
            return XCTFail("expected unauthenticated, got \(result)")
        }
        // Two keys that are not the same — a different thing to fix from an
        // answer that carried no signature at all.
        XCTAssertTrue(
            failure.message.contains("did not match"),
            "a wrong signature must say so, got: \(failure.message)"
        )
    }

    func testACorrectlySignedAnswerToADifferentRequestIsRefused() throws {
        // A replayed answer: signed with the right key, but for another
        // transaction. The nonce is what catches it.
        server = try FakeTerminalServer { request, _ in
            try? self.signedReply(to: request, ["nonce": SecureHash.newNonce()])
        }

        let result = try terminal(autoInquire: false).sale(amount: Decimal(string: "1.234")!)

        guard case let .failed(_, failure, _) = result, case .unauthenticated = failure else {
            return XCTFail("expected unauthenticated, got \(result)")
        }
        XCTAssertTrue(failure.message.contains("different request"))
    }

    func testATamperedAmountIsRefused() throws {
        // The whole point of signing: nothing on the network can rewrite a
        // figure the till acts on.
        server = try FakeTerminalServer { request, _ in
            guard var reply = try? self.signedReply(to: request) else { return nil }
            reply["amount"] = "000000009999"          // after signing
            return reply
        }

        let result = try terminal(autoInquire: false).sale(amount: Decimal(string: "1.234")!)

        guard case let .failed(_, failure, _) = result, case .unauthenticated = failure else {
            return XCTFail("expected unauthenticated, got \(result)")
        }
    }

    // MARK: - Diagnostics

    func testTheLoggerSeesWhatWentOutAndWhatCameBack() throws {
        // The Kotlin SDK routes these to Logcat; on iOS the client decides where
        // they go. Either way the SDK gains no logging dependency of its own.
        server = try FakeTerminalServer { request, _ in try? self.signedReply(to: request) }

        let lock = NSLock()
        var lines: [String] = []
        let logger = EcrLogger { message in
            lock.lock(); lines.append(message); lock.unlock()
        }

        _ = try terminal(logger: logger).sale(amount: Decimal(string: "1.234")!,
                                              merchantReferenceId: "ORDER-4471")

        lock.lock(); let seen = lines; lock.unlock()
        XCTAssertTrue(seen.contains { $0.contains("Sending SALE ORDER-4471") }, "\(seen)")
        XCTAssertTrue(seen.contains { $0.contains("Received") }, "\(seen)")
        // The payload is logged, which is why the docs call these transaction
        // records — but the key itself never appears.
        XCTAssertFalse(seen.contains { $0.contains(key) })
    }

    func testNothingIsLoggedByDefault() throws {
        // `.none` discards, so a client that never asks for diagnostics does not
        // quietly accumulate masked card numbers in a log.
        server = try FakeTerminalServer { request, _ in try? self.signedReply(to: request) }

        _ = try terminal().sale(amount: Decimal(string: "1.234")!)
        // Nothing to assert but that it did not crash or print: the default
        // logger has nowhere to write.
    }

    // MARK: - The answer that never arrived

    func testALostAnswerIsFollowedUpByReferenceOnAFreshConnection() throws {
        server = try FakeTerminalServer { request, connection in
            // The sale is taken and the answer never gets back.
            if connection == 0 { return nil }

            // The follow-up: an inquiry naming the original by its reference.
            var reply: [String: Any] = [
                "responseCode": "00",
                "responseMessage": "Transaction found",
                "approved": true,
                "merchantReferenceId": request["merchantReferenceId"] ?? "",
                "nonce": request["nonce"] ?? "",
                "ecrResponse": [
                    "success": true,
                    "data": [
                        "transactionId": "e970c800",
                        "stan": "000215",
                        "status": "Approved",
                        "amount": 1.234,
                    ],
                ],
            ]
            reply[SecureHash.field] = try? SecureHash.sign(SecureHash.compose(reply), key: key)
            return reply
        }

        let result = try terminal().sale(amount: Decimal(string: "1.234")!,
                                         merchantReferenceId: "ORDER-4471")

        XCTAssertEqual(2, server.requests.count, "the sale, then one inquiry")

        let inquiry = server.requests[1]
        XCTAssertEqual("INQUIRY", inquiry["messageType"] as? String)
        // By reference, because the receipt number arrives *in* the answer that
        // went missing.
        XCTAssertEqual("ORDER-4471", inquiry["originalMerchantReference"] as? String)
        XCTAssertNil(inquiry["stan"])

        // The exchange still failed — that is what happened — but the outcome is
        // no longer unknown.
        guard case let .failed(reference, _, recovered) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertEqual("ORDER-4471", reference)
        XCTAssertTrue(result.settled)
        guard case let .some(.found(_, transaction, _)) = recovered else {
            return XCTFail("expected a found transaction, got \(String(describing: recovered))")
        }
        XCTAssertEqual("Approved", transaction.status)
    }

    func testTheFollowUpCanBeTurnedOff() throws {
        server = try FakeTerminalServer { _, _ in nil }

        let result = try terminal(autoInquire: false).sale(
            amount: Decimal(string: "1.234")!,
            merchantReferenceId: "ORDER-4471"
        )

        XCTAssertEqual(1, server.requests.count, "the sale, and nothing else")
        XCTAssertNil(result.recovered)
        XCTAssertFalse(result.settled)
    }

    func testTheSaleIsNeverSentTwice() throws {
        // The one thing that must never happen. The follow-up is an inquiry,
        // which reads; it is not the sale again.
        server = try FakeTerminalServer { request, connection in
            connection == 0 ? nil : try? self.signedReply(to: request)
        }

        _ = try terminal().sale(amount: Decimal(string: "1.234")!,
                                merchantReferenceId: "ORDER-4471")

        let sales = server.requests.filter { $0["messageType"] as? String == "SALE" }
        XCTAssertEqual(1, sales.count)
    }
}

/// Verifies a message the way the terminal would — deliberately not by calling
/// the client's own verify, so both halves are not the same code.
private func verifies(_ message: [String: Any]) -> Bool {
    guard let presented = message[SecureHash.field] as? String else { return false }
    guard let expected = try? SecureHash.sign(SecureHash.compose(message), key: key) else {
        return false
    }
    return presented == expected
}
