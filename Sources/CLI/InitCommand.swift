import ArgumentParser
import Foundation

/// `utility init [--path <path>]`
/// Scans the project at the given path (or CWD) and generates `.utility/deps.sqlite`.
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Scan the project and generate a dependency graph (.utility/deps.sqlite)",
    )

    @Option(name: .shortAndLong, help: ArgumentHelp("Project path (default: current directory)"))
    var path: String?

    func run() throws {
        let projectPath = path ?? FileManager.default.currentDirectoryPath

        // Validate project path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir),
              isDir.boolValue
        else {
            print("Error: invalid path or not a directory — \(projectPath)")
            Darwin.exit(1)
        }

        print("Scanning project: \(projectPath)")
        let summary = try ProjectScanner.shared.scan(projectPath: projectPath)
        print(summary)
        print("Written: \((projectPath as NSString).appendingPathComponent(".utility/deps.sqlite"))")
    }
}
