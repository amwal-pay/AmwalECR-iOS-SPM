import Foundation
import CommonCrypto

/// Web Service ECR request signing.
enum WebServiceSecureHash {
    static let field = "secureHashValue"
    static let keyLabel = "Web Service secure hash key"

    private static let algorithm = CCHmacAlgorithm(kCCHmacAlgSHA256)

    static func calcHash(_ message: String, secret: String) -> String {
        if secret.isEmpty { return "" }
        guard let secretBytes = try? decodeHexKey(secret) else { return "" }
        let body = Array(message.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        secretBytes.withUnsafeBufferPointer { secretBuffer in
            CCHmac(
                algorithm,
                secretBuffer.baseAddress, secretBuffer.count,
                body, body.count,
                &digest
            )
        }
        return hexUpper(digest)
    }

    static func sign(payload: String, secretKey: String) -> String {
        calcHash(payload, secret: secretKey)
    }

    static func sign(_ body: [String: Any], secretKey: String) -> String {
        calcHash(compose(unsigned(body)), secret: secretKey)
    }

    static func withHash(_ body: [String: Any], secretKey: String) throws -> [String: Any] {
        if secretKey.isEmpty { return body }
        var unsignedBody = unsigned(body)
        let payloadToSign = compose(unsignedBody)
        let hash = calcHash(payloadToSign, secret: secretKey)
        guard !hash.isEmpty else {
            throw EcrInvalidArgument(
                "Web Service secureHashValue could not be computed — check the secure hash key"
            )
        }
        unsignedBody[field] = hash
        return unsignedBody
    }

    static func payloadString(_ body: [String: Any]) -> String {
        compose(unsigned(body))
    }

    static func compose(_ json: [String: Any]) -> String {
        json
            .compactMap { key, value -> (String, String)? in
                guard key != field, let text = scalar(value) else { return nil }
                return (key, text)
            }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    private static func unsigned(_ body: [String: Any]) -> [String: Any] {
        body.filter { $0.key != field }
    }

    private static func scalar(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            if CFNumberIsFloatType(number) {
                return NSDecimalNumber(decimal: number.decimalValue).stringValue
            }
            return number.stringValue
        }
        return nil
    }

    private static func decodeHexKey(_ key: String) throws -> [UInt8] {
        guard key.count >= 2, key.count % 2 == 0, key.allSatisfy(\.isHexDigit) else {
            throw EcrInvalidArgument("The Web Service secret must be an even-length hex string")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(key.count / 2)
        var pair = ""
        for character in key {
            pair.append(character)
            if pair.count == 2 {
                bytes.append(UInt8(pair, radix: 16) ?? 0)
                pair = ""
            }
        }
        return bytes
    }

    private static func hexUpper(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
