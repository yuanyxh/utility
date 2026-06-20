import Foundation
import Yams

public final class ConfigManager {
    public static let shared = ConfigManager()
    public private(set) var config: AppConfig = .init()

    private let fileManager = FileManager.default
    private var configDir: URL { AppPaths.configDir }
    private var configFile: URL { AppPaths.configFile }

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
        debugLog("[Config] Loaded from \(configFile.path)")
    }

    public func reload() throws {
        try load()
        cleanupStaleTaskStates()
        TaskScheduler.shared.reschedule()
    }

    private func cleanupStaleTaskStates() {
        let configuredNames = Set(config.tasks.map { $0.name })
        let dbNames = TaskStateDB.shared.allTaskNames()
        let stale = dbNames.filter { !configuredNames.contains($0) }
        for name in stale {
            TaskStateDB.shared.remove(taskName: name)
            debugLog("[Config] Removed stale task state: \(name)")
        }
    }

    private func writeDefault() throws {
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(AppConfig())
        let commented = """
        # Utility 配置文件
        # 修改后通过菜单栏「重载配置」或重启生效
        \(yaml)
        """
        try commented.write(to: configFile, atomically: true, encoding: .utf8)
    }
}
