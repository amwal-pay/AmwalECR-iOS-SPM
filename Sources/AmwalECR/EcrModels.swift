import Foundation

/// How this till identifies itself and how it talks to a terminal.
///
/// Mirrors `EcrConfig` in the Kotlin SDK, with `TimeInterval` where Kotlin has
/// `kotlin.time.Duration`.
public struct EcrConfig {
    /// The port Amwal POS terminals listen on for ECR requests.
    public static let defaultPort = 9100

    public var ecrId: String = "ECR01"
    public var currencyCode: String = "512"
    public var minorUnitDigits: Int = 3
    public var port: Int = EcrConfig.defaultPort
    public var connectTimeout: TimeInterval = 10
    public var responseTimeout: TimeInterval = 120
    public var probeTimeout: TimeInterval = 3

    /// The secret this till shares with the terminal, as hex.
    ///
    /// Set it and every request is signed and every response is checked.
    /// Required in practice: a terminal refuses everything it cannot verify, so
    /// a till without the key is answered with a security violation and nothing
    /// else. Amwal issues it per terminal — it is not a value to invent, and not
    /// one to commit to a repository.
    ///
    /// Must be an even-length hex string of at least 16 characters, or empty to
    /// send unsigned messages. A key that is neither is reported by
    /// [secureHashKeyError], and every operation is refused rather than sent
    /// unsigned — see `EcrTerminal`.
    public var secureHashKey: String = ""

    /// Whether a transaction whose answer never arrived is followed by an
    /// inquiry, so the till learns what actually happened instead of being left
    /// to guess.
    ///
    /// On by default, and safe: an inquiry reads and nothing more, so repeating
    /// one changes nothing — unlike sending the sale again, which charges the
    /// cardholder twice and is never done automatically. The finding arrives on
    /// the failed result's `recovered`.
    ///
    /// Turn it off only if the till runs its own reconciliation and would rather
    /// not have the extra round trip on a failure.
    public var autoInquireOnFailure: Bool = true

    /// Every setting has the default an Amwal terminal expects, so a till that
    /// only needs the standard port and currency writes `EcrConfig()`.
    public init(
        ecrId: String = "ECR01",
        currencyCode: String = "512",
        minorUnitDigits: Int = 3,
        port: Int = EcrConfig.defaultPort,
        connectTimeout: TimeInterval = 10,
        responseTimeout: TimeInterval = 120,
        probeTimeout: TimeInterval = 3,
        secureHashKey: String = "",
        autoInquireOnFailure: Bool = true
    ) {
        self.ecrId = ecrId
        self.currencyCode = currencyCode
        self.minorUnitDigits = minorUnitDigits
        self.port = port
        self.connectTimeout = connectTimeout
        self.responseTimeout = responseTimeout
        self.probeTimeout = probeTimeout
        self.secureHashKey = secureHashKey
        self.autoInquireOnFailure = autoInquireOnFailure
    }

    /// Whether this till signs what it sends.
    public var signsMessages: Bool { !secureHashKey.isEmpty }

    /// Why [secureHashKey] cannot be used, or nil when it can.
    ///
    /// Swift structs stay assignable after construction, so this is a check a
    /// caller can make rather than something an initialiser could guarantee —
    /// the Kotlin SDK refuses a bad key in `EcrConfig`'s constructor, and the
    /// Flutter host and the Dart API both refuse one before the call is made.
    /// `EcrTerminal` reads it before every operation, so a native till that
    /// never checks still cannot send unsigned traffic by accident.
    public var secureHashKeyError: String? {
        if secureHashKey.isEmpty { return nil }
        if SecureHash.isValidSecret(secureHashKey) { return nil }
        return "The ECR secret must be an even-length hex string of at least "
            + "\(SecureHash.minSecretLength) characters, or empty to send "
            + "unsigned messages."
    }
}

/// Operations a terminal can be asked to run.
public enum EcrTransactionType: String {
    case sale = "SALE"
    case void = "VOID"
    case refund = "REFUND"
    case inquiry = "INQUIRY"
    case receipt = "RECEIPT"

    public var displayName: String {
        switch self {
        case .sale: return "Sale"
        case .void: return "Void"
        case .refund: return "Refund"
        case .inquiry: return "Inquiry"
        case .receipt: return "Receipt"
        }
    }

    /// Whether the caller supplies an amount.
    public var requiresAmount: Bool { self == .sale || self == .refund }

    /// Whether the caller identifies an earlier transaction by receipt number.
    public var requiresOriginalStan: Bool { self != .sale }

    /// Whether the caller supplies the original's date.
    public var requiresOriginalDate: Bool {
        self == .refund || self == .inquiry || self == .receipt
    }

    /// Whether the caller may name a different terminal to act on.
    public var allowsOtherTerminal: Bool { requiresOriginalStan }

    /// Whether the operation moves money. Reading a record does not.
    public var movesMoney: Bool { self == .sale || self == .void || self == .refund }
}

