import Foundation

// MARK: - 配置默认值

/// 跨类型共用的配置默认值（单一权威）。
///
/// 同一条默认值同时出现在「属性初值」与「解码兜底」两处时，改一处漏一处就会产生
/// 「YAML 写了走一个默认、没写走另一个默认」的行为分裂；`OpenAIClient` 的兜底
/// 又是第三处。故集中于此，三处一律引用常量。
enum ConfigDefaults {
    /// AI API 请求超时（秒）——`general.aiTimeout` 的默认值。
    ///
    /// ⚠️ 语义是 **agent / HTTP 调用**超时（Swift 注入 `AGENT_TIMEOUT` 供 Python 侧
    /// agent 子进程使用），与 `ai.llmTimeout`（Python 侧 LLM 单次推理超时，
    /// 注入 `AI_LLM_TIMEOUT`）**不是一回事**——两者值恰好都是 120，极易混用。
    static let defaultAITimeout: TimeInterval = 120

    /// LLM 单次推理超时（秒）——`ai.llmTimeout` 的默认值。
    ///
    /// 三处 Python 侧 LLM 调用共用它（单次摘要 / 批量聚合 / 规则提炼）。
    /// `0` 或负值 = 用本默认值（沿用 `OpenAIClient.init` 的 `timeout > 0` 约定）。
    static let llmTimeout: TimeInterval = 120
}

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
    }
}

// MARK: - MCP

public struct MCPConfig: Codable {
    var enabled: Bool = true
    /// 本地 MCP 服务端口，0 = 自动检测可用端口
    var port: Int = 0

    // 数据存储路径（空字符串 = 未配置，使用 ~./utility/ 推导）
    var qdrantPath: String = ""
    var knowledgeBasePath: String = ""

    /// fastembed 模型缓存（空字符串 = 未配置，使用 ~/.cache/utility/fastembed/）
    var fastembedCacheDir: String = ""
    /// 空字符串 = 使用内置默认模型
    var embedderModel: String = ""

    // 记忆生命周期
    var hotRetentionDays: Int = 180
    var archiveDays: Int = 90

    // 每日总结
    var summaryEnabled: Bool = true
    var summaryHour: Int = 17

    /// 总结排除 tag（跳过含这些 tag 的记忆）
    var excludeTags: [String] = []

    /// 检索同义词扩展表（**增量补充**：同名覆盖内置、异名追加）。
    /// 内置表在 `Sources/MCPScripts/synonyms.py`，这里只放用户自定义的部分——
    /// 用户改的应该是「加几个词」，而不是抄一份完整内置表来维护。
    var synonyms: [String: String] = [:]

    /// 工具参数默认值（tool name → args name → 默认值，**增量补充**：同名覆盖内置）。
    /// 内置表在 `Sources/MCPScripts/tool_defaults.py`；这些默认值直接决定每次
    /// 工具调用的返回量，即 token 消耗，故做成配置面而非代码常量。
    var toolDefaults: [String: [String: Int]] = [:]

    // 进程守护
    var maxRestarts: Int = 3
    var restartDelayMs: Int = 2000

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        qdrantPath = try c.decodeIfPresent(String.self, forKey: .qdrantPath) ?? ""
        knowledgeBasePath = try c.decodeIfPresent(String.self, forKey: .knowledgeBasePath) ?? ""
        fastembedCacheDir = try c.decodeIfPresent(String.self, forKey: .fastembedCacheDir) ?? ""
        embedderModel = try c.decodeIfPresent(String.self, forKey: .embedderModel) ?? ""
        hotRetentionDays = try c.decodeIfPresent(Int.self, forKey: .hotRetentionDays) ?? 180
        archiveDays = try c.decodeIfPresent(Int.self, forKey: .archiveDays) ?? 90
        summaryEnabled = try c.decodeIfPresent(Bool.self, forKey: .summaryEnabled) ?? true
        summaryHour = try c.decodeIfPresent(Int.self, forKey: .summaryHour) ?? 17
        synonyms = try c.decodeIfPresent([String: String].self, forKey: .synonyms) ?? [:]
        toolDefaults = try c.decodeIfPresent([String: [String: Int]].self, forKey: .toolDefaults) ?? [:]
        maxRestarts = try c.decodeIfPresent(Int.self, forKey: .maxRestarts) ?? 3
        restartDelayMs = try c.decodeIfPresent(Int.self, forKey: .restartDelayMs) ?? 2000
    }
}

