import Foundation

/// How a terminal is attached, as its TMS profile says.
public enum EcrTerminalTransport: Int {
    case unknown = 0
    case usbCable = 1
    case wifi = 2
    case bluetooth = 3
    case webService = 4

    public var ecrMode: Int { rawValue }

    /// A mode this version does not know stays [unknown] rather than being
    /// guessed into a transport the till can drive.
    public static func fromMode(_ mode: Int?) -> EcrTerminalTransport {
        guard let mode, let known = EcrTerminalTransport(rawValue: mode) else {
            return .unknown
        }
        return known
    }
}

/// One operation a till may send, and the amounts it may send with it.
public struct EcrPermittedTransaction {
    public let type: EcrTransactionType
    /// Major units. Empty when the terminal set no limit.
    public let minAmount: String
    public let maxAmount: String

    public init(type: EcrTransactionType, minAmount: String = "", maxAmount: String = "") {
        self.type = type
        self.minAmount = minAmount
        self.maxAmount = maxAmount
    }
}

/// A terminal's configuration, as it reports it.
public struct EcrTerminalCapabilities {
    public let available: Bool
    public let reason: String
    public let transport: EcrTerminalTransport
    public let terminalName: String
    public let currencyCode: String
    public let minorUnitDigits: Int
    public let eReceipt: Bool
    public let physicalReceipt: Bool
    public let permitted: [EcrPermittedTransaction]

    public init(
        available: Bool = false,
        reason: String = "",
        transport: EcrTerminalTransport = .unknown,
        terminalName: String = "",
        currencyCode: String = "",
        minorUnitDigits: Int = 0,
        eReceipt: Bool = false,
        physicalReceipt: Bool = false,
        permitted: [EcrPermittedTransaction] = []
    ) {
        self.available = available
        self.reason = reason
        self.transport = transport
        self.terminalName = terminalName
        self.currencyCode = currencyCode
        self.minorUnitDigits = minorUnitDigits
        self.eReceipt = eReceipt
        self.physicalReceipt = physicalReceipt
        self.permitted = permitted
    }

    public func permits(_ type: EcrTransactionType) -> Bool {
        permitted.contains { $0.type == type }
    }

    public func limitsFor(_ type: EcrTransactionType) -> EcrPermittedTransaction? {
        permitted.first { $0.type == type }
    }
}

/// What the terminal said when asked what it is and what it will accept.
///
/// Local links only. A Web Service terminal is reached through Amwal, so a
/// till configured for it already knows the one thing a sign-on would say
/// about the link.
public enum EcrSignOn {
    case available(merchantReference: String, capabilities: EcrTerminalCapabilities, raw: String)
    case unavailable(
        merchantReference: String,
        reason: String,
        capabilities: EcrTerminalCapabilities,
        raw: String
    )
    case failed(merchantReference: String, failure: EcrFailure)

    public var merchantReference: String {
        switch self {
        case let .available(reference, _, _),
             let .unavailable(reference, _, _, _),
             let .failed(reference, _):
            return reference
        }
    }
}
