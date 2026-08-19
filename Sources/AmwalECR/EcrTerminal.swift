import Foundation

/// A POS terminal reachable over the network.
///
/// The iOS counterpart of the Kotlin SDK's `EcrTerminal`, method for method and
/// outcome for outcome. One instance addresses one terminal and holds no
/// connection between calls.
///
/// Every call blocks, so callers run it off the main thread — `EcrCallHandler`
/// does that once, on a queue of its own, rather than leaving it to each caller.
///
/// The money-moving calls `throw` only for arguments that cannot be used — a
/// reference the wire format cannot carry, a secret that is not hex. Nothing was
/// sent in that case. Everything that happens on the wire is an `EcrResult`,
/// never an exception.
public final class EcrTerminal {

    private let host: String
    private let serialNumber: String
    private let config: EcrConfig
    private let logger: EcrLogger

    /// The socket of the exchange currently in flight, so [cancel] has
    /// something to shut down. Guarded because cancel arrives from elsewhere.
    private var live: EcrSocket?
    private let liveLock = NSLock()
    private var cancelled = false

    /// Addresses one terminal. Nothing is opened here: each call makes its own
    /// connection and closes it again.
    public init(
        host: String,
        serialNumber: String = "",
        config: EcrConfig = EcrConfig(),
        logger: EcrLogger = .none
    ) {
        self.host = host
        self.serialNumber = serialNumber
        self.config = config
        self.logger = logger
    }

    /// Whether the terminal is listening.
    ///
    /// Proves the port is open, not that the terminal is idle — a terminal
    /// already taking a payment answers a handshake too.
    public func isReachable() -> Bool {
        let socket = EcrSocket()
        defer { socket.close() }
        do {
            try socket.connect(host: host, port: config.port, timeout: config.probeTimeout)
            return true
        } catch {
            logger.debug("Probe failed for \(host):\(config.port) — \(error)")
            return false
        }
    }

    /// Takes a payment. The cardholder presents their card at the terminal.
    ///
    /// - Parameter merchantReferenceId: the till's own reference for this sale —
    ///   an order number, a basket id, whatever the caller's system already uses
    ///   to name it. Left out, the SDK generates one and reports it on the
    ///   result.
    public func sale(amount: Decimal, merchantReferenceId: String = "") throws -> EcrResult {
        try run(.sale, amount: amount, merchantReferenceId: merchantReferenceId)
    }

    /// Cancels an earlier transaction in full, by its receipt number.
    ///
    /// - Parameter merchantReferenceId: the till's own reference for the void.
    ///   This names the cancellation, not the transaction being cancelled — that
    ///   one is named by `receiptNumber`.
    public func void(
        receiptNumber: String,
        originalTerminalId: String = "",
        merchantReferenceId: String = ""
    ) throws -> EcrResult {
        try run(
            .void,
            originalStan: receiptNumber,
            originalTerminalId: originalTerminalId,
            merchantReferenceId: merchantReferenceId
        )
    }

    /// Returns money against an earlier transaction, in full or in part.
    public func refund(
        amount: Decimal,
        receiptNumber: String,
        transactionDate: String,
        originalTerminalId: String = "",
        merchantReferenceId: String = ""
    ) throws -> EcrResult {
        try run(
            .refund,
            amount: amount,
            originalStan: receiptNumber,
            originalTerminalId: originalTerminalId,
            originalDate: transactionDate,
            merchantReferenceId: merchantReferenceId
        )
    }

