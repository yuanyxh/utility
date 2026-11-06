import ArgumentParser
import Foundation

/// Headless checks for the workspace model: migration, JSON round-trip and document state.
struct WorkspaceCheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace-check",
        abstract: L10n.CLI.workspaceCheckAbstract,
    )

    @Option(name: .customLong("sessions"), help: ArgumentHelp(L10n.CLI.workspaceSessionsHelp))
    var sessions: String?

    @Flag(name: .customLong("dry-run"), help: ArgumentHelp(L10n.CLI.workspaceDryRunHelp))
    var dryRun = false

    @Option(name: .customLong("roundtrip"), help: ArgumentHelp(L10n.CLI.workspaceRoundtripHelp))
    var roundtrip: String?

    @Option(name: .customLong("state"), help: ArgumentHelp(L10n.CLI.workspaceStateHelp))
    var state: String?

    @Option(name: .customLong("reattach"), help: ArgumentHelp(L10n.CLI.workspaceReattachHelp))
    var reattach: String?

    @Option(name: .customLong("restore"), help: ArgumentHelp(L10n.CLI.workspaceRestoreHelp))
    var restore: String?

    @Option(name: .customLong("live"), help: ArgumentHelp(L10n.CLI.workspaceLiveHelp))
    var live: String?

    @Option(name: .customLong("tree"), help: ArgumentHelp(L10n.CLI.workspaceTreeHelp))
    var tree: String?

    @Option(name: .customLong("save"), help: ArgumentHelp(L10n.CLI.workspaceSaveHelp))
    var save: String?

    @Option(name: .customLong("draft"), help: ArgumentHelp(L10n.CLI.workspaceDraftHelp))
    var draft: String?

    @Option(name: .customLong("highlight"), help: ArgumentHelp(L10n.CLI.workspaceHighlightHelp))
    var highlight: String?

    @Option(name: .customLong("git"), help: ArgumentHelp(L10n.CLI.workspaceGitHelp))
    var git: String?

    @Option(name: .customLong("dirty"), help: ArgumentHelp(L10n.CLI.workspaceDirtyHelp))
    var dirty: String?

    @Option(name: .customLong("ui"), help: ArgumentHelp(L10n.CLI.workspaceUiHelp))
    var ui: String?

    func run() throws {
        var handled = false
        if let sessions, reattach == nil {
            handled = true
            try printMigration(path: sessions)
        }
        if let roundtrip {
            handled = true
            try checkRoundtrip(path: roundtrip)
        }
        if let state {
            handled = true
            try printState(path: state)
        }
        if let reattach {
            handled = true
            try printReattachment(documentPath: reattach)
        }
        if let restore {
            handled = true
            try printRestorePlan(path: restore)
        }
        if let tree {
            handled = true
            try printTree(path: tree)
        }
        if let save {
            handled = true
            try checkSave(path: save)
        }
        if let draft {
            handled = true
            try checkDraft(directory: draft)
        }
        if let highlight {
            handled = true
            try printHighlight(path: highlight)
        }
        if let git {
            handled = true
            try printGit(path: git)
        }
        if let dirty {
            handled = true
            try checkDirty(path: dirty)
        }
        if let ui {
            handled = true
            try printUIState(path: ui)
        }
        guard handled else {
            throw ValidationError(
                "Provide --sessions, --roundtrip, --state, --reattach, --restore, "
                    + "--tree, --save, --draft, --highlight, --git, --dirty or --ui",
            )
        }
    }

    private func printMigration(path: String) throws {
        let stored = try loadSessions(path)
        let document = WorkspaceMigration.plan(sessions: stored)
        if dryRun {
            print("dry-run: true")
        }
        print("workspaces: \(document.workspaces.count)")
        print("sessions: \(stored.count)")
        for workspace in document.workspaces {
            print("workspace: \(workspace.id) \(workspace.path)")
            if let main = workspace.mainSessionID {
                print("  main: \(main)")
            }
            for sub in workspace.subSessionIDs {
                print("  sub: \(sub)")
            }
        }
    }

    private func checkRoundtrip(path: String) throws {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: source)
        let original = try WorkspaceJSON.decode(data).normalized()
        let encoded = try WorkspaceJSON.encode(original)
        let decoded = try WorkspaceJSON.decode(encoded).normalized()
        guard original == decoded else {
            print("roundtrip: mismatch")
            throw ExitCode.failure
        }
        print("roundtrip: ok")
        print("workspaces: \(decoded.workspaces.count)")
        print("sessions: \(decoded.sessionCount)")
        if let selected = decoded.selectedWorkspaceID {
            print("selected: \(selected)")
        }
    }

    private func printState(path: String) throws {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: source)
        let document = try WorkspaceJSON.decode(data).normalized()
        print("workspaces: \(document.workspaces.count)")
        print("sessions: \(document.sessionCount)")
        if let selected = document.selectedWorkspaceID {
            print("selected: \(selected)")
        }
    }

    private func printUIState(path: String) throws {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let document = try WorkspaceJSON.decode(try Data(contentsOf: source)).normalized()
        print("version: \(document.version)")
        for workspace in document.workspaces {
            let ui = workspace.ui
            print("workspace: \(workspace.id) \(workspace.name)")
            print(
                "  ui: list=\(ui.activeList.rawValue) expanded=\(ui.expandedPaths.count) "
                    + "caret=\(ui.caretLocation) scroll=\(Int(ui.scrollY)) "
                    + "preview=\(ui.previewMode.rawValue)",
            )
        }
    }

    private func printReattachment(documentPath: String) throws {
        guard let sessions else {
            throw ValidationError("--reattach requires --sessions")
        }
        let document = try loadDocument(documentPath)
        let merged = WorkspaceReattribution.apply(
            document: document, sessions: try loadSessions(sessions),
        )
        print("reattach: ok")
        print("workspaces: \(merged.workspaces.count)")
        for workspace in merged.workspaces {
            print("workspace: \(workspace.id) \(workspace.path)")
            if let main = workspace.mainSessionID {
                print("  main: \(main)")
            }
            for sub in workspace.subSessionIDs {
                print("  sub: \(sub)")
            }
        }
    }

    private func printRestorePlan(path: String) throws {
        guard let live else {
            throw ValidationError("--restore requires --live")
        }
        let liveIDs = Set(
            live.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            },
        )
        let document = try loadDocument(path)
        let plan = WorkspaceRestorePlan(document: document, liveIDs: liveIDs)
        print("workspaces: \(plan.workspaces.count)")
        for workspace in plan.workspaces {
            print("workspace: \(workspace.workspaceID)")
            if let main = workspace.mainSessionID {
                print("  main: \(main)")
            }
            for sub in workspace.subSessionIDs {
                print("  sub: \(sub)")
            }
            if workspace.rebuildMain {
                print("  rebuild-main: true")
            }
        }
    }

    private func printTree(path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            print("tree: error not-a-directory \(url.path)")
            throw ExitCode.failure
        }
        let config = ConfigManager.shared.config.workspace
        let count = FileTreeScanner.countFiles(
            at: url, showHidden: config.showHiddenFiles,
            extraIgnores: Set(config.ignoredDirectories),
        )
        print("tree: \(count)")
    }

    /// Saves a probe marker, then checks encoding/BOM/CRLF and external-change detection.
    /// The original bytes and mtime are restored before returning.
    private func checkSave(path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let fm = FileManager.default
        let original = try Data(contentsOf: url)
        let originalDate = (try fm.attributesOfItem(atPath: url.path))[.modificationDate] as? Date
        defer {
            try? original.write(to: url)
            if let originalDate {
                try? fm.setAttributes([.modificationDate: originalDate], ofItemAtPath: url.path)
            }
        }

        let maxBytes = 32 * 1024 * 1024
        guard case .text(let document) = FileDocument.load(url: url, maxBytes: maxBytes) else {
            print("save: not-text")
            throw ExitCode.failure
        }
        let lineEnding = document.lineEnding
        let hadBOM = document.hadBOM
        let marker = "save-check-\(UUID().uuidString.prefix(8))"
        document.updateText(document.text + "\n// \(marker)\n")
        try document.save(overwriteExternal: false)
        guard !document.isDirty(currentText: document.text) else {
            print("save: dirty-after-save")
            throw ExitCode.failure
        }
        guard case .text(let reloaded) = FileDocument.load(url: url, maxBytes: maxBytes),
            reloaded.text.contains(marker), reloaded.lineEnding == lineEnding,
            reloaded.hadBOM == hadBOM
        else {
            print("save: reload-mismatch")
            throw ExitCode.failure
        }

        var same = try Data(contentsOf: url)
        if let index = same.lastIndex(of: UInt8(ascii: "z")) {
            same[index] = UInt8(ascii: "y")
        } else {
            same[same.count - 1] ^= 1
        }
        try same.write(to: url)
        let modified = reloaded.fingerprint.modified
        try? fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path,
        )
        guard reloaded.checkExternalChange() == .modified else {
            print("save: hash-check-missed")
            throw ExitCode.failure
        }
        try fm.removeItem(at: url)
        guard reloaded.checkExternalChange() == .deleted else {
            print("save: delete-missed")
            throw ExitCode.failure
        }
        print("save: ok lineEnding=\(lineEnding.rawValue) bom=\(hadBOM)")
    }

    private func checkDirty(path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard case .text(let document) = FileDocument.load(url: url, maxBytes: 32 * 1024 * 1024)
        else {
            print("dirty: not-text")
            throw ExitCode.failure
        }
        print("baseline: \(document.isDirty(currentText: document.text))")
        print("appended: \(document.isDirty(currentText: document.text + "x"))")
        print("restored: \(document.isDirty(currentText: document.text))")
        let crlf = document.text.replacingOccurrences(of: "\n", with: "\r\n")
        print("crlf-equal: \(document.isDirty(currentText: crlf))")
    }

    private func checkDraft(directory: String) throws {
        let dir = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EditorDraftStore(directory: dir)
        let sample = dir.appendingPathComponent("sample.txt")
        let draft = EditorDraft(
            url: sample, text: "hello\nworld\n", encoding: .utf8, lineEnding: .crlf,
            fingerprint: FileFingerprint(size: 12, modified: 0),
        )
        try store.save(draft)
        guard store.loadAll().first?.text == draft.text else {
            print("draft: roundtrip-mismatch")
            throw ExitCode.failure
        }
        try Data("{".utf8).write(to: dir.appendingPathComponent("broken.json"))
        guard store.loadAll().count == 1,
            try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .contains(where: { $0.contains(".corrupt-") })
        else {
            print("draft: quarantine-missed")
            throw ExitCode.failure
        }
        for index in 0..<3 {
            let extra = EditorDraft(
                url: dir.appendingPathComponent("extra-\(index).txt"), text: "x",
                encoding: .utf8, lineEnding: .lf,
                fingerprint: FileFingerprint(size: 1, modified: 0),
            )
            try store.save(extra)
        }
        store.evict(maxCount: 2, maxBytes: 50 * 1024 * 1024)
        let kept = store.loadAll().count
        guard kept <= 2 else {
            print("draft: evict-missed count=\(kept)")
            throw ExitCode.failure
        }
        store.delete(draft)
        guard !store.loadAll().contains(where: { $0.url == sample.path }) else {
            print("draft: delete-missed")
            throw ExitCode.failure
        }
        print("draft: ok kept=\(kept)")
    }

    /// Prints git status grouped by staged / unstaged / untracked.
    private func printGit(path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let service = GitService(root: url)
        let box = GitCLIResult()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let isRepository = await service.isRepository()
            var items: [GitFileStatus] = []
            var ignored: Set<String> = []
            var failure: String?
            if isRepository {
                do {
                    let status = try await service.status()
                    items = status.files
                    ignored = status.ignoredPaths
                } catch {
                    failure = "\(error)"
                }
            }
            let branch = isRepository ? await service.branch() : nil
            box.set(
                isRepository: isRepository, items: items, ignored: ignored, branch: branch,
                error: failure,
            )
            semaphore.signal()
        }
        semaphore.wait()
        guard box.isRepository else {
            print("git: not-repository")
            return
        }
        if let failure = box.error {
            print("git: error \(failure)")
            throw ExitCode.failure
        }
        print("git: \(box.items.count) files")
        print("branch: \(box.branch ?? "unknown")")
        print("ignored: \(box.ignored.count)")
        if !box.ignored.isEmpty {
            print("ignored-sample: \(box.ignored.sorted().prefix(3).joined(separator: ", "))")
        }
        for section in GitStatusModel.sections(from: box.items) {
            print("\(section.title): \(section.items.count)")
            for item in section.items {
                print("  \(item.code) \(item.path)")
            }
        }
    }

    private final class GitCLIResult {
        private let lock = NSLock()
        private var repository = false
        private var files: [GitFileStatus] = []
        private var ignoredPaths: Set<String> = []
        private var branchName: String?
        private var failure: String?

        func set(
            isRepository: Bool, items: [GitFileStatus], ignored: Set<String>, branch: String?,
            error: String?,
        ) {
            lock.lock()
            repository = isRepository
            files = items
            ignoredPaths = ignored
            branchName = branch
            failure = error
            lock.unlock()
        }

        var ignored: Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return ignoredPaths
        }

        var error: String? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        var branch: String? {
            lock.lock()
            defer { lock.unlock() }
            return branchName
        }

        var isRepository: Bool {
            lock.lock()
            defer { lock.unlock() }
            return repository
        }

        var items: [GitFileStatus] {
            lock.lock()
            defer { lock.unlock() }
            return files
        }
    }

    /// Prints line count, token totals and up to five samples per token kind.
    private func printHighlight(path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let definition = SyntaxDefinitions.definition(forExtension: url.pathExtension) else {
            print("highlight: unsupported")
            throw ExitCode.failure
        }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self) as NSString
        let started = DispatchTime.now().uptimeNanoseconds
        let tokens = SyntaxHighlighter.tokens(
            in: text, range: NSRange(location: 0, length: text.length), definition: definition,
        )
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print("highlight: \(text.components(separatedBy: "\n").count)")
        print(String(format: "time: %.2fms", elapsed))
        let order: [SyntaxTokenKind] = [.keyword, .string, .comment, .number]
        let totals = order.map { kind in
            "\(kind.rawValue)=\(tokens.filter { $0.kind == kind }.count)"
        }
        print("tokens: " + totals.joined(separator: " "))
        for kind in order {
            let samples = tokens.filter { $0.kind == kind }.prefix(5)
            for token in samples {
                var sample = text.substring(with: token.range)
                if sample.count > 40 { sample = String(sample.prefix(40)) }
                print("\(kind.rawValue): \(sample)")
            }
        }
    }

    private func loadDocument(_ path: String) throws -> WorkspaceDocument {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return try WorkspaceJSON.decode(try Data(contentsOf: url))
    }

    private func loadSessions(_ path: String) throws -> [StoredTerminalSession] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([StoredTerminalSession].self, from: data)
    }
}
