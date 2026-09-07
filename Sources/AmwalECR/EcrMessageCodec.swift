import Foundation

/// The wire format.
///
/// Framing: a 2-byte big-endian unsigned length header followed by that many
/// bytes of UTF-8 JSON. TCP carries no message boundaries, so the header is
/// what tells the reader where one message ends and the next begins.
///
/// Framing lives in public `EcrFrames` so external channels (USB, Bluetooth)
/// share one implementation. This codec owns JSON encode/parse on top of that.
///
/// This matches the Kotlin SDK's `EcrMessageCodec` and the terminal's own copy.
/// The three must change together — see `ecr-sdk/docs/protocol.md`.
enum EcrMessageCodec {

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

        do {
            return try EcrFrames.wrap(body)
        } catch {
            throw CodecError.tooLarge("Request exceeds \(EcrFrames.maxBodyBytes) bytes")
        }
    }

    /// One message body, as the object it claims to be.
    ///
    /// Separate from reading it off the wire, because a channel that is not a
    /// stream — a USB transfer, a Bluetooth packet — already holds the bytes by
    /// the time anyone wants them parsed.
    static func parse(_ body: Data) throws -> [String: Any] {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: body, options: []),
            let json = parsed as? [String: Any]
        else {
            let text = String(data: body, encoding: .utf8) ?? "<not UTF-8>"
            throw CodecError.notJson("Terminal returned a message that is not valid JSON: \(text)")
        }
        return json
    }

    /// Reads exactly one framed message from [socket].
    static func decode(from socket: EcrSocket) throws -> [String: Any] {
        let body: Data
        do {
            body = try EcrFrames.readBody { count, what in
                try socket.readExactly(count, what: what)
            }
        } catch let error as EcrFrameError {
            let reason = error.errorDescription ?? ""
            if reason.contains("empty message") {
                throw CodecError.empty
            }
            throw error
        }

        return try parse(body)
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
