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
    var summaryStatsOnly: Bool = false

    /// 总结排除 tag（跳过含这些 tag 的记忆）
    var excludeTags: [String] = []

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
        summaryStatsOnly = try c.decodeIfPresent(Bool.self, forKey: .summaryStatsOnly) ?? false
        maxRestarts = try c.decodeIfPresent(Int.self, forKey: .maxRestarts) ?? 3
        restartDelayMs = try c.decodeIfPresent(Int.self, forKey: .restartDelayMs) ?? 2000
    }
}

// MARK: - General

public struct GeneralConfig: Codable {
    var language: String = ""

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
    /// AI API 请求超时（秒），0 = 不限制
    var aiTimeout: TimeInterval = 120

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        logMaxSize = try c.decodeIfPresent(Int.self, forKey: .logMaxSize) ?? 10 * 1024 * 1024
        logBackupCount = try c.decodeIfPresent(Int.self, forKey: .logBackupCount) ?? 3
        httpTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .httpTimeout) ?? 30
        httpRetryCount = try c.decodeIfPresent(Int.self, forKey: .httpRetryCount) ?? 0
        aiTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .aiTimeout) ?? 120
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
    /// 本地代理监听端口，0 = 自动检测可用端口
    var port: Int = 0
    /// providers 路由表，默认取第一个作为兜底（未匹配 model 时）
    var providers: [ProviderConfig] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        providers = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? []
        router = try c.decodeIfPresent(ModelRouterConfig.self, forKey: .router)
    }

    /// 智能路由配置（可选，不配置则保持手动切换行为）
    var router: ModelRouterConfig?
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

/// 模型分级路由：按任务分类选择档位，会话内单调不降。
///
/// 判据全部来自 Anthropic / OpenAI 协议字段（工具失败走 `tool_result.is_error`、
/// 打转走工具名+入参、循环位置走消息结构），不含任何客户端产品实现细节，因此
/// 可服务任意 agent 客户端与任意 OpenAI/Anthropic 格式请求。
public struct ModelRouterConfig: Codable {
    var enabled: Bool = false
    /// 档位定义，**数组顺序 = 强度从高到低**（索引 0 最强）
    var tiers: [RouterTier] = []
    /// 分类器配置
    var classifier: RouterClassifier = .init()
    /// 分类失败 / 无分类器时的兜底档名；留空则取最后一档（最弱）
    var defaultTier: String = ""
    /// 策略阈值
    var policy: RouterPolicy = .init()
    /// 会话身份
    var conversation: RouterConversation = .init()
    /// agent 类型先验（子 agent / 重复劳动任务免检）
    var profile: RouterProfile = .init()

    public init() {}
    public init(from decoder: Decoder) throws {
        // 本段**一律**走 decodeAny，不混用 container(keyedBy:)：
        // 混用会让「新增字段时照抄哪一行」变成运气问题——照抄 c.decodeIfPresent
        // 写多词字段就会静默失效（snake_case 不命中也回退默认值，不报错）。
        enabled = decodeAny(decoder, Bool.self, keys: ["enabled"]) ?? false
        // tiers 兼容两种形态：
        //   新（推荐）：[{name, model, description}] —— 保序，顺序即强度
        //   旧：{name: model} 字典 —— Dictionary 编码无序，按 key 排序做尽力还原
        if let list = decodeAny(decoder, [RouterTier].self, keys: ["tiers"]) {
            tiers = list
        } else if let legacy = decodeAny(decoder, [String: String].self, keys: ["tiers"]) {
            tiers = legacy.keys.sorted().map { RouterTier(name: $0, model: legacy[$0] ?? "") }
        }
        classifier = decodeAny(decoder, RouterClassifier.self, keys: ["classifier"]) ?? RouterClassifier()
        defaultTier = decodeAny(decoder, String.self, keys: ["defaultTier", "default_tier"]) ?? ""
        policy = decodeAny(decoder, RouterPolicy.self, keys: ["policy"]) ?? RouterPolicy()
        conversation = decodeAny(decoder, RouterConversation.self, keys: ["conversation"]) ?? RouterConversation()
        profile = decodeAny(decoder, RouterProfile.self, keys: ["profile"]) ?? RouterProfile()
    }

    enum CodingKeys: String, CodingKey {
        case enabled, tiers, classifier, defaultTier, policy, conversation, profile
    }
}

/// 单个档位定义。
///
/// `description` 会被拼进分类 prompt（`{tier_lines}`），因此新增档位（如 medium）
/// 只需改配置，无需改代码。
public struct RouterTier: Codable {
    var name: String = ""
    /// 必须在 modelProxy.providers 的某个 models 列表中
    var model: String = ""
    /// 供分类器判断的档位描述
    var description: String = ""

    public init() {}
    public init(name: String, model: String, description: String = "") {
        self.name = name
        self.model = model
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case name, model, description
    }
}

