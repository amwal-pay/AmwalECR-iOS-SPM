import Foundation

/// One opened transport for a validated `EcrSessionPlan`.
///
/// Apps open this through `EcrSessions.open` so LAN / USB / Web Service dispatch
/// lives in one place — sale, inquiry, and recovery then share the same path.
public final class EcrOpenedSession {
    public let plan: EcrSessionPlan
    private let local: EcrTerminal?
    private let web: EcrWebServiceTerminal?

    init(plan: EcrSessionPlan, local: EcrTerminal?, web: EcrWebServiceTerminal?) {
        self.plan = plan
        self.local = local
        self.web = web
    }

    public var usesWebService: Bool { web != nil }

    public var usesLocalTerminal: Bool { local != nil }

    /// Receipt URLs exist only on the local (LAN / USB) protocol.
    public var supportsReceipt: Bool { local != nil }

    /// Whether this session can ask the terminal to describe itself.
    public var supportsSignOn: Bool { local != nil }

    /// Reachability for local links, or `nil` when Web Service — Hub HTTPS has
    /// no pre-flight probe equivalent.
    public func probeReachability() -> EcrReachability? {
        local?.probeReachability()
    }

    public func sale(amount: Decimal, merchantReference: String = "") throws -> EcrResult {
        if let local {
            return try local.sale(amount: amount, merchantReference: merchantReference)
        }
        if let web {
            return web.sale(amount: amount, merchantReference: merchantReference)
        }
        preconditionFailure("Session has no transport")
    }

    public func void(
        receiptNumber: String,
        originalTerminalId: String = "",
        merchantReference: String = ""
    ) throws -> EcrResult {
        if let local {
            return try local.void(
                receiptNumber: receiptNumber,
                originalTerminalId: originalTerminalId,
                merchantReference: merchantReference
            )
        }
        if let web {
            return web.void(
                receiptNumber: receiptNumber,
                merchantReference: merchantReference
            )
        }
        preconditionFailure("Session has no transport")
    }

    public func refund(
        amount: Decimal,
        receiptNumber: String,
        transactionDate: String,
        originalTerminalId: String = "",
        merchantReference: String = ""
    ) throws -> EcrResult {
        if let local {
            return try local.refund(
                amount: amount,
                receiptNumber: receiptNumber,
                transactionDate: transactionDate,
                originalTerminalId: originalTerminalId,
                merchantReference: merchantReference
            )
        }
        if let web {
            return web.refund(
                amount: amount,
                receiptNumber: receiptNumber,
                transactionDate: transactionDate,
                merchantReference: merchantReference
            )
        }
        preconditionFailure("Session has no transport")
    }

    public func inquire(
        receiptNumber: String,
        transactionDate: String,
        originalTerminalId: String = "",
        merchantReference: String = ""
    ) throws -> EcrInquiry {
        if let local {
            return try local.inquire(
                receiptNumber: receiptNumber,
                transactionDate: transactionDate,
                originalTerminalId: originalTerminalId,
                merchantReference: merchantReference
            )
        }
        if let web {
            return web.inquire(
                receiptNumber: receiptNumber,
                transactionDate: transactionDate,
                merchantReference: merchantReference
            )
        }
        preconditionFailure("Session has no transport")
    }

    public func inquireByReference(
        _ originalReference: String,
        transactionDate: String = "",
        originalTerminalId: String = "",
        merchantReference: String = ""
    ) throws -> EcrInquiry {
        if let local {
            return try local.inquireByReference(
                originalReference,
                transactionDate: transactionDate,
                originalTerminalId: originalTerminalId,
                merchantReference: merchantReference
            )
        }
        if let web {
            return web.inquireByReference(
                originalReference: originalReference,
                transactionDate: transactionDate,
                merchantReference: merchantReference
            )
        }
        preconditionFailure("Session has no transport")
    }

    public func receipt(
        receiptNumber: String,
        transactionDate: String,
        originalTerminalId: String = "",
        merchantReference: String = ""
    ) throws -> EcrReceipt {
        guard let local else {
            return .unavailable(
                merchantReference: merchantReference,
                reason: "Receipt fetch is only supported over Wi‑Fi and USB cable ECR",
                raw: ""
            )
        }
        return try local.receipt(
            receiptNumber: receiptNumber,
            transactionDate: transactionDate,
            originalTerminalId: originalTerminalId,
            merchantReference: merchantReference
        )
    }

    /// Asks the terminal what it is and what it will accept.
    ///
    /// Local links only. A Web Service session answers unavailable and sends
    /// nothing: the till already named that terminal when it opened the session.
    public func signOn(merchantReference: String = "") throws -> EcrSignOn {
        guard let local else {
            return .unavailable(
                merchantReference: merchantReference,
                reason: "Sign-on is only supported over Wi‑Fi and USB cable ECR",
                capabilities: EcrTerminalCapabilities(),
                raw: ""
            )
        }
        return try local.signOn(merchantReference: merchantReference)
    }

    /// Asks the terminal to put its receipt away and return to idle.
    ///
    /// Local links only. A Web Service session answers refused and sends
    /// nothing: the terminal is not on the till's counter.
    public func closeReceipt(merchantReference: String = "") throws -> EcrReceiptClosed {
        guard let local else {
            return .refused(
                merchantReference: merchantReference,
                responseCode: "",
                reason: "Closing the receipt is only supported over Wi‑Fi and USB cable ECR",
                raw: ""
            )
        }
        return try local.closeReceipt(merchantReference: merchantReference)
    }

    public func cancel() {
        local?.cancel()
    }
}
