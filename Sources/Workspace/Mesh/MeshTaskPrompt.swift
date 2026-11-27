import Foundation

/// Bounded FIFO for prompts that arrive before their agent is ready.
struct MeshTaskQueue {
    let limit: Int
    private(set) var prompts: [String] = []

    init(limit: Int = 10) { self.limit = limit }

    var isEmpty: Bool { prompts.isEmpty }

    /// Returns true when the oldest prompt was dropped to make room.
    @discardableResult
    mutating func push(_ prompt: String) -> Bool {
        var dropped = false
        if prompts.count >= max(limit, 1) {
            prompts.removeFirst()
            dropped = true
        }
        prompts.append(prompt)
        return dropped
    }
}

/// Renders a mesh task as one line so tmux send-keys submits it as a single prompt.
enum MeshTaskPrompt {
    static let maxBytes = 8_192

    static func truncate(_ text: String, limit: Int = maxBytes) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > limit else { return trimmed }
        debugLog("[Mesh] task text truncated bytes=\(trimmed.utf8.count)")
        let budget = max(0, limit - 3)
        var result = ""
        var used = 0
        for character in trimmed {
            let size = String(character).utf8.count
            if used + size > budget { break }
            result.append(character)
            used += size
        }
        return result + "..."
    }

    static func render(
        id: String, sender: String, serviceID: String, text: String, expectsReply: Bool
    ) -> String {
        let messageID = singleLine(id)
        let from = singleLine(sender)
        let body = singleLine(truncate(text))
        let prefix = expectsReply ? "MESH TASK" : "MESH REPLY"
        let head = "\(prefix) \(messageID) from \(from): \(body)"
        guard expectsReply else { return head }
        return
            "\(head) - When done, reply with service_send(sender=\"\(singleLine(serviceID))\", recipient=\"\(from)\", kind=\"reply\", reply_to=\"\(messageID)\", payload=\"<summary>\")."
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
