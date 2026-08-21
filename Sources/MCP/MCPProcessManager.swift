import AppKit
import Foundation

/// Manages the Python MCP server subprocess lifecycle.
/// Starts on app launch, restarts on crash (maxRetries), stops on app quit.
/// 所有配置从 ConfigManager 实时读取，不缓存旧值。
final class MCPProcessManager {
    static let shared = MCPProcessManager()

    /// Path to the Python venv where MCP dependencies are installed.
    /// Created by: `python3.12 -m venv ~/.config/utility/mcp-venv && pip install -r requirements.txt`
    static let pythonVenvPath = (
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/utility/mcp-venv/bin/python3")
            .path,
    )

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

    private var process: Process?
    private var healthCheckTimer: Timer?
    private var crashCount = 0
    /// stop() 主动关闭时不触发重启
    private var isStopping = false

    // Pre-flight cache（config 层不缓存，但 python 检查结果缓存——python 版本不会动态变）
    private var cachedServerPath: String?
    private var pythonChecked = false
    private var pythonAvailable = false
    /// Serial queue for process lifecycle (stop → start), prevents
    /// a new process from launching while an old one is still dying.
    private let lifecycleQueue = DispatchQueue(label: "mcp-process-lifecycle")

    /// 配置读取（实时，不缓存）
    private var mcpConfig: MCPConfig? {
        ConfigManager.shared.config.mcp
    }

    private var port: Int {
        mcpConfig?.port ?? 9001
    }

    private var maxRestarts: Int {
        mcpConfig?.maxRestarts ?? 3
    }

    private var restartDelaySec: Double {
        Double(mcpConfig?.restartDelayMs ?? 2000) / 1000.0
    }

    /// 从 config 实时构建环境变量
    private func buildEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["MCP_PORT"] = String(port)
        env["PYTHONUNBUFFERED"] = "1"
        env["UTILITY_DATA_DIR"] = AppPaths.configDir.path

        // ai 配置
        let ai = ConfigManager.shared.config.ai
        if !ai.apiKey.isEmpty { env["DEEPSEEK_API_KEY"] = ai.apiKey }
        if !ai.baseURL.isEmpty { env["SUMMARY_API_URL"] = ai.baseURL }
        if !ai.model.isEmpty { env["SUMMARY_MODEL"] = ai.model }

