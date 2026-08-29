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

    /// 将当前 config 编码写回配置文件（运行时修改持久化）。
    public func save() throws {
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(config)
        let content = """
        \(L10n.Config.headerComment)
        \(yaml)
        """
        try content.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// 把指定 provider 移到数组首位作为默认（默认 = providers[0]），并持久化。
    /// 未找到或已是首位时不修改。
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
