import Foundation

/// Amounts, converted between what a till says and what the wire carries.
///
/// Mirrors the Kotlin SDK's `EcrMessage.minorUnits` and `majorUnits` exactly,
/// including the rounding: half up, so 1.2345 at three decimal places is 1235
/// baisa on both platforms rather than on one. Two platforms that disagree
/// about a rounding boundary is a difference nobody finds until it is a
/// reconciliation query.
///
/// Everything here is `Decimal`, never `Double`. A binary float cannot hold
/// 1.234, and an amount that is off by a thousandth is a wrong charge.
public enum EcrDecimal {

    /// Round half away from zero — `NSRoundPlain`, which is what
    /// `RoundingMode.HALF_UP` means on the Kotlin side.
    private static func handler(scale: Int) -> NSDecimalNumberHandler {
        NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: Int16(scale),
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
    }

    /// Parses a plain decimal string, or `nil` if it is not one.
    ///
    /// Rejects exponents, grouping separators and anything with a sign. Locale
    /// independent on purpose: an Arabic-locale device must send the same
    /// digits as an English one.
    public static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        for part in parts where part.isEmpty || !part.allSatisfy(\.isNumber) {
            return nil
        }
        // `Decimal(string:locale:)` with the POSIX locale so "." is the point
        // whatever the device is set to.
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Amount in minor units, zero-padded to 12 digits — ISO 8583 field 4.
    ///
    /// A `nil` amount is twelve zeros, matching the Kotlin SDK: the field is
    /// present but says nothing, for an operation that carries no amount.
    public static func minorUnits(_ amount: Decimal?, digits: Int) -> String {
        guard let amount = amount else { return String(repeating: "0", count: 12) }

        let scaled = NSDecimalNumber(decimal: amount)
            .multiplying(byPowerOf10: Int16(digits))
            .rounding(accordingToBehavior: handler(scale: 0))

        let text = scaled.stringValue
        return text.count >= 12 ? text : String(repeating: "0", count: 12 - text.count) + text
    }

    /// Reports minor units as major ones: `"000000000365"` at 3 digits is
    /// `"0.365"`.
    ///
    /// Anything that is not a whole number of minor units is passed through as
    /// it arrived rather than mangled into a wrong figure — a terminal that
    /// sends `"1.234"` is already reporting major units, and converting again
    /// would report 0.001234 and be silently wrong.
    public static func majorUnits(_ minorUnits: String, digits: Int) -> String {
        guard !minorUnits.isEmpty else { return "" }

        let negative = minorUnits.hasPrefix("-")
        let body = negative ? String(minorUnits.dropFirst()) : minorUnits
        guard !body.isEmpty, body.allSatisfy(\.isNumber) else { return minorUnits }

        guard let value = Decimal(string: body, locale: Locale(identifier: "en_US_POSIX")) else {
            return minorUnits
        }

        let shifted = NSDecimalNumber(decimal: value)
            .multiplying(byPowerOf10: Int16(-digits))

        return (negative ? "-" : "") + plainString(shifted, digits: digits)
    }

    /// Writes a decimal with exactly `digits` places and no grouping, the way
    /// `BigDecimal.toPlainString` does after `movePointLeft`.
    private static func plainString(_ value: NSDecimalNumber, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.minimumIntegerDigits = 1
        formatter.roundingMode = .halfUp
        return formatter.string(from: value) ?? value.stringValue
    }
}
