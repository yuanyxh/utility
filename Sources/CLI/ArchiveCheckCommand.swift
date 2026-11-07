import ArgumentParser
import Foundation
import GRDB
import Yams

/// Headless checks for the user-data archive: scopes, export, import and round-trip.
struct ArchiveCheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive-check",
        abstract: L10n.CLI.archiveCheckAbstract,
    )

    @Option(help: ArgumentHelp(L10n.CLI.archiveRootHelp))
    var root: String?

    @Flag(help: ArgumentHelp(L10n.CLI.archiveScopesHelp))
    var scopes = false

    @Option(help: ArgumentHelp(L10n.CLI.archiveExportHelp))
    var export: String?

    @Option(help: ArgumentHelp(L10n.CLI.archiveScopeHelp))
    var scope: String?

    @Flag(help: ArgumentHelp(L10n.CLI.archiveSecretsHelp))
    var secrets = false

    @Option(name: .customLong("import"), help: ArgumentHelp(L10n.CLI.archiveImportHelp))
    var importArchive: String?

    @Flag(help: ArgumentHelp(L10n.CLI.archiveDryRunHelp))
    var dryRun = false

    @Option(help: ArgumentHelp(L10n.CLI.archiveRemapHelp))
    var remap: [String] = []

    @Option(help: ArgumentHelp(L10n.CLI.archivePolicyHelp))
    var policy = "skip"

    @Flag(help: ArgumentHelp(L10n.CLI.archiveRoundtripHelp))
    var roundtrip = false

    func run() throws {
        if roundtrip {
            try runRoundtrip()
            return
        }
        if scopes {
            try printScopes()
            return
        }
        if let export {
            try runExport(export)
            return
        }
        if let importArchive {
            try runImport(importArchive)
            return
        }
        throw CleanExit.helpRequest()
    }

    private func printScopes() throws {
        let directory = try configDirectory()
        let config = try loadConfig(directory)
        let available = ArchiveScope.available(in: config, configDir: directory)
        let defaults = ArchiveScope.defaultSelection(in: config, configDir: directory)
        print("available: \(names(available))")
        print("default: \(names(ArchiveScope.allCases.filter(defaults.contains)))")
    }

    private func runExport(_ path: String) throws {
        let directory = try configDirectory()
        let config = try loadConfig(directory)
        let selected: Set<ArchiveScope>
        if let scope {
            let names = scope.split(separator: ",").map(String.init)
            let parsed = names.compactMap(ArchiveScope.init(rawValue:))
            guard parsed.count == names.count else {
                throw ValidationError("invalid --scope \(scope)")
            }
            selected = Set(parsed)
        } else {
            selected = ArchiveScope.defaultSelection(in: config, configDir: directory)
        }

        let destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let manifest = try ConfigArchive.export(
            options: ArchiveOptions(scopes: selected, includesSecrets: secrets),
            config: config,
            configDir: directory,
            appVersion: "cli",
            gatewayWheel: GatewayInstaller.bundledWheelName,
            destination: destination,
            log: { print($0) },
        )
        print("exported: \(destination.path)")
        print("files: \(manifest.files.count)")
        print("external: \(manifest.external.count)")
    }

    private func runImport(_ path: String) throws {
        let directory = try configDirectory()
        let archive = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let plan = try ConfigArchive.validate(
            archive: archive,
            configDir: directory,
            log: { print($0) },
        )
        print("validate: ok")

        let defaults = ConfigArchive.defaultDecisions(plan: plan)
        let conflicts = ConfigArchive.scanConflicts(plan: plan, decisions: defaults)
        for conflict in conflicts {
            print(
                "conflict: \(conflict.role.rawValue) "
                    + "existing=\(conflict.existingCount)/\(conflict.totalCount)",
            )
        }
        if dryRun {
            print("dry-run: ok")
            ConfigArchive.discard(plan)
            return
        }

        let conflictPolicy = try parsePolicy()
        let remaps = try parseRemaps()
        let decisions = defaults.map { decision in
            ExternalRestoreDecision(
                role: decision.role,
                destination: remaps[decision.role] ?? decision.destination,
                policy: conflictPolicy,
            )
        }
        try ConfigArchive.validateExternalDestinations(decisions)
        if !remaps.isEmpty {
            try ConfigArchive.rewriteConfigPaths(
                configFile: plan.stagingDir.appendingPathComponent("config/config.yaml"),
                remaps: remaps,
            )
        }

        let backup = try ConfigArchive.applyCore(plan, configDir: directory, log: { print($0) })
        if plan.manifest.gatewayWheel != GatewayInstaller.bundledWheelName {
            GatewayInstaller.invalidateStamp()
        }
        print("apply-core: ok")
        let result = try ConfigArchive.applyExternal(
            decisions: decisions,
            plan: plan,
            backup: backup,
            log: { print($0) },
        )
        print(
            "apply-external: ok copied=\(result.copied) "
                + "skipped=\(result.skipped) overwritten=\(result.overwritten)",
        )
        ConfigArchive.discard(plan)
    }

    private func runRoundtrip() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("utility-archive-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.trashItem(at: base, resultingItemURL: nil) }
        let sourceRoot = base.appendingPathComponent("A")
        let targetRoot = base.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let notes = sourceRoot.appendingPathComponent("notes")
        try write("alpha", to: notes.appendingPathComponent("a.md"))
        try write("beta", to: notes.appendingPathComponent("sub/b.md"))
        try write("ignored", to: notes.appendingPathComponent(".git/ignored.txt"))
        try write("noise", to: notes.appendingPathComponent(".DS_Store"))

        try write(
            """
            ai:
              apiKey: secret
            mcp:
              knowledgeBasePath: \(notes.path)
            knowledge:
              enabled: true
              likedSaveDir: \(notes.path)/cards
            rss:
              daily:
                enabled: true
                outputDir: \(notes.path)/RSS
            terminal:
              enabled: true
            """,
            to: sourceRoot.appendingPathComponent("config.yaml"),
        )
        try write("{\"llm\":{\"apiKey\":\"secret\"}}", to: sourceRoot.appendingPathComponent("agent-gateway.yaml"))
        try write("[]", to: sourceRoot.appendingPathComponent("workspaces.json"))
        try write("[]", to: sourceRoot.appendingPathComponent("terminal-sessions.json"))
        try write("junk", to: sourceRoot.appendingPathComponent("mcp-venv/junk.txt"))
        try write("wal", to: sourceRoot.appendingPathComponent("data.sqlite-wal"))
        try createDatabase(
            at: sourceRoot.appendingPathComponent("data.sqlite"),
            sql: "CREATE TABLE probe (value TEXT); INSERT INTO probe VALUES ('ok');",
        )
        try createDatabase(
            at: sourceRoot.appendingPathComponent("memory_graph.sqlite"),
            sql: "CREATE TABLE memory (id TEXT);",
        )
        try createWALDatabase(
            at: sourceRoot.appendingPathComponent("cold_sync.sqlite"),
            sql: "CREATE TABLE sync (id TEXT);",
        )
        try createDatabase(
            at: sourceRoot.appendingPathComponent("knowledge.sqlite"),
            sql: "CREATE TABLE card (id TEXT);",
        )
        try createDatabase(
            at: sourceRoot.appendingPathComponent("notices.sqlite"),
            sql: "CREATE TABLE notice (id TEXT);",
        )

        let config = try loadConfig(sourceRoot)
        let archive = base.appendingPathComponent("archive.zip")
        let manifest = try ConfigArchive.export(
            options: ArchiveOptions(
                scopes: [.config, .memory, .knowledge, .local, .terminal, .notes],
            ),
            config: config,
            configDir: sourceRoot,
            appVersion: "cli",
            gatewayWheel: GatewayInstaller.bundledWheelName,
            destination: archive,
        )
        try require(manifest.external.count == 1, "notes role was not exported")
        try require(
            !manifest.files.contains {
                $0.path.contains("mcp-venv") || $0.path.hasSuffix(".sqlite-wal")
            },
            "archive included venv or WAL",
        )
        try require(
            manifest.external.first?.originalPath == notes.path,
            "notes path was not recorded",
        )

        let plan = try ConfigArchive.validate(archive: archive, configDir: targetRoot)
        let stagedGateway =
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: plan.stagingDir.appendingPathComponent(
                        "config/agent-gateway.yaml",
                    )
                ),
            ) as? [String: Any]
        let stagedLLM = stagedGateway?["llm"] as? [String: Any]
        try require(stagedLLM?["apiKey"] as? String == "", "gateway apiKey was not stripped")
        let stagedConfigText = try String(
            contentsOf: plan.stagingDir.appendingPathComponent("config/config.yaml"),
            encoding: .utf8,
        )
        let stagedConfig = (try? Yams.load(yaml: stagedConfigText)) as? [String: Any]
        let stagedAI = stagedConfig?["ai"] as? [String: Any]
        try require(stagedAI?["apiKey"] as? String == "", "config apiKey was not stripped")
        let targetNotes = targetRoot.appendingPathComponent("notes")
        try ConfigArchive.rewriteConfigPaths(
            configFile: plan.stagingDir.appendingPathComponent("config/config.yaml"),
            remaps: [.notes: targetNotes],
        )
        let backup = try ConfigArchive.applyCore(plan, configDir: targetRoot)
        let decisions = [
            ExternalRestoreDecision(
                role: .notes,
                destination: targetNotes,
                policy: .skipExisting,
            )
        ]
        let result = try ConfigArchive.applyExternal(
            decisions: decisions,
            plan: plan,
            backup: backup,
        )
        ConfigArchive.discard(plan)

        let imported = try loadConfig(targetRoot)
        try require(
            imported.mcp?.knowledgeBasePath == targetNotes.path,
            "knowledgeBasePath was not rewritten",
        )
        try require(
            imported.knowledge.likedSaveDir == targetNotes.appendingPathComponent("cards").path,
            "nested likedSaveDir was not rewritten",
        )
        try require(
            imported.rss.daily.outputDir == targetNotes.appendingPathComponent("RSS").path,
            "nested rss outputDir was not rewritten",
        )
        try require(result.copied == 2, "unexpected external file count")
        try require(
            (try? String(contentsOf: targetNotes.appendingPathComponent("a.md"), encoding: .utf8))
                == "alpha",
            "missing a.md",
        )
        try require(
            !FileManager.default.fileExists(
                atPath: targetNotes.appendingPathComponent(".git").path,
            ),
            ".git was exported",
        )
        let value = try readProbe(at: targetRoot.appendingPathComponent("data.sqlite"))
        try require(value == "ok", "data.sqlite row missing")

        let mismatchRoot = base.appendingPathComponent("D")
        try FileManager.default.createDirectory(
            at: mismatchRoot,
            withIntermediateDirectories: true,
        )
        try createDatabase(
            at: mismatchRoot.appendingPathComponent("data.sqlite"),
            sql: "CREATE TABLE other (id TEXT);",
        )
        do {
            _ = try ConfigArchive.validate(archive: archive, configDir: mismatchRoot)
            throw ValidationError("roundtrip failed: schema mismatch was accepted")
        } catch let error as ArchiveError {
            guard case .schemaMismatch = error else { throw error }
        }

        let forgedRoot = base.appendingPathComponent("F")
        try FileManager.default.createDirectory(
            at: forgedRoot,
            withIntermediateDirectories: true,
        )
        let extract = CommandRunner.run(
            ["/usr/bin/tar", "-xf", archive.path, "-C", forgedRoot.path],
            timeout: 60,
        )
        try require(extract.ok, "cannot unpack the archive")
        let forgedManifest = forgedRoot.appendingPathComponent("manifest.json")
        var object =
            (try JSONSerialization.jsonObject(with: Data(contentsOf: forgedManifest)))
            as? [String: Any] ?? [:]
        var external = object["external"] as? [[String: Any]] ?? []
        try require(!external.isEmpty, "archive has no external entry")
        external[0]["archivePath"] = "../escape"
        object["external"] = external
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: forgedManifest, options: .atomic)
        let forgedArchive = base.appendingPathComponent("forged.zip")
        let forgedZip = CommandRunner.run(
            ["/usr/bin/ditto", "-c", "-k", "--norsrc", forgedRoot.path, forgedArchive.path],
            timeout: 60,
        )
        try require(forgedZip.ok, "cannot build the forged archive")
        do {
            _ = try ConfigArchive.validate(archive: forgedArchive, configDir: targetRoot)
            throw ValidationError("roundtrip failed: unsafe external path was accepted")
        } catch let error as ArchiveError {
            guard case .pathTraversal = error else { throw error }
        }

        let scopeRoot = base.appendingPathComponent("E")
        try write(
            "knowledge:\n  enabled: false\nterminal:\n  enabled: false\n",
            to: scopeRoot.appendingPathComponent("config.yaml"),
        )
        let scopeConfig = try loadConfig(scopeRoot)
        let available = ArchiveScope.available(in: scopeConfig, configDir: scopeRoot)
        try require(
            !available.contains(.knowledge) && !available.contains(.terminal),
            "scope filtering failed",
        )
        try require(
            ArchiveScope.defaultSelection(in: scopeConfig, configDir: scopeRoot).contains(.notes),
            "notes is not a default scope",
        )
        print("roundtrip: ok")
    }

    private func configDirectory() throws -> URL {
        guard let root else {
            throw ValidationError("--root is required")
        }
        return URL(
            fileURLWithPath: (root as NSString).expandingTildeInPath,
            isDirectory: true,
        )
    }

    private func loadConfig(_ directory: URL) throws -> AppConfig {
        let file = directory.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: file.path) else { return AppConfig() }
        return try YAMLDecoder().decode(AppConfig.self, from: Data(contentsOf: file))
    }

    private func parsePolicy() throws -> ExternalConflictPolicy {
        switch policy {
        case "skip":
            return .skipExisting
        case "overwrite":
            return .overwrite
        default:
            throw ValidationError("invalid --policy \(policy)")
        }
    }

    private func parseRemaps() throws -> [ExternalRole: URL] {
        var result: [ExternalRole: URL] = [:]
        for value in remap {
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let role = ExternalRole(rawValue: parts[0]), !parts[1].isEmpty
            else {
                throw ValidationError("invalid --remap \(value)")
            }
            result[role] = URL(
                fileURLWithPath: (parts[1] as NSString).expandingTildeInPath,
                isDirectory: true,
            )
        }
        return result
    }

    private func names(_ scopes: [ArchiveScope]) -> String {
        scopes.map(\.rawValue).joined(separator: ",")
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func createDatabase(at url: URL, sql: String) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: sql) }
    }

    private func createWALDatabase(at url: URL, sql: String) throws {
        var configuration = Configuration()
        configuration.journalMode = .wal
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            try queue.write { db in try db.execute(sql: sql) }
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil)
            }
        }
    }

    private func readProbe(at url: URL) throws -> String? {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM probe")
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ValidationError("roundtrip failed: \(message)")
        }
    }
}
