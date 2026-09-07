import Foundation

/// Result of `EcrTerminal.probeReachability()`.
public struct EcrReachability {
    public let reachable: Bool
    public let host: String
    public let port: Int
    public let error: String?
    /// What to show an operator: an address and port over Wi‑Fi, the cable otherwise.
    public let endpoint: String

    public init(
        reachable: Bool,
        host: String,
        port: Int,
        error: String? = nil,
        endpoint: String? = nil
    ) {
        self.reachable = reachable
        self.host = host
        self.port = port
        self.error = error
        self.endpoint = endpoint ?? (port > 0 ? "\(host):\(port)" : host)
    }
}

/// A POS terminal reachable over a channel (LAN TCP, USB cable, or anything
/// else that can carry one request and bring back one answer).
public final class EcrTerminal {

    private let channel: EcrChannel
    private let serialNumber: String
    private let config: EcrConfig
    private let logger: EcrLogger

    private let liveLock = NSLock()
    private var cancelled = false

    /// The terminal reached through an arbitrary byte channel.
    ///
    /// Prefer `init(host:…)` for LAN, or `EcrSessions.usbCableTerminal` when the
    /// caller already holds a cable channel.
    public init(
        channel: EcrChannel,
        serialNumber: String = "",
        config: EcrConfig = EcrConfig(),
        logger: EcrLogger = .none
    ) {
        self.channel = channel
        self.serialNumber = serialNumber
        self.config = config
        self.logger = logger
    }

    /// The terminal at an address on the local network.
    ///
    /// Kept so callers that address a terminal by IP read exactly as they always
    /// did; it builds a `TcpEcrChannel` and hands it to the channel initialiser.
    public convenience init(
        host: String,
        serialNumber: String = "",
        config: EcrConfig = EcrConfig(),
        logger: EcrLogger = .none
    ) {
        self.init(
            channel: TcpEcrChannel(
                host: host,
                port: config.port,
                connectTimeout: config.connectTimeout
            ),
            serialNumber: serialNumber,
            config: config,
            logger: logger
        )
    }

    public func isReachable() -> Bool {
        probeReachability().reachable
    }

    /// Asks the channel whether the terminal is there, before sending anything.
    public func probeReachability() -> EcrReachability {
        let problem = channel.probe(timeout: config.probeTimeout)
        if let problem {
            logger.debug("Probe failed for \(channel.endpoint) — \(problem)")
        }
        return EcrReachability(
            reachable: problem == nil,
            host: channel.host,
            port: channel.port,
            error: problem,
            endpoint: channel.endpoint
        )
    }

    public func sale(amount: Decimal, merchantReference: String = "") throws -> EcrResult {
        try run(.sale, amount: amount, merchantReference: merchantReference)
    }

    public func void(
        receiptNumber: String,
        originalTerminalId: String = "",
        merchantReference: String = ""
    ) throws -> EcrResult {
        try run(
            .void,
            originalStan: receiptNumber,
            originalTerminalId: originalTerminalId,
            merchantReference: merchantReference
        )
    }

    public func refund(
        amount: Decimal,
        receiptNumber: String,
        transactionDate: String,
        originalTerminalId: String = "",
        merchantReference: String = ""
    ) throws -> EcrResult {
        try run(
            .refund,
            amount: amount,
            originalStan: receiptNumber,
            originalTerminalId: originalTerminalId,
            originalDate: transactionDate,
            merchantReference: merchantReference
        )
    }

    public func run(
        _ type: EcrTransactionType,
        amount: Decimal? = nil,
        originalStan: String = "",
        originalTerminalId: String = "",
        originalDate: String = "",
        merchantReference: String = ""
    ) throws -> EcrResult {
        precondition(type.movesMoney, "\(type.displayName) is run with inquire()")

        let message = try build(
            type,
            amount: amount,
            originalStan: originalStan,
            originalTerminalId: originalTerminalId,
            originalDate: originalDate,
            merchantReference: merchantReference
        )

        switch exchange(message) {
        case let .failure(failure):
            return lost(message.merchantReference, failure)
        case let .success(json):
            return EcrTerminal.result(
                from: json,
                merchantReference: message.merchantReference,
                minorUnitDigits: config.minorUnitDigits
            )
        }
    }

    public func inquire(
        receiptNumber: String,
        transactionDate: String,
        originalTerminalId: String = "",
        merchantReference: String = ""
    ) throws -> EcrInquiry {
        guard !receiptNumber.trimmed.isEmpty else {
            throw EcrInvalidArgument("An inquiry needs a receipt number")
        }

        let message = try build(
            .inquiry,
            originalStan: receiptNumber,
            originalTerminalId: originalTerminalId,
            originalDate: transactionDate,
            merchantReference: merchantReference
        )

        return inquiryAnswer(message)
    }

    public func inquireByReference(
        _ originalReference: String,
        transactionDate: String = "",
        originalTerminalId: String = "",
        merchantReference: String = ""
    ) throws -> EcrInquiry {
        guard !originalReference.trimmed.isEmpty else {
            throw EcrInvalidArgument("An inquiry by reference needs the original's reference")
        }

        let message = try build(
            .inquiry,
            originalTerminalId: originalTerminalId,
            originalDate: transactionDate,
            originalReference: originalReference,
            merchantReference: merchantReference
        )

        return inquiryAnswer(message)
    }

