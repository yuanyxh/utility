import Foundation

// MARK: - Config Defaults

/// Config defaults shared across types (single source of truth).
///
/// When the same default appears both as a "property initial value" and as a
/// "decoding fallback", changing one place while missing the other produces a
/// "YAML sets one default, absence yields another" behavioral split; `OpenAIClient`'s fallback is a third place. Hence centralized here, all three referencing the constants.
enum ConfigDefaults {
    /// AI API request timeout (seconds) — default for `general.aiTimeout`.
    ///
    /// ⚠️ The semantics are the **agent / HTTP call** timeout (Swift injects
    /// `AGENT_TIMEOUT` for the Python-side agent subprocess), NOT the same as
    /// `ai.llmTimeout` (Python-side single LLM inference timeout, injected as `AI_LLM_TIMEOUT`) — both values happen to be 120, very easy to confuse.
    static let defaultAITimeout: TimeInterval = 120

    /// Single LLM inference timeout (seconds) — default for `ai.llmTimeout`.
    ///
    /// Shared by three Python-side LLM call sites (single summary / batch aggregation / rule extraction).
    /// `0` or a negative value = use this default (following `OpenAIClient.init`'s `timeout > 0` convention).
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
    var knowledge: KnowledgeConfig = .init()
    var runtime: RuntimeConfig = .init()
    var mcp: MCPConfig? = nil
    var modelProxy: ModelProxyConfig? = nil
    var terminal: TerminalConfig = .init()

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
        knowledge = (try? c.decode(KnowledgeConfig.self, forKey: .knowledge)) ?? .init()
        runtime = (try? c.decodeIfPresent(RuntimeConfig.self, forKey: .runtime)) ?? .init()
        mcp = try? c.decodeIfPresent(MCPConfig.self, forKey: .mcp)
        modelProxy = try? c.decodeIfPresent(ModelProxyConfig.self, forKey: .modelProxy)
        terminal = (try? c.decodeIfPresent(TerminalConfig.self, forKey: .terminal)) ?? .init()
    }
}

// MARK: - Terminal

public struct TerminalConfig: Codable {
    var enabled: Bool = true
    var hotkey: String = "option+space"
    /// auto | tmux | screen | local
    var backend: String = "auto"
    /// Empty = $SHELL
    var shell: String = ""
    /// Empty = home directory
    var workingDirectory: String = ""
    var fontSize: Double = 12
    var maxSessions: Int = 20
    var restoreSessions: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? "option+space"
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? "auto"
        shell = try c.decodeIfPresent(String.self, forKey: .shell) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 12
        maxSessions = try c.decodeIfPresent(Int.self, forKey: .maxSessions) ?? 20
        restoreSessions = try c.decodeIfPresent(Bool.self, forKey: .restoreSessions) ?? true
    }
}

// MARK: - Runtime

/// Python-layer runtime switches (config.yaml `runtime`).
public struct RuntimeConfig: Codable {
    /// The Python layer reads config.yaml itself; Swift stops injecting those values as env.
    var selfManaged: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selfManaged = (try? c.decodeIfPresent(Bool.self, forKey: .selfManaged)) ?? false
    }
}

// MARK: - MCP

public struct MCPConfig: Codable {
    var enabled: Bool = true
    /// Local MCP service port, 0 = auto-detect an available port
    var port: Int = 0

    // Data storage paths (empty string = not configured, derived under ~/.config/utility/)
    var qdrantPath: String = ""
    var knowledgeBasePath: String = ""

    /// Note scanning: directory names skipped at any depth. Empty = skip nothing (no built-in list).
    var noteExcludeDirs: [String] = []
    /// Note scanning: file extensions. Empty = the built-in generic set.
    var noteExtensions: [String] = []

    /// fastembed model cache (empty string = not configured, uses ~/.cache/utility/fastembed/)
    var fastembedCacheDir: String = ""
    /// Empty string = use the built-in default model
    var embedderModel: String = ""

    // Memory lifecycle
    var hotRetentionDays: Int = 180
    var archiveDays: Int = 90

    // Daily summary
    var summaryEnabled: Bool = true
    var summaryHour: Int = 17

    /// Tags to exclude from summaries (skip memories containing these tags)
    var excludeTags: [String] = []

    /// Retrieval synonym extension table (**incremental**: same name overrides built-in, new name appends).
    /// The built-in table lives in the agent-gateway repo's `core/synonyms.py`; only the user-customized part goes here —
    /// what users edit should be "add a few words", not maintaining a full copy of the built-in table.
    var synonyms: [String: String] = [:]

