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

    /// 端口配置：0 = 自动检测可用端口
    private var port: Int {
        let configured = proxyConfig?.port ?? 0
        if configured > 0 {
            return configured
        }
        // 自动检测：从 8613 开始探测（避免与 MCP 9001 冲突）
        return detectAvailablePort(startingFrom: 8613)
    }

    /// 探测可用端口
    private func detectAvailablePort(startingFrom startPort: Int) -> Int {
        for port in startPort ..< startPort + 100 {
            if isPortAvailable(port) {
                return port
            }
        }
        // 全部占用，返回第一个（让后续绑定报错）
        return startPort
    }

    /// 检查端口是否可用
    private func isPortAvailable(_ port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let socketfd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketfd) }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketfd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
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
        }
        let payload = providers.map {
            Payload(
                name: $0.name, url: $0.url,
                apiFormat: $0.apiFormat.rawValue, apiKey: $0.apiKey,
                models: $0.models
            )
        }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 路由配置序列化为 JSON 传给 Python（config.yaml modelProxy.router）。
    private func routerJSON() -> String? {
        guard let router = proxyConfig?.router, router.enabled else { return nil }
        // 用原始 JSON 编码，保留 snake_case key
        struct ClassifierPayload: Encodable {
            let provider: String
            let max_retries: Int
            let retry_delay_ms: Int
            let timeout_ms: Int
        }
        struct RouterPayload: Encodable {
            let enabled: Bool
            let tiers: [String: String]
            let classifier: ClassifierPayload
            let default_tier: String
        }
        let c = router.classifier
        let classifier = ClassifierPayload(
            provider: c.provider,
            max_retries: c.maxRetries,
            retry_delay_ms: c.retryDelayMs,
            timeout_ms: c.timeoutMs
        )
        let payload = RouterPayload(
            enabled: router.enabled,
            tiers: router.tiers,
            classifier: classifier,
            default_tier: router.defaultTier
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 脚本专属环境变量（公共部分由 PythonScriptRunner.baseEnvironment() 提供）。
    /// 实时读取——PythonDaemon 每次启动时经 environment 闭包调用本属性。
    private var proxyEnvironment: [String: String] {
        var overrides: [String: String] = [:]
        overrides["MODEL_PROXY_PORT"] = String(port)
        if let providersJSON = providersJSON() {
            overrides["MODEL_PROXY_PROVIDERS"] = providersJSON
        } else {
            overrides["MODEL_PROXY_URL"] = upstreamURL
        }
        if let routerJSON = routerJSON() {
            overrides["MODEL_PROXY_ROUTER"] = routerJSON
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
        guard let url = URL(string: "http://127.0.0.1:\(port)/usage/summary") else { return TodaySummary() }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(TodaySummary.self, from: data)
        } catch {
            return TodaySummary()
        }
    }

    // MARK: - Daemon 装配

    private func ensureDaemon() -> PythonDaemon? {
        if let daemon { return daemon }
        guard let scriptPath = PythonScriptRunner.findScript(named: "token_proxy.py") else {
            return nil
        }
        let config = PythonDaemon.Config(
            // token_proxy.py 路径固定，捕获即可；端口可能随配置重载变化，走闭包
            scriptPath: { scriptPath },
            port: { [weak self] in
                self?.port ?? 8613 // 兜底值，正常流程不会到这
            },
            healthPath: "/health",
            service: nil, // token_proxy 不校验 service 字段
            readySignals: [], // 静默启动，直接健康检查
            maxRestarts: 3,
            restartDelaySec: 2.0,
            environment: { [weak self] in
                self?.proxyEnvironment ?? [:]
            },
            logTag: "TokenProxy"
        )
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
