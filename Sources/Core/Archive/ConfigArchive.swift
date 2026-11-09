import CryptoKit
import Foundation
import GRDB
import Yams

/// Builds and validates portable user-data archives.
enum ConfigArchive {
    static let maxBytes = 8 * 1024 * 1024 * 1024
    static let maxFiles = 100_000
    private static let totalTimeout: TimeInterval = 600
    private static let databaseTimeout: TimeInterval = 120
    private static let zipTimeout: TimeInterval = 300

    static func export(
        options: ArchiveOptions,
        config: AppConfig,
        configDir: URL,
        appVersion: String,
        gatewayWheel: String? = nil,
        destination: URL,
        log: @escaping (String) -> Void = { _ in },
    ) throws -> ArchiveManifest {
        guard !options.scopes.isEmpty else {
            throw ArchiveError.invalidManifest("no scopes selected")
        }

        let deadline = Date().addingTimeInterval(totalTimeout)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("utility-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { trash(staging) }

        var fileCount = 0
        var totalBytes = 0
        func account(files: Int, bytes: Int) throws {
            fileCount += files
            totalBytes += bytes
            if fileCount > maxFiles { throw ArchiveError.fileLimit(maxFiles) }
            if totalBytes > maxBytes { throw ArchiveError.sizeLimit(maxBytes) }
        }
        func checkDeadline() throws {
            guard Date() < deadline else {
                throw ArchiveError.timeout("export exceeded \(Int(totalTimeout))s")
            }
        }

        let orderedScopes = ArchiveScope.allCases.filter { options.scopes.contains($0) }
        let externalPaths = ArchiveScope.resolveExternalDirs(config: config, configDir: configDir)
        var externalDirs: [ExternalDir] = []

        for scope in orderedScopes {
            if scope == .notes {
                for path in externalPaths {
                    try checkDeadline()
                    let scan = ArchiveExternal.scan(root: path.root)
                    guard !scan.files.isEmpty else {
                        log("skip \(path.role.rawValue): \(path.root.path) is empty or missing")
                        continue
                    }
                    try account(files: scan.files.count, bytes: scan.bytes)
                    let archiveRoot = "external/\(path.role.rawValue)"
                    for url in scan.files {
                        let relative = ArchiveExternal.relativePath(of: url, root: path.root)
                        let target =
                            staging
                            .appendingPathComponent(archiveRoot)
                            .appendingPathComponent(relative)
                        try copy(url, to: target)
                    }
                    externalDirs.append(
                        ExternalDir(
                            role: path.role,
                            originalPath: path.root.path,
                            archivePath: archiveRoot,
                            fileCount: scan.files.count,
                            bytes: scan.bytes,
                        )
                    )
                    log("exported \(path.role.rawValue): \(scan.files.count) files")
                }
                continue
            }

            for member in scope.members(configDir: configDir) {
                try checkDeadline()
                let target = staging.appendingPathComponent(member.archivePath)
                try exportMember(
                    member,
                    to: target,
                    includesSecrets: options.includesSecrets,
                )
                let stats = stats(of: target)
                try account(files: stats.files, bytes: stats.bytes)
                log("exported \(member.archivePath)")
            }
        }

        let files = try stagedFiles(root: staging)
        let manifest = ArchiveManifest(
            formatVersion: ArchiveManifest.currentFormatVersion,
            appVersion: appVersion,
            gatewayWheel: gatewayWheel,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            includesSecrets: options.includesSecrets,
            scope: orderedScopes,
            files: files,
            external: externalDirs,
            sourcePaths: sourcePaths(
                config: config,
                notesRoot: externalPaths.first { $0.role == .notes }?.root.path ?? "",
            ),
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: staging.appendingPathComponent("manifest.json"),
            options: .atomic,
        )

        try checkDeadline()
        try zip(staging: staging, destination: destination)
        log("archive written: \(destination.path)")
        return manifest
    }

    // MARK: - Import validation

    static func validate(
        archive: URL,
        configDir: URL,
        log: @escaping (String) -> Void = { _ in },
    ) throws -> ArchiveImportPlan {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("utility-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            return try validate(
                archive: archive,
                staging: staging,
                configDir: configDir,
                log: log,
            )
        } catch {
            trash(staging)
            throw error
        }
    }

