import Foundation

/// Reads the unified ECR response envelope:
///
/// `{ success, responseCode, message, data, errorList, nonce?, secureHash? }`
///
/// Legacy answers that still nest the envelope under `ecrResponse`, or carry
/// flat `approved` / `responseMessage` fields, are normalised here.
enum EcrResponseEnvelope {

    private static let approvedCode = "00"

    static func parse(_ json: [String: Any]) -> EcrWireResponse {
        EcrWireResponse(
            success: isSuccess(json),
            responseCode: responseCode(json),
            message: wireMessage(json),
            data: data(json),
            errorList: errorList(json),
            nonce: ecrString(json, "nonce"),
            secureHash: ecrString(json, SecureHash.field)
        )
    }

    static func root(_ json: [String: Any]) -> [String: Any] {
        if json["success"] != nil || json["data"] != nil { return json }
        if let nested = json["ecrResponse"] as? [String: Any] { return nested }
        return json
    }

    static func isSuccess(_ json: [String: Any]) -> Bool {
        let rootObj = root(json)
        if let success = strictBool(rootObj["success"]) { return success }
        if let approved = strictBool(json["approved"]) { return approved }
        return responseCode(json) == approvedCode
    }

    static func responseCode(_ json: [String: Any]) -> String {
        let code = ecrString(root(json), "responseCode")
        if !code.isEmpty { return code }
        return ecrString(json, "responseCode")
    }

    /// Top-level `message` / legacy `responseMessage` from the wire payload.
    static func wireMessage(_ json: [String: Any]) -> String {
        let rootObj = root(json)
        let message = ecrString(rootObj, "message")
        if !message.isEmpty { return message }
        return ecrString(json, "responseMessage")
    }

    /// User-facing text: `errorList` entries first, then wire message.
    static func displayMessage(_ json: [String: Any]) -> String {
        let rootObj = root(json)
        let errors = errorList(rootObj)
        if !errors.isEmpty { return errors.joined(separator: "\n") }
        return wireMessage(json)
    }

    static func data(_ json: [String: Any]) -> [String: Any]? {
        root(json)["data"] as? [String: Any]
    }

    static func errorList(_ json: [String: Any]) -> [String] {
        let rootObj = root(json)
        let raw = rootObj["errorList"] ?? json["errorList"]
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { element -> String? in
            guard !(element is NSNull) else { return nil }
            if let text = element as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let number = element as? NSNumber {
                return number.stringValue
            }
            return nil
        }
    }

    /// Resolves merchant reference from response data, accepting legacy keys.
    static func merchantReference(from data: [String: Any]?) -> String {
        guard let data = data else { return "" }
        let reference = ecrString(data, "merchantReference")
        if !reference.isEmpty { return reference }
        let legacyId = ecrString(data, "merchantReferenceId")
        if !legacyId.isEmpty { return legacyId }
        return ecrString(data, "requestId")
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let value = value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        switch value as? String {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
