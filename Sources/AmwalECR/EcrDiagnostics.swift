import Foundation

/// Redaction helpers for SDK diagnostic output.
enum EcrDiagnostics {
    static func secretFingerprint(_ hexSecret: String) -> String {
        if hexSecret.isEmpty { return "not configured" }
        if hexSecret.count <= 8 { return "\(hexSecret.count) hex chars" }
        let prefix = hexSecret.prefix(4)
        let suffix = hexSecret.suffix(4)
        return "\(hexSecret.count) hex chars, fingerprint \(prefix)…\(suffix)"
    }
}
