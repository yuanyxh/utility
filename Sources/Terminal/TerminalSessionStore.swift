import Foundation

struct StoredTerminalSession: Codable {
    let id: String
    var title: String
    var cwd: String
    /// Older builds decode this as required; keep writing it.
    let backend: String
    let createdAt: Date
    let workspaceID: String?
    let role: TerminalRole?

    init(
        id: String, title: String, cwd: String, backend: String, createdAt: Date,
        workspaceID: String? = nil, role: TerminalRole? = nil,
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.backend = backend
        self.createdAt = createdAt
        self.workspaceID = workspaceID
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        cwd = try c.decode(String.self, forKey: .cwd)
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? TmuxBackend.storageName
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
        role = try c.decodeIfPresent(TerminalRole.self, forKey: .role)
    }
}

/// Metadata only; the terminal state itself lives in tmux.
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