    /// Runs any operation that moves money.
    ///
    /// Rejects the read-only types the same way the Kotlin SDK does, so a
    /// caller that gets it wrong is told on both platforms rather than one.
    public func run(
        _ type: EcrTransactionType,
        amount: Decimal? = nil,
        originalStan: String = "",
        originalTerminalId: String = "",
        originalDate: String = "",
        merchantReferenceId: String = ""
    ) throws -> EcrResult {
        precondition(type.movesMoney, "\(type.displayName) is run with inquire()")

        let message = try build(
            type,
            amount: amount,
            originalStan: originalStan,
            originalTerminalId: originalTerminalId,
            originalDate: originalDate,
            merchantReferenceId: merchantReferenceId
        )

        switch exchange(message) {
        case let .failure(failure):
            return lost(message.merchantReferenceId, failure)
        case let .success(json):
            return EcrTerminal.result(
                from: json,
                merchantReferenceId: message.merchantReferenceId,
                minorUnitDigits: config.minorUnitDigits
            )
        }
    }

    /// Asks what became of an earlier transaction, without touching it.
    ///
    /// Safe to repeat, and answered even while the terminal is taking a
    /// payment — which is when a till most needs it.
    public func inquire(
        receiptNumber: String,
        transactionDate: String,
        originalTerminalId: String = "",
        merchantReferenceId: String = ""
    ) throws -> EcrInquiry {
        guard !receiptNumber.trimmed.isEmpty else {
            throw EcrInvalidArgument("An inquiry needs a receipt number")
        }

        let message = try build(
            .inquiry,
            originalStan: receiptNumber,
            originalTerminalId: originalTerminalId,
            originalDate: transactionDate,
            merchantReferenceId: merchantReferenceId
        )

        return inquiryAnswer(message)
    }

    /// Asks what became of the transaction this till named [originalReference],
    /// without touching it.
    ///
    /// This is the answer to an outcome you never received. A receipt number
    /// arrives *in* the terminal's answer, so after a timeout, a lost connection
    /// or an unauthenticated answer there is no receipt number to quote — but the
    /// reference you sent the request with is still yours. That is what this
    /// looks the transaction up by.
    ///
    /// ```swift
    /// let result = try terminal.sale(amount: total, merchantReferenceId: order.number)
    /// if case .failed = result {
    ///     // Never retry here — find out first.
    ///     switch try terminal.inquireByReference(order.number) {
    ///     case let .found(_, transaction, _): reconcile(transaction)
    ///     case .notFound:                     break  // nothing was taken
    ///     case .failed:                       break  // still unknown; ask later
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - originalReference: the reference the earlier transaction was sent
    ///     with — not a reference for this inquiry, which is
    ///     `merchantReferenceId`.
    ///   - transactionDate: the day the original was taken, as `yyyyMMdd`.
    ///     Optional: a reference is not scoped to a day the way a receipt number
    ///     is.
    public func inquireByReference(
        _ originalReference: String,
        transactionDate: String = "",
        originalTerminalId: String = "",
        merchantReferenceId: String = ""
    ) throws -> EcrInquiry {
        guard !originalReference.trimmed.isEmpty else {
            throw EcrInvalidArgument("An inquiry by reference needs the original's reference")
        }

        let message = try build(
            .inquiry,
            originalTerminalId: originalTerminalId,
            originalDate: transactionDate,
            originalReference: originalReference,
            merchantReferenceId: merchantReferenceId
        )

        return inquiryAnswer(message)
    }

    /// Fetches an earlier transaction's e-receipt.
    public func receipt(
        receiptNumber: String,
        transactionDate: String,
        originalTerminalId: String = "",
        merchantReferenceId: String = ""
    ) throws -> EcrReceipt {
        guard !receiptNumber.trimmed.isEmpty else {
            throw EcrInvalidArgument("A receipt needs a receipt number")
        }

        let message = try build(
            .receipt,
            originalStan: receiptNumber,
            originalTerminalId: originalTerminalId,
            originalDate: transactionDate,
            merchantReferenceId: merchantReferenceId
        )

        switch exchange(message) {
        case let .failure(failure):
            return .failed(merchantReferenceId: message.merchantReferenceId, failure: failure)
        case let .success(json):
            return EcrTerminal.receipt(
                from: json,
                merchantReferenceId: message.merchantReferenceId
            )
        }
    }

