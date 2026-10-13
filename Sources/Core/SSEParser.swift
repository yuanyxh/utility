import Foundation

/// Standalone SSE (Server-Sent Events) parser
/// Parses `data: {...}` frames line by line, extracts content deltas, and invokes callbacks
public final class SSEParser {
    private var buffer = ""

    public init() {}

    /// Feeds in a Data chunk, invoking the callback for each parsed token
    /// - Parameters:
    ///   - data: streaming response chunk
    ///   - onToken: each content delta (non-empty string)
    ///   - onComplete: invoked when the `[DONE]` signal is received
    public func feed(
        _ data: Data,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
    ) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        buffer += str

        let lines = buffer.components(separatedBy: "\n")
        buffer = lines.last ?? ""

        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data: ") else { continue }

            let jsonStr = String(trimmed.dropFirst(6))
            if jsonStr == "[DONE]" {
                onComplete()
                return
            }
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String,
                  !content.isEmpty
            else { continue }

            onToken(content)
        }
    }
}