    /// Tool argument defaults (tool name → args name → default value, **incremental**: same name overrides built-in).
    /// The built-in table lives in the agent-gateway repo's `core/tool_defaults.py`; these defaults directly determine each
    /// tool call's return volume, i.e. token consumption, hence exposed as configuration rather than a code constant.
    var toolDefaults: [String: [String: Int]] = [:]

    // Process supervision
    var maxRestarts: Int = 3
    var restartDelayMs: Int = 2000

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        qdrantPath = try c.decodeIfPresent(String.self, forKey: .qdrantPath) ?? ""
        knowledgeBasePath = try c.decodeIfPresent(String.self, forKey: .knowledgeBasePath) ?? ""
        noteExcludeDirs = try c.decodeIfPresent([String].self, forKey: .noteExcludeDirs) ?? []
        noteExtensions = try c.decodeIfPresent([String].self, forKey: .noteExtensions) ?? []
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

    /// Whether to enable the system proxy. When enabled, the macOS system proxy settings are read automatically
    var proxyEnabled: Bool = false

    /// Logging configuration
    /// Maximum log file size (bytes), 0 = unlimited
    var logMaxSize: Int = 10 * 1024 * 1024
    /// Number of log backups
    var logBackupCount: Int = 3

    /// HTTP timeout configuration
    /// Default HTTP request timeout (seconds), 0 = unlimited
    var httpTimeout: TimeInterval = 30
    /// HTTP request retry count
    var httpRetryCount: Int = 0

    /// AI client timeout
    /// AI API request timeout (seconds), 0 = unlimited (default see `ConfigDefaults.defaultAITimeout`)
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

    /// Single LLM inference timeout (seconds). 0 or negative = use default (see `ConfigDefaults.llmTimeout`).
    ///
    /// Swift injects `AI_LLM_TIMEOUT`; three Python-side LLM call sites (single summary / batch aggregation /
    /// rule extraction) share it. **Not reused from `general.aiTimeout`**: that one is the agent/HTTP call timeout
    /// (`AGENT_TIMEOUT`); the semantics and magnitude differ, so merging them would let "raising the agent timeout" accidentally loosen
    /// or tighten LLM calls, and vice versa.
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

/// A single upstream provider. The model name list is what the /model selector
/// offers (an exact match on body.model routes to this provider).
public struct ProviderConfig: Codable {
    var name: String = ""
    var url: String = "" // Upstream API address (the provider's own format endpoint)
    var apiFormat: ProxyAPIFormat = .anthropic // anthropic | openai
    var apiKey: String = "" // Provider key substituted when forwarding; if empty, pass through the client key
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
    var url: String = "" // Compat: the single upstream address when providers is empty
    /// Local proxy listen port, 0 = auto-detect an available port
    var port: Int = 0
    /// providers routing table; the first is used as the fallback (when no model matches)
    var providers: [ProviderConfig] = []
    /// Max restart count after the proxy process crashes (same meaning as the mcp section)
    var maxRestarts: Int = 3
    /// Milliseconds to wait before restarting after a crash (same meaning as the mcp section)
    var restartDelayMs: Int = 2000
    /// Full-text skill dedup: when the same skill is called repeatedly, the second copy onward is replaced with a short notice (on by default)
    var skillDedupEnabled: Bool = true
    /// Append "what the proxy rewrote this round" at the end of the response (on by default)
    var responseAnnotationEnabled: Bool = true
    /// Context-size threshold in tokens: above it the appended line suggests starting a new session (0 = never suggest)
    var contextWarnTokens: Int = 300_000
    /// Shell tool output slimming: trim head/tail of overly long output + lossless JSON minify (on by default)
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
        contextWarnTokens = try c.decodeIfPresent(
            Int.self, forKey: .contextWarnTokens,
        ) ?? 300_000
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

