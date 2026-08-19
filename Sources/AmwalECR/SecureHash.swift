import Foundation
import CommonCrypto

/// Message authentication for the ECR link.
///
/// The Swift counterpart of the Kotlin SDK's `SecureHash`, rule for rule. A
/// shared secret proves two things at once: that a request came from a till that
/// holds the key, and that nothing on the network altered it on the way. Without
/// it any device on the shop Wi-Fi can open the terminal's port and issue a
/// refund, because the terminal has no other way to tell callers apart.
///
/// Built on CommonCrypto rather than CryptoKit so the SDK keeps its iOS 12
/// floor — CryptoKit needs 13.
enum SecureHash {

    /// Field carrying the signature. Never part of what is signed.
    static let field = "secureHash"

    private static let nonceBytes = 16

    /// 64 bits is the shortest key worth calling a secret.
    static let minSecretLength = 16

    /// The exact bytes both sides agree to sign.
    ///
    /// Rules, which the Kotlin SDK's `SecureHash.compose` and the terminal's
    /// `EcrSecureHash.compose` repeat verbatim:
    ///
    ///  1. Take every top-level entry whose value is a string, number or boolean.
    ///  2. Drop nulls, nested objects and arrays.
    ///  3. Drop [field] itself.
    ///  4. Sort what remains by key.
    ///  5. Join as `key=value`, separated by `&`.
    ///
    /// Nested values are left out on purpose. `ecrResponse` carries the
    /// backend's own record through untouched, and two JSON libraries cannot be
    /// relied on to serialise a nested object identically — a signature that
    /// depended on key order inside a passthrough field would fail for reasons
    /// that have nothing to do with tampering. Every field a till acts on
    /// (`approved`, `responseCode`, `amount`, `rrn`, the reference and the
    /// nonce) is a top-level scalar and is covered.
    ///
    /// Keys are protocol field names, so ASCII: sorting them with Swift's `<`
    /// gives the same order as Kotlin's `sortedBy`, which sorts by UTF-16 code
    /// unit. The two would part company on non-ASCII keys, which the protocol
    /// does not have.
    static func compose(_ json: [String: Any]) -> String {
        json
            .compactMap { key, value -> (key: String, text: String)? in
                guard key != field, let text = scalar(value) else { return nil }
                return (key, text)
            }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.text)" }
            .joined(separator: "&")
    }

    /// A scalar as the signature writes it, or nil for anything not signed.
    ///
    /// The boolean check comes before the number check on purpose: JSON
    /// booleans arrive as `NSNumber`, and `NSNumber(1) as? Bool` is `true` — so
    /// testing for `Bool` first would sign the integer `1` as "true".
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
        // Dictionaries, arrays and anything else this SDK does not put on the
        // wire. Left out rather than stringified: a value whose text form is
        // not agreed between the two sides can only make signatures disagree.
        return nil
    }

    /// HMAC-SHA256 of [message] under [key], as uppercase hex.
    ///
    /// Throws when the key is not hex — see [decodeKey].
    static func sign(_ message: String, key: String) throws -> String {
        let secret = try decodeKey(key)
        let body = Array(message.utf8)

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(
            CCHmacAlgorithm(kCCHmacAlgSHA256),
            secret, secret.count,
            body, body.count,
            &digest
        )
        return hex(digest)
    }

    /// Whether [json] carries a signature that matches [key].
    ///
    /// A key that is not hex answers `false` rather than throwing: this is the
    /// path an answer arrives on, and an answer that cannot be checked is
    /// simply not trustworthy — which is what the caller has to act on either
    /// way.
    static func verify(_ json: [String: Any], key: String) -> Bool {
        let presented = ecrString(json, field)
        guard !presented.isEmpty else { return false }
        guard let expected = try? sign(compose(json), key: key) else { return false }
        return constantTimeEquals(presented, expected)
    }

    /// A fresh 128-bit nonce, as uppercase hex.
    static func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: nonceBytes)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // The system CSPRNG does not fail in practice. If it ever does,
            // a predictable nonce is worse than no transaction: a captured
            // message could be replayed against the terminal.
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return hex(bytes)
    }

    /// Whether a string is usable as the shared secret.
    ///
    /// Even-length hex of at least [minSecretLength] characters, matching the
    /// Kotlin SDK's `EcrConfig` check.
    static func isValidSecret(_ key: String) -> Bool {
        key.count >= minSecretLength
            && key.count % 2 == 0
            && key.allSatisfy(\.isHexDigit)
    }

    /// The key as bytes.
    ///
    /// Hex, matching the convention the POS already uses for its backend secret
    /// — a 32-character key is 16 bytes, not 32. A key that is not hex is
    /// rejected rather than quietly read as text, because the two sides would
    /// then disagree about the bytes and every message would fail to verify
    /// with nothing to show why.
    private static func decodeKey(_ key: String) throws -> [UInt8] {
        guard key.count >= 2, key.count % 2 == 0, key.allSatisfy(\.isHexDigit) else {
            throw EcrInvalidArgument(
                "The ECR secret must be an even-length hex string, e.g. "
                    + "\"881dc200c9833da726e9376c2e32cff7\""
            )
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

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Compares without leaking where two signatures first differ.
    ///
    /// Both are digests of the same length, so this is belt-and-braces rather
    /// than load-bearing — but a signature comparison is exactly the place the
    /// habit is worth keeping.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let left = Array(a.uppercased().utf8)
        let right = Array(b.uppercased().utf8)
        guard left.count == right.count else { return false }

        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