    /// Abandons the exchange in flight, from another thread.
    ///
    /// The terminal is not told and does not stop. A cancelled money-moving
    /// request has an unknown outcome: reconcile with [inquire], never retry.
    public func cancel() {
        liveLock.lock()
        cancelled = true
        let socket = live
        liveLock.unlock()
        socket?.cancel()
    }

    private func inquiryAnswer(_ message: EcrMessage) -> EcrInquiry {
        switch exchange(message) {
        case let .failure(failure):
            return .failed(merchantReferenceId: message.merchantReferenceId, failure: failure)
        case let .success(json):
            return EcrTerminal.inquiry(
                from: json,
                merchantReferenceId: message.merchantReferenceId,
                minorUnitDigits: config.minorUnitDigits
            )
        }
    }

    /// Turns a lost exchange into a result, asking the terminal what became of
    /// the transaction where that can be answered.
    ///
    /// The request went out and no answer came back, which is the one situation a
    /// till cannot resolve on its own — and the thing it reaches for instead is
    /// sending the sale again, which charges the cardholder twice. So the
    /// question is asked here, once, on a fresh connection.
    ///
    /// The finding is attached rather than substituted: a failed result whose
    /// `recovered` is `.found` still says the exchange failed, because it did.
    /// What changed is that the outcome is no longer unknown.
    private func lost(_ reference: String, _ failure: EcrFailure) -> EcrResult {
        let plain = EcrResult.failed(
            merchantReferenceId: reference,
            failure: failure,
            recovered: nil
        )

        guard config.autoInquireOnFailure else { return plain }
        // Nothing was sent, so there is nothing to ask about — and asking would
        // only make the caller wait through a second connection that will fail
        // for the same reason the first one did.
        guard failure.outcomeUnknown else { return plain }
        guard !reference.isEmpty else { return plain }

        // A cancelled exchange is the caller saying it is done waiting. Holding
        // it for a second round trip is the one thing it asked not to happen;
        // the reference is on the result, and the till can inquire when it
        // chooses to.
        liveLock.lock()
        let abandoned = cancelled
        liveLock.unlock()
        guard !abandoned else { return plain }

        // An inquiry reads and nothing more, so this cannot itself move money
        // however it goes. A failure here leaves the outcome exactly as unknown
        // as it already was.
        let found = try? inquireByReference(reference)

        return .failed(merchantReferenceId: reference, failure: failure, recovered: found)
    }

    private func build(
        _ type: EcrTransactionType,
        amount: Decimal? = nil,
        originalStan: String = "",
        originalTerminalId: String = "",
        originalDate: String = "",
        originalReference: String = "",
        merchantReferenceId: String = ""
    ) throws -> EcrMessage {
        let message = try EcrMessage.build(
            type: type,
            config: config,
            terminalSerial: serialNumber,
            amount: amount,
            originalStan: originalStan,
            originalTerminalId: originalTerminalId,
            originalDate: originalDate,
            originalReference: originalReference,
            merchantReferenceId: merchantReferenceId
        )

        logger.debug(
            "Sending \(type.rawValue) \(message.merchantReferenceId) "
                + "to \(host):\(config.port)"
        )
        logger.debug(EcrMessageCodec.text(message.json))
        return message
    }

