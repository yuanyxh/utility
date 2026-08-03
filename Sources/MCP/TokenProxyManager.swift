import AppKit
import Foundation

/// 管理 token_proxy.py 子进程生命周期。
/// 在 MCP 启动后启动，崩溃自动重启，退出时停止。
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

    private var process: Process?
    private var healthCheckTimer: Timer?
    private var crashCount = 0
    private var isStopping = false
    private let lifecycleQueue = DispatchQueue(label: "token-proxy-lifecycle")

    private let maxRestarts = 3
    private let restartDelaySec: Double = 2.0

    private var proxyConfig: ModelProxyConfig? {
        ConfigManager.shared.config.modelProxy
    }

    private var port: Int {
        proxyConfig?.port ?? 8080
    }

    /// 上游 API 地址：modelProxy.url → ai.baseURL
    private var upstreamURL: String {
        if let url = proxyConfig?.url, !url.isEmpty { return url }
        let ai = ConfigManager.shared.config.ai
        if !ai.baseURL.isEmpty { return ai.baseURL }
        return ""
    }

    private func buildEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["MODEL_PROXY_PORT"] = String(port)
        env["MODEL_PROXY_URL"] = upstreamURL
        env["UTILITY_DATA_DIR"] = AppPaths.configDir.path
        env["PYTHONUNBUFFERED"] = "1"

        let ai = ConfigManager.shared.config.ai
        if !ai.apiKey.isEmpty { env["DEEPSEEK_API_KEY"] = ai.apiKey }
        if !ai.baseURL.isEmpty { env["SUMMARY_API_URL"] = ai.baseURL }
        if !ai.model.isEmpty { env["SUMMARY_MODEL"] = ai.model }

        if let mcp = ConfigManager.shared.config.mcp {
            let notesDir = (mcp.knowledgeBasePath as NSString).expandingTildeInPath
            env["NOTES_DIR"] = notesDir
        }

        return env
    }

    // MARK: - Public

    func start() {
        lifecycleQueue.async { [self] in
            guard state == .stopped || state == .crashed else { return }
            guard proxyConfig?.enabled == true else {
                debugLog("[TokenProxy] Disabled by config")
                return
            }
            guard !upstreamURL.isEmpty else {
                debugLog("[TokenProxy] No upstream URL configured")
                return
            }
            launchProcess()
        }
    }

    func stop() {
        lifecycleQueue.async { [self] in
            isStopping = true
            healthCheckTimer?.invalidate()
            healthCheckTimer = nil
            process?.terminate()
            process = nil
            state = .stopped
            debugLog("[TokenProxy] Stopped")
        }
    }

    func forceRestart() {
        lifecycleQueue.async { [self] in
            isStopping = true
            healthCheckTimer?.invalidate()
            healthCheckTimer = nil
            process?.terminate()
            process = nil
            crashCount = 0
            isStopping = false
            state = .stopped

            guard proxyConfig?.enabled == true else { return }
            guard !upstreamURL.isEmpty else { return }
            launchProcess()
        }
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

    // MARK: - Internal

    private func findScript() -> String? {
        let candidates = [
            Bundle.main.resourcePath.map { "\($0)/MCPScripts/token_proxy.py" },
            #file.replacingOccurrences(of: #"/Sources/MCP/TokenProxyManager.swift"#, with: "/Sources/MCPScripts/token_proxy.py"),
        ]
        for case let path? in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // 回退：相对于当前文件往上找
        let dir = (#file as NSString).deletingLastPathComponent
        let rel = (dir as NSString).appendingPathComponent("../MCPScripts/token_proxy.py")
        let resolved = NSString(string: rel).standardizingPath
        return FileManager.default.fileExists(atPath: resolved) ? resolved : nil
    }

    private func launchProcess() {
        guard let scriptPath = findScript() else {
            debugLog("[TokenProxy] token_proxy.py not found")
            state = .crashed
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: MCPProcessManager.pythonVenvPath)
        proc.arguments = [scriptPath]
        proc.environment = buildEnv()

        proc.terminationHandler = { [weak self] p in
            guard let self = self else { return }
            if self.isStopping { return }

            if p.terminationReason == .uncaughtSignal {
                self.crashCount += 1
                debugLog("[TokenProxy] Crashed (\(self.crashCount)/\(self.maxRestarts))")
                if self.crashCount >= self.maxRestarts {
                    self.state = .crashed
                    return
                }
                self.state = .stopped
                DispatchQueue.main.asyncAfter(deadline: .now() + self.restartDelaySec) {
                    self.lifecycleQueue.async { self.launchProcess() }
                }
            } else {
                self.state = .stopped
            }
        }

        do {
            // 静默 stdout/stderr，避免 pipe buffer 问题
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice

            try proc.run()
            process = proc
            debugLog("[TokenProxy] Started (PID \(proc.processIdentifier))")
            DispatchQueue.main.async { self.startHealthCheck() }
        } catch {
            debugLog("[TokenProxy] Failed to launch: \(error.localizedDescription)")
            state = .crashed
        }
    }

    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var retries = 0
        let maxRetries = 20

        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            retries += 1
            if retries > maxRetries {
                debugLog("[TokenProxy] Health check timed out")
                timer.invalidate()
                self.state = .crashed
                self.stop()
                return
            }

            Task {
                let healthy = await self.checkHealth(url: url)
                guard !Task.isCancelled else { return }
                if healthy {
                    self.crashCount = 0
                    self.state = .running
                    timer.invalidate()
                    debugLog("[TokenProxy] Server ready")
                }
            }
        }
    }

    @MainActor
    private func checkHealth(url: URL) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["status"] as? String) == "ok"
            {
                return true
            }
        } catch {}
        return false
    }
}
