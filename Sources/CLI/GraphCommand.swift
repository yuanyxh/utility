import ArgumentParser
import Foundation

/// `utility graph --sync [--dir <path>]`
struct GraphCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graph",
        abstract: L10n.CLI.graphAbstract,
    )

    @Flag(name: .customLong("sync"), help: ArgumentHelp(L10n.CLI.graphSyncHelp))
    var sync = false

    @Option(name: .customLong("dir"), help: ArgumentHelp(L10n.CLI.graphDirHelp))
    var directory = FileManager.default.currentDirectoryPath

    func run() throws {
        guard sync else { throw CleanExit.helpRequest() }
        let scanner = try GraphScanner(projectPath: directory)
        defer { scanner.stop() }
        let summary = try scanner.syncScan()
        print(
            "files=\(summary.stats.files) symbols=\(summary.stats.symbols) "
                + "edges=\(summary.stats.edges) elapsedMs=\(summary.elapsedMs)"
        )
    }
}