/// What the till should do about an outcome it cannot act on directly.
///
/// Stated by the terminal rather than left for a till to infer from a response
/// code, because the wrong inference is expensive: reading an unknown outcome as
/// a refusal and sending the sale again charges the cardholder twice.
///
/// The raw values are the protocol's own, which are the Kotlin SDK's enum names
/// — one spelling across the terminal, both SDKs and the Flutter channel.
public enum EcrNextStep: String {

    /// The answer settles the matter. Nothing further is needed.
    case none = "NONE"

    /// Ask what became of the transaction, quoting the reference this request
    /// was sent with.
    ///
    /// The reference is the only identifier a till holds before the terminal
    /// answers — a receipt number arrives *in* the answer, which is exactly what
    /// went missing. **Never retry instead.**
    case inquireByMerchantReference = "INQUIRE_BY_MERCHANT_REFERENCE"

    /// Unknown values read as [none]: a till must not act on a step this version
    /// does not understand.
    static func of(_ value: String) -> EcrNextStep {
        EcrNextStep(rawValue: value) ?? .none
    }
}

/// Why an exchange could not be completed.
///
/// The same five cases as the Kotlin SDK's `Failure`, so the two hosts cannot
/// report the same network event differently.
///
/// Conforms to `Error` only so it can be the failure half of a `Result`.
/// Nothing throws one: a failure here is an outcome the caller is handed, not
/// an exception it has to catch — the distinction the whole package rests on.
public enum EcrFailure: Error {
    /// Nothing is listening: wrong address, terminal off, or another network.
    case unreachable(String)
    /// The terminal accepted the request but never answered. The transaction
    /// may still have completed.
    case timeout(String)
    /// The terminal answered with something that could not be read.
    case malformed(String)
    /// The connection broke part way through.
    case connectionLost(String)
    /// The answer could not be shown to have come from the terminal.
    ///
    /// Either it was not signed with this till's key, or it answered a different
    /// request. Both mean something else may have replied on the terminal's port
    /// — so the answer is discarded rather than believed.
    ///
    /// Like [timeout], this is **not** a decline: the terminal may have taken
    /// the payment. Inquire before retrying, and never treat it as a refusal.
    /// Seeing this repeatedly usually means the key on this till and the key on
    /// the terminal do not match.
    case unauthenticated(String)

    public var message: String {
        switch self {
        case let .unreachable(message),
             let .timeout(message),
             let .malformed(message),
             let .connectionLost(message),
             let .unauthenticated(message):
            return message
        }
    }

    /// Whether the request reached the terminal, leaving the outcome unknown.
    ///
    /// The one distinction that matters after a failure. [unreachable] means no
    /// connection was ever made and nothing was attempted, so there is nothing
    /// to reconcile. Everything else means the request went out and the terminal
    /// may have acted on it, whatever came back — or did not.
    public var outcomeUnknown: Bool {
        switch self {
        case .unreachable: return false
        case .timeout, .malformed, .connectionLost, .unauthenticated: return true
        }
    }
}

/// Money was taken.
public struct EcrApproved {
    /// The reference the transaction was sent with. See
    /// `EcrResult.merchantReferenceId`.
    public let merchantReferenceId: String
    /// In major units, e.g. `"1.234"`.
    public let amount: String
    public let responseCode: String
    public let rrn: String
    public let authCode: String
    /// Masked, never the full number. May be empty.
    public let maskedPan: String
    /// Set when the bank authorised less than was asked for. Not a refusal.
    public let partialApproval: Bool
    /// What was asked for, when `partialApproval` is set.
    public let requestedAmount: String
    /// The terminal's full answer as JSON text.
    public let raw: String

    public init(
        merchantReferenceId: String,
        amount: String,
        responseCode: String,
        rrn: String,
        authCode: String,
        maskedPan: String,
        partialApproval: Bool,
        requestedAmount: String,
        raw: String
    ) {
        self.merchantReferenceId = merchantReferenceId
        self.amount = amount
        self.responseCode = responseCode
        self.rrn = rrn
        self.authCode = authCode
        self.maskedPan = maskedPan
        self.partialApproval = partialApproval
        self.requestedAmount = requestedAmount
        self.raw = raw
    }
}

/// The terminal answered and no money was taken.
public struct EcrDeclined {
    /// The reference the transaction was sent with.
    public let merchantReferenceId: String
    public let responseCode: String
    /// The backend's own words where it gave any.
    public let reason: String
    /// What to do about it.
    ///
    /// Usually [EcrNextStep.none] — a decline says plainly that no money moved —
    /// but the terminal can report that it does not actually know, and then this
    /// asks for an inquiry rather than a retry.
    public let nextStep: EcrNextStep
    public let raw: String

    public init(
        merchantReferenceId: String,
        responseCode: String,
        reason: String,
        nextStep: EcrNextStep = .none,
        raw: String
    ) {
        self.merchantReferenceId = merchantReferenceId
        self.responseCode = responseCode
        self.reason = reason
        self.nextStep = nextStep
        self.raw = raw
    }
}

