import Foundation

/// 常驻 Python 进程守护：进程启动、崩溃重启、健康检查、停止。
///
/// 通用生命周期骨架（MCPProcessManager / TokenProxyManager 共用的部分收束于此）。
/// 业务决策（State enum 语义、事件广播、复用探测、崩溃通知、config 读取时机）仍由
/// 组合方负责——Daemon 通过 `onStateChange` / `onMaxRestarts` 回调上报，组合方自行映射。
final class PythonDaemon {
    struct Config {
        /// 脚本路径（闭包：配置重载后 forceRestart 无需重建 daemon 即可应用新路径）
        var scriptPath: () -> String
        /// 端口（闭包：配置重载后应用新端口，避免新旧进程端口竞争）
        var port: () -> Int
        /// 健康检查路径，默认 /health
        var healthPath = "/health"
        /// 健康检查校验的 service 字段；nil 则不校验（TokenProxy 场景）
        var service: String?
        /// stderr 就绪信号；非空则启动后监听 stderr 等到该信号再健康检查，
        /// 空则静默（nullDevice）启动后立即健康检查（TokenProxy 场景）
        var readySignals: [String] = []
        var maxRestarts = 3
        var restartDelaySec: TimeInterval = 2.0
        /// 实时从 config 构建环境变量（不缓存）
        var environment: () -> [String: String]
        var logTag = "PythonDaemon"
    }

    /// 通用守护状态。组合方在 onStateChange 中映射到自己 State enum 并广播。
    enum State: String {
        case stopped, starting, running, restarting, crashed
    }

    private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    /// 状态变化回调（组合方更新自身 State + 广播）
    var onStateChange: ((State) -> Void)?
    /// 崩溃达上限回调（组合方决定通知/停止）
    var onMaxRestarts: ((Int) -> Void)?

    private var process: Process?
    private var healthCheckTimer: Timer?
    private var crashCount = 0
    private var isStopping = false
    private let lifecycleQueue = DispatchQueue(label: "python-daemon-lifecycle")
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    var processIdentifier: Int32? {
        process?.processIdentifier
    }

    /// 探测端口是否已有健康进程（健康则复用，避免重复 spawn 端口竞争）。
    /// service 校验防止误复用同端口其他服务（MCP 场景）。
    func probeExistingServer() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(config.port())\(config.healthPath)") else {
            return false
        }
        let sem = DispatchSemaphore(value: 0)
        var healthy = false
        URLSession.shared.dataTask(with: url) { [config] data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["status"] as? String) == "ok",
               config.service == nil || (json["service"] as? String) == config.service
            {
                healthy = true
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2.0)
        return healthy
    }

    // MARK: - 生命周期

    /// - Parameter reuseIfHealthy: 冷启动时 true，端口已被健康进程占用则复用。
    ///   forceRestart/restart 传 false——那些场景期望真正重启应用新配置。
    func start(reuseIfHealthy: Bool = true) {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            // 端口已被健康进程占用时复用，避免重复 spawn 端口竞争
            if reuseIfHealthy, probeExistingServer() {
                state = .running
                debugLog("[\(config.logTag)] Reusing existing healthy process on port \(config.port())")
                return
            }
            launchProcess()
        }
    }

    func stop() {
        lifecycleQueue.async { [weak self] in
            self?.stopSync()
        }
    }

    /// 强制重启（配置重载时调用）：停旧进程 → 等死 → 真正 spawn。
    func forceRestart() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            stopSync()
            crashCount = 0
            launchProcess()
        }
    }

    func restart() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            stopSync()
            launchProcess()
        }
    }

    // MARK: - Internal

    /// stop 的同步实现（在 lifecycleQueue 内执行）。
    private func stopSync() {
        isStopping = true
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        guard let proc = process else {
            state = .stopped
            return
        }

        proc.terminate()
        state = .stopped

        // 等进程确认死亡，防止新进程并发竞争端口
        let deadline = DispatchTime.now() + 3.0
        while proc.isRunning, .now() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        if process?.processIdentifier == proc.processIdentifier {
            process = nil
        }
    }

    private func launchProcess() {
        isStopping = false
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: PythonScriptRunner.pythonVenvPath)
        proc.arguments = [config.scriptPath()]

        // 实时从 config 构建环境变量
        proc.environment = config.environment()

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            // stop() 主动关闭时不触发重启
            if isStopping { return }

            let reason = p.terminationReason
            if reason == .uncaughtSignal {
                crashCount += 1
                debugLog("[\(config.logTag)] Process crashed (\(crashCount)/\(config.maxRestarts))")
                if crashCount >= config.maxRestarts {
                    state = .crashed
                    onMaxRestarts?(config.maxRestarts)
                    return
                }
                state = .restarting
                DispatchQueue.main.asyncAfter(deadline: .now() + config.restartDelaySec) {
                    self.lifecycleQueue.async { self.launchProcess() }
                }
            } else {
                // Normal exit
                state = .stopped
            }
        }

        do {
            state = .starting

            // readySignals 非空：捕获 stderr 检测启动信号；空：静默（nullDevice）
            let stderrPipe = Pipe()
            proc.standardError = config.readySignals.isEmpty ? FileHandle.nullDevice : stderrPipe
            proc.standardOutput = FileHandle.nullDevice

            try proc.run()
            process = proc
            debugLog("[\(config.logTag)] Started (PID \(proc.processIdentifier))")

            if config.readySignals.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.startHealthCheck()
                }
            } else {
                waitForReady(pipe: stderrPipe)
            }
        } catch {
            debugLog("[\(config.logTag)] Failed to launch: \(error.localizedDescription)")
            state = .crashed
        }
    }

    /// 监听进程 stderr 的就绪信号，再开始健康检查。
    /// EOF 时必须清除 handler，否则 fd_monitoring 队列无限触发吃满 CPU。
    private func waitForReady(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        var ready = false

        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            if !ready {
                buffer.append(data)
                guard let output = String(data: buffer, encoding: .utf8) else { return }

                if config.readySignals.contains(where: { output.contains($0) }) {
                    ready = true
                    DispatchQueue.main.async { [weak self] in
                        self?.startHealthCheck()
                    }
                }
            }
            // ready 后继续读取并丢弃数据，防止 pipe buffer 写满阻塞子进程
        }
    }

    /// 轮询 /health 直到 ok 或超时。
    /// 健康检查必须 async/await + @MainActor，不能用 DispatchSemaphore
    /// （阻塞主线程导致 URLSession 回调死锁——项目实测教训，见 CLAUDE.md）。
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        guard let url = URL(string: "http://127.0.0.1:\(config.port())\(config.healthPath)") else {
            return
        }
        var retries = 0
        let maxRetries = 20 // ~10s total wait

        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return }

            retries += 1
            if retries > maxRetries {
                debugLog("[\(config.logTag)] Health check timed out (unresponsive)")
                timer.invalidate()
                state = .crashed
                stopSync()
                return
            }

            Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                let healthy = await checkHealth(url: url)
                if healthy {
                    crashCount = 0
                    state = .running
                    timer.invalidate()
                    debugLog("[\(config.logTag)] Server ready")
                }
            }
        }
    }

    @MainActor
    private func checkHealth(url: URL) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["status"] as? String) == "ok",
               config.service == nil || (json["service"] as? String) == config.service
            {
                return true
            }
        } catch {}
        return false
    }
}
