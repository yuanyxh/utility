import Cocoa

extension Notification.Name {
    static let knowledgeNeedsRefill = Notification.Name("knowledgeNeedsRefill")
}

/// 知识面板的调度：后台补货 + 定时自动弹。
/// **必须自建 Timer**：TaskScheduler 的 `handleMissed()` 以「今天 00:00 后第一个 cron 点」为基准，
/// 任何 sub-daily 的 cron 都会静默退化成每天一次。两个 timer 的间隔都只是节拍:补货看池容量、自动弹出看上次弹出时刻。
final class KnowledgeService: NSObject {
    static let shared = KnowledgeService()

    /// 面板引用由 AppDelegate 注入（面板自身零引用 service，只经 EventBus 收发 show/close）。
    weak var panel: KnowledgePanelController?

    private var refillTimer: Timer?
    private var autoShowTimer: Timer?
    /// 补货一轮可能要几分钟，比间隔更长，用闸门防止叠着起多个进程。
    private var refillRunning = false
    /// 系统休眠中：不再启动新补货，正在跑的子进程也被 `shouldCancel` 中止。
    private var suspended = false
    private var lastRefillAt: Date?
    private var lastSummary = ""
    private let refillLock = NSLock()

    /// 自动弹出的 timer 只当**唤醒节拍**:真正的开关是「距上次弹出是否已过 autoShowIntervalMinutes」。
    /// 拿间隔本身当节拍会退化成「连续运行时长」,被重载/重启/休眠反复归零(实测一天 12 次 rearm,60 分钟从未凑齐)
    private static let autoShowBeatSeconds: TimeInterval = 60
    var isRefillRunning: Bool {
        refillLock.lock()
        defer { refillLock.unlock() }
        return refillRunning
    }

