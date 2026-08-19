import Foundation

/// The wire format.
///
/// Framing: a 2-byte big-endian unsigned length header followed by that many
/// bytes of UTF-8 JSON. TCP carries no message boundaries, so the header is
/// what tells the reader where one message ends and the next begins.
///
/// This is the single place the format lives on iOS, and it matches the Kotlin
/// SDK's `EcrMessageCodec` and the terminal's own copy. The three must change
/// together — see `ecr-sdk/docs/protocol.md`.
enum EcrMessageCodec {

    private static let headerBytes = 2
    private static let maxMessageBytes = 0xFFFF

    enum CodecError: Error {
        case tooLarge(String)
        case empty
        case notJson(String)
    }

    /// Frames a message ready to write to the socket.
    static func encode(_ message: EcrMessage) throws -> Data {
        // `sortedKeys` is not set: the terminal reads by key and the order is
        // its own business. It is left unsorted so the bytes match what the
        // Kotlin SDK sends, which is insertion order.
        let body = try JSONSerialization.data(withJSONObject: message.json, options: [])

        guard body.count <= maxMessageBytes else {
            throw CodecError.tooLarge("Request exceeds \(maxMessageBytes) bytes")
        }

        var packet = Data(capacity: headerBytes + body.count)
        packet.append(UInt8((body.count >> 8) & 0xFF))
        packet.append(UInt8(body.count & 0xFF))
        packet.append(body)
        return packet
    }

    /// Reads exactly one framed message from [socket].
    static func decode(from socket: EcrSocket) throws -> [String: Any] {
        let header = try socket.readExactly(headerBytes, what: "response header")
        let length = (Int(header[header.startIndex]) << 8) | Int(header[header.startIndex + 1])

        guard length > 0 else { throw CodecError.empty }

        let body = try socket.readExactly(length, what: "response body")

        guard
            let parsed = try? JSONSerialization.jsonObject(with: body, options: []),
            let json = parsed as? [String: Any]
        else {
            let text = String(data: body, encoding: .utf8) ?? "<not UTF-8>"
            throw CodecError.notJson("Terminal returned a message that is not valid JSON: \(text)")
        }

        return json
    }

    /// The terminal's answer as JSON text, for the `raw` field callers get.
    ///
    /// Re-serialised rather than kept as the received bytes so that both
    /// platforms hand back the same shape of text for the same answer.
    static func text(_ json: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: json)
        }
        return text
    }
}