    private static func validate(
        archive: URL,
        staging: URL,
        configDir: URL,
        log: @escaping (String) -> Void,
    ) throws -> ArchiveImportPlan {
        let extract = ProcessRunner.runSync(
            ["/usr/bin/tar", "-xf", archive.path, "-C", staging.path],
            timeout: zipTimeout,
        )
        guard extract.ok else {
            let detail =
                extract.timedOut
                ? "extract timed out"
                : "extract exited \(extract.exitCode): \(extract.output.suffix(400))"
            throw ArchiveError.invalidManifest(detail)
        }

        let manifestURL = staging.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw ArchiveError.invalidManifest("manifest.json is missing")
        }
        let manifest: ArchiveManifest
        do {
            manifest = try JSONDecoder().decode(ArchiveManifest.self, from: data)
        } catch {
            throw ArchiveError.invalidManifest("cannot decode manifest.json")
        }
        guard manifest.formatVersion == ArchiveManifest.currentFormatVersion else {
            throw ArchiveError.invalidManifest(
                "unsupported formatVersion \(manifest.formatVersion)",
            )
        }

        var roles = Set<ExternalRole>()
        for record in manifest.external {
            guard roles.insert(record.role).inserted else {
                throw ArchiveError.invalidManifest(
                    "duplicate external role \(record.role.rawValue)",
                )
            }
            try validateArchivePath(record.archivePath)
            guard record.archivePath == "external/\(record.role.rawValue)" else {
                throw ArchiveError.invalidManifest(
                    "unexpected external path \(record.archivePath)",
                )
            }
            guard record.originalPath.hasPrefix("/") else {
                throw ArchiveError.invalidManifest(
                    "external original path must be absolute: \(record.originalPath)",
                )
            }
        }