/// 分类器配置：用哪个 provider 做分类、重试与 prompt 模板。
public struct RouterClassifier: Codable {
    /// 引用 providers 中的 name（如 "deepseek"）
    var provider: String = ""
    /// 分类 prompt 模板，支持 `{tier_lines}` 与 `{last_user_message}` 占位；
    /// 留空则用 Python 侧 DEFAULT_CLASSIFY_PROMPT_TEMPLATE
    var promptTemplate: String = ""
    var maxRetries: Int = 3
    var retryDelayMs: Int = 500
    var timeoutMs: Int = 10000
    /// 分类器**总**时间预算（毫秒）。单次超时 × 重试次数会全部叠加在转发前的
    /// 关键链路上，因此必须有总闸：预算耗尽即放弃分类走兜底档。
    var totalBudgetMs: Int = 3000

    public init() {}
    public init(from decoder: Decoder) throws {
        provider = decodeAny(decoder, String.self, keys: ["provider"]) ?? ""
        promptTemplate = decodeAny(decoder, String.self, keys: ["promptTemplate", "prompt_template"]) ?? ""
        maxRetries = decodeAny(decoder, Int.self, keys: ["maxRetries", "max_retries"]) ?? 3
        retryDelayMs = decodeAny(decoder, Int.self, keys: ["retryDelayMs", "retry_delay_ms"]) ?? 500
        timeoutMs = decodeAny(decoder, Int.self, keys: ["timeoutMs", "timeout_ms"]) ?? 10000
        totalBudgetMs = decodeAny(decoder, Int.self, keys: ["totalBudgetMs", "total_budget_ms"]) ?? 3000
    }

    enum CodingKeys: String, CodingKey {
        case provider, promptTemplate, maxRetries, retryDelayMs, timeoutMs, totalBudgetMs
    }
}

/// 路由策略阈值。全部可配置——代码侧不内置任何判据字面量。
///
/// `switchCostTurns` 的定量依据：设 Ps/Pw 为两档输入未命中价、c 为缓存折扣
/// （命中价/未命中价），双向切档回本轮数 M* = 2 + [Pw + Ps(1-2c)] / [c(Ps-Pw)]。
/// 该式与上下文规模无关，对价差极不敏感、对 c 极敏感：
/// c=0.10（Anthropic 量级）时 M*≈12；c=0.26（deepseek 量级）时 M*≈4.5。
public struct RouterPolicy: Codable {
    /// 结构判定的非 agent 请求（Claude Code safety classifier：stream 为假 + 无
    /// tools + messages ≤ 2）直通兜底档，不建会话、不调分类器。关闭它会让每条
    /// classifier 请求额外发一次 LLM 分类调用，且该路径在工具批准的关键链路上。
    var classifierFastPath: Bool = true
    /// 双向切档回本轮数（降档「预期收益」判断的阈值）
    var switchCostTurns: Int = 12
    /// 连续同名同参工具调用达到此数即判定打转 → 升档
    var loopStreak: Int = 3
    /// 连续多少轮工具失败才升档。1 = 单次失败即升档（不推荐：`is_error` 是客户端
    /// 按「非零退出」判定的，grep 无匹配 / diff 有差异 / test 失败都会被标 true，
    /// 单次就升档会把会话永久锁到强档）
    var escalateErrorStreak: Int = 2
    /// 每 N 轮强制升档一次（is_error 不可用时的主力兜底），0 = 禁用
    var checkpointInterval: Int = 8
    /// 内容层兜底正则（仅当 provider 不返回 is_error 时才需要），默认空
    var escalatePatterns: [String] = []
    /// 只读工具白名单，**默认空 = 永不允许降档**（通用 agent 的最保守默认）
    var readonlyTools: [String] = []
    /// 正常终止原因；留空用协议默认 {end_turn, tool_use, stop_sequence}
    var normalStopReasons: [String] = []
    /// 切档前要求工具调用配对完整（防严格上游 400，已知故障模式）
    var requirePairedHistory: Bool = true

    public init() {}
    public init(from decoder: Decoder) throws {
        classifierFastPath = decodeAny(decoder, Bool.self, keys: ["classifierFastPath", "classifier_fast_path"]) ?? true
        switchCostTurns = decodeAny(decoder, Int.self, keys: ["switchCostTurns", "switch_cost_turns"]) ?? 12
        loopStreak = decodeAny(decoder, Int.self, keys: ["loopStreak", "loop_streak"]) ?? 3
        escalateErrorStreak = decodeAny(decoder, Int.self, keys: ["escalateErrorStreak", "escalate_error_streak"]) ?? 2
        checkpointInterval = decodeAny(decoder, Int.self, keys: ["checkpointInterval", "checkpoint_interval"]) ?? 8
        escalatePatterns = decodeAny(decoder, [String].self, keys: ["escalatePatterns", "escalate_patterns"]) ?? []
        readonlyTools = decodeAny(decoder, [String].self, keys: ["readonlyTools", "readonly_tools"]) ?? []
        normalStopReasons = decodeAny(decoder, [String].self, keys: ["normalStopReasons", "normal_stop_reasons"]) ?? []
        requirePairedHistory = decodeAny(decoder, Bool.self, keys: ["requirePairedHistory", "require_paired_history"]) ?? true
    }

