import Foundation

/// How this till reaches a POS terminal.
///
/// The app supplies addressing and backend IDs; the SDK owns protocol choice,
/// signing, and transport.
public enum EcrLink {
    /// Wi‑Fi / LAN — TCP to `host`:`port`.
    case lan(host: String, port: Int = EcrConfig.defaultPort)

    /// A USB cable straight from this till to the terminal.
    ///
    /// No address: the caller supplies an `EcrChannel` that already owns the
    /// byte stream. Finding and opening the cable is a platform job outside
    /// this library.
    case usbCable

    /// Hosted REST — HTTPS with JSON body signing.
    case webService(merchantId: String, terminalId: String)
}
