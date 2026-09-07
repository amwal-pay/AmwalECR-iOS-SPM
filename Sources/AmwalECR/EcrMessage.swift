import Foundation

/// A request as it goes on the wire.
struct EcrMessage {

    static let protocolVersion = 1
    private static let stanDigits = 6
    static let merchantReferenceMaxLength = 32
    private static let reservedInReference: Set<Character> = ["&", "="]

    let merchantReference: String
    let json: [String: Any]

    var nonce: String { ecrString(json, "nonce") }

    static func build(
        type: EcrTransactionType,
        config: EcrConfig,
        terminalSerial: String,
        amount: Decimal?,
        originalStan: String,
        originalTerminalId: String,
        originalDate: String,
        originalReference: String = "",
        merchantReference: String = ""
    ) throws -> EcrMessage {
        if let problem = config.secureHashKeyError {
            throw EcrInvalidArgument(problem)
        }

        let reference = try Self.merchantReference(merchantReference)

        var json: [String: Any] = [
            "version": protocolVersion,
            "messageType": type.rawValue,
            "merchantReference": reference,
            "terminalSerial": terminalSerial,
            "currencyCode": config.currencyCode,
            "transactionDateTime": timestamp(),
            "ecrId": config.ecrId,
        ]

        if type.requiresAmount {
            json["amount"] = EcrDecimal.minorUnits(amount, digits: config.minorUnitDigits)
        }
        if type.requiresOriginalStan, !originalStan.trimmed.isEmpty {
            json["stan"] = paddedStan(originalStan)
        }
        if type.allowsOtherTerminal, !originalTerminalId.trimmed.isEmpty {
            json["originalTerminalId"] = originalTerminalId
        }
        if type.requiresOriginalDate, !originalDate.trimmed.isEmpty {
            json["originalTransactionDate"] = originalDate
        }
        if !type.movesMoney, !originalReference.trimmed.isEmpty {
            json["originalMerchantReference"] = try Self.merchantReference(originalReference)
        }

        if config.signsMessages {
            json["nonce"] = SecureHash.newNonce()
            json[SecureHash.field] = try SecureHash.sign(
                SecureHash.compose(json),
                key: config.secureHashKey
            )
        }

        return EcrMessage(merchantReference: reference, json: json)
    }

    static func merchantReference(_ supplied: String) throws -> String {
        let trimmed = supplied.trimmed
        if trimmed.isEmpty { return newReference() }

        guard trimmed.count <= merchantReferenceMaxLength else {
            throw EcrInvalidArgument(
                "A merchant reference is at most \(merchantReferenceMaxLength) "
                    + "characters, was \(trimmed.count)"
            )
        }
        guard trimmed.allSatisfy(isAllowedInReference) else {
            throw EcrInvalidArgument(
                "A merchant reference takes printable ASCII without spaces, "
                    + "'&' or '=': was \"\(trimmed)\""
            )
        }
        return trimmed
    }

    private static func isAllowedInReference(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        return scalar.value >= 0x21 && scalar.value <= 0x7E
            && !reservedInReference.contains(character)
    }

    static func paddedStan(_ stan: String) -> String {
        let digits = String(stan.filter(\.isNumber)).drop { $0 == "0" }
        if digits.isEmpty { return "" }
        return digits.count >= stanDigits
            ? String(digits)
            : String(repeating: "0", count: stanDigits - digits.count) + digits
    }

    static func timestamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }

    static func newReference() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

func ecrString(_ json: [String: Any], _ key: String) -> String {
    guard let value = json[key], !(value is NSNull) else { return "" }
    if let text = value as? String { return text }
    if let number = value as? NSNumber {
        if CFNumberIsFloatType(number) {
            return NSDecimalNumber(decimal: number.decimalValue).stringValue
        }
        return number.stringValue
    }
    return String(describing: value)
}

func ecrFlag(_ json: [String: Any], _ key: String) -> Bool {
    guard let value = json[key], !(value is NSNull) else { return false }
    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue
    }
    if let text = value as? String { return text == "true" }
    return false
}