// MARK: - General

public struct GeneralConfig: Codable {
    var language: String = ""

    /// 是否启用系统代理。启用时自动读取 macOS 系统代理设置
    var proxyEnabled: Bool = false

    /// 日志配置
    /// 日志文件最大大小（字节），0 = 不限制
    var logMaxSize: Int = 10 * 1024 * 1024
    /// 日志备份数量
    var logBackupCount: Int = 3

    /// HTTP 超时配置
    /// HTTP 请求默认超时（秒），0 = 不限制
    var httpTimeout: TimeInterval = 30
    /// HTTP 请求重试次数
    var httpRetryCount: Int = 0

    /// AI 客户端超时
    /// AI API 请求超时（秒），0 = 不限制（默认值见 `ConfigDefaults.defaultAITimeout`）
    var aiTimeout: TimeInterval = ConfigDefaults.defaultAITimeout

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        proxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? false
        logMaxSize = try c.decodeIfPresent(Int.self, forKey: .logMaxSize) ?? 10 * 1024 * 1024
        logBackupCount = try c.decodeIfPresent(Int.self, forKey: .logBackupCount) ?? 3
        httpTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .httpTimeout) ?? 30
        httpRetryCount = try c.decodeIfPresent(Int.self, forKey: .httpRetryCount) ?? 0
        aiTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .aiTimeout)
            ?? ConfigDefaults.defaultAITimeout
    }
}

// MARK: - AI

public struct AIConfig: Codable {
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = ""

    /// LLM 单次推理超时（秒）。0 或负值 = 用默认（见 `ConfigDefaults.llmTimeout`）。
    ///
    /// Swift 注入 `AI_LLM_TIMEOUT`，Python 侧三处 LLM 调用（单次摘要 / 批量聚合 /
    /// 规则提炼）共用。**不复用 `general.aiTimeout`**：那一项是 agent/HTTP 调用超时
    /// （`AGENT_TIMEOUT`），语义与量级都不同，合并会让「调大 agent 超时」意外放宽
    /// 或收紧 LLM 调用，反之亦然。
    var llmTimeout: TimeInterval = ConfigDefaults.llmTimeout

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        llmTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .llmTimeout)
            ?? ConfigDefaults.llmTimeout
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
    /// 本地代理监听端口，0 = 自动检测可用端口
    var port: Int = 0
    /// providers 路由表，默认取第一个作为兜底（未匹配 model 时）
    var providers: [ProviderConfig] = []
    /// 代理进程崩溃后的最大重启次数（与 mcp 段同义）
    var maxRestarts: Int = 3
    /// 崩溃后重启前的等待毫秒数（与 mcp 段同义）
    var restartDelayMs: Int = 2000
    /// skill 全文去重：同一 skill 被反复调用时，第二份起换成短提示（默认开）
    var skillDedupEnabled: Bool = true
    /// 响应末尾追加「本轮代理改写了什么」（默认开）
    var responseAnnotationEnabled: Bool = true
    /// shell 工具输出瘦身：超长砍头尾 + JSON 无损 minify（默认开）
    var outputFilter: OutputFilterConfig = OutputFilterConfig()

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        providers = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? []
        maxRestarts = try c.decodeIfPresent(Int.self, forKey: .maxRestarts) ?? 3
        restartDelayMs = try c.decodeIfPresent(Int.self, forKey: .restartDelayMs) ?? 2000
        skillDedupEnabled = try c.decodeIfPresent(Bool.self, forKey: .skillDedupEnabled) ?? true
        responseAnnotationEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .responseAnnotationEnabled,
        ) ?? true
        outputFilter = decodeAny(
            decoder, OutputFilterConfig.self, keys: ["outputFilter", "output_filter"],
        ) ?? OutputFilterConfig()
        clientAccel = decodeAny(
            decoder, ClientAccelConfig.self, keys: ["clientAccel", "client_accel"],
        )
        clientText = decodeAny(
            decoder, ClientTextConfig.self, keys: ["clientText", "client_text"],
        )
    }

    /// classifier 加速的客户端白名单（可选；缺省用内置默认，配置为**增量补充**）
    var clientAccel: ClientAccelConfig?
    /// 客户端注入文案/标签表（可选；缺省用内置默认，配置为**增量补充**）
    var clientText: ClientTextConfig?
}

