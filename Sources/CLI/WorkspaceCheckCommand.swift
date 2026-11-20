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
        guard handled else {
            throw ValidationError(
                "Provide --sessions, --roundtrip, --state, --reattach or --restore",
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
