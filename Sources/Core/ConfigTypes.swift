import Foundation

// MARK: - Root Config

public struct AppConfig: Codable {
    var general: GeneralConfig = .init()
    var ai: AIConfig = .init()
    var clipboard: ClipboardConfig = .init()
    var translation: TranslationConfig = .init()
    var stage: StageConfig = .init()
    var rss: RSSConfig = .init()
    var tasks: [TaskConfig] = []
    var prompts: PromptConfig = .init()
    var notifications: NotificationConfig = .init()
    var mcp: MCPConfig? = nil
    var modelProxy: ModelProxyConfig? = nil
    var article: ArticleConfig = .init()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = (try? c.decode(GeneralConfig.self, forKey: .general)) ?? .init()
        ai = (try? c.decode(AIConfig.self, forKey: .ai)) ?? .init()
        clipboard = (try? c.decode(ClipboardConfig.self, forKey: .clipboard)) ?? .init()
        translation = (try? c.decode(TranslationConfig.self, forKey: .translation)) ?? .init()
        stage = (try? c.decode(StageConfig.self, forKey: .stage)) ?? .init()
        rss = (try? c.decode(RSSConfig.self, forKey: .rss)) ?? .init()
        tasks = (try? c.decode([TaskConfig].self, forKey: .tasks)) ?? []
        prompts = (try? c.decode(PromptConfig.self, forKey: .prompts)) ?? .init()
        notifications = (try? c.decode(NotificationConfig.self, forKey: .notifications)) ?? .init()
        mcp = try? c.decodeIfPresent(MCPConfig.self, forKey: .mcp)
        modelProxy = try? c.decodeIfPresent(ModelProxyConfig.self, forKey: .modelProxy)
        article = (try? c.decode(ArticleConfig.self, forKey: .article)) ?? .init()
    }
}

// MARK: - MCP

public struct MCPConfig: Codable {
    var enabled: Bool = true
    var port: Int = 9001

    // 数据存储路径
    var qdrantPath: String = "~/Documents/selfdata/database/qdrant_data"
    var knowledgeBasePath: String = "~/Documents/selfdata/notes"

    // fastembed 模型缓存
    var fastembedCacheDir: String = "~/.cache/fastembed_cache"
    var embedderModel: String = "sentence-transformers/all-MiniLM-L6-v2"

    // 记忆生命周期
    var hotRetentionDays: Int = 180
    var archiveDays: Int = 90

    // 每日总结
    var summaryEnabled: Bool = true
    var summaryHour: Int = 17
    var summaryStatsOnly: Bool = false

    // 进程守护
    var maxRestarts: Int = 3
    var restartDelayMs: Int = 2000

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 9001
        qdrantPath = try c.decodeIfPresent(String.self, forKey: .qdrantPath) ?? "~/Documents/selfdata/database/qdrant_data"
        knowledgeBasePath = try c.decodeIfPresent(String.self, forKey: .knowledgeBasePath) ?? "~/Documents/selfdata/notes"
        fastembedCacheDir = try c.decodeIfPresent(String.self, forKey: .fastembedCacheDir) ?? "~/.cache/fastembed_cache"
        embedderModel = try c.decodeIfPresent(String.self, forKey: .embedderModel) ?? "sentence-transformers/all-MiniLM-L6-v2"
        hotRetentionDays = try c.decodeIfPresent(Int.self, forKey: .hotRetentionDays) ?? 180
        archiveDays = try c.decodeIfPresent(Int.self, forKey: .archiveDays) ?? 90
        summaryEnabled = try c.decodeIfPresent(Bool.self, forKey: .summaryEnabled) ?? true
        summaryHour = try c.decodeIfPresent(Int.self, forKey: .summaryHour) ?? 17
        summaryStatsOnly = try c.decodeIfPresent(Bool.self, forKey: .summaryStatsOnly) ?? false
        maxRestarts = try c.decodeIfPresent(Int.self, forKey: .maxRestarts) ?? 3
        restartDelayMs = try c.decodeIfPresent(Int.self, forKey: .restartDelayMs) ?? 2000
    }
}

// MARK: - General

public struct GeneralConfig: Codable {
    var language: String = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
    }
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

// MARK: - Model Proxy

public enum ProxyAPIFormat: String, Codable {
    case anthropic
    case openai
}

/// 单个上游 provider（deepseek/mimo 等）。模型名列表即 /model 选择器
/// 可选的模型（body.model 精确匹配即路由到此 provider）。
public struct ProviderConfig: Codable {
    var name: String = ""
    var url: String = "" // 上游 API 地址（provider 自己的格式端点）
    var apiFormat: ProxyAPIFormat = .anthropic // anthropic | openai
    var apiKey: String = "" // 转发时替换的 provider key，为空则透传客户端 key
    var models: [String] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        apiFormat = (try? c.decode(ProxyAPIFormat.self, forKey: .apiFormat)) ?? .anthropic
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
    }
}

