import Foundation

/// Parses the payload of OSC 777 (`notify;title;body`) and OSC 9 (`body`)
/// desktop notifications. Both the live PTY tap and the screen log tap use it,
/// so a payload change only needs to be handled once.
enum TerminalNotificationParser {
    struct Message {
        let title: String
        let body: String
    }

    /// Extracts complete OSC messages from a raw terminal byte stream, then
    /// drops the consumed prefix. An unterminated trailing sequence stays in
    /// `buffer` so the next chunk can complete it.
    static func drain(_ buffer: inout [UInt8]) -> [Message] {
        var messages: [Message] = []
        var consumed = 0
        while consumed < buffer.count {
            guard let start = buffer[consumed...].firstIndex(of: 0x1B) else {
                consumed = buffer.count
                break
            }
            guard start + 1 < buffer.count, buffer[start + 1] == 0x5D else {
                consumed = start + 1
                continue
            }
            guard let end = terminator(in: buffer, from: start + 2) else {
                consumed = start
                break
            }
            let payload = String(decoding: buffer[(start + 2)..<end.index], as: UTF8.self)
            if let message = parse(payload: payload) { messages.append(message) }
            consumed = end.next
        }
        buffer.removeFirst(consumed)
        // A runaway unterminated sequence must not grow without bound.
        if buffer.count > 8192 { buffer.removeAll() }
        return messages
    }

    private static func terminator(
        in bytes: [UInt8], from index: Int,
    ) -> (index: Int, next: Int)? {
        var i = index
        while i < bytes.count {
            if bytes[i] == 0x07 { return (i, i + 1) }
            if bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5C {
                return (i, i + 2)
            }
            i += 1
        }
        return nil
    }

    /// - Parameter payload: OSC payload including its numeric code, e.g. `777;notify;done;ok`.
    static func parse(payload: String) -> Message? {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        let message: Message?
        if parts.count >= 3, parts[0] == "777", parts[1] == "notify" {
            message = Message(title: parts[2], body: parts[3...].joined(separator: ";"))
        } else if parts.count >= 2, parts[0] == "9",
                  // `9;4;…` is a progress report, not a message.
                  let first = parts[1].first, !first.isNumber
        {
            message = Message(title: "", body: parts[1...].joined(separator: ";"))
        } else {
            message = nil
        }
        guard let message else { return nil }
        let title = message.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !body.isEmpty else { return nil }
        return Message(title: title, body: body)
    }
}