/// How a transaction ended.
public enum EcrResult {
    case approved(EcrApproved)
    case declined(EcrDeclined)
    /// The exchange itself failed, so the outcome is unknown.
    ///
    /// `recovered` is what the terminal said when asked afterwards, or nil when
    /// it was not asked. The SDK follows a lost exchange with an inquiry by
    /// reference — see `EcrConfig.autoInquireOnFailure` — because that is the
    /// only way to learn an outcome whose answer never arrived, and the
    /// alternative a till reaches for is sending the sale again.
    case failed(merchantReferenceId: String, failure: EcrFailure, recovered: EcrInquiry?)

    /// The reference the transaction was sent with, so a caller can match the
    /// outcome both to what it sent and to its own record of the sale.
    ///
    /// The caller's own reference when one was given, otherwise the one the SDK
    /// generated. Either way it is worth storing: it is what names this
    /// transaction to the terminal afterwards.
    public var merchantReferenceId: String {
        switch self {
        case let .approved(approved): return approved.merchantReferenceId
        case let .declined(declined): return declined.merchantReferenceId
        case let .failed(reference, _, _): return reference
        }
    }

    /// What the terminal said when asked what became of the transaction, for a
    /// [failed] result that was followed up. Nil for every other outcome.
    ///
    /// `.found` settles it: the transaction exists, and `EcrTransaction.status`
    /// says what became of it. Anything else means it is still unknown, and
    /// money may still have moved.
    public var recovered: EcrInquiry? {
        guard case let .failed(_, _, recovered) = self else { return nil }
        return recovered
    }

    /// Whether the follow-up actually found the transaction, so this is no
    /// longer an unknown outcome — only a delivery that failed.
    public var settled: Bool {
        guard case .some(.found) = recovered else { return false }
        return true
    }

    /// What the till should do next.
    ///
    /// [EcrNextStep.inquireByMerchantReference] for every [failed] result: no
    /// answer arrived at all, so nothing about it can say the transaction did
    /// not happen. A decline carries whatever the terminal stated.
    public var nextStep: EcrNextStep {
        switch self {
        case .approved: return .none
        case let .declined(declined): return declined.nextStep
        case .failed: return .inquireByMerchantReference
        }
    }
}

/// A transaction as the terminal's backend records it.
public struct EcrTransaction {
    public let transactionId: String
    public let stan: String
    public let type: String
    public let status: String
    public let amount: String
    public let totalAmount: String
    public let currency: String
    public let transactionTime: String
    public let maskedPan: String
    public let cardHolderName: String
    public let rrn: String
    public let authCode: String
    public let batchId: String
    public let terminalId: String
    public let isRefunded: Bool
    public let canVoid: Bool
    public let canRefund: Bool

    public init(
        transactionId: String,
        stan: String,
        type: String,
        status: String,
        amount: String,
        totalAmount: String,
        currency: String,
        transactionTime: String,
        maskedPan: String,
        cardHolderName: String,
        rrn: String,
        authCode: String,
        batchId: String,
        terminalId: String,
        isRefunded: Bool,
        canVoid: Bool,
        canRefund: Bool
    ) {
        self.transactionId = transactionId
        self.stan = stan
        self.type = type
        self.status = status
        self.amount = amount
        self.totalAmount = totalAmount
        self.currency = currency
        self.transactionTime = transactionTime
        self.maskedPan = maskedPan
        self.cardHolderName = cardHolderName
        self.rrn = rrn
        self.authCode = authCode
        self.batchId = batchId
        self.terminalId = terminalId
        self.isRefunded = isRefunded
        self.canVoid = canVoid
        self.canRefund = canRefund
    }
}

/// The answer to "what became of this transaction".
///
/// Kept apart from [EcrResult] because it reports on a transaction rather than
/// performing one: an inquiry that succeeds says nothing about whether money
/// moved — that is `EcrTransaction.status`.
public enum EcrInquiry {
    case found(merchantReferenceId: String, transaction: EcrTransaction, raw: String)
    case notFound(merchantReferenceId: String, reason: String, raw: String)
    case failed(merchantReferenceId: String, failure: EcrFailure)

    /// The reference the inquiry was sent with.
    public var merchantReferenceId: String {
        switch self {
        case let .found(reference, _, _),
             let .notFound(reference, _, _),
             let .failed(reference, _):
            return reference
        }
    }
}

/// A transaction's e-receipt.
public enum EcrReceipt {
    case ready(merchantReferenceId: String, url: String, raw: String)
    case unavailable(merchantReferenceId: String, reason: String, raw: String)
    case failed(merchantReferenceId: String, failure: EcrFailure)

    /// The reference the request was sent with.
    public var merchantReferenceId: String {
        switch self {
        case let .ready(reference, _, _),
             let .unavailable(reference, _, _),
             let .failed(reference, _):
            return reference
        }
    }
}

/// The arguments cannot be used, and nothing was sent.
public struct EcrInvalidArgument: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}