/// 客户端身份白名单条目：哪些客户端享受 classifier thinking disabled 加速。
///
/// 客户端身份**不是协议事实**，故此处不含任何写死的指纹判断——历史上
/// `proxy_protocol._is_claude_code` 用 UA 子串/私有请求头硬编码 Claude Code，
/// 使其他客户端在同一结构的请求下拿不到加速（上游为默认 thinking 的模型时
/// 响应 28-32s，撞客户端超时、关键操作被拦）。匹配条件全部由配置声明。
public struct ClientMatcherConfig: Codable {
    /// 客户端名（仅用于日志区分命中者，也用于「同名覆盖默认项」）
    var name: String = ""
    /// UA 需包含的子串（任一命中即可）
    var userAgentContains: [String] = []
    /// 需存在的请求头名（全部存在才命中）
    var headerPresent: [String] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        // 一律走 decodeAny：混用 container(keyedBy:) 时「照抄哪一行」会决定多词字段
        // 是否静默失效（snake_case 不命中也只是回退默认值，不报错）。
        name = decodeAny(decoder, String.self, keys: ["name"]) ?? ""
        userAgentContains = decodeAny(
            decoder, [String].self, keys: ["userAgentContains", "user_agent_contains"],
        ) ?? []
        headerPresent = decodeAny(
            decoder, [String].self, keys: ["headerPresent", "header_present"],
        ) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case name, userAgentContains, headerPresent
    }
}

/// classifier 加速的客户端白名单（config.yaml `modelProxy.clientAccel`）。
///
/// 配置为**增量补充**：内置默认始终是基线，这里声明的客户端追加（同名覆盖）。
/// 唯一的关闭开关是 `enabled`。
public struct ClientAccelConfig: Codable {
    var enabled: Bool = true
    var clients: [ClientMatcherConfig] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        enabled = decodeAny(decoder, Bool.self, keys: ["enabled"]) ?? true
        clients = decodeAny(decoder, [ClientMatcherConfig].self, keys: ["clients"]) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case enabled, clients
    }
}

/// 客户端注入文案/标签表（config.yaml `modelProxy.clientText`）。
///
/// 续接提示词、摘要前缀、客户端标签随客户端版本变化且各家取值不同，故为可配置表；
/// 配置为**增量补充**（默认在前、配置在后），避免只写一个字段就把其余默认静默清空。
public struct ClientTextConfig: Codable {
    var continuationPrefixes: [String] = []
    var summaryPrefixes: [String] = []
    var injectedTags: [String] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        continuationPrefixes = decodeAny(
            decoder, [String].self,
            keys: ["continuationPrefixes", "continuation_prefixes"],
        ) ?? []
        summaryPrefixes = decodeAny(
            decoder, [String].self, keys: ["summaryPrefixes", "summary_prefixes"],
        ) ?? []
        injectedTags = decodeAny(
            decoder, [String].self, keys: ["injectedTags", "injected_tags"],
        ) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case continuationPrefixes, summaryPrefixes, injectedTags
    }
}

