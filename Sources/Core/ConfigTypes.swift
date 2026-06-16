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
    var baseURL: String = "https://api.deepseek.com"
    var apiKey: String = ""
    var model: String = "deepseek-v4-flash"
}

// MARK: - Clipboard

public struct ClipboardConfig: Codable {
    var maxDays: Int = 3
    var excludeApps: [String] = ["SecurityAgent", "KeychainAccess"]
    var hotkey: String = "cmd+shift+c"
    var maxItems: Int = 1000
    var pollInterval: Double = 0.3
}

// MARK: - Translation

public struct TranslationConfig: Codable {
    var hotkey: String = "option+d"
    var hotkeyOCR: String = "option+shift+d"
    var sourceLang: String = "auto"
    var targetLang: String = "zh"
    var secondLang: String = "en"

    /// 自定义翻译提示词，例如 "你是一个专业的技术文档翻译，保留代码和专有名词不翻译"
    /// 支持 {source} 和 {target} 变量替换
    var prompt: String = ""
}

// MARK: - Stage (Drag & Drop)

public struct StageConfig: Codable {
    var storageLimit: Int = 50
}

// MARK: - RSS

public struct RSSConfig: Codable {
    var feeds: [RSSFeedConfig] = []
    var updateInterval: Int = 30  // 分钟
}

public struct RSSFeedConfig: Codable {
    var name: String
    var url: String
    var tags: [String] = []
}

// MARK: - Prompt Templates

public struct PromptConfig: Codable {
    /// 提示词模板字典：键是功能名，值是提示词内容
    /// 例如 "summarize": "请用中文总结以下内容的要点"
    var templates: [String: String] = [:]
}
