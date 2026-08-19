import Foundation

/// Where the SDK writes its diagnostics.
///
/// The counterpart of the Kotlin SDK's `EcrLogger`. It has no logger of its own,
/// so a client routes this wherever it already logs — `OSLog`, a file, its own
/// crash reporter — and inherits no dependency it did not ask for:
///
/// ```swift
/// var config = EcrConfig()
/// let terminal = EcrTerminal(
///     host: host,
///     serialNumber: serial,
///     config: config,
///     logger: EcrLogger { message in os_log("%{public}@", message) }
/// )
/// ```
///
/// Messages contain request and response payloads, which include the masked card
/// number. They are safe to keep, but treat them as transaction records — and
/// note that a signed message's `secureHash` appears in them too, so a log that
/// is shipped off the device carries a signature, though never the key.
public struct EcrLogger {

    private let write: (String) -> Void

    /// Wraps a function. `EcrLogger { print($0) }` is the whole of it.
    public init(_ write: @escaping (String) -> Void) {
        self.write = write
    }

    public func debug(_ message: String) {
        write(message)
    }

    /// Discards everything. The default.
    public static let none = EcrLogger { _ in }
}
