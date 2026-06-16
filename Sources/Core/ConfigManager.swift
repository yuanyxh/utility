import Foundation
import Yams

public final class ConfigManager {
    public static let shared = ConfigManager()
    public private(set) var config: AppConfig = .init()

    private let fileManager = FileManager.default
    private var configDir: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/utility")
    }
    private var configFile: URL {
        configDir.appendingPathComponent("config.yaml")
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
        Log.debug("[Config] Loaded from \(configFile.path)")
    }

    public func reload() throws {
        try load()
        NotificationCenter.default.post(name: .configDidReload, object: nil)
    }

    private func writeDefault() throws {
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(AppConfig())
        // 添加注释（Yams 不支持直接写注释，用字符串替换方式追加）
        let commented = """
        # Utility 配置文件
        # 存放路径: ~/.config/utility/config.yaml
        # 修改后通过菜单栏「重载配置」或重启生效
        \(yaml)
        """
        try commented.write(to: configFile, atomically: true, encoding: .utf8)
        Log.debug("[Config] Created default config at \(configFile.path)")
    }

    /// 获取某个配置值的字符串表示（用于菜单栏展示）
    public func summary() -> String {
        let aiModel = config.ai.model
        let clipDays = config.clipboard.maxDays
        let langPair = "\(config.translation.sourceLang)→\(config.translation.targetLang)"
        return "AI: \(aiModel) | 剪切板: \(clipDays)天 | 翻译: \(langPair)"
    }
}

extension Notification.Name {
    static let configDidReload = Notification.Name("configDidReload")
}