/// shell 工具输出瘦身（config.yaml `modelProxy.outputFilter`）。
///
/// 两层安全动作：超长砍头尾（带自证标记）与 JSON 无损 minify。按命令配的
/// `rules` 默认空表——实测本项目 shell 输出 ≤4KB 占 61%、>8KB 全是内容型，
/// 没有可规则化的模板噪音，硬写规则只会凭空制造误删风险。
public struct OutputFilterConfig: Codable {
    var enabled: Bool = true
    var maxBytes: Int = 8000
    var formatCompress: Bool = true
    /// 连续重复行折叠。**非无损**（行数变了），故默认关。
    var foldRepeatedLines: Bool = false
    var bypassTools: [String] = []
    /// 额外声明的 shell 工具名。跨客户端名字各不相同，故为配置面而非写死。
    var shellTools: [String] = []
    var rules: [OutputFilterRule] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        enabled = decodeAny(decoder, Bool.self, keys: ["enabled"]) ?? true
        maxBytes = decodeAny(decoder, Int.self, keys: ["maxBytes", "max_bytes"]) ?? 8000
        formatCompress = decodeAny(
            decoder, Bool.self, keys: ["formatCompress", "format_compress"],
        ) ?? true
        foldRepeatedLines = decodeAny(
            decoder, Bool.self, keys: ["foldRepeatedLines", "fold_repeated_lines"],
        ) ?? false
        bypassTools = decodeAny(
            decoder, [String].self, keys: ["bypassTools", "bypass_tools"],
        ) ?? []
        shellTools = decodeAny(
            decoder, [String].self, keys: ["shellTools", "shell_tools"],
        ) ?? []
        rules = decodeAny(decoder, [OutputFilterRule].self, keys: ["rules"]) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case enabled, maxBytes, formatCompress, foldRepeatedLines
        case bypassTools, shellTools, rules
    }
}

/// 单条命令规则（`modelProxy.outputFilter.rules[]`），语义对齐 snip 的 filter：
/// 按 `command` 首个 token 匹配，可选 `subcommand` 收窄；`maxBytes` 为 0 时用全局值。
public struct OutputFilterRule: Codable {
    var command: String = ""
    var subcommand: String = ""
    var maxBytes: Int = 0
    var dropLines: [String] = []
    var keepLines: [String] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        command = decodeAny(decoder, String.self, keys: ["command"]) ?? ""
        subcommand = decodeAny(decoder, String.self, keys: ["subcommand"]) ?? ""
        maxBytes = decodeAny(decoder, Int.self, keys: ["maxBytes", "max_bytes"]) ?? 0
        dropLines = decodeAny(
            decoder, [String].self, keys: ["dropLines", "drop_lines"],
        ) ?? []
        keepLines = decodeAny(
            decoder, [String].self, keys: ["keepLines", "keep_lines"],
        ) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case command, subcommand, maxBytes, dropLines, keepLines
    }
}

/// 按任意候选键名取同类型值——同时兼容 camelCase 与 snake_case 两种 YAML 写法。
///
/// **不能用 `K(stringValue:)` 去试探键名**：合成 `CodingKeys` 的
/// `init?(stringValue:)` 只认 case 名（即 camelCase），传 snake_case 恒返回 nil，
/// 于是「回退到另一种拼写」这一支永远不可达、变成死代码（已实测）。
/// 这里改为用 `Decoder` 另开一个以任意字符串为 key 的容器，键名才真正自由。
///
/// 背景：Yams 的 `YAMLDecoder` **不做**键名转换（源码已核实：无
/// `keyDecodingStrategy`，`_KeyedDecodingContainer` 直接用 `key.stringValue`
/// 查表）。历史上 default-config 里写成 snake_case 的键因此从未生效、被静默
/// 回退到默认值。本函数是那类静默失效的通用解。
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? {
        nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

private func decodeAny<T: Decodable>(
    _ decoder: Decoder, _: T.Type, keys: [String],
) -> T? {
    guard let c = try? decoder.container(keyedBy: AnyKey.self) else { return nil }
    for name in keys {
        guard let key = AnyKey(stringValue: name) else { continue }
        if let value = try? c.decodeIfPresent(T.self, forKey: key) { return value }
    }
    return nil
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