    public func receipt(
        receiptNumber: String,
        transactionDate: String,
        originalTerminalId: String = "",
        merchantReference: String = ""
    ) throws -> EcrReceipt {
        guard !receiptNumber.trimmed.isEmpty else {
            throw EcrInvalidArgument("A receipt needs a receipt number")
        }

        let message = try build(
            .receipt,
            originalStan: receiptNumber,
            originalTerminalId: originalTerminalId,
            originalDate: transactionDate,
            merchantReference: merchantReference
        )

        switch exchange(message) {
        case let .failure(failure):
            return .failed(merchantReference: message.merchantReference, failure: failure)
        case let .success(json):
            return EcrTerminal.receipt(
                from: json,
                merchantReference: message.merchantReference
            )
        }
    }

    public func cancel() {
        liveLock.lock()
        cancelled = true
        liveLock.unlock()
        (channel as? TcpEcrChannel)?.cancel()
    }

    private func inquiryAnswer(_ message: EcrMessage) -> EcrInquiry {
        switch exchange(message) {
        case let .failure(failure):
            return .failed(merchantReference: message.merchantReference, failure: failure)
        case let .success(json):
            return EcrTerminal.inquiry(
                from: json,
                merchantReference: message.merchantReference,
                minorUnitDigits: config.minorUnitDigits
            )
        }
    }

    private func lost(_ reference: String, _ failure: EcrFailure) -> EcrResult {
        let plain = EcrResult.failed(
            merchantReference: reference,
            failure: failure,
            recovered: nil
        )

        guard config.autoInquireOnFailure else { return plain }
        guard failure.outcomeUnknown else { return plain }
        guard !reference.isEmpty else { return plain }

        liveLock.lock()
        let abandoned = cancelled
        liveLock.unlock()
        guard !abandoned else { return plain }

        logger.debug("Lost the answer for \(reference) — asking what became of it")

        let found = try? inquireByReference(reference)

        return .failed(merchantReference: reference, failure: failure, recovered: found)
    }

    private func build(
        _ type: EcrTransactionType,
        amount: Decimal? = nil,
        originalStan: String = "",
        originalTerminalId: String = "",
        originalDate: String = "",
        originalReference: String = "",
        merchantReference: String = ""
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
            merchantReference: merchantReference
        )

        logger.debug(
            "Sending \(type.rawValue) \(message.merchantReference) "
                + "to \(channel.endpoint)"
        )
        logger.debug(EcrMessageCodec.text(message.json))
        return message
    }

    private func exchange(_ message: EcrMessage) -> Result<[String: Any], EcrFailure> {
        liveLock.lock()
        if cancelled {
            liveLock.unlock()
            return .failure(.connectionLost("Cancelled before the request was sent"))
        }
        liveLock.unlock()

        do {
            let body = try JSONSerialization.data(withJSONObject: message.json, options: [])
            let reply = try channel.exchange(body: body, timeout: config.responseTimeout)
            let answer = try EcrMessageCodec.parse(reply)
            logger.debug("Received \(EcrMessageCodec.text(answer))")

            if let rejection = untrustworthy(answer, sent: message) {
                logger.debug("Rejected the answer: \(rejection.message)")
                return .failure(rejection)
            }
            return .success(answer)
        } catch is EcrChannelTimeout {
            return .failure(.timeout(
                "The terminal did not answer within \(Int(config.responseTimeout))s. "
                    + "The transaction may still have completed — inquire before retrying."
            ))
        } catch let error as EcrSocket.SocketError {
            return .failure(EcrTerminal.failure(
                for: error,
                endpoint: channel.endpoint,
                responseTimeout: config.responseTimeout
            ))
        } catch let error as EcrFrameError {
            let reason = error.errorDescription ?? "Framing error"
            if reason.contains("empty message") || reason.contains("does not fit") {
                return .failure(.malformed(reason))
            }
            if reason.contains("closed the connection") {
                return .failure(.connectionLost(reason))
            }
            return .failure(.unreachable("\(reason) (\(channel.endpoint))"))
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
            let reason = error.localizedDescription
            if reason.contains("not valid JSON") || reason.contains("empty message") {
                return .failure(.malformed(reason))
            }
            if reason.contains("closed the connection") {
                return .failure(.connectionLost(reason))
            }
            return .failure(.unreachable("\(reason) (\(channel.endpoint))"))
        }
    }

    private func untrustworthy(_ answer: [String: Any], sent: EcrMessage) -> EcrFailure? {
        guard config.signsMessages else { return nil }

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

        guard ecrString(answer, "nonce") == sent.nonce else {
            return .unauthenticated(
                "The answer belongs to a different request. The transaction "
                    + "may still have completed — inquire before retrying."
            )
        }

        return nil
    }

    private static func failure(
        for error: EcrSocket.SocketError,
        endpoint: String,
        responseTimeout: TimeInterval
    ) -> EcrFailure {
        switch error {
        case let .unreachable(message):
            return .unreachable("\(message) (\(endpoint))")
        case .timedOut:
            return .timeout(
                "The terminal did not answer within \(Int(responseTimeout))s. "
                    + "The transaction may still have completed — inquire before retrying."
            )
        case let .closed(message):
            return .connectionLost(message)
        case .cancelled:
            return .connectionLost("The exchange was cancelled by the caller")
        }
    }
}
