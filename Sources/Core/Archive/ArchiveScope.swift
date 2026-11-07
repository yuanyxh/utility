import Foundation

extension ArchiveScope {
    /// Scopes that make sense for the current configuration, in stable display order.
    static func available(
        in config: AppConfig,
        configDir: URL,
        fileManager: FileManager = .default,
    ) -> [ArchiveScope] {
        allCases.filter { scope in
            switch scope {
            case .knowledge:
                config.knowledge.enabled
            case .terminal:
                config.terminal.enabled
            case .usage:
                usageFilesExist(configDir: configDir, fileManager: fileManager)
            case .config, .memory, .local, .notes:
                true
            }
        }
    }

    /// Everything available except the large usage databases.
    static func defaultSelection(
        in config: AppConfig,
        configDir: URL,
        fileManager: FileManager = .default,
    ) -> Set<ArchiveScope> {
        Set(available(in: config, configDir: configDir, fileManager: fileManager))
            .subtracting([.usage])
    }

    /// Files owned by this scope, with their archive-relative destinations.
    func members(configDir: URL, fileManager: FileManager = .default) -> [ArchiveMember] {
        var result: [ArchiveMember] = []
        func append(_ name: String, as archivePath: String, kind: ArchiveMemberKind) {
            let url = configDir.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { return }
            result.append(ArchiveMember(archivePath: archivePath, sourceURL: url, kind: kind))
        }

        switch self {
        case .config:
            append("config.yaml", as: "config/config.yaml", kind: .copy)
            append("agent-gateway.yaml", as: "config/agent-gateway.yaml", kind: .copy)
            append(
                "retrieval_thresholds.json",
                as: "config/retrieval_thresholds.json",
                kind: .copy,
            )
            let prompts = configDir.appendingPathComponent("prompts")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: prompts.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                result.append(
                    ArchiveMember(
                        archivePath: "config/prompts",
                        sourceURL: prompts,
                        kind: .directory,
                    )
                )
            }
        case .memory:
            append("memory_graph.sqlite", as: "data/memory_graph.sqlite", kind: .sqliteBackup)
            append("cold_sync.sqlite", as: "data/cold_sync.sqlite", kind: .sqliteBackup)
            append(
                "consolidation_state.json",
                as: "data/consolidation_state.json",
                kind: .copy,
            )
            for url in Self.cleanupFiles(configDir: configDir, fileManager: fileManager) {
                result.append(
                    ArchiveMember(
                        archivePath: "data/\(url.lastPathComponent)",
                        sourceURL: url,
                        kind: .copy,
                    )
                )
            }
        case .knowledge:
            append("knowledge.sqlite", as: "data/knowledge.sqlite", kind: .sqliteBackup)
        case .local:
            append("data.sqlite", as: "data/data.sqlite", kind: .sqliteBackup)
            append("notices.sqlite", as: "data/notices.sqlite", kind: .sqliteBackup)
        case .terminal:
            append(
                "terminal-sessions.json",
                as: "data/terminal-sessions.json",
                kind: .copy,
            )
            append("workspaces.json", as: "data/workspaces.json", kind: .copy)
        case .usage:
            append("token_usage.sqlite", as: "data/token_usage.sqlite", kind: .sqliteBackup)
            append("tool_output.sqlite", as: "data/tool_output.sqlite", kind: .sqliteBackup)
        case .notes:
            break
        }
        return result
    }

    /// Notes, liked cards and RSS output; nested directories are packaged once.
    static func resolveExternalDirs(config: AppConfig, configDir: URL) -> [ExternalPath] {
        let notes = notesRoot(config: config, configDir: configDir)
        var result = [ExternalPath(role: .notes, root: notes)]

        let liked = likedRoot(config: config, notesRoot: notes)
        if !isContained(liked, in: notes) {
            result.append(ExternalPath(role: .liked, root: liked))
        }

        let rss = rssRoot(config: config, notesRoot: notes)
        if !isContained(rss, in: notes) {
            result.append(ExternalPath(role: .rss, root: rss))
        }
        return result
    }

    private static func usageFilesExist(configDir: URL, fileManager: FileManager) -> Bool {
        let names = ["token_usage.sqlite", "tool_output.sqlite"]
        return names.contains {
            fileManager.fileExists(atPath: configDir.appendingPathComponent($0).path)
        }
    }

    private static func cleanupFiles(configDir: URL, fileManager: FileManager) -> [URL] {
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: configDir,
                includingPropertiesForKeys: nil,
            )) ?? []
        return contents.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("memory-cleanup-") && name.hasSuffix(".json")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func notesRoot(config: AppConfig, configDir: URL) -> URL {
        expand(config.mcp?.knowledgeBasePath)
            ?? configDir.appendingPathComponent("notes", isDirectory: true)
    }

    private static func likedRoot(config: AppConfig, notesRoot: URL) -> URL {
        expand(config.knowledge.likedSaveDir)
            ?? notesRoot.appendingPathComponent(L10n.Knowledge.savedDir, isDirectory: true)
    }

    private static func rssRoot(config: AppConfig, notesRoot: URL) -> URL {
        expand(config.rss.daily.outputDir)
            ?? notesRoot.appendingPathComponent("RSS", isDirectory: true)
    }

    private static func expand(_ raw: String?) -> URL? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    private static func isContained(_ child: URL, in parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if childPath == parentPath { return true }
        return childPath.hasPrefix(parentPath.hasSuffix("/") ? parentPath : parentPath + "/")
    }
}
