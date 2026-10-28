import Foundation
import Yams

public final class ConfigManager {
    public static let shared = ConfigManager()
    public private(set) var config: AppConfig = .init()

    private let fileManager = FileManager.default
    private var configDir: URL {
        AppPaths.configDir
    }

    private var configFile: URL {
        AppPaths.configFile
    }

    private init() {}

    public func load() throws {
        if !fileManager.fileExists(atPath: configDir.path) {
            try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: configFile.path) {
            try writeDefault()
        }
        let data = try Data(contentsOf: configFile)
        let decoder = YAMLDecoder()
        config = try decoder.decode(AppConfig.self, from: data)
        L10n.setup()
        EventBus.shared.publish(AppEvent.configDidLoad)
    }

    public func reload() throws {
        try load()
    }

    /// Validates `rawText` as a complete config, writes it verbatim, then reloads.
    /// Validation runs before the write, so a bad edit never replaces a working config.
    public func apply(rawText: String) throws {
        _ = try YAMLDecoder().decode(AppConfig.self, from: Data(rawText.utf8))
        if !fileManager.fileExists(atPath: configDir.path) {
            try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
        try rawText.write(to: configFile, atomically: true, encoding: .utf8)
        try load()
    }

    /// Encodes the current config back to the config file (persists runtime changes).
    public func save() throws {
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(config)
        let content = """
        \(L10n.Config.headerComment)
        \(yaml)
        """
        try content.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Moves the specified provider to the front of the array as the default (default = providers[0]) and persists it.
    /// Does not modify anything if it is not found or is already first.
    public func setDefaultProvider(named name: String) throws {
        guard var proxy = config.modelProxy else { return }
        guard let idx = proxy.providers.firstIndex(where: { $0.name == name }), idx != 0 else { return }
        let provider = proxy.providers.remove(at: idx)
        proxy.providers.insert(provider, at: 0)
        config.modelProxy = proxy
        try save()
        EventBus.shared.publish(AppEvent.configDidLoad)
    }

    private func writeDefault() throws {
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(AppConfig())
        let commented = """
        \(L10n.Config.headerComment)
        \(yaml)
        """
        try commented.write(to: configFile, atomically: true, encoding: .utf8)
    }
}
