import ArgumentParser
import Foundation

/// `utility graph --sync [--root <path>]`
struct GraphCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graph",
        abstract: L10n.CLI.graphAbstract,
    )

    @Flag(name: .customLong("sync"), help: ArgumentHelp(L10n.CLI.graphSyncHelp))
    var sync = false

    @Option(name: .customLong("root"), help: ArgumentHelp(L10n.CLI.graphDirHelp))
    var root = FileManager.default.currentDirectoryPath

    func run() throws {
        guard sync else { throw CleanExit.helpRequest() }
        let scanner = try GraphScanner(projectPath: root)
        defer { scanner.stop() }
        let summary = try scanner.syncScan()
        print(
            "files=\(summary.stats.files) symbols=\(summary.stats.symbols) "
                + "edges=\(summary.stats.edges) elapsedMs=\(summary.elapsedMs)"
        )
    }
}
