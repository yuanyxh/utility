import ArgumentParser
import Foundation

/// `utility init [--path <path>]`
/// Scans the project at the given path (or CWD) and generates `.utility/deps.sqlite`.
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "扫描项目并生成依赖图 (.utility/deps.sqlite)"
    )

    @Option(name: .shortAndLong, help: ArgumentHelp("项目路径（默认：当前目录）"))
    var path: String?

    func run() throws {
        let projectPath = path ?? FileManager.default.currentDirectoryPath

        // Validate project path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir),
              isDir.boolValue
        else {
            print("错误：路径无效或不是目录 — \(projectPath)")
            Darwin.exit(1)
        }

        print("扫描项目: \(projectPath)")
        let summary = try ProjectScanner.shared.scan(projectPath: projectPath)
        print(summary)
        print("已写入: \((projectPath as NSString).appendingPathComponent(".utility/deps.sqlite"))")
    }
}
