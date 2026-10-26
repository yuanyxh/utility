import AppKit
import Foundation

/// Manages the lifecycle of the token_proxy.py child process.
/// Starts after MCP starts, restarts automatically on crash, stops on exit.
/// Process lifecycle (launch / crash restart / health check / stop) is delegated to PythonDaemon;
/// this class only handles business decisions: State semantics, event broadcast, config reading, HTTP query API.
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

    /// Auto-detected port (used only when the `port` config is 0).
    ///
    /// **Must be cached**: port probing is a bind test, and once the proxy is up it occupies that port
    /// itself, so probing again skips it and returns the next one (8613 -> 8614). This used to be a computed
    /// property that "re-probed on every access", causing `fetchTodaySummary()` to hit the wrong port whenever
    /// the proxy was running, so the menu bar's today usage was always empty.
    private var cachedPort: Int?
    private let portLock = NSLock()

    /// The port actually used for this run. The server side (daemon launch arguments and environment variables) and
    /// the query side (`fetchTodaySummary`) share the same source, keeping both sides consistent.
    var currentPort: Int {
        let configured = proxyConfig?.port ?? 0
        // An explicitly configured port is always authoritative and does not go through the cache -- user config changes should take effect immediately
        if configured > 0 { return configured }

        portLock.lock()
        defer { portLock.unlock() }
        if let cachedPort { return cachedPort }
        // A self-managed service records its port; prefer it over bind probing.
        if let recorded = PortProbe.recordedPort(service: PortProbe.Service.tokenProxy) {
            cachedPort = recorded
            return recorded
        }
        let detected = PortProbe.detectAvailable(startingFrom: PortProbe.Base.tokenProxy)
        cachedPort = detected
        return detected
    }

    /// Upstream API address: modelProxy.url -> ai.baseURL
    private var upstreamURL: String {
        if let url = proxyConfig?.url, !url.isEmpty { return url }
        let ai = ConfigManager.shared.config.ai
        if !ai.baseURL.isEmpty { return ai.baseURL }
        return ""
    }

    /// providers serialized to JSON and passed to Python (config.yaml modelProxy.providers).
    /// Returns nil when empty, falling back to the legacy single upstream (MODEL_PROXY_URL).
    private func providersJSON() -> String? {
        guard let providers = proxyConfig?.providers, !providers.isEmpty else { return nil }
        struct Payload: Encodable {
            let name: String
            let url: String
            let apiFormat: String
            let apiKey: String
            let models: [String]

            /// The JSON side uses snake_case uniformly (the Python `proxy_provider.py` parses by that naming).
            /// Property names keep the Swift convention, mapped by CodingKeys.
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

    /// classifier acceleration whitelist serialized to JSON (config.yaml `modelProxy.clientAccel`).
    ///
    /// The JSON side uses snake_case uniformly -- the Python `proxy_client.load_client_accel` parses by that naming.
    /// Returns nil when unconfigured (no injection); the Python side uses the built-in default whitelist.
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

    /// Client injection text/tag table serialized to JSON (config.yaml `modelProxy.clientText`).
    ///
    /// Returns nil when unconfigured (no injection); the Python side uses the built-in default table (= historical behavior).
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

    /// Env name for the shell tool output slimming config (same value as Python `proxy_output_filter.OUTPUT_FILTER_ENV_KEY`)
    static let outputFilterEnvKey = "MODEL_PROXY_OUTPUT_FILTER"
    /// Env name for the response annotation switch (same value as Python `proxy_response_note.RESPONSE_NOTE_ENV_KEY`)
    static let responseNoteEnvKey = "MODEL_PROXY_RESPONSE_NOTE"
    static let contextWarnEnvKey = "MODEL_PROXY_CONTEXT_WARN"

    /// Shell tool output slimming config. **Always injected** (except when proxyConfig is nil), so the Python
    /// side does not depend on its own default -- same reasoning as the skill dedup switch.
    private func outputFilterJSON() -> String? {
        guard let filter = proxyConfig?.outputFilter else { return nil }

        // The JSON side uses snake_case uniformly (the Python `proxy_output_filter._parse_config` parses by that
        // naming), consistent with the existing convention for providers / clientAccel.
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

    /// Script-specific environment variables (the common part is provided by PythonScriptRunner.baseEnvironment()).
    /// Read live -- PythonDaemon calls this property through the environment closure on every launch.
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
        // skill full-text dedup switch: always injected ("1"/"0"), so the Python side does not depend on its own default
        overrides["MODEL_PROXY_SKILL_DEDUP"] =
            (proxyConfig?.skillDedupEnabled ?? true) ? "1" : "0"
        if let outputFilterJSON = outputFilterJSON() {
            overrides[Self.outputFilterEnvKey] = outputFilterJSON
        }
        // response annotation switch: always injected ("1"/"0"), so the Python side does not depend on its own default
        overrides[Self.responseNoteEnvKey] =
            (proxyConfig?.responseAnnotationEnabled ?? true) ? "1" : "0"
        // context-size warning threshold: always injected, so changing it takes effect on reload
        // without the Python side keeping its own copy of the default
        overrides[Self.contextWarnEnvKey] =
            String(proxyConfig?.contextWarnTokens ?? 300_000)
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

    // MARK: - Query API (called by the menu bar)

    struct TodaySummary: Codable {
        var input_tokens: Int = 0
        var output_tokens: Int = 0
        var cache_read_tokens: Int = 0
        var total_requests: Int = 0
        var invalid_requests: Int = 0
    }

    func fetchTodaySummary() async -> TodaySummary {
        // Must use currentPort (the cached value): with a freshly re-probed port, while the proxy is running it
        // occupies 8613 itself and probes 8614, so the request cannot reach its own query endpoint.
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

    // MARK: - Daemon assembly

    private func ensureDaemon() -> PythonDaemon? {
        if let daemon { return daemon }
        guard let scriptPath = PythonScriptRunner.findScript(named: PythonScripts.tokenProxy) else {
            return nil
        }
        var config = PythonDaemon.Config(
            // token_proxy.py path is fixed, so capturing it is fine; the port may change on config reload, so use a closure
            scriptPath: { scriptPath },
            port: { [weak self] in
                // The fallback value shares the same source as PortProbe.Base.tokenProxy, avoiding two literals drifting apart
                self?.currentPort ?? PortProbe.Base.tokenProxy
            },
            healthPath: "/health",
            service: nil, // token_proxy does not validate the service field
            readySignals: [], // silent launch, health-check directly
            environment: { [weak self] in
                self?.proxyEnvironment ?? [:]
            },
            logTag: "TokenProxy",
        )
        // Crash restart parameters are synonymous with the mcp section and read from config -- previously hardcoded
        // as 3 / 2.0, inconsistent with MCPProcessManager reading config, and changing one while forgetting the other would diverge
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

    /// Map the PythonDaemon generic state to TokenProxy's own State and broadcast.
    /// TokenProxy has no starting/restarting intermediate state -- it keeps the status quo while starting, until running.
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