        // mcp 路径配置
        if let mcp = mcpConfig {
            env["QDRANT_PATH"] = (mcp.qdrantPath as NSString).expandingTildeInPath
            env["NOTES_DIR"] = (mcp.knowledgeBasePath as NSString).expandingTildeInPath
            env["FASTEMBED_CACHE_PATH"] = (mcp.fastembedCacheDir as NSString).expandingTildeInPath
            env["EMBEDDER_MODEL"] = mcp.embedderModel
        }
        return env
    }

    /// 重置预检缓存（配置重载后调用，下次 start 重新检查）
    private func resetPrefetch() {
        cachedServerPath = nil
        pythonChecked = false
        pythonAvailable = false
        crashCount = 0
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

        state = .initializing
        // 端口已被健康 server 占用时复用，避免重复 spawn 触发端口竞争
        if reuseIfHealthy, probeExistingServer() {
            state = .running
            log("[MCP] Reusing existing healthy server on port \(port)")
            return
        }
        launchProcess(serverPath: serverPath)
    }

    /// 探测端口是否已有健康的 MCP server（health endpoint 返回 status=ok 且 service 匹配）。
    /// 健康则复用，否则由调用方 spawn 新实例。校验 service 防止误复用同端口其他服务。
    private func probeExistingServer() -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let sem = DispatchSemaphore(value: 0)
        var healthy = false
        URLSession.shared.dataTask(with: url) { data, _, err in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["status"] as? String) == "ok",
               (json["service"] as? String) == "mino-brain"
            {
                healthy = true
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2.0)
        return healthy
    }

    /// 强制重启（配置重载时调用，无论当前状态如何）
    func forceRestart() {
        log("[MCP] Force restart (config reload)")
        stop()
        resetPrefetch()
        // Wait for old process to fully release resources (Qdrant lock, port, etc.)
        // before launching the new instance. stop() kills async so we poll here.
        let deadline = DispatchTime.now() + 4.0
        while let p = process, p.isRunning, .now() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        // reuseIfHealthy: false —— 重启必须真正 spawn，若 probe 发现旧进程仍健康而复用，
        // 新配置（port/qdrantPath/apiKey）不会生效，重载/手动重启变成空操作。
        start(reuseIfHealthy: false)
    }

    func stop() {
        isStopping = true
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        guard let proc = process else {
            state = .stopped
            return
        }

        proc.terminate()
        state = .stopped

        // Keep process reference until old process is confirmed dead,
        // so a concurrent start() can wait for it before creating a
        // new instance — prevents two processes sharing the same
        // Qdrant migration dir / port / etc.
        lifecycleQueue.async { [weak self] in
            let deadline = DispatchTime.now() + 3.0
            while proc.isRunning, .now() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                _ = 1
            }
            DispatchQueue.main.async {
                // Only null out if still the same process (not a newer one)
                if self?.process?.processIdentifier == proc.processIdentifier {
                    self?.process = nil
                }
            }
        }
    }

    func restart() {
        stop()
        start()
    }

    // MARK: - Pre-flight checks

    private func pythonCheck() -> Bool {
        if pythonChecked { return pythonAvailable }
        pythonChecked = true

        // 1. Check if venv exists
        let venvPython = Self.pythonVenvPath
        guard FileManager.default.fileExists(atPath: venvPython) else {
            // 2. Check if Homebrew python3.12 is available
            let brewTask = Process()
            brewTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            brewTask.arguments = ["bash", "-c", "command -v python3.12"]
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
                let msg = "请安装 Python 3.12：brew install python"
                log("[MCP] ❌ \(msg)")
                notify("MCP 环境检查", msg)
            } else {
                let reqPath = "Sources/MCPScripts/requirements.txt"
                let steps = """
                创建虚拟环境：
                  python3.12 -m venv ~/.config/utility/mcp-venv
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
        findScript(named: "server.py")
    }

    /// Resolve path to a script in MCPScripts bundle directory.
    /// Checks bundle first (packaged app), then dev source directory.
    func findScript(named name: String) -> String? {
        // In SPM, resources are at Bundle.module.resourceURL
        guard let resourceURL = Bundle.module.resourceURL else {
            log("[MCP] No bundle resource URL")
            return nil
        }

        let scriptsDir = resourceURL.appendingPathComponent("MCPScripts")
        let scriptPath = scriptsDir.appendingPathComponent(name).path

        if FileManager.default.fileExists(atPath: scriptPath) {
            return scriptPath
        }

        // Fallback: development path (source directory)
        let devBase = resourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devPath = devBase.appendingPathComponent("MCPScripts/\(name)").path

        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        return nil
    }

    // MARK: - Process lifecycle

    private func launchProcess(serverPath: String) {
        isStopping = false
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.pythonVenvPath)
        proc.arguments = [serverPath] // port via MCP_PORT env in buildEnv()

        // 实时从 config 构建环境变量
        proc.environment = buildEnv()

        // Handle process exit
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            // stop() 主动关闭时不触发重启
            if isStopping { return }

            let reason = p.terminationReason
            if reason == .uncaughtSignal {
                crashCount += 1
                log("[MCP] Process crashed (\(crashCount)/\(maxRestarts))")
                if crashCount >= maxRestarts {
                    state = .crashed
                    notifyCrash()
                    return
                }
                state = .restarting
                DispatchQueue.main.asyncAfter(deadline: .now() + restartDelaySec) {
                    self.launchProcess(serverPath: serverPath)
                }
            } else {
                // Normal exit (exit(0) — shouldn't happen in server mode)
                state = .stopped
            }
        }

        do {
            // Capture stderr 以检测 Uvicorn 启动完成信号
            let stderrPipe = Pipe()
            proc.standardError = stderrPipe

            try proc.run()
            process = proc
            log("[MCP] Started (PID \(proc.processIdentifier))")

            // 等待服务器输出启动完成信号后再健康检查
            waitForReady(pipe: stderrPipe)
        } catch {
            log("[MCP] Failed to launch: \(error.localizedDescription)")
            state = .crashed
        }
    }

    // MARK: - Startup readiness detection

    /// Monitors process stderr for the server startup signal ("Application startup complete"
    /// or "Uvicorn running on"), then begins health check polling.
    /// Falls back to a timeout if the signal never arrives.
    private func waitForReady(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        var ready = false

        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF：子进程已退出（或从未成功写入）。此时 fd 永远"可读"，
                // 不清除 handler 会导致 fd_monitoring 队列无限触发，吃满 CPU。
                handle.readabilityHandler = nil
                return
            }

            if !ready {
                buffer.append(data)
                guard let output = String(data: buffer, encoding: .utf8) else { return }

                if output.contains("Application startup complete") || output.contains("Uvicorn running on") {
                    ready = true
                    // 启动后仍保持读取管道，避免 pipe buffer 积满导致子进程 write() 阻塞
                    DispatchQueue.main.async { [weak self] in
                        self?.startHealthCheck()
                    }
                }
            }
            // ready 后继续读取并丢弃数据，防止 pipe buffer 写满阻塞子进程
        }

        // 不加超时杀死进程——服务器可能因网络/模型加载慢但最终会准备好
        // 如果进程真正崩溃退出, terminationHandler 会处理重启
    }

    // MARK: - Health check

    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var retries = 0
        let maxRetries = 20 // ~10s total wait (服务器已就绪，应该很快响应)

        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] timer in
            guard let self else { return }

            retries += 1
            if retries > maxRetries {
                log("[MCP] Health check timed out (server unresponsive)")
                timer.invalidate()
                state = .crashed
                stop()
                return
            }

            let sem = DispatchSemaphore(value: 0)
            var healthy = false

            URLSession.shared.dataTask(with: url) { data, _, err in
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (json["status"] as? String) == "ok"
                {
                    healthy = true
                } else if let err {
                    log("[MCP] Health check attempt \(retries): \(err.localizedDescription)")
                }
                sem.signal()
            }.resume()

            _ = sem.wait(timeout: .now() + 2.0)

            if healthy {
                crashCount = 0
                state = .running
                timer.invalidate()
                log("[MCP] Server ready")
            }
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
