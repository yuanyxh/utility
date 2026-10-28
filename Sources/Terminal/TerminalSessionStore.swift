import Foundation

struct StoredTerminalSession: Codable {
    let id: String
    var title: String
    var cwd: String
    let backend: String
    let createdAt: Date
}

/// Metadata only; terminal state lives in tmux/screen or dies with the app.
final class TerminalSessionStore {
    private let fileURL: URL

    init(fileURL: URL = AppPaths.configDir.appendingPathComponent("terminal-sessions.json")) {
        self.fileURL = fileURL
    }

    func load() -> [StoredTerminalSession] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredTerminalSession].self, from: data)) ?? []
    }

    func save(_ sessions: [StoredTerminalSession]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
