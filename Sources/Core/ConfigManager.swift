import Foundation
import Yams

public enum ConfigApplyError: LocalizedError {
    case fileTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes):
            "Config file too large: \(bytes) bytes (limit 1048576)"
        }
    }
}

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
        try? GatewayConfigWriter.write(config)
        L10n.setup()
        EventBus.shared.publish(AppEvent.configDidLoad)
    }

    public func reload() throws {
        try load()
    }

    /// Encodes the full config, validates it, then replaces the file.
    /// Backs up the previous file and keeps top-level keys the Swift model does not own.
    public func apply(_ newConfig: AppConfig) throws {
        let encoded = try YAMLEncoder().encode(newConfig)
        let yaml = Self.decimalized(try mergedWithUnknownKeys(encoded))
        let content = "\(L10n.Config.headerComment)\n\(yaml)"
        let data = Data(content.utf8)
        guard data.count <= Self.maxConfigBytes else {
            throw ConfigApplyError.fileTooLarge(data.count)
        }
        _ = try YAMLDecoder().decode(AppConfig.self, from: data)
        try Self.writeWithBackup(content, to: configFile)
        try load()
    }

    /// Decodes the file without publishing `configDidLoad`.
    public func readConfigFromDisk() throws -> AppConfig {
        let data = try Data(contentsOf: configFile)
        return try YAMLDecoder().decode(AppConfig.self, from: data)
    }

    private static let maxConfigBytes = 1_048_576

    /// Writes the previous file to `<name>.bak`, then replaces the target.
    static func writeWithBackup(_ content: String, to file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try Data(contentsOf: file)
            try existing.write(to: file.appendingPathExtension("bak"), options: .atomic)
        }
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Keys such as `search` have no Swift model but still belong to the host config.
    /// Top-level only: nested drift is out of scope for the settings window.
    private func mergedWithUnknownKeys(_ encoded: String) throws -> String {
        guard let originalText = try? String(contentsOf: configFile, encoding: .utf8),
            let original = (try? Yams.load(yaml: originalText)) as? [String: Any],
            var updated = (try? Yams.load(yaml: encoded)) as? [String: Any]
        else { return encoded }
        for (key, value) in original where updated[key] == nil {
            updated[key] = value
        }
        return try Yams.dump(object: updated, allowUnicode: true, sortKeys: true)
    }

    /// Fills keys present in the template but missing from `original`.
    static func mergedWithTemplate(
        _ original: [String: Any], _ template: [String: Any], path: String = ""
    ) -> (value: [String: Any], added: [String]) {
        var value = original
        var added: [String] = []
        for (key, item) in template {
            let name = path.isEmpty ? key : "\(path).\(key)"
            if value[key] == nil {
                value[key] = item
                added.append(contentsOf: Self.leafNames(item, path: name))
            } else if let nested = item as? [String: Any],
                let current = value[key] as? [String: Any]
            {
                let merged = mergedWithTemplate(current, nested, path: name)
                value[key] = merged.value
                added.append(contentsOf: merged.added)
            }
        }
        return (value, added)
    }

    private static func leafNames(_ item: Any, path: String) -> [String] {
        guard let dict = item as? [String: Any], !dict.isEmpty else { return [path] }
        return dict.flatMap { leafNames($0.value, path: "\(path).\($0.key)") }.sorted()
    }

    /// Yams renders every `Double` in scientific notation (`3e-1`), which PyYAML
    /// reads back as a string. Rewrite scalar-only numeric lines as decimals.
    static func decimalized(_ yaml: String) -> String {
        let pattern = #"^(\s*[^#\s][^:]*:\s*)([-+]?\d+(?:\.\d+)?[eE][-+]?\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return yaml }
        var lines = yaml.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                let valueRange = Range(match.range(at: 2), in: line),
                let value = Double(line[valueRange])
            else { continue }
            lines[index] = line.replacingCharacters(
                in: valueRange, with: decimalText(value)
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func decimalText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumSignificantDigits = 15
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Validates `rawText` as a complete config, writes it verbatim, then reloads.
    /// Validation runs before the write, so a bad edit never replaces a working config.
    public func apply(rawText: String) throws {
        _ = try YAMLDecoder().decode(AppConfig.self, from: Data(rawText.utf8))
        if !fileManager.fileExists(atPath: configDir.path) {
            try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
        try Self.writeWithBackup(rawText, to: configFile)
        try load()
    }

    /// Encodes the current config back to the config file (persists runtime changes).
    public func save() throws {
        let encoder = YAMLEncoder()
        let yaml = Self.decimalized(try encoder.encode(config))
        let content = """
        \(L10n.Config.headerComment)
        \(yaml)
        """
        try Self.writeWithBackup(content, to: configFile)
        try? GatewayConfigWriter.write(config)
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

    /// Reads config.yaml, falling back to the bundled template before `load()` writes it.
    /// Setup runs ahead of `load()`, so a fresh machine has no file yet; decoding
    /// `AppConfig()` there leaves `mcp` nil and hides the optional installs.
    static func readConfigOrDefault(in directory: URL) -> AppConfig {
        let file = directory.appendingPathComponent("config.yaml")
        if let data = try? Data(contentsOf: file),
            let config = try? YAMLDecoder().decode(AppConfig.self, from: data)
        {
            return config
        }
        if let url = Bundle.module.url(forResource: "default-config", withExtension: "yaml"),
            let data = try? Data(contentsOf: url),
            let config = try? YAMLDecoder().decode(AppConfig.self, from: data)
        {
            return config
        }
        return AppConfig()
    }

    private func writeDefault() throws {
        if let url = Bundle.module.url(forResource: "default-config", withExtension: "yaml"),
            let data = try? Data(contentsOf: url)
        {
            try data.write(to: configFile, options: .atomic)
            return
        }
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(AppConfig())
        let commented = """
        \(L10n.Config.headerComment)
        \(yaml)
        """
        try commented.write(to: configFile, atomically: true, encoding: .utf8)
    }
}