    enum CodingKeys: String, CodingKey {
        case classifierFastPath
        case switchCostTurns, loopStreak, escalateErrorStreak
        case checkpointInterval, escalatePatterns
        case readonlyTools, normalStopReasons, requirePairedHistory
    }
}

/// 会话身份配置。
public struct RouterConversation: Codable {
    /// task_key 的分量。默认对 system+tools+首条真实用户消息取指纹：
    /// 整个 agent loop 命中同一会话，用户发新指令时自动分界。
    var keyParts: [String] = ["system", "tools", "first_user"]
    var maxSessions: Int = 512
    /// 会话状态存活秒数（过期时把该会话统计回填 profile）
    var ttlSeconds: Int = 7200

    public init() {}
    public init(from decoder: Decoder) throws {
        keyParts = decodeAny(decoder, [String].self, keys: ["keyParts", "key_parts"]) ?? ["system", "tools", "first_user"]
        maxSessions = decodeAny(decoder, Int.self, keys: ["maxSessions", "max_sessions"]) ?? 512
        ttlSeconds = decodeAny(decoder, Int.self, keys: ["ttlSeconds", "ttl_seconds"]) ?? 7200
    }

    enum CodingKeys: String, CodingKey {
        case keyParts, maxSessions, ttlSeconds
    }
}

/// agent 类型先验：子 agent / 重复劳动任务免检。
///
/// profile_key = system+tools 指纹。子 agent 的 system prompt 与裁剪过的工具集
/// 与主 agent 天然不同，因此自动隔离，无需客户端配合。历史升级率低于阈值的
/// profile 直接按先验档起步并跳过 LLM 分类——重复劳动「第一次学、之后免检」。
public struct RouterProfile: Codable {
    var enabled: Bool = true
    /// 启用先验所需的最少会话样本数
    var minSamples: Int = 5
    /// 滑动窗口（会话数）
    var window: Int = 50
    /// 升级率低于此值才启用先验
    var upgradeRateThreshold: Double = 0.1
    /// 先验档名；留空 = 最低档
    var priorTier: String = ""
    /// 内存中保留的 profile 条目上限。与会话表一样必须有界——否则本机任意进程
    /// 用互不相同的 system/tools 发请求就能驱动它无界增长。
    var maxProfiles: Int = 256

    public init() {}
    public init(from decoder: Decoder) throws {
        enabled = decodeAny(decoder, Bool.self, keys: ["enabled"]) ?? true
        minSamples = decodeAny(decoder, Int.self, keys: ["minSamples", "min_samples"]) ?? 5
        window = decodeAny(decoder, Int.self, keys: ["window"]) ?? 50
        upgradeRateThreshold = decodeAny(decoder, Double.self, keys: ["upgradeRateThreshold", "upgrade_rate_threshold"]) ?? 0.1
        priorTier = decodeAny(decoder, String.self, keys: ["priorTier", "prior_tier"]) ?? ""
        maxProfiles = decodeAny(decoder, Int.self, keys: ["maxProfiles", "max_profiles"]) ?? 256
    }

    enum CodingKeys: String, CodingKey {
        case enabled, minSamples, window, upgradeRateThreshold, priorTier, maxProfiles
    }
}

// MARK: - Article

/// 文章生成（gen-article 内部任务）配置。路径一律由 mcp.knowledgeBasePath
/// 推导出 Gen_Articles/ 工作目录，不做路径配置（最少配置化）。
public struct ArticleConfig: Codable {
    var enabled: Bool = false
    /// agent CLI 命令模板（占位符 {system_prompt_file}/{prompt_file} 由脚本替换）。
    /// ⚠️ GUI/LaunchAgent 启动的子进程 PATH 不含用户工具目录，主命令须写绝对路径。
    /// 空字符串 = 未配置，启用时报错提示用户配置。
    var agentCli: String = ""
    var retries: Int = 5
    /// 生成后启用 LLM-as-Judge 管道式评估（素材校验 + 文章二次检测）
    var judge: Bool = true

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        agentCli = try c.decodeIfPresent(String.self, forKey: .agentCli) ?? ""
        retries = try c.decodeIfPresent(Int.self, forKey: .retries) ?? 5
        judge = try c.decodeIfPresent(Bool.self, forKey: .judge) ?? true
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
