import Foundation

/// The wire framing, for anyone writing an `EcrChannel`.
///
/// A message is a 2-byte big-endian length followed by that many bytes of UTF-8
/// JSON. A stream carries no message boundaries, so the header is what says
/// where one message ends and the next begins.
///
/// Public because a channel outside this library — a USB cable, a Bluetooth
/// socket — has to frame the same way, and a second private implementation of
/// "two bytes then the body" is a second chance to get it subtly wrong.
public enum EcrFrames {

    public static let headerBytes = 2

    /// The header is two bytes, so nothing longer can be described.
    public static let maxBodyBytes = 0xFFFF

    /// Puts a length header in front of `body`.
    public static func wrap(_ body: Data) throws -> Data {
        guard body.count <= maxBodyBytes else {
            throw EcrFrameError("Message of \(body.count) bytes does not fit a frame")
        }
        var packet = Data(capacity: headerBytes + body.count)
        packet.append(UInt8((body.count >> 8) & 0xFF))
        packet.append(UInt8(body.count & 0xFF))
        packet.append(body)
        return packet
    }

    /// The body length a header announces.
    ///
    /// Only the first two bytes are read, so a larger buffer that starts with a
    /// header — as USB transfer accumulation does — is fine.
    public static func bodyLength(_ header: Data) -> Int {
        guard header.count >= headerBytes else { return 0 }
        return (Int(header[header.startIndex]) << 8) | Int(header[header.startIndex + 1])
    }

    /// Reads exactly one message body via `readExactly`, blocking until it
    /// arrives or the underlying read times out.
    public static func readBody(
        using readExactly: (_ count: Int, _ what: String) throws -> Data
    ) throws -> Data {
        let header = try readExactly(headerBytes, "response header")
        let length = bodyLength(header)
        guard length > 0 else {
            throw EcrFrameError("Terminal returned an empty message")
        }
        return try readExactly(length, "response body")
    }
}

/// Framing refused a message — too large, empty, or truncated on the wire.
public struct EcrFrameError: LocalizedError {
    public let errorDescription: String?

    public init(_ message: String) {
        errorDescription = message
    }
}
