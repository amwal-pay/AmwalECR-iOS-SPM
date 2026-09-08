import Foundation

/// Redaction helpers for SDK diagnostic output.
enum EcrDiagnostics {
    /// Whether a signing secret is present — never hex slices of the secret.
    static func secretFingerprint(_ hexSecret: String) -> String {
        hexSecret.isEmpty ? "not configured" : "configured"
    }
}
