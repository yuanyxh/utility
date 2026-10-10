import AppKit
import Foundation

/// 管理 token_proxy.py 子进程生命周期。
/// 在 MCP 启动后启动，崩溃自动重启，退出时停止。
/// 进程生命周期（启动/崩溃重启/健康检查/停止）委托给 PythonDaemon；
/// 本类只负责业务决策：State 语义、事件广播、配置读取、HTTP 查询 API。
final class TokenProxyManager {
    static let shared = TokenProxyManager()

    enum State: String {
        case stopped, running, crashed
    }

    private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            EventBus.shared.publish("token_proxy_state_changed", payload: state.rawValue)
        }
    }

    private var daemon: PythonDaemon?

    private var proxyConfig: ModelProxyConfig? {
        ConfigManager.shared.config.modelProxy
    }

    /// 自动检测出的端口（仅 `port` 配置为 0 时使用）。
    ///
    /// **必须缓存**：端口探测是 bind 测试，而代理起来之后自己就占着这个端口，
    /// 再探测会跳过它返回下一个（8613 → 8614）。原先这里是「每次访问都重新探测」
    /// 的 computed property，导致 `fetchTodaySummary()` 在代理运行时必定打错端口、
    /// 菜单栏今日用量恒为空。
    private var cachedPort: Int?
    private let portLock = NSLock()

    /// 本次运行实际使用的端口。服务端（daemon 启动参数与环境变量）与查询方
    /// （`fetchTodaySummary`）共用同一来源，保证两侧一致。
    var currentPort: Int {
        let configured = proxyConfig?.port ?? 0
        // 显式配置的端口永远权威，不走缓存——用户改配置后应当立即生效
        if configured > 0 { return configured }

        portLock.lock()
        defer { portLock.unlock() }
        if let cachedPort { return cachedPort }
        let detected = PortProbe.detectAvailable(startingFrom: PortProbe.Base.tokenProxy)
        cachedPort = detected
        return detected
    }

    /// 上游 API 地址：modelProxy.url → ai.baseURL
    private var upstreamURL: String {
        if let url = proxyConfig?.url, !url.isEmpty { return url }
        let ai = ConfigManager.shared.config.ai
        if !ai.baseURL.isEmpty { return ai.baseURL }
        return ""
    }

    /// providers 序列化为 JSON 传给 Python（config.yaml modelProxy.providers）。
    /// 为空时返回 nil，回退到旧单上游（MODEL_PROXY_URL）。
    private func providersJSON() -> String? {
        guard let providers = proxyConfig?.providers, !providers.isEmpty else { return nil }
        struct Payload: Encodable {
            let name: String
            let url: String
            let apiFormat: String
            let apiKey: String
            let models: [String]

            /// JSON 侧统一 snake_case（Python `proxy_provider.py` 按该命名解析）。
            /// 属性名保持 Swift 惯例，由 CodingKeys 映射。
            enum CodingKeys: String, CodingKey {
                case name, url, models
                case apiFormat = "api_format"
                case apiKey = "api_key"
            }
        }
        let payload = providers.map {
            Payload(
                name: $0.name, url: $0.url,
                apiFormat: $0.apiFormat.rawValue, apiKey: $0.apiKey,
                models: $0.models,
            )
        }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// classifier 加速白名单序列化为 JSON（config.yaml `modelProxy.clientAccel`）。
    ///
    /// JSON 侧统一 snake_case——Python `proxy_client.load_client_accel` 按该命名解析。
    /// 未配置时返回 nil（不注入），Python 侧用内置默认白名单。
    private func clientAccelJSON() -> String? {
        guard let accel = proxyConfig?.clientAccel else { return nil }

        struct MatcherPayload: Encodable {
            let name: String
            let user_agent_contains: [String]
            let header_present: [String]
        }
        struct AccelPayload: Encodable {
            let enabled: Bool
            let clients: [MatcherPayload]
        }

        let payload = AccelPayload(
            enabled: accel.enabled,
            clients: accel.clients.map {
                MatcherPayload(
                    name: $0.name,
                    user_agent_contains: $0.userAgentContains,
                    header_present: $0.headerPresent,
                )
            },
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 客户端注入文案/标签表序列化为 JSON（config.yaml `modelProxy.clientText`）。
    ///
    /// 未配置时返回 nil（不注入），Python 侧用内置默认表（= 历史行为）。
    private func clientTextJSON() -> String? {
        guard let text = proxyConfig?.clientText else { return nil }

        struct TextPayload: Encodable {
            let continuation_prefixes: [String]
            let summary_prefixes: [String]
            let injected_tags: [String]
        }

        let payload = TextPayload(
            continuation_prefixes: text.continuationPrefixes,
            summary_prefixes: text.summaryPrefixes,
            injected_tags: text.injectedTags,
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// shell 工具输出瘦身配置的 env 名（Python `proxy_output_filter.OUTPUT_FILTER_ENV_KEY` 同值）
    static let outputFilterEnvKey = "MODEL_PROXY_OUTPUT_FILTER"

    /// shell 工具输出瘦身配置。**总是注入**（proxyConfig 为空时除外），让 Python
    /// 侧不依赖自己的缺省值——与 skill dedup 开关同理。
    private func outputFilterJSON() -> String? {
        guard let filter = proxyConfig?.outputFilter else { return nil }

        // JSON 侧统一 snake_case（Python `proxy_output_filter._parse_config` 按该
        // 命名解析），与 providers / clientAccel 的既有约定一致。
        struct RulePayload: Encodable {
            let command: String
            let subcommand: String
            let max_bytes: Int
            let drop_lines: [String]
            let keep_lines: [String]
        }
        struct FilterPayload: Encodable {
            let enabled: Bool
            let max_bytes: Int
            let format_compress: Bool
            let fold_repeated_lines: Bool
            let bypass_tools: [String]
            let shell_tools: [String]
            let rules: [RulePayload]
        }

        let payload = FilterPayload(
            enabled: filter.enabled,
            max_bytes: filter.maxBytes,
            format_compress: filter.formatCompress,
            fold_repeated_lines: filter.foldRepeatedLines,
            bypass_tools: filter.bypassTools,
            shell_tools: filter.shellTools,
            rules: filter.rules.map {
                RulePayload(
                    command: $0.command,
                    subcommand: $0.subcommand,
                    max_bytes: $0.maxBytes,
                    drop_lines: $0.dropLines,
                    keep_lines: $0.keepLines,
                )
            },
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 脚本专属环境变量（公共部分由 PythonScriptRunner.baseEnvironment() 提供）。
    /// 实时读取——PythonDaemon 每次启动时经 environment 闭包调用本属性。
    private var proxyEnvironment: [String: String] {
        var overrides: [String: String] = [:]
        overrides["MODEL_PROXY_PORT"] = String(currentPort)
        if let providersJSON = providersJSON() {
            overrides["MODEL_PROXY_PROVIDERS"] = providersJSON
        } else {
            overrides["MODEL_PROXY_URL"] = upstreamURL
        }
        if let clientAccelJSON = clientAccelJSON() {
            overrides["MODEL_PROXY_CLIENT_ACCEL"] = clientAccelJSON
        }
        if let clientTextJSON = clientTextJSON() {
            overrides["MODEL_PROXY_CLIENT_TEXT"] = clientTextJSON
        }
        // skill 全文去重开关：总是注入（"1"/"0"），让 Python 侧不依赖自己的缺省值
        overrides["MODEL_PROXY_SKILL_DEDUP"] =
            (proxyConfig?.skillDedupEnabled ?? true) ? "1" : "0"
        if let outputFilterJSON = outputFilterJSON() {
            overrides[Self.outputFilterEnvKey] = outputFilterJSON
        }
        return PythonScriptRunner.environment(overrides: overrides)
    }

    // MARK: - Public

    func start() {
        guard state == .stopped || state == .crashed else { return }
        guard proxyConfig?.enabled == true else {
            debugLog("[TokenProxy] Disabled by config")
            return
        }
        guard !upstreamURL.isEmpty else {
            debugLog("[TokenProxy] No upstream URL configured")
            return
        }
        guard let daemon = ensureDaemon() else {
            debugLog("[TokenProxy] token_proxy.py not found")
            state = .crashed
            return
        }
        daemon.start(reuseIfHealthy: false)
    }

    func stop() {
        daemon?.stop()
    }

    func forceRestart() {
        guard proxyConfig?.enabled == true else { return }
        guard !upstreamURL.isEmpty else { return }
        guard let daemon = ensureDaemon() else {
            state = .crashed
            return
        }
        daemon.forceRestart()
    }

    // MARK: - Query API（供菜单栏调用）

    struct TodaySummary: Codable {
        var input_tokens: Int = 0
        var output_tokens: Int = 0
        var cache_read_tokens: Int = 0
        var total_requests: Int = 0
        var invalid_requests: Int = 0
    }

    func fetchTodaySummary() async -> TodaySummary {
        // 必须用 currentPort（缓存值）：用每次重新探测的端口，代理运行时会因
        // 自己占着 8613 而探测到 8614，请求打不到自己的查询端点。
        guard let url = HTTP.localURL(port: currentPort, path: "/usage/summary") else {
            return TodaySummary()
        }
        do {
            let (data, _) = try await URLSessionManager.shared.directSession.data(from: url)
            return try JSONDecoder().decode(TodaySummary.self, from: data)
        } catch {
            return TodaySummary()
        }
    }

    // MARK: - Daemon 装配

    private func ensureDaemon() -> PythonDaemon? {
        if let daemon { return daemon }
        guard let scriptPath = PythonScriptRunner.findScript(named: PythonScripts.tokenProxy) else {
            return nil
        }
        var config = PythonDaemon.Config(
            // token_proxy.py 路径固定，捕获即可；端口可能随配置重载变化，走闭包
            scriptPath: { scriptPath },
            port: { [weak self] in
                // 兜底值与 PortProbe.Base.tokenProxy 同源，避免两处字面量各自漂移
                self?.currentPort ?? PortProbe.Base.tokenProxy
            },
            healthPath: "/health",
            service: nil, // token_proxy 不校验 service 字段
            readySignals: [], // 静默启动，直接健康检查
            environment: { [weak self] in
                self?.proxyEnvironment ?? [:]
            },
            logTag: "TokenProxy",
        )
        // 崩溃重启参数与 mcp 段同义，从配置读——此前写死 3 / 2.0，与
        // MCPProcessManager 读配置的行为不一致，改一处忘另一处就会分叉
        if let proxy = proxyConfig {
            config.maxRestarts = proxy.maxRestarts
            config.restartDelaySec = Double(proxy.restartDelayMs) / 1000.0
        }
        let daemon = PythonDaemon(config: config)
        daemon.onStateChange = { [weak self] daemonState in
            self?.applyDaemonState(daemonState)
        }
        daemon.onMaxRestarts = { _ in
            debugLog("[TokenProxy] Crashed (reached max restarts)")
        }
        self.daemon = daemon
        return daemon
    }

    /// 把 PythonDaemon 通用状态映射到 TokenProxy 自身 State 并广播。
    /// TokenProxy 无 starting/restarting 中间态——启动中保持现状，直到 running。
    private func applyDaemonState(_ daemonState: PythonDaemon.State) {
        switch daemonState {
        case .running:
            state = .running
        case .crashed:
            state = .crashed
        case .stopped:
            state = .stopped
        case .starting, .restarting:
            break
        }
    }
}
