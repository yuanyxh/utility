import Foundation

// MARK: - Root Config

public struct AppConfig: Codable {
    var ai: AIConfig = .init()
    var clipboard: ClipboardConfig = .init()
    var translation: TranslationConfig = .init()
    var stage: StageConfig = .init()
    var rss: RSSConfig = .init()
    var prompts: PromptConfig = .init()
}

// MARK: - AI

public struct AIConfig: Codable {
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
    }
}

// MARK: - Clipboard

public struct ClipboardConfig: Codable {
    var maxDays: Int = 3
    var excludeApps: [String] = ["SecurityAgent", "KeychainAccess"]
    var hotkey: String = "cmd+shift+c"
    var pollInterval: Double = 0.3

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxDays = try c.decodeIfPresent(Int.self, forKey: .maxDays) ?? 3
        excludeApps = try c.decodeIfPresent([String].self, forKey: .excludeApps) ?? ["SecurityAgent", "KeychainAccess"]
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? "cmd+shift+c"
        pollInterval = try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? 0.3
    }
}

// MARK: - Translation

public struct TranslationConfig: Codable {
    var hotkey: String = "option+d"
    var hotkeyOCR: String = "option+s"
    var sourceLang: String = "auto"
    var targetLang: String = "auto"
    var firstLang: String = "zh"
    var secondLang: String = "en"
    var prompt: String = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? "option+d"
        hotkeyOCR = try c.decodeIfPresent(String.self, forKey: .hotkeyOCR) ?? "option+s"
        sourceLang = try c.decodeIfPresent(String.self, forKey: .sourceLang) ?? "auto"
        targetLang = try c.decodeIfPresent(String.self, forKey: .targetLang) ?? "auto"
        firstLang = try c.decodeIfPresent(String.self, forKey: .firstLang) ?? "zh"
        secondLang = try c.decodeIfPresent(String.self, forKey: .secondLang) ?? "en"
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }
}

// MARK: - Stage

public struct StageConfig: Codable {
    var moveOnDragOut: Bool = false

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        moveOnDragOut = try c.decodeIfPresent(Bool.self, forKey: .moveOnDragOut) ?? false
    }
}

// MARK: - RSS

public struct RSSConfig: Codable {
    var feeds: [RSSFeedConfig] = []
    var updateInterval: Int = 30

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feeds = try c.decodeIfPresent([RSSFeedConfig].self, forKey: .feeds) ?? []
        updateInterval = try c.decodeIfPresent(Int.self, forKey: .updateInterval) ?? 30
    }
}

public struct RSSFeedConfig: Codable {
    var name: String
    var url: String
    var tags: [String] = []

    public init(name: String, url: String, tags: [String] = []) {
        self.name = name
        self.url = url
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

// MARK: - Prompt Templates

public struct PromptConfig: Codable {
    var templates: [String: String] = [:]

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templates = try c.decodeIfPresent([String: String].self, forKey: .templates) ?? [:]
    }
}