        for file in manifest.files {
            try validateArchivePath(file.path)
            let url = staging.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ArchiveError.invalidManifest("missing \(file.path)")
            }
            guard stats(of: url).bytes == file.bytes else {
                throw ArchiveError.checksumMismatch(file.path)
            }
            guard try sha256(url) == file.sha256 else {
                throw ArchiveError.checksumMismatch(file.path)
            }
        }

        for file in manifest.files where file.path.hasSuffix(".sqlite") {
            guard let destination = destinationPath(for: file.path, configDir: configDir),
                FileManager.default.fileExists(atPath: destination.path)
            else { continue }
            let incoming = try tableNames(at: staging.appendingPathComponent(file.path))
            let current = try tableNames(at: destination)
            guard incoming == current else {
                let difference = incoming.symmetricDifference(current).sorted()
                throw ArchiveError.schemaMismatch(file.path, difference)
            }
        }

        log("validated \(manifest.files.count) files")
        return ArchiveImportPlan(stagingDir: staging, manifest: manifest, files: manifest.files)
    }

    static func discard(_ plan: ArchiveImportPlan) {
        trash(plan.stagingDir)
    }

    static func applyCore(
        _ plan: ArchiveImportPlan,
        configDir: URL,
        log: @escaping (String) -> Void = { _ in },
    ) throws -> URL {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let backup = try makeBackupDirectory(configDir: configDir)
        do {
            try backupConfigDirectory(configDir: configDir, to: backup)
            log("backup: \(backup.path)")
            for file in plan.files {
                guard let destination = destinationPath(for: file.path, configDir: configDir) else {
                    continue
                }
                try replace(
                    staged: plan.stagingDir.appendingPathComponent(file.path),
                    destination: destination,
                )
                log("applied \(file.path)")
            }
            return backup
        } catch {
            try? restore(backup: backup, configDir: configDir)
            throw error
        }
    }

    // MARK: - External directories

    static func defaultDecisions(plan: ArchiveImportPlan) -> [ExternalRestoreDecision] {
        plan.manifest.external.map {
            ExternalRestoreDecision(
                role: $0.role,
                destination: URL(fileURLWithPath: $0.originalPath, isDirectory: true),
                policy: .skipExisting,
            )
        }
    }

    static func scanConflicts(
        plan: ArchiveImportPlan,
        decisions: [ExternalRestoreDecision],
    ) -> [ExternalConflict] {
        plan.manifest.external.compactMap { record in
            guard let decision = decisions.first(where: { $0.role == record.role }) else {
                return nil
            }
            let sourceRoot = plan.stagingDir.appendingPathComponent(record.archivePath)
            let files = (try? regularFiles(under: sourceRoot)) ?? []
            let existing = files.filter { file in
                let relative = relativePath(of: file, root: sourceRoot)
                let target = decision.destination.appendingPathComponent(relative)
                return FileManager.default.fileExists(atPath: target.path)
            }
            return ExternalConflict(
                role: record.role,
                destination: decision.destination,
                existingCount: existing.count,
                totalCount: files.count,
            )
        }
    }

    /// Fails before core files are replaced when an external destination cannot be written.
    static func validateExternalDestinations(
        _ decisions: [ExternalRestoreDecision],
    ) throws {
        let manager = FileManager.default
        for decision in decisions {
            var url = decision.destination
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw ArchiveError.writeFailed("\(url.path) is not a directory")
                }
                guard manager.isWritableFile(atPath: url.path) else {
                    throw ArchiveError.writeFailed("\(url.path) is not writable")
                }
                continue
            }
            while !manager.fileExists(atPath: url.path) {
                let parent = url.deletingLastPathComponent()
                if parent.path == url.path { break }
                url = parent
            }
            var parentIsDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &parentIsDirectory),
                parentIsDirectory.boolValue,
                manager.isWritableFile(atPath: url.path)
            else {
                throw ArchiveError.writeFailed(
                    "cannot create \(decision.destination.path)",
                )
            }
        }
    }

    @discardableResult
    static func applyExternal(
        decisions: [ExternalRestoreDecision],
        plan: ArchiveImportPlan,
        backup: URL,
        log: @escaping (String) -> Void = { _ in },
    ) throws -> ExternalApplyResult {
        var result = ExternalApplyResult()
        var applied: [(destination: URL, saved: URL?)] = []
        do {
            for record in plan.manifest.external {
                guard let decision = decisions.first(where: { $0.role == record.role }) else {
                    continue
                }
                let sourceRoot = plan.stagingDir.appendingPathComponent(record.archivePath)
                let files = try regularFiles(under: sourceRoot)
                for source in files {
                    let relative = relativePath(of: source, root: sourceRoot)
                    let destination = decision.destination.appendingPathComponent(relative)
                    var saved: URL?
                    if FileManager.default.fileExists(atPath: destination.path) {
                        switch decision.policy {
                        case .skipExisting:
                            result.skipped += 1
                            continue
                        case .overwrite:
                            let target =
                                backup
                                .appendingPathComponent("external-\(record.role.rawValue)")
                                .appendingPathComponent(relative)
                            try copy(destination, to: target)
                            saved = target
                            result.overwritten += 1
                        }
                    }
                    // Record first: copy trashes the target before writing.
                    applied.append((destination, saved))
                    try copy(source, to: destination)
                    result.copied += 1
                }
                log(
                    "restored \(record.role.rawValue) to \(decision.destination.path) "
                        + "(copied \(result.copied), skipped \(result.skipped))",
                )
            }
            return result
        } catch {
            rollbackExternal(applied)
            throw error
        }
    }

    private static func rollbackExternal(
        _ applied: [(destination: URL, saved: URL?)],
    ) {
        let manager = FileManager.default
        for entry in applied.reversed() {
            try? manager.trashItem(at: entry.destination, resultingItemURL: nil)
            if let saved = entry.saved {
                try? manager.copyItem(at: saved, to: entry.destination)
            }
        }
    }

    static func rewriteConfigPaths(
        configFile: URL,
        remaps: [ExternalRole: URL],
    ) throws {
        guard !remaps.isEmpty else { return }
        guard let text = try? String(contentsOf: configFile, encoding: .utf8),
            var root = (try? Yams.load(yaml: text)) as? [String: Any]
        else {
            throw ArchiveError.invalidManifest("cannot parse config.yaml")
        }
        if let newNotes = remaps[.notes], let oldNotes = stringValue(at: notesKey, in: root) {
            remapNested(key: likedKey, oldParent: oldNotes, newParent: newNotes, in: &root)
            remapNested(key: rssKey, oldParent: oldNotes, newParent: newNotes, in: &root)
        }
        for (role, url) in remaps {
            switch role {
            case .notes:
                setValue(url.path, at: notesKey, in: &root)
            case .liked:
                setValue(url.path, at: likedKey, in: &root)
            case .rss:
                setValue(url.path, at: rssKey, in: &root)
            }
        }
        let dumped = try Yams.dump(object: root, allowUnicode: true, sortKeys: true)
        let content = "\(L10n.Config.headerComment)\n\(dumped)"
        try Data(content.utf8).write(to: configFile, options: .atomic)
    }

    private static let notesKey = ["mcp", "knowledgeBasePath"]
    private static let likedKey = ["knowledge", "likedSaveDir"]
    private static let rssKey = ["rss", "daily", "outputDir"]

    /// Explicit liked/RSS paths inside the old notes directory follow the notes remap.
    private static func remapNested(
        key: [String],
        oldParent: String,
        newParent: URL,
        in root: inout [String: Any],
    ) {
        guard
            let raw = stringValue(at: key, in: root)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return }
        let child = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .standardizedFileURL.path
        let parent = URL(fileURLWithPath: (oldParent as NSString).expandingTildeInPath)
            .standardizedFileURL.path
        if child == parent {
            setValue(newParent.path, at: key, in: &root)
            return
        }
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        guard child.hasPrefix(prefix) else { return }
        let relative = String(child.dropFirst(prefix.count))
        setValue(newParent.appendingPathComponent(relative).path, at: key, in: &root)
    }

    private static func stringValue(at keys: [String], in root: [String: Any]) -> String? {
        guard let first = keys.first else { return nil }
        guard keys.count > 1 else { return root[first] as? String }
        guard let child = root[first] as? [String: Any] else { return nil }
        return stringValue(at: Array(keys.dropFirst()), in: child)
    }

    private static func setValue(
        _ value: Any,
        at keys: [String],
        in root: inout [String: Any],
    ) {
        guard let first = keys.first else { return }
        guard keys.count > 1 else {
            root[first] = value
            return
        }
        var child = root[first] as? [String: Any] ?? [:]
        setValue(value, at: Array(keys.dropFirst()), in: &child)
        root[first] = child
    }

    // MARK: - Import helpers

    private static func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            throw ArchiveError.pathTraversal(path)
        }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw ArchiveError.pathTraversal(path)
            }
        }
        let allowedPrefixes = ["config/", "data/", "external/"]
        guard allowedPrefixes.contains(where: path.hasPrefix) else {
            throw ArchiveError.invalidManifest("unexpected path \(path)")
        }
    }

    private static func destinationPath(for archivePath: String, configDir: URL) -> URL? {
        for prefix in ["config/", "data/"] where archivePath.hasPrefix(prefix) {
            return configDir.appendingPathComponent(String(archivePath.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func tableNames(at url: URL) throws -> Set<String> {
        let queue = try openReader(at: url)
        let names = try queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                    """,
            )
        }
        return Set(names)
    }

    private static func makeBackupDirectory(configDir: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let stamp = formatter.string(from: Date())
        let base = configDir.deletingLastPathComponent()
        var candidate = base.appendingPathComponent("utility.backup-\(stamp)", isDirectory: true)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent(
                "utility.backup-\(stamp)-\(index)",
                isDirectory: true,
            )
            index += 1
        }
        return candidate
    }

    private static func backupConfigDirectory(configDir: URL, to backup: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: backup, withIntermediateDirectories: true)
        let contents =
            (try? manager.contentsOfDirectory(at: configDir, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            let name = url.lastPathComponent
            if name == "mcp-venv" || name == ".import-staging" || name == ".DS_Store" { continue }
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") { continue }
            let target = backup.appendingPathComponent(name)
            if name.hasSuffix(".sqlite") {
                try backupDatabase(from: url, to: target)
            } else {
                try manager.copyItem(at: url, to: target)
            }
        }
    }

    private static func replace(staged: URL, destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        if destination.path.hasSuffix(".sqlite") {
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: destination.path + suffix)
                if manager.fileExists(atPath: sidecar.path) {
                    try? manager.trashItem(at: sidecar, resultingItemURL: nil)
                }
            }
        }
        if manager.fileExists(atPath: destination.path) {
            try manager.trashItem(at: destination, resultingItemURL: nil)
        }
        try manager.copyItem(at: staged, to: destination)
    }

    /// Restore the core config directory after a later import stage failed.
    static func rollbackCore(
        backup: URL,
        configDir: URL,
        plan: ArchiveImportPlan,
    ) throws {
        try restore(backup: backup, configDir: configDir)
        let manager = FileManager.default
        for file in plan.files {
            guard let destination = destinationPath(for: file.path, configDir: configDir)
            else { continue }
            let relative =
                destination.path.hasPrefix(configDir.path + "/")
                ? String(destination.path.dropFirst(configDir.path.count + 1))
                : destination.lastPathComponent
            let backedUp = backup.appendingPathComponent(relative)
            if !manager.fileExists(atPath: backedUp.path),
                manager.fileExists(atPath: destination.path)
            {
                if destination.path.hasSuffix(".sqlite") {
                    for suffix in ["-wal", "-shm"] {
                        let sidecar = URL(fileURLWithPath: destination.path + suffix)
                        try? manager.trashItem(at: sidecar, resultingItemURL: nil)
                    }
                }
                try? manager.trashItem(at: destination, resultingItemURL: nil)
            }
        }
    }

    private static func restore(backup: URL, configDir: URL) throws {
        let manager = FileManager.default
        let contents =
            (try? manager.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            let name = url.lastPathComponent
            guard !name.hasPrefix("external-") else { continue }
            let destination = configDir.appendingPathComponent(name)
            if name.hasSuffix(".sqlite") {
                for suffix in ["-wal", "-shm"] {
                    let sidecar = URL(fileURLWithPath: destination.path + suffix)
                    try? manager.trashItem(at: sidecar, resultingItemURL: nil)
                }
            }
            if manager.fileExists(atPath: destination.path) {
                try? manager.trashItem(at: destination, resultingItemURL: nil)
            }
            try manager.copyItem(at: url, to: destination)
        }
    }

    // MARK: - Staging

    private static func exportMember(
        _ member: ArchiveMember,
        to target: URL,
        includesSecrets: Bool,
    ) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        switch member.kind {
        case .copy:
            if !includesSecrets, member.archivePath == "config/config.yaml" {
                try sanitizedConfig(member.sourceURL).write(to: target, options: .atomic)
            } else if !includesSecrets, member.archivePath == "config/agent-gateway.yaml" {
                try sanitizedGatewayConfig(member.sourceURL).write(to: target, options: .atomic)
            } else {
                try FileManager.default.copyItem(at: member.sourceURL, to: target)
            }
        case .directory:
            try FileManager.default.copyItem(at: member.sourceURL, to: target)
        case .sqliteBackup:
            try backupDatabase(from: member.sourceURL, to: target)
        }
    }

    private static func copy(_ source: URL, to target: URL) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
        }
        try FileManager.default.copyItem(at: source, to: target)
    }

    private static func backupDatabase(from source: URL, to target: URL) throws {
        try withTimeout(databaseTimeout, label: "backup \(source.lastPathComponent)") {
            let reader = try openReader(at: source)
            let writer = try DatabaseQueue(path: target.path)
            try reader.backup(to: writer)
        }
    }

    /// A read-only connection cannot open a WAL database whose `-shm` file is absent
    /// (`SQLITE_CANTOPEN`). Retry read-write so SQLite may create the sidecar; the backup
    /// itself only reads.
    private static func openReader(at url: URL) throws -> DatabaseQueue {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArchiveError.invalidManifest("missing database \(url.lastPathComponent)")
        }
        var readOnly = Configuration()
        readOnly.readonly = true
        readOnly.busyMode = .timeout(5)
        if let queue = try? DatabaseQueue(path: url.path, configuration: readOnly) {
            return queue
        }
        var readWrite = Configuration()
        readWrite.busyMode = .timeout(5)
        return try DatabaseQueue(path: url.path, configuration: readWrite)
    }

    private static func zip(staging: URL, destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        }
        let result = ProcessRunner.runSync(
            ["/usr/bin/ditto", "-c", "-k", "--norsrc", staging.path, destination.path],
            timeout: zipTimeout,
        )
        guard result.ok, FileManager.default.fileExists(atPath: destination.path) else {
            let detail =
                result.timedOut
                ? "ditto timed out"
                : "ditto exited \(result.exitCode): \(result.output.suffix(400))"
            throw ArchiveError.writeFailed(detail)
        }
    }

    // MARK: - Secrets

    private static func sanitizedConfig(_ url: URL) throws -> Data {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let root = (try? Yams.load(yaml: text)) as? [String: Any] else {
            throw ArchiveError.invalidManifest("cannot parse \(url.lastPathComponent)")
        }
        let sanitized = blankAPIKeys(in: root)
        let dumped = try Yams.dump(object: sanitized, allowUnicode: true, sortKeys: true)
        let content = "\(L10n.Config.headerComment)\n\(dumped)"
        return Data(content.utf8)
    }

    private static func sanitizedGatewayConfig(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArchiveError.invalidManifest("cannot parse \(url.lastPathComponent)")
        }
        let sanitized = blankAPIKeys(in: root)
        return try JSONSerialization.data(
            withJSONObject: sanitized,
            options: [.prettyPrinted, .sortedKeys],
        )
    }

    private static func blankAPIKeys(in value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result = dictionary
            for key in Array(result.keys) {
                if key == "apiKey" {
                    result[key] = ""
                } else if let child = result[key] {
                    result[key] = blankAPIKeys(in: child)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map(blankAPIKeys)
        }
        return value
    }

    // MARK: - Manifest data

    private static func stagedFiles(root: URL) throws -> [ArchiveFile] {
        let urls = try regularFiles(under: root)
        let files = try urls.map { url in
            ArchiveFile(
                path: relativePath(of: url, root: root),
                sha256: try sha256(url),
                bytes: stats(of: url).bytes,
            )
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func sourcePaths(config: AppConfig, notesRoot: String) -> [String: String] {
        [
            "notesDir": notesRoot,
            "knowledgeBasePath": config.mcp?.knowledgeBasePath ?? "",
            "likedSaveDir": config.knowledge.likedSaveDir,
            "rssOutputDir": config.rss.daily.outputDir,
            "qdrantPath": config.mcp?.qdrantPath ?? "",
        ]
    }

    private static func regularFiles(under root: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in true },
            )
        else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            result.append(url)
        }
        return result
    }

    private static func stats(of url: URL) -> (files: Int, bytes: Int) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory != true {
            return (1, values?.fileSize ?? 0)
        }
        var files = 0
        var bytes = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true },
        )
        while let child = enumerator?.nextObject() as? URL {
            guard let childValues = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                childValues.isRegularFile == true
            else { continue }
            files += 1
            bytes += childValues.fileSize ?? 0
        }
        return (files, bytes)
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Utilities

    private static func withTimeout<T>(
        _ seconds: TimeInterval,
        label: String,
        _ work: @escaping () throws -> T,
    ) throws -> T {
        let box = TimeoutBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.result = Result { try work() }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + seconds) == .success else {
            throw ArchiveError.timeout(label)
        }
        guard let result = box.result else {
            throw ArchiveError.timeout(label)
        }
        return try result.get()
    }

    private static func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

private final class TimeoutBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
