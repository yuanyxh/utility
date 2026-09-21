import AppKit
import Foundation

/// Manages the Python MCP server subprocess lifecycle.
/// Starts on app launch, restarts on crash (maxRestarts), stops on app quit.
/// 所有配置从 ConfigManager 实时读取，不缓存旧值。
/// 进程生命周期（启动/崩溃重启/健康检查/停止）委托给 PythonDaemon；
/// 本类负责业务决策：State 语义、事件广播、复用探测、崩溃通知、python 预检。
final class MCPProcessManager {
    static let shared = MCPProcessManager()

    enum State: String {
        case stopped, initializing, running, restarting, crashed
    }

    private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            MCPMenuManager.shared.updateState(state)
            // Broadcast for menu bar integration (P4)
            EventBus.shared.publish("mcp_state_changed", payload: state.rawValue)
        }
    }

    private var daemon: PythonDaemon?

    // Pre-flight cache（config 层不缓存，但 python 检查结果缓存——python 版本不会动态变）
    private var cachedServerPath: String?
    private var pythonChecked = false
    private var pythonAvailable = false

    /// 配置读取（实时，不缓存）
    private var mcpConfig: MCPConfig? {
        ConfigManager.shared.config.mcp
    }

    /// 自动检测出的端口（仅 `port` 配置为 0 时使用）。
    ///
    /// **必须缓存**：端口探测是 bind 测试，而 MCP 服务起来之后自己就占着这个
    /// 端口，再探测会跳过它返回下一个（9001 → 9002）。原先这里是「每次访问都
    /// 重新探测」的 computed property，于是运行期任何一次读取都会拿到漂移值。
    private var cachedPort: Int?
    private let portLock = NSLock()

    /// 本次运行实际使用的端口。服务端（daemon 的启动参数与环境变量）与消费方
    /// （`MCPClient`、用量查询）都从这里读，保证两侧指向同一个端口。
    var currentPort: Int {
        let configured = mcpConfig?.port ?? 0
        // 显式配置的端口永远权威，不走缓存——用户改配置后应当立即生效
        if configured > 0 { return configured }

        portLock.lock()
        defer { portLock.unlock() }
        if let cachedPort { return cachedPort }
        let detected = PortProbe.detectAvailable(startingFrom: PortProbe.Base.mcp)
        cachedPort = detected
        return detected
    }

    private var maxRestarts: Int {
        mcpConfig?.maxRestarts ?? 3
    }

    private var restartDelaySec: Double {
        Double(mcpConfig?.restartDelayMs ?? 2000) / 1000.0
    }

    /// 脚本专属环境变量（公共部分由 PythonScriptRunner.baseEnvironment() 提供）。
    /// 实时读取——PythonDaemon 每次启动时经 environment 闭包调用本属性。
    private var serverEnvironment: [String: String] {
        var overrides: [String: String] = [:]
        overrides["MCP_PORT"] = String(currentPort)

        // MEMORY_SERVER_URL：summarize.py 用此变量访问 MCP 服务
        overrides["MEMORY_SERVER_URL"] = HTTP.localBaseURL(port: currentPort)

        // mcp 路径配置（空字符串 = 使用默认路径）
        if let mcp = mcpConfig {
            // 空字符串 = 使用默认路径 ~/.utility/data/qdrant/
            let qdrantPath: String = if mcp.qdrantPath.isEmpty {
                AppPaths.configDir
                    .appendingPathComponent("data/qdrant").path
            } else {
                (mcp.qdrantPath as NSString).expandingTildeInPath
            }
            overrides["QDRANT_PATH"] = qdrantPath

            // 空字符串 = 使用默认路径 ~/.cache/utility/fastembed/
            let fastembedCachePath: String = if mcp.fastembedCacheDir.isEmpty {
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".cache/utility/fastembed").path
            } else {
                (mcp.fastembedCacheDir as NSString).expandingTildeInPath
            }
            overrides["FASTEMBED_CACHE_PATH"] = fastembedCachePath

            // 空字符串 = 使用内置默认模型
            if !mcp.embedderModel.isEmpty {
                overrides["EMBEDDER_MODEL"] = mcp.embedderModel
            }

            // 检索同义词扩展表：键值都由用户定义，无法用固定 struct 承载，故整体序列化透传。
            // 合并留在 Python 侧一处完成——两侧各写一遍合并逻辑，迟早出现「Swift 覆盖了、
            // Python 追加了」这种没法解释的差异。
            if let json = Self.synonymsJSON(mcp.synonyms) {
                overrides[Self.synonymsEnvKey] = json
            }
        }
        return PythonScriptRunner.environment(overrides: overrides)
    }

    /// 同义词表的 env 名（跨语言契约，Python 侧 `synonyms.SYNONYMS_ENV_KEY` 同值，
    /// 由 `scripts/check-router-config-contract.py` 交叉断言）。
    static let synonymsEnvKey = "MCP_SYNONYMS"

    /// 同义词表 → JSON；空表返回 nil（不注入，Python 侧用内置默认）。
    static func synonymsJSON(_ synonyms: [String: String]) -> String? {
        guard !synonyms.isEmpty,
              let data = try? JSONEncoder().encode(synonyms),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    /// 重置预检缓存（配置重载后调用，下次 start 重新检查）
    private func resetPrefetch() {
        cachedServerPath = nil
        pythonChecked = false
        pythonAvailable = false
    }

    // MARK: - Public API

    /// - Parameter reuseIfHealthy: 冷启动（app launch）时 true，端口已被健康 server 占用则复用
    ///   （历史孤儿进程 reparent 到 launchd 后仍监听端口，新 spawn 必然绑定失败）。
    ///   forceRestart/restart 传 false——那些场景用户期望真正重启应用新配置，
    ///   若复用旧进程会导致新配置静默不生效。
    func start(reuseIfHealthy: Bool = true) {
        guard mcpConfig?.enabled ?? false else {
            log("[MCP] Disabled by config, skipping")
            return
        }

        // 每次 start 重新检查（配置可能已变更）
        guard pythonCheck() else {
            state = .crashed
            return
        }

        guard let serverPath = findServerScript() else {
            log("[MCP] server.py not found in bundle")
            state = .crashed
            return
        }

        let daemon = ensureDaemon(scriptPath: serverPath)
        state = .initializing
        // 端口已被健康 server 占用时复用，避免重复 spawn 触发端口竞争
        daemon.start(reuseIfHealthy: reuseIfHealthy)
    }

    /// 强制重启（配置重载时调用，无论当前状态如何）。
    /// 委托 PythonDaemon.forceRestart()：停旧进程 → 等死 → 真正 spawn。
    /// port/scriptPath 经闭包实时读取，无需重建 daemon 即可应用新配置。
    func forceRestart() {
        log("[MCP] Force restart (config reload)")
        resetPrefetch()
        guard let daemon else {
            log("[MCP] No daemon, cold start instead")
            start(reuseIfHealthy: false)
            return
        }
        daemon.forceRestart()
    }

    func stop() {
        daemon?.stop()
    }

    func restart() {
        stop()
        start(reuseIfHealthy: false)
    }

    // MARK: - Pre-flight checks

    private func pythonCheck() -> Bool {
        if pythonChecked { return pythonAvailable }
        pythonChecked = true

        // 1. Check if venv exists
        let venvPython = PythonScriptRunner.pythonVenvPath
        guard FileManager.default.fileExists(atPath: venvPython) else {
            // 2. Check if Homebrew python3.12 is available
            let brewTask = Process()
            brewTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            // 探测任意 python3，不写死小版本：用户装 3.13 时找 python3.12 会误报未安装
            brewTask.arguments = ["bash", "-c", "command -v python3"]
            let brewPipe = Pipe()
            brewTask.standardOutput = brewPipe
            brewTask.standardError = FileHandle.nullDevice
            var brewPython: String? = nil
            if (try? brewTask.run()) != nil {
                brewTask.waitUntilExit()
                if brewTask.terminationStatus == 0 {
                    let data = brewPipe.fileHandleForReading.readDataToEndOfFile()
                    brewPython = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if brewPython == nil {
                let msg = "请安装 Python 3：brew install python"
                log("[MCP] ❌ \(msg)")
                notify("MCP 环境检查", msg)
            } else {
                let reqPath = "Sources/MCPScripts/requirements.txt"
                let steps = """
                创建虚拟环境：
                  python3 -m venv ~/.config/utility/mcp-venv
                  ~/.config/utility/mcp-venv/bin/pip install -r \(reqPath)
                """
                log("[MCP] ❌ 虚拟环境未就绪\n\(steps)")
                notify("MCP 环境检查", "虚拟环境未就绪，请查看 debug.log 获取安装步骤")
            }
            pythonAvailable = false
            return false
        }

        // 3. venv exists, verify it works
        let task = Process()
        task.executableURL = URL(fileURLWithPath: venvPython)
        task.arguments = ["--version"]
        task.standardOutput = Pipe()
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            pythonAvailable = task.terminationStatus == 0
        } catch {
            pythonAvailable = false
        }
        if !pythonAvailable {
            log("[MCP] ❌ 虚拟环境 Python 不可用: \(venvPython)")
        }
        return pythonAvailable
    }

    private func findServerScript() -> String? {
        PythonScriptRunner.findScript(named: PythonScripts.server)
    }

    // MARK: - Daemon 装配

    /// 创建（或复用）PythonDaemon，挂接状态回调。
    /// daemon 生命周期（启动/崩溃重启/健康检查/停止）由 PythonDaemon 自管。
    private func ensureDaemon(scriptPath: String) -> PythonDaemon {
        if let daemon { return daemon }

        let config = PythonDaemon.Config(
            scriptPath: { [weak self] in
                self?.findServerScript() ?? scriptPath
            },
            port: { [weak self] in
                // 兜底值与 PortProbe.Base.mcp 同源，避免两处字面量各自漂移
                self?.currentPort ?? PortProbe.Base.mcp
            },
            healthPath: "/health",
            service: "mino-brain", // 校验 service 字段，防止误复用同端口其他服务
            readySignals: ["Application startup complete", "Uvicorn running on"],
            maxRestarts: maxRestarts,
            restartDelaySec: restartDelaySec,
            environment: { [weak self] in
                self?.serverEnvironment ?? [:]
            },
            logTag: "MCP",
        )
        let daemon = PythonDaemon(config: config)
        daemon.onStateChange = { [weak self] daemonState in
            self?.applyDaemonState(daemonState)
        }
        daemon.onMaxRestarts = { [weak self] _ in
            self?.notifyCrash()
        }
        self.daemon = daemon
        return daemon
    }

    /// 把 PythonDaemon 通用状态映射到 MCP 自身 5 态 State 并广播。
    private func applyDaemonState(_ daemonState: PythonDaemon.State) {
        switch daemonState {
        case .starting:
            state = .initializing
        case .running:
            state = .running
        case .restarting:
            state = .restarting
        case .crashed:
            state = .crashed
        case .stopped:
            state = .stopped
        }
    }

    private func notify(_ title: String, _ body: String) {
        EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(title: title, body: body))
    }

    private func notifyCrash() {
        notify(L10n.MCP.notifyCrashedTitle, L10n.MCP.notifyCrashedBody(maxRestarts))
    }
}

// MARK: - Logger

private func log(_ msg: String) {
    debugLog(msg)
}