    /// One request, one answer — or why there was none.
    private func exchange(_ message: EcrMessage) -> Result<[String: Any], EcrFailure> {
        let socket = EcrSocket()

        liveLock.lock()
        if cancelled {
            liveLock.unlock()
            return .failure(.connectionLost("Cancelled before the request was sent"))
        }
        live = socket
        liveLock.unlock()

        defer {
            socket.close()
            liveLock.lock()
            live = nil
            liveLock.unlock()
        }

        do {
            let packet = try EcrMessageCodec.encode(message)
            try socket.connect(host: host, port: config.port, timeout: config.connectTimeout)
            socket.setReadTimeout(config.responseTimeout)
            try socket.write(packet)

            let answer = try EcrMessageCodec.decode(from: socket)
            logger.debug("Received \(EcrMessageCodec.text(answer))")

            if let rejection = untrustworthy(answer, sent: message) {
                logger.debug("Rejected the answer: \(rejection.message)")
                return .failure(rejection)
            }
            return .success(answer)
        } catch let error as EcrSocket.SocketError {
            return .failure(EcrTerminal.failure(for: error, host: host, port: config.port,
                                                responseTimeout: config.responseTimeout))
        } catch let error as EcrMessageCodec.CodecError {
            switch error {
            case let .tooLarge(message):
                return .failure(.malformed(message))
            case .empty:
                return .failure(.malformed("Terminal returned an empty message"))
            case let .notJson(message):
                return .failure(.malformed(message))
            }
        } catch {
            return .failure(.malformed(error.localizedDescription))
        }
    }

    /// Why this answer must not be believed, or nil when it can be.
    ///
    /// Checking the answer matters as much as signing the request. An answer is
    /// what decides whether the till hands over the goods, so anything on the
    /// network that replies on the terminal's port before the terminal does could
    /// otherwise claim `approved` for a payment that never happened — without
    /// ever touching the payment backend.
    ///
    /// The outcome is [EcrFailure.unauthenticated] rather than a decline, because
    /// a rejected answer says nothing about what the terminal did. The
    /// transaction may well have completed; it simply cannot be confirmed from
    /// here.
    private func untrustworthy(_ answer: [String: Any], sent: EcrMessage) -> EcrFailure? {
        guard config.signsMessages else { return nil }

        // Told apart because the two mean different things to whoever has to fix
        // it. No signature at all is a terminal that has no key — signing is
        // switched on per terminal by TMS issuing one, so a till configured with
        // a key can be pointed at a terminal that has none, and every answer
        // then arrives unsigned. A signature that does not match is two keys
        // that are not the same.
        guard !ecrString(answer, SecureHash.field).isEmpty else {
            return .unauthenticated(
                "The terminal's answer carried no signature. This till is set to "
                    + "sign, so the terminal must hold the same key: check what is "
                    + "provisioned on it, or leave secureHashKey empty to talk to a "
                    + "terminal that has none."
            )
        }

        guard SecureHash.verify(answer, key: config.secureHashKey) else {
            return .unauthenticated(
                "The answer's signature did not match this till's key. The key on "
                    + "this till and the key on the terminal are not the same."
            )
        }

        // Binds the answer to this request. A correctly signed answer to an
        // earlier transaction, replayed onto this connection, fails here.
        guard ecrString(answer, "nonce") == sent.nonce else {
            return .unauthenticated(
                "The answer belongs to a different request. The transaction "
                    + "may still have completed — inquire before retrying."
            )
        }

        return nil
    }

    /// Maps a socket error onto the SDK's failures.
    ///
    /// The mapping is the point of the whole class: a timeout is not a decline,
    /// and calling it one is how a customer gets charged twice.
    private static func failure(
        for error: EcrSocket.SocketError,
        host: String,
        port: Int,
        responseTimeout: TimeInterval
    ) -> EcrFailure {
        switch error {
        case let .unreachable(message):
            return .unreachable("\(message) (\(host):\(port))")
        case .timedOut:
            return .timeout(
                "The terminal did not answer within \(Int(responseTimeout))s. "
                    + "The transaction may still have completed — inquire before retrying."
            )
        case let .closed(message):
            return .connectionLost(message)
        case .cancelled:
            // The handler turns this into the channel's `cancelled` kind. Named
            // connectionLost here because that is what happened to the socket,
            // and it carries the same "outcome unknown" weight.
            return .connectionLost("The exchange was cancelled by the caller")
        }
    }
}
