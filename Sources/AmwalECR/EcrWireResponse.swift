import Foundation

/// Unified ECR response envelope from the terminal:
///
/// `{ success, responseCode, message, data, errorList, nonce?, secureHash? }`
public struct EcrWireResponse {
    public let success: Bool
    public let responseCode: String
    public let message: String
    public let data: [String: Any]?
    public let errorList: [String]
    public let nonce: String
    public let secureHash: String

    public var merchantReference: String {
        EcrResponseEnvelope.merchantReference(from: data)
    }

    public var terminalSerial: String {
        guard let data = data else { return "" }
        return ecrString(data, "terminalSerial")
    }

    /// User-facing text: `errorList` entries first, then `message`.
    public var displayMessage: String {
        if !errorList.isEmpty { return errorList.joined(separator: "\n") }
        return message
    }

    /// Parses the wire JSON, including legacy flat/nested shapes.
    public static func parse(_ json: [String: Any]) -> EcrWireResponse {
        EcrResponseEnvelope.parse(json)
    }

    /// Reads user-facing text from a raw JSON string: `errorList` first,
    /// then wire `message`. Returns `fallback` when `raw` is empty or invalid.
    public static func displayMessageFromRaw(_ raw: String, fallback: String = "") -> String {
        if raw.isEmpty { return fallback }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return fallback }
        let message = parse(json).displayMessage
        return message.isEmpty ? fallback : message
    }
}
