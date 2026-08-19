import Foundation

/// A request as it goes on the wire.
///
/// Mirrors the Kotlin SDK's `EcrMessage`. Fields that do not apply to the
/// operation are **left out entirely**, not sent empty — the terminal reads a
/// field's presence as meaning the operation uses it, so an empty `stan` on a
/// sale is not the same message as no `stan` at all.
struct EcrMessage {

    /// Bumped when the message format changes in a way older terminals cannot
    /// read.
    static let protocolVersion = 1

    /// Width the terminal stores and looks up receipt numbers by.
    private static let stanDigits = 6

    /// Longest reference the terminal will carry. Generous enough for the order
    /// numbers and GUIDs tills actually use, short enough that it cannot be used
    /// to push an unbounded string through the terminal.
    static let merchantReferenceMaxLength = 32

    /// Characters kept out of a reference because a signed message builds its
    /// input as `key=value&key=value`; a reference carrying a separator could
    /// make two different messages hash alike.
    private static let reservedInReference: Set<Character> = ["&", "="]

    let merchantReferenceId: String
    let json: [String: Any]

    /// The nonce this request went out with, empty when unsigned.
    ///
    /// Kept so the answer can be checked against it: a response carrying a
    /// different nonce is an answer to some other request, which is what an old
    /// response replayed onto this connection would look like.
    var nonce: String { ecrString(json, "nonce") }

    /// Builds one request.
    ///
    /// Throws [EcrInvalidArgument] when a supplied reference cannot be carried,
    /// or when the configured secret is not usable — in both cases before
    /// anything is sent.
    static func build(
        type: EcrTransactionType,
        config: EcrConfig,
        terminalSerial: String,
        amount: Decimal?,
        originalStan: String,
        originalTerminalId: String,
        originalDate: String,
        originalReference: String = "",
        merchantReferenceId: String = ""
    ) throws -> EcrMessage {
        // Caught here rather than at the first sale: a key with a stray space or
        // a missing character otherwise fails on the shop floor, as a decline
        // the cashier cannot explain. The Kotlin SDK refuses it in `EcrConfig`'s
        // constructor; a Swift struct stays assignable, so the check belongs at
        // the last point before the key is used.
        if let problem = config.secureHashKeyError {
            throw EcrInvalidArgument(problem)
        }

        let reference = try merchantReference(merchantReferenceId)

        var json: [String: Any] = [
            "version": protocolVersion,
            "messageType": type.rawValue,
            "merchantReferenceId": reference,
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
        // Names the transaction being looked up, in place of its receipt
        // number. Only a read-only type may: acting on a transaction still goes
        // by the number on the printed receipt, which is what the operator at
        // the terminal is reading.
        if !type.movesMoney, !originalReference.trimmed.isEmpty {
            json["originalMerchantReference"] = try merchantReference(originalReference)
        }

        // The nonce is what makes a captured message useless a second time: the
        // terminal remembers the ones it has seen and refuses a repeat. It is
        // only meaningful alongside a signature, since an attacker could
        // otherwise just change it.
        if config.signsMessages {
            json["nonce"] = SecureHash.newNonce()
            json[SecureHash.field] = try SecureHash.sign(
                SecureHash.compose(json),
                key: config.secureHashKey
            )
        }

        return EcrMessage(merchantReferenceId: reference, json: json)
    }

    /// The reference to put on the message: the caller's own, or one made here
    /// when they did not supply one.
    ///
    /// A till that already numbers its orders should pass that number, so the
    /// same string identifies the transaction in its books, in the terminal's
    /// records and in any later inquiry — no mapping table to keep. A till with
    /// nothing to link to leaves it blank and gets the generated reference back
    /// on the result.
    ///
    /// Throws [EcrInvalidArgument] if the reference is too long or carries
    /// characters the wire format cannot represent unambiguously.
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

    /// 0x21..0x7E is printable ASCII with the space (0x20) left out: a reference
    /// is copied into logs and receipts, where a leading or doubled space is
    /// invisible and turns two references into one.
    private static func isAllowedInReference(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        return scalar.value >= 0x21 && scalar.value <= 0x7E
            && !reservedInReference.contains(character)
    }

    /// The terminal stores receipt numbers padded; an operator types "24".
    static func paddedStan(_ stan: String) -> String {
        let digits = String(stan.filter(\.isNumber)).drop { $0 == "0" }
        if digits.isEmpty { return "" }
        return digits.count >= stanDigits
            ? String(digits)
            : String(repeating: "0", count: stanDigits - digits.count) + digits
    }

    /// `yyyyMMddHHmmss` on the till's clock.
    ///
    /// POSIX locale and the current calendar's time zone: a device set to a
    /// non-Gregorian calendar must still send a Gregorian timestamp, or the
    /// terminal files the transaction under a year that does not exist.
    static func timestamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }

    /// Twelve uppercase hex characters, as the Kotlin SDK generates.
    static func newReference() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Reads a string field, whatever JSON type it arrived as.
///
/// A field the terminal sent as JSON `null` reads as absent rather than as the
/// text "null" — the same rule the Kotlin SDK's `JsonObject.string` applies.
/// Numbers are rendered without a decimal point where they are whole, so a
/// `terminalId` of 31629 does not read as "31629.0" on one platform and
/// "31629" on the other.
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

/// Reads a boolean field.
///
/// Strict, matching the Kotlin SDK's `toBooleanStrictOrNull`: a real JSON
/// boolean, or the exact text `"true"`. A numeric `1` is **not** true — the
/// backend does not send flags that way, and accepting it here would make the
/// two platforms disagree about a payload neither should ever see.
func ecrFlag(_ json: [String: Any], _ key: String) -> Bool {
    guard let value = json[key], !(value is NSNull) else { return false }
    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue
    }
    if let text = value as? String { return text == "true" }
    return false
}
