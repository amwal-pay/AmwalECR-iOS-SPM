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
    /// **The app owns persistence and chooses which secret to pass** for the
    /// selected terminal mode (LAN vs Web Service use different secrets and
    /// signing formats, but both are supplied through this single field).
    /// LAN ECR signs sorted `key=value` pairs; Web Service ECR signs the JSON
    /// request body with HMAC-SHA256 under the hex-decoded key.
    public var secureHashKey: String = ""
    public var merchantId: String = ""
    public var terminalId: String = ""
    public var environment: EcrEnvironment = .default
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
        merchantId: String = "",
        terminalId: String = "",
        environment: EcrEnvironment = .default,
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
        self.merchantId = merchantId
        self.terminalId = terminalId
        self.environment = environment
        self.autoInquireOnFailure = autoInquireOnFailure
    }

    /// Whether this till signs what it sends.
    public var signsMessages: Bool { !secureHashKey.isEmpty }

    /// Whether `key` is acceptable for `secureHashKey`.
    public static func isValidSecureHashKey(_ key: String) -> Bool {
        key.isEmpty || SecureHash.isValidSecret(key)
    }

    /// Why [secureHashKey] cannot be used, or nil when it can.
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

    /// The value carried in the message's `messageType` field.
    public var messageType: String { rawValue }

    public var displayName: String {
        switch self {
        case .sale: return "Sale"
        case .void: return "Void"
        case .refund: return "Refund"
        case .inquiry: return "Inquiry"
        case .receipt: return "Receipt"
        }
    }

    /// The operations an operator picks from, in the order a till usually
    /// offers them. `receipt` is absent by design.
    public static let menuOptions: [EcrTransactionType] = [.sale, .void, .refund, .inquiry]

    public var requiresAmount: Bool { self == .sale || self == .refund }
    public var requiresOriginalStan: Bool { self != .sale }
    public var requiresOriginalDate: Bool {
        self == .refund || self == .inquiry || self == .receipt
    }
    public var allowsOtherTerminal: Bool { requiresOriginalStan }
    public var movesMoney: Bool { self == .sale || self == .void || self == .refund }
}

/// What the till should do about an outcome it cannot act on directly.
public enum EcrNextStep: String {
    case none = "NONE"
    case inquireByMerchantReference = "INQUIRE_BY_MERCHANT_REFERENCE"

    static func of(_ value: String) -> EcrNextStep {
        EcrNextStep(rawValue: value) ?? .none
    }
}

/// Why an exchange could not be completed.
public enum EcrFailure: Error {
    case unreachable(String)
    case timeout(String)
    case malformed(String)
    case connectionLost(String)
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

    public var outcomeUnknown: Bool {
        switch self {
        case .unreachable: return false
        case .timeout, .malformed, .connectionLost, .unauthenticated: return true
        }
    }
}

/// Money was taken.
public struct EcrApproved {
    public let merchantReference: String
    public let amount: String
    public let responseCode: String
    public let rrn: String
    public let authCode: String
    public let maskedPan: String
    public let partialApproval: Bool
    public let requestedAmount: String
    public let raw: String

    public init(
        merchantReference: String,
        amount: String,
        responseCode: String,
        rrn: String,
        authCode: String,
        maskedPan: String,
        partialApproval: Bool,
        requestedAmount: String,
        raw: String
    ) {
        self.merchantReference = merchantReference
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
    public let merchantReference: String
    public let responseCode: String
    public let reason: String
    public let nextStep: EcrNextStep
    public let raw: String

    public init(
        merchantReference: String,
        responseCode: String,
        reason: String,
        nextStep: EcrNextStep = .none,
        raw: String
    ) {
        self.merchantReference = merchantReference
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
    case failed(merchantReference: String, failure: EcrFailure, recovered: EcrInquiry?)

    public var merchantReference: String {
        switch self {
        case let .approved(approved): return approved.merchantReference
        case let .declined(declined): return declined.merchantReference
        case let .failed(reference, _, _): return reference
        }
    }

    public var recovered: EcrInquiry? {
        guard case let .failed(_, _, recovered) = self else { return nil }
        return recovered
    }

    public var settled: Bool {
        guard case .some(.found) = recovered else { return false }
        return true
    }

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
    public let partialApproval: Bool
    public let authorizedAmount: String
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
        partialApproval: Bool = false,
        authorizedAmount: String = "",
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
        self.partialApproval = partialApproval
        self.authorizedAmount = authorizedAmount
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
public enum EcrInquiry {
    case found(merchantReference: String, transaction: EcrTransaction, raw: String)
    case notFound(merchantReference: String, reason: String, raw: String)
    case failed(merchantReference: String, failure: EcrFailure)

    public var merchantReference: String {
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
    case ready(merchantReference: String, url: String, raw: String)
    case unavailable(merchantReference: String, reason: String, raw: String)
    case failed(merchantReference: String, failure: EcrFailure)

    public var merchantReference: String {
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