    /// Client allowlist for classifier acceleration (optional; defaults to built-in when absent, config is **incremental**)
    var clientAccel: ClientAccelConfig?
    /// Client-injected text/tag table (optional; defaults to built-in when absent, config is **incremental**)
    var clientText: ClientTextConfig?
}

/// A client-identity allowlist entry: which clients get classifier thinking-disabled acceleration.
///
/// Client identity is **not a protocol fact**, so no hardcoded fingerprint check appears here — historically
/// `proxy_protocol._is_claude_code` hardcoded Claude Code via a UA substring/private request header,
/// so other clients get no acceleration for requests of the same shape (when the upstream model defaults to thinking,
/// responses take 28-32s, hitting the client timeout and getting key operations blocked). All match conditions are declared by config.
public struct ClientMatcherConfig: Codable {
    /// Client name (used only in logs to distinguish matches, and for "same name overrides the default entry")
    var name: String = ""
    /// Substrings the UA must contain (any one match suffices)
    var userAgentContains: [String] = []
    /// Request header names that must exist (all must exist to match)
    var headerPresent: [String] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        // Always go through decodeAny: when mixing with container(keyedBy:), "which line you copy" decides whether
        // a multi-word field silently fails (a snake_case miss just falls back to the default, with no error).
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

/// Client allowlist for classifier acceleration (config.yaml `modelProxy.clientAccel`).
///
/// Config is **incremental**: the built-in defaults are always the baseline, and clients declared here are appended (same name overrides).
/// The only off switch is `enabled`.
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

/// Client-injected text/tag table (config.yaml `modelProxy.clientText`).
///
/// Continuation prompts, summary prefixes and client tags vary by client version and differ across clients, hence a configurable table;
/// config is **incremental** (defaults first, config after), avoiding silently wiping the other defaults by writing just one field.
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

/// Shell tool output slimming (config.yaml `modelProxy.outputFilter`).
///
/// Two safe actions: trimming the head/tail of overly long output (with a self-evidencing marker) and lossless JSON minify. The per-command
/// `rules` default to an empty table — measured on this project, shell output ≤4KB is 61%, and >8KB is all content-type,
/// with no templatable noise to rule-ify; hardcoding rules would only manufacture deletion risk out of thin air.
public struct OutputFilterConfig: Codable {
    var enabled: Bool = true
    var maxBytes: Int = 8000
    var formatCompress: Bool = true
    /// Fold consecutive repeated lines. **Not lossless** (the line count changes), hence off by default.
    var foldRepeatedLines: Bool = false
    var bypassTools: [String] = []
    /// Additionally declared shell tool names. Names differ across clients, hence a configuration surface rather than hardcoded.
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

/// A single command rule (`modelProxy.outputFilter.rules[]`), semantics aligned with snip's filter:
/// Matches on the first token of `command`, optionally narrowed by `subcommand`; `maxBytes` of 0 uses the global value.
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

/// Fetch a value of the same type by any candidate key name — compatible with both camelCase and snake_case YAML styles.
///
/// **Do not probe key names with `K(stringValue:)`**: a synthesized `CodingKeys`'s
/// `init?(stringValue:)` only recognizes case names (i.e. camelCase); passing snake_case always returns nil,
/// so the "fall back to the other spelling" branch is forever unreachable and becomes dead code (verified).
/// Instead, here we open another container keyed by arbitrary strings via `Decoder`, so key names are truly free.
///
/// Background: Yams's `YAMLDecoder` does **not** do key-name conversion (verified in source: no
/// `keyDecodingStrategy`; `_KeyedDecodingContainer` looks up directly with `key.stringValue`
/// in the table). Historically, keys written in snake_case in default-config thus never took effect and were silently
/// reverted to the default. This function is the general solution to that class of silent failure.
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

// MARK: - Knowledge

/// 主题种子。`kind` 取 `principle` / `trend`。
public struct KnowledgeTopicSeed: Codable {
    var name: String = ""
    var kind: String = "principle"
    /// 选题硬边界。为空时以该主题的教科书目录为准。
    var scope: String = ""
    /// 明确不覆盖的内容：产品、厂商方案、行业趋势等。
    var exclude: String = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "principle"
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        exclude = try c.decodeIfPresent(String.self, forKey: .exclude) ?? ""
    }
}

public struct KnowledgeConfig: Codable {
    var enabled: Bool = true
    var refillIntervalMinutes: Int = 30
    var autoShowEnabled: Bool = true
    var autoShowIntervalMinutes: Int = 120
    var autoCloseSeconds: Int = 25
    var poolTargetTopic: Int = 5
    var maxFailStreak: Int = 3
    var maxShownPerCard: Int = 2
    /// Cards older than this are pruned on refill; liked cards are kept. 0 = keep forever.
    var retentionDays: Int = 365
    var hotkey: String = "option+k"
    var saveLikedMarkdown: Bool = true
    /// Empty = `<mcp.knowledgeBasePath>/知识卡片` (or the default notes dir).
    var likedSaveDir: String = ""
    var showReviewedCards: Bool = false
    var topics: [KnowledgeTopicSeed] = []

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        refillIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .refillIntervalMinutes) ?? 30
        autoShowEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoShowEnabled) ?? true
        autoShowIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .autoShowIntervalMinutes) ?? 120
        autoCloseSeconds = try c.decodeIfPresent(Int.self, forKey: .autoCloseSeconds) ?? 25
        poolTargetTopic = try c.decodeIfPresent(Int.self, forKey: .poolTargetTopic) ?? 5
        maxFailStreak = try c.decodeIfPresent(Int.self, forKey: .maxFailStreak) ?? 3
        maxShownPerCard = try c.decodeIfPresent(Int.self, forKey: .maxShownPerCard) ?? 2
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 365
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? "option+k"
        saveLikedMarkdown = try c.decodeIfPresent(Bool.self, forKey: .saveLikedMarkdown) ?? true
        likedSaveDir = try c.decodeIfPresent(String.self, forKey: .likedSaveDir) ?? ""
        showReviewedCards = try c.decodeIfPresent(Bool.self, forKey: .showReviewedCards) ?? false
        topics = try c.decodeIfPresent([KnowledgeTopicSeed].self, forKey: .topics) ?? []
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
    var daily: RSSDailyConfig = .init()

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feeds = try c.decodeIfPresent([RSSFeedConfig].self, forKey: .feeds) ?? []
        daily = try c.decodeIfPresent(RSSDailyConfig.self, forKey: .daily) ?? .init()
    }
}

