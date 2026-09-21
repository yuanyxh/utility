import Foundation

/// 常驻 Python 进程守护：进程启动、崩溃重启、健康检查、停止。
///
/// 通用生命周期骨架（MCPProcessManager / TokenProxyManager 共用的部分收束于此）。
/// 业务决策（State enum 语义、事件广播、复用探测、崩溃通知、config 读取时机）仍由
/// 组合方负责——Daemon 通过 `onStateChange` / `onMaxRestarts` 回调上报，组合方自行映射。
/// - Note: 标注 `@unchecked Sendable` 的依据（不是「反正能编过」）：
///   - `process` / `crashCount` / `isStopping` / `state`：由 `lifecycleQueue` 独占，
///     所有写入点都在该队列上（`launchProcess` / `stopSync` / `terminationHandler`
///     的派发块 / 健康检查的两个收敛点）
///   - `healthCheckTimer`：由主线程独占——`Timer` 必须挂在有 runloop 的线程上，
///     lifecycleQueue 没有 runloop，它天然不属于该队列
///   - `onStateChange` / `onMaxRestarts`：初始化后只赋值一次，此后只读
///   - `config`：`let`，不可变
///
///   `DispatchQueue.async` 的闭包是 `@Sendable`，不标注的话每处捕获 self 都会报
///   `SendableClosureCaptures`；告警噪声会淹掉真正的新告警。
final class PythonDaemon: @unchecked Sendable {
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
        /// 健康检查轮询上限（次数），默认 20 × 0.5s ≈ 10s。依赖重的服务
        /// （加载模型、建索引）可能更慢，组合方可按需抬高，不必改这里的常量。
        var healthCheckMaxRetries = 20
        /// 健康检查轮询间隔（秒）
        var healthCheckIntervalSec: TimeInterval = 0.5
        /// 实时从 config 构建环境变量（不缓存）
        var environment: () -> [String: String]
        var logTag = "PythonDaemon"
    }

    /// 通用守护状态。组合方在 onStateChange 中映射到自己 State enum 并广播。
    enum State: String {
        case stopped, starting, running, restarting, crashed
    }

    /// 状态。写入点全部收敛到 `lifecycleQueue` 与主线程（见各处 `state = …`），
    /// 但回调的消费方还有主线程假设——那里会更新菜单栏、发通知。统一在主线程
    /// 投递回调，避免 UI 从后台队列被更新。
    private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            let changed = state
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(changed)
            }
        }
    }

    /// 状态变化回调（组合方更新自身 State + 广播）
    var onStateChange: ((State) -> Void)?
    /// 崩溃达上限回调（组合方决定通知/停止）
    var onMaxRestarts: ((Int) -> Void)?

    /// 就绪信号探测的缓冲上限（字节），超出时只保留尾部。
    private static let readyBufferLimit = 64 * 1024

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
        guard let url = HTTP.localURL(port: config.port(), path: config.healthPath) else {
            return false
        }
        // 这里在 lifecycleQueue（后台队列）上同步等待，不是在主线程——
        // URLSession 的回调走自己的 delegate 队列，不依赖主 runloop，
        // 因此不会出现 CLAUDE.md 里记的那类主线程死锁。主线程上的健康轮询
        // 走异步版 checkHealth。
        let sem = DispatchSemaphore(value: 0)
        var healthy = false
        URLSessionManager.shared.directSession.dataTask(with: url) { [config] data, _, _ in
            if let data {
                healthy = isHealthyBody(data, service: config.service)
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
    ///
    /// 若本进程是冷启动时「复用」来的外部健康进程（孤儿），`process` 为 nil，
    /// `stopSync()` 停不掉它，spawn 会撞端口。故此处补一步按端口清理。
    /// 只在没有托管进程时做——正常托管的重启路径行为完全不变。
    func forceRestart() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            let hadManagedProcess = process != nil
            stopSync()
            if !hadManagedProcess {
                terminatePortOccupant()
            }
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
        // healthCheckTimer 在主线程（runloop）上创建，这里保持同一线程失效与置空，
        // 避免跨队列读写这个引用本身
        DispatchQueue.main.async { [weak self] in
            self?.healthCheckTimer?.invalidate()
            self?.healthCheckTimer = nil
        }

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

    /// 终止端口上的监听进程——用于「冷启动时复用了孤儿进程」的场景。
    ///
    /// 那种情况下 `process` 为 nil，`stopSync()` 无从下手，直接 spawn 会因端口
    /// 仍被占而失败（uvicorn 报 Errno 48）。这里按端口找出监听者清掉，
    /// 让随后的 `launchProcess()` 能绑上。
    ///
    /// **必须带 `-sTCP:LISTEN`**：不带时 `lsof -ti:<port>` 会连「连接该端口的
    /// 客户端」一并返回（实测 8613 上会返回正在走代理的 Clash Verge），
    /// 照此 kill 即误杀无关进程。
    private func terminatePortOccupant() {
        for pid in listeningPIDs() {
            kill(pid, SIGTERM)
        }
        // 等端口真正释放再返回：launchProcess() 紧随其后要绑同一端口，
        // 进程未死透时绑定依旧失败——这正是本函数存在的理由。
        let deadline = DispatchTime.now() + 3.0
        while .now() < deadline, !listeningPIDs().isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for pid in listeningPIDs() {
            kill(pid, SIGKILL)
        }
    }

    /// 端口上的监听进程 PID（仅 LISTEN，不含连接方）。
    /// `lsof` 走全路径：本进程由 launchd 启动，PATH 不含 /usr/sbin。
    private func listeningPIDs() -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-ti:\(config.port())", "-sTCP:LISTEN"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            debugLog("[\(config.logTag)] lsof 调用失败: \(error.localizedDescription)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
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
            let reason = p.terminationReason
            // 本闭包由系统在自己的队列上回调，而 isStopping / crashCount / state
            // 都由 lifecycleQueue 独占（stopSync 与 launchProcess 也在那里写）。
            // 全部收敛回该队列再读写，消除这组无同步竞争。
            lifecycleQueue.async { [weak self] in
                guard let self else { return }

                // 身份判断必须凌驾于 isStopping 之上。forceRestart 的 stopSync()
                // 置 isStopping 后立刻 launchProcess()，而后者第一步就把该标志重置
                // 回 false；等这个异步回调真正跑起来时标志已失效，旧进程的正常关闭
                // 会被误判成崩溃——表现为每次重载配置凭空多 spawn 一个进程，它撞上
                // 被占用的端口后进入无限重启循环（2026-09-21 实测 784 次、持续 49
                // 分钟）。process 已被替换成新进程，即说明这次退出属于旧进程，忽略。
                // 真崩溃时 process 仍等于 p，不受影响。
                if process !== p { return }

                // stop() 主动关闭时不触发重启
                if isStopping { return }

                // 判据须同时覆盖「被信号杀死」与「非零退出码」：只看 .uncaughtSignal
                // 会漏掉最常见的失败——Python 未捕获异常、端口绑定失败（uvicorn 报
                // Errno 48 后 exit 3）、外部 kill 都退化为 .exit，被当作正常退出
                // 静默置 .stopped 且永不重试。
                if reason == .uncaughtSignal || p.terminationStatus != 0 {
                    crashCount += 1
                    let count = crashCount
                    debugLog(
                        "[\(config.logTag)] Process crashed (\(count)/\(config.maxRestarts))",
                    )
                    if count >= config.maxRestarts {
                        state = .crashed
                        DispatchQueue.main.async {
                            self.onMaxRestarts?(self.config.maxRestarts)
                        }
                        return
                    }
                    state = .restarting
                    DispatchQueue.main.asyncAfter(deadline: .now() + config.restartDelaySec) {
                        self.lifecycleQueue.async {
                            // 重启前先探一次端口：若已有健康进程在跑，说明这次「崩溃」
                            // 多半是新进程撞了被占用的端口，再 spawn 只会重复撞。直接
                            // 认领，避免把一次端口冲突放大成重启风暴。
                            // probeExistingServer 在 lifecycleQueue（非主线程）上同步
                            // 等待，不会死锁——与 start() 的调用点同理。
                            if self.probeExistingServer() {
                                self.crashCount = 0
                                self.state = .running
                                debugLog("[\(self.config.logTag)] Adopted healthy process after crash")
                            } else {
                                self.launchProcess()
                            }
                        }
                    }
                } else {
                    // Normal exit
                    state = .stopped
                }
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
                // 就绪前必须有上限：子进程若持续输出却永不发就绪信号（例如依赖
                // 缺失后反复打印错误），无界的 buffer 会一直吃内存。保留尾部——
                // 信号总是出现在最近的输出里。
                if buffer.count > Self.readyBufferLimit {
                    buffer = Data(buffer.suffix(Self.readyBufferLimit))
                }
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
        guard let url = HTTP.localURL(port: config.port(), path: config.healthPath) else {
            return
        }
        var retries = 0
        let maxRetries = config.healthCheckMaxRetries

        healthCheckTimer = Timer.scheduledTimer(
            withTimeInterval: config.healthCheckIntervalSec, repeats: true,
        ) { [weak self] timer in
            guard let self else { return }

            retries += 1
            if retries > maxRetries {
                debugLog("[\(config.logTag)] Health check timed out (unresponsive)")
                timer.invalidate()
                // stopSync 操作 process / isStopping，必须在 lifecycleQueue 上执行
                // ——Timer 回调在主线程，直接调用会与 launchProcess 竞争
                lifecycleQueue.async { [weak self] in
                    guard let self else { return }
                    state = .crashed
                    stopSync()
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                let healthy = await checkHealth(url: url)
                if healthy {
                    // crashCount 与 state 都由 lifecycleQueue 独占，回到该队列收敛
                    lifecycleQueue.async { [weak self] in
                        guard let self else { return }
                        crashCount = 0
                        state = .running
                    }
                    timer.invalidate()
                    debugLog("[\(config.logTag)] Server ready")
                }
            }
        }
    }

    @MainActor
    private func checkHealth(url: URL) async -> Bool {
        do {
            let (data, _) = try await URLSessionManager.shared.directSession.data(from: url)
            return isHealthyBody(data, service: config.service)
        } catch {
            return false
        }
    }
}

/// 健康响应判定。两个消费方（复用探测 `probeExistingServer` 与轮询检查
/// `checkHealth`）共用同一判据。
///
/// 抽出来的理由不是省几行：判据分散时两处容易漂移——一处放宽、一处收紧，
/// 就会出现「复用了既有进程，却一直判定未就绪」这种只在单个入口复现的状态。
private func isHealthyBody(_ data: Data, service: String?) -> Bool {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (json["status"] as? String) == "ok"
    else {
        return false
    }
    return service == nil || (json["service"] as? String) == service
}