public struct ModelProxyConfig: Codable {
    var enabled: Bool = false
    var url: String = "" // 兼容：providers 为空时的单一上游地址
    var port: Int = 8080 // 本地代理监听端口
    /// providers 路由表，默认取第一个作为兜底（未匹配 model 时）
    var providers: [ProviderConfig] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        providers = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? []
    }
}

// MARK: - Article

/// 文章生成（gen-article 内部任务）配置。路径一律由 mcp.knowledgeBasePath
/// 推导出 Gen_Articles/ 工作目录，不做路径配置（最少配置化）。
public struct ArticleConfig: Codable {
    var enabled: Bool = false
    /// agent CLI 命令模板（占位符 {system_prompt_file}/{prompt_file} 由脚本替换）。
    /// ⚠️ GUI/LaunchAgent 启动的子进程 PATH 不含用户工具目录，主命令须写绝对路径。
    var agentCli: String = "/opt/homebrew/bin/claude -p --output-format text --append-system-prompt-file {system_prompt_file}"
    var retries: Int = 5

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        agentCli = try c.decodeIfPresent(String.self, forKey: .agentCli) ?? "/opt/homebrew/bin/claude -p --output-format text --append-system-prompt-file {system_prompt_file}"
        retries = try c.decodeIfPresent(Int.self, forKey: .retries) ?? 5
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
        excludeApps =
            try c.decodeIfPresent([String].self, forKey: .excludeApps) ?? [
                "SecurityAgent", "KeychainAccess",
            ]
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

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feeds = try c.decodeIfPresent([RSSFeedConfig].self, forKey: .feeds) ?? []
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

// MARK: - Notification

public struct NotificationConfig: Codable {
    var enabled: Bool = true

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

// MARK: - Task

public enum TaskTriggerMode: String, Codable {
    case cron
    case manual
}

public struct TaskConfig: Codable {
    var name: String = ""
    var trigger: String = "" // cron 表达式 或 事件名
    var exec: TaskExecConfig = .sh("")
    var enabled: Bool = true
    var mode: TaskTriggerMode = .cron

    public init() {}

    public init(name: String = "", trigger: String = "", exec: TaskExecConfig = .sh(""),
                enabled: Bool = true, mode: TaskTriggerMode = .cron)
    {
        self.name = name
        self.trigger = trigger
        self.exec = exec
        self.enabled = enabled
        self.mode = mode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = (try? c.decode(TaskTriggerMode.self, forKey: .mode)) ?? .cron
        // exec 可能是字符串（自动推断）或字典（显式声明）
        if let str = try? c.decode(String.self, forKey: .exec) {
            exec = TaskExecConfig.infer(from: str)
        } else if let dict = try? c.decode(TaskExecConfig.self, forKey: .exec) {
            exec = dict
        } else {
            exec = .sh("")
        }
    }
}

public enum TaskExecConfig: Codable {
    case sh(String)
    case js(String)
    case shortcuts(String)
    case py(String)

    enum CodingKeys: String, CodingKey { case type, command }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let cmd = try c.decode(String.self, forKey: .command)
        switch type {
        case "sh": self = .sh(cmd)
        case "js": self = .js(cmd)
        case "shortcuts": self = .shortcuts(cmd)
        case "py": self = .py(cmd)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown exec type: \(type)",
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .sh(v):
            try c.encode("sh", forKey: .type)
            try c.encode(v, forKey: .command)
        case let .js(v):
            try c.encode("js", forKey: .type)
            try c.encode(v, forKey: .command)
        case let .shortcuts(v):
            try c.encode("shortcuts", forKey: .type)
            try c.encode(v, forKey: .command)
        case let .py(v):
            try c.encode("py", forKey: .type)
            try c.encode(v, forKey: .command)
        }
    }

    /// Process 执行配置 — 包含已配置好的 Process 及管道
    struct ProcessConfig {
        let task: Process
        let outputPipe: Pipe
        let errorPipe: Pipe
    }

    /// 将配置转为 ProcessConfig
    func toProcess() -> ProcessConfig {
        let outPipe = Pipe()
        let errPipe = Pipe()
        let task = Process()
        task.standardOutput = outPipe
        task.standardError = errPipe

        switch self {
        case let .sh(cmd):
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-c", cmd]
        case let .js(code):
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-l", "JavaScript", "-e", code]
        case let .shortcuts(name):
            task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            task.arguments = ["run", name]
        case let .py(code):
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["python3", "-c", code]
        }

        return ProcessConfig(task: task, outputPipe: outPipe, errorPipe: errPipe)
    }

    /// 从字符串自动推断执行类型
    static func infer(from raw: String) -> TaskExecConfig {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix(".sh") { return .sh(t) }
        if t.hasSuffix(".js") || t.contains("Application(") { return .js(t) }
        if t.hasSuffix(".py") || t.contains("def ") || t.contains("import ") { return .py(t) }
        if t.contains("\n") { return .sh(t) } // 多行默认 shell
        return .shortcuts(t) // 单行默认快捷指令名
    }
}