/// RSS 日报内置任务配置。cron 为空字符串时只注册手动任务（菜单栏点击触发）。
public struct RSSDailyConfig: Codable {
    var enabled: Bool = false
    var cron: String = "0 10 * * *"
    /// Empty = `<NOTES_DIR>/RSS`
    var outputDir: String = ""
    var markRead: Bool = true
    var maxConcurrency: Int = 4
    var articleMaxChars: Int = 12000
    var filterBatch: Int = 40
    var summaryBatch: Int = 4
    /// Only items published within this window enter a digest; 0 disables the window.
    var maxAgeDays: Int = 7
    var maxDigestLinks: Int = 10
    var fetchTimeout: Int = 20
    var llmTimeout: Int = 120
    var clash: RSSClashConfig = .init()

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        cron = try c.decodeIfPresent(String.self, forKey: .cron) ?? "0 10 * * *"
        outputDir = try c.decodeIfPresent(String.self, forKey: .outputDir) ?? ""
        markRead = try c.decodeIfPresent(Bool.self, forKey: .markRead) ?? true
        maxConcurrency = try c.decodeIfPresent(Int.self, forKey: .maxConcurrency) ?? 4
        articleMaxChars = try c.decodeIfPresent(Int.self, forKey: .articleMaxChars) ?? 12000
        filterBatch = try c.decodeIfPresent(Int.self, forKey: .filterBatch) ?? 40
        summaryBatch = try c.decodeIfPresent(Int.self, forKey: .summaryBatch) ?? 4
        maxAgeDays = try c.decodeIfPresent(Int.self, forKey: .maxAgeDays) ?? 7
        maxDigestLinks = try c.decodeIfPresent(Int.self, forKey: .maxDigestLinks) ?? 10
        fetchTimeout = try c.decodeIfPresent(Int.self, forKey: .fetchTimeout) ?? 20
        llmTimeout = try c.decodeIfPresent(Int.self, forKey: .llmTimeout) ?? 120
        clash = try c.decodeIfPresent(RSSClashConfig.self, forKey: .clash) ?? .init()
    }
}

/// 可选：日报期间切换 Clash 代理组，结束后恢复原选择。
public struct RSSClashConfig: Codable {
    var enabled: Bool = false
    var group: String = ""
    var target: String = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
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
    var trigger: String = "" // cron expression or event name
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
        // exec may be a string (auto-inferred) or a dictionary (explicitly declared)
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

    /// Process execution config — contains the configured Process and pipes
    struct ProcessConfig {
        let task: Process
        let outputPipe: Pipe
        let errorPipe: Pipe
    }

    /// Convert the config into a ProcessConfig
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

    /// Auto-infer the execution type from a string
    static func infer(from raw: String) -> TaskExecConfig {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix(".sh") { return .sh(t) }
        if t.hasSuffix(".js") || t.contains("Application(") { return .js(t) }
        if t.hasSuffix(".py") || t.contains("def ") || t.contains("import ") { return .py(t) }
        if t.contains("\n") { return .sh(t) } // multiline defaults to shell
        return .shortcuts(t) // single line defaults to a shortcut name
    }
}
