import Foundation

enum WorkspaceStoreError: LocalizedError {
    case corrupt(quarantined: URL)

    var errorDescription: String? {
        switch self {
        case .corrupt(let url):
            return "workspaces.json could not be decoded; moved to \(url.lastPathComponent)"
        }
    }
}

/// Owns `workspaces.json`. Corrupt input is quarantined instead of overwritten.
final class WorkspaceStore {
    private let fileURL: URL
    private let sessionsURL: URL
    private let fileManager = FileManager.default

    init(
        fileURL: URL = AppPaths.configDir.appendingPathComponent("workspaces.json"),
        sessionsURL: URL = AppPaths.configDir.appendingPathComponent("terminal-sessions.json"),
    ) {
        self.fileURL = fileURL
        self.sessionsURL = sessionsURL
    }

    func load() throws -> WorkspaceDocument? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try WorkspaceJSON.decode(data).normalized()
        } catch {
            let target = quarantineURL()
            try? fileManager.moveItem(at: fileURL, to: target)
            throw WorkspaceStoreError.corrupt(quarantined: target)
        }
    }

    func save(_ document: WorkspaceDocument) throws {
        backUpLegacyVersionIfNeeded()
        let data = try WorkspaceJSON.encode(document.normalized())
        try data.write(to: fileURL, options: .atomic)
    }

    private var didCheckLegacyBackup = false

    /// Keeps the pre-v2 file once per launch, so a downgrade can still read the old layout.
    private func backUpLegacyVersionIfNeeded() {
        guard !didCheckLegacyBackup else { return }
        didCheckLegacyBackup = true
        guard let existing = try? Data(contentsOf: fileURL),
            let version = try? WorkspaceJSON.decode(existing).version,
            version < WorkspaceDocument.currentVersion
        else { return }
        let backup = fileURL.appendingPathExtension("bak")
        guard !fileManager.fileExists(atPath: backup.path) else { return }
        do {
            try fileManager.copyItem(at: fileURL, to: backup)
        } catch {
            debugLog("[Workspace] legacy backup failed: \(error)")
        }
    }

    /// Copies the legacy session file once, before the first workspace document exists.
    func backupSessionsIfNeeded() {
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }
        let backup = sessionsURL.appendingPathExtension("bak")
        guard fileManager.fileExists(atPath: sessionsURL.path),
            !fileManager.fileExists(atPath: backup.path)
        else { return }
        try? fileManager.copyItem(at: sessionsURL, to: backup)
    }

    private func quarantineURL() -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970)
        var candidate = directory.appendingPathComponent("\(base).corrupt-\(stamp)")
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base).corrupt-\(stamp)-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}
