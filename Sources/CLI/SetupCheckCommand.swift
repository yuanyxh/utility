import ArgumentParser
import Foundation

/// Headless view of the first-launch dependency probe.
struct SetupCheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup-check",
        abstract: L10n.CLI.setupCheckAbstract,
    )

    @Option(help: ArgumentHelp(L10n.CLI.setupRootHelp))
    var root: String?

    func run() throws {
        let rawRoot = root ?? AppPaths.configDir.path
        let directory = URL(
            fileURLWithPath: (rawRoot as NSString).expandingTildeInPath,
            isDirectory: true,
        )
        let config = loadConfig(directory)
        for item in SetupProbe.check(config: config, configDir: directory) {
            var line = "\(item.id.rawValue): \(state(item.state))"
            if let version = item.version, !version.isEmpty {
                line += " version=\(version)"
            }
            if let path = item.path, !path.isEmpty {
                line += " path=\(path)"
            }
            print(line)
        }
    }

    private func loadConfig(_ directory: URL) -> AppConfig {
        ConfigManager.readConfigOrDefault(in: directory)
    }

    private func state(_ state: SetupState) -> String {
        switch state {
        case .ok: "ok"
        case .missing: "missing"
        case .optional: "optional"
        case .failed(let message): "failed(\(message))"
        }
    }
}