    /// 菜单栏「任务」里那一条的状态文本（池容量 + 上次结果）。
    var statusText: String {
        refillLock.lock()
        let summary = lastSummary
        let at = lastRefillAt
        refillLock.unlock()
        let topics = KnowledgeStore.shared.unseenCount(kind: KnowledgePanelController.kindTopic)
        let stamp = at.map { Self.timeFormatter.string(from: $0) } ?? "-"
        return summary.isEmpty
            ? L10n.Knowledge.statusNew(topics: topics, stamp: stamp)
            : L10n.Knowledge.statusNewSummary(
                topics: topics, stamp: stamp, summary: summary,
            )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var isSuspended: Bool {
        refillLock.lock()
        defer { refillLock.unlock() }
        return suspended
    }

    override private init() {
        super.init()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 生命周期

    func start() {
        installWakeObserver()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onNeedsRefill),
            name: .knowledgeNeedsRefill, object: nil,
        )
        rearm()
        // 首启时池是空的,但立刻起子进程会和 app 启动抢资源,延后一轮唤醒再补
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.refillTick()
        }
    }

    /// 按当前配置重建两个 timer。配置重载时调用（enabled == false 只停不建）。
    func rearm() {
        refillTimer?.invalidate()
        refillTimer = nil
        autoShowTimer?.invalidate()
        autoShowTimer = nil

        let knowledge = ConfigManager.shared.config.knowledge
        guard knowledge.enabled else { return }

        if knowledge.refillIntervalMinutes > 0 {
            let timer = Timer(
                timeInterval: TimeInterval(knowledge.refillIntervalMinutes * 60),
                target: self, selector: #selector(refillTick), userInfo: nil, repeats: true,
            )
            RunLoop.main.add(timer, forMode: .common)
            refillTimer = timer
        }
        if knowledge.autoShowEnabled, knowledge.autoShowIntervalMinutes > 0 {
            let timer = Timer(
                timeInterval: Self.autoShowBeatSeconds,
                target: self, selector: #selector(autoShowTick), userInfo: nil, repeats: true,
            )
            RunLoop.main.add(timer, forMode: .common)
            autoShowTimer = timer
        }
        debugLog("[Knowledge] schedule loaded (refill=\(knowledge.refillIntervalMinutes)m, autoShow=\(knowledge.autoShowIntervalMinutes)m)")
    }

    func stop() {
        refillTimer?.invalidate()
        refillTimer = nil
        autoShowTimer?.invalidate()
        autoShowTimer = nil
    }

    /// 休眠期间**不执行任何补货**：timer 停掉,已在跑的子进程由 `shouldCancel` 中止
    /// （否则它被系统冻结后会一直挂着,唤醒时又立刻撞上 wall-clock 超时）。
    private func installWakeObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            refillLock.lock()
            suspended = true
            refillLock.unlock()
            stop()
            debugLog("[Knowledge] system sleep: stop scheduling, running refill will be aborted")
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            refillLock.lock()
            suspended = false
            refillLock.unlock()
            rearm()
            debugLog("[Knowledge] system wake: reschedule")
            refillTick()
        }
    }

    // MARK: - 补货

    @objc private func onNeedsRefill() {
        guard ConfigManager.shared.config.knowledge.enabled else { return }
        launchRefill()
    }

    @objc private func refillTick() {
        let knowledge = ConfigManager.shared.config.knowledge
        guard knowledge.enabled else { return }
        refillLock.lock()
        let running = refillRunning
        let asleep = suspended
        refillLock.unlock()
        guard !(running || asleep) else {
            debugLog("[Knowledge] refill tick skipped: running=\(running) suspended=\(asleep)")
            return
        }

        let topics = KnowledgeStore.shared.unseenCount(kind: KnowledgePanelController.kindTopic)
        guard topics < knowledge.poolTargetTopic else {
            debugLog("[Knowledge] refill tick skipped: enough unread unseen=\(topics)/\(knowledge.poolTargetTopic)")
            return
        }
        launchRefill()
    }

    /// 起子进程补货。`runCaptureOutput` 已实现超时 + SIGKILL + 边读边存（防管道塞死），
    /// 正是这里需要的；environment 必须显式传 —— 否则子进程继承 GUI 进程环境，没有 `AI_API_KEY`。
    func launchRefill() {
        refillLock.lock()
        if refillRunning || suspended {
            let running = refillRunning
            let asleep = suspended
            refillLock.unlock()
            debugLog("[Knowledge] refill start blocked: running=\(running) suspended=\(asleep)")
            return
        }
        refillRunning = true
        refillLock.unlock()

        guard PythonScriptRunner.isGatewayAvailable else {
            debugLog("[Knowledge] gateway unavailable, refill skipped")
            finishRefill()
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.finishRefill() }
            do {
                let data = try PythonScriptRunner.runCaptureOutput(
                    module: GatewayEntry.knowledgeRefill,
                    arguments: [],
                    timeout: 900,
                    environment: PythonScriptRunner.environment(overrides: [:]),
                    shouldCancel: { [weak self] in self?.isSuspended ?? true },
                )
                let out = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self?.record(summary: Self.briefSummary(out))
                debugLog("[Knowledge] refill done: \(out)")
            } catch {
                if case PythonProcessError.cancelled = error {
                    // 休眠中止不是失败:记进 lastSummary 会让唤醒后菜单显示一次莫名的「补货失败」
                    debugLog("[Knowledge] refill aborted by system sleep")
                } else {
                    self?.record(summary: "")
                    debugLog("[Knowledge] refill failed: \(error)")
                }
            }
        }
    }

    private func finishRefill() {
        refillLock.lock()
        refillRunning = false
        refillLock.unlock()
    }

    private func record(summary: String) {
        refillLock.lock()
        lastRefillAt = Date()
        lastSummary = summary
        refillLock.unlock()
    }

    /// stdout 是一整行 JSON,菜单里只放得下 `made=N` 这一项。
    private static func briefSummary(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let made = obj["made"] as? Int
        else { return "" }
        return L10n.Knowledge.summaryMade(count: made)
    }

    // MARK: - 定时自动弹

    @objc private func autoShowTick() {
        let knowledge = ConfigManager.shared.config.knowledge
        guard knowledge.enabled, knowledge.autoShowEnabled else { return }
        // 到点判定放在守卫之前:节拍只有 1 分钟,若放到后面,长时间有面板开着时会每分钟刷一条守卫日志
        guard autoShowDue(intervalMinutes: knowledge.autoShowIntervalMinutes) else { return }
        guard let panel else {
            debugLog("[Knowledge] auto show skipped: panel not wired")
            return
        }
        // 「等了两小时没弹出来」时,这三条是唯一能区分「没到点」与「被挡掉」的线索
        guard !panel.isPanelVisible else {
            debugLog("[Knowledge] auto show skipped: panel already visible")
            return
        }
        guard !PanelManager.shared.hasVisiblePanel else {
            debugLog("[Knowledge] auto show skipped: another panel is visible")
            return
        }

        panel.showAuto()
        UserDefaults.standard.set(Date(), forKey: UDKey.knowledgeLastAutoShow)
        if panel.hasCard {
            debugLog("[Knowledge] auto show panel")
        } else {
            debugLog("[Knowledge] auto show: pool empty, refill immediately")
            launchRefill()
        }
    }

    /// 到点判定:timer 只提供节拍,该不该弹由「距上次弹出是否已过 interval」决定。从未弹过即到点。
    /// 被守卫挡下时**不**更新时刻 —— 那样要等到下一轮判定才补弹,而这正是想要的行为。
    private func autoShowDue(intervalMinutes: Int) -> Bool {
        let last = UserDefaults.standard.object(forKey: UDKey.knowledgeLastAutoShow) as? Date
        guard let last else { return true }
        return Date().timeIntervalSince(last) >= TimeInterval(intervalMinutes * 60)
    }
}
