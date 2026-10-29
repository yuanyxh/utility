import Foundation

/// Parses the payload of OSC 777 (`notify;title;body`) and OSC 9 (`body`)
/// desktop notifications. Both the live PTY tap and the screen log tap use it,
/// so a payload change only needs to be handled once.
enum TerminalNotificationParser {
    struct Message {
        let title: String
        let body: String
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
