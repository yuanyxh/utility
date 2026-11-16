import ArgumentParser
import Foundation
import Yams

/// `utility config --migrate [--dry-run]`
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: L10n.CLI.configAbstract,
    )

    @Flag(
        name: .customLong("migrate"),
        help: ArgumentHelp(L10n.CLI.configMigrateHelp))
    var migrate = false

    @Flag(
        name: .customLong("dry-run"),
        help: ArgumentHelp(L10n.CLI.configDryRunHelp))
    var dryRun = false

    func run() throws {
        guard migrate else { throw CleanExit.helpRequest() }
        let file = AppPaths.configFile
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw ValidationError("no config at \(file.path)")
        }
        guard let original = (try? Yams.load(yaml: text)) as? [String: Any] else {
            throw ValidationError("config.yaml is not a mapping")
        }
        guard
            let templateURL = Bundle.module.url(
                forResource: "default-config", withExtension: "yaml"
            ), let templateText = try? String(contentsOf: templateURL, encoding: .utf8),
            let template = (try? Yams.load(yaml: templateText)) as? [String: Any]
        else {
            throw ValidationError("bundled default-config.yaml is missing")
        }

        let merged = ConfigManager.mergedWithTemplate(original, template)
        let yaml = ConfigManager.decimalized(
            try Yams.dump(object: merged.value, allowUnicode: true, sortKeys: true)
        )
        _ = try YAMLDecoder().decode(AppConfig.self, from: Data(yaml.utf8))

        for name in merged.added.sorted() { print("added \(name)") }
        for change in Self.decimalChanges(in: text) { print("decimal \(change)") }
        print("missing=\(merged.added.count)")

        guard !dryRun else { return }
        let content = "\(L10n.Config.headerComment)\n\(yaml)"
        try ConfigManager.shared.apply(rawText: content)
        print("backup=\(file.appendingPathExtension("bak").path)")
    }

    private static func decimalChanges(in text: String) -> [String] {
        let before = text.components(separatedBy: "\n")
        let after = ConfigManager.decimalized(text).components(separatedBy: "\n")
        return zip(before, after).compactMap {
            $0 == $1 ? nil : $0.trimmingCharacters(in: .whitespaces)
        }
    }
}
