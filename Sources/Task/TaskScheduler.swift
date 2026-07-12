import Cocoa

public final class TaskScheduler {
    public static let shared = TaskScheduler()

    private var timer: Timer?
    private let stateDB = TaskStateDB.shared

    /// 内部任务（由模块注册，非用户配置），优先级高于用户 tasks
    private(set) var internalTasks: [TaskConfig] = []

    private init() {
        EventBus.shared.subscribe(AppEvent.configDidLoad) { [weak self] _ in
            self?.reschedule()
        }
        installWakeObserver()
    }

    // MARK: - Internal task registration

    /// 注册内部任务（由各模块如 MCP 注册），启动时自动加入调度
    public func registerInternalTask(_ task: TaskConfig) {
        // 同名替换
        internalTasks.removeAll { $0.name == task.name }
        internalTasks.append(task)
        reschedule()
    }

    public func unregisterInternalTask(named name: String) {
        internalTasks.removeAll { $0.name == name }
        reschedule()
    }

    /// 合并用户配置 + 内部任务
    private func allTasks() -> [TaskConfig] {
        ConfigManager.shared.config.tasks + internalTasks
    }

    // MARK: - Start / Stop

    public func start() {
        handleMissed()
        scheduleNext()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 配置重载后：清理过期任务状态、补触发、重排下一轮
    public func reschedule() {
        timer?.invalidate()
        cleanupStaleTaskStates()
        handleMissed()
        scheduleNext()
    }

    // MARK: - Stale cleanup

    private func cleanupStaleTaskStates() {
        let configuredNames = Set(allTasks().map { $0.name })
        let dbNames = stateDB.allTaskNames()
        let stale = dbNames.filter { !configuredNames.contains($0) }
        for name in stale {
            stateDB.remove(taskName: name)
        }
    }

    // MARK: - Missed catch-up

    private func handleMissed() {
        let now = Date()
        let configs = allTasks().filter { $0.enabled && !$0.name.isEmpty && $0.mode != .manual }

        for task in configs {
            guard let expr = CronExpression(task.trigger) else { continue }

            // 无历史记录时，用今天 00:00 作为基准（防止 DB 重建后错过今日触发）
            let lastFire = stateDB.lastFire(for: task.name)
            let reference = lastFire ?? Calendar.current.startOfDay(for: now)
            let nextFire = nextCronDate(after: reference, expr: expr)
            guard let next = nextFire, next <= now else { continue }

            fireTask(task)
            stateDB.setLastFire(now, for: task.name)
        }
    }

    // MARK: - Schedule next

    private func scheduleNext() {
        let now = Date()
        let configs = allTasks().filter { $0.enabled && !$0.name.isEmpty && $0.mode != .manual }
        var earliest: Date?

        for task in configs {
            guard let expr = CronExpression(task.trigger) else { continue }
            let lastFire = stateDB.lastFire(for: task.name)
            // 下次触发：lastFire（或 now）之后的下一个 cron 匹配点
            if let next = nextCronDate(after: lastFire ?? now, expr: expr),
               next > now
            {
                if earliest == nil || next < earliest! {
                    earliest = next
                }
            }
        }

        timer?.invalidate()

        guard let fireAt = earliest else { return }

        let interval = fireAt.timeIntervalSince(now)

        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.1), repeats: false) {
            [weak self] _ in
            self?.onTimerFired()
        }
    }

    // MARK: - Timer fired

    private func onTimerFired() {
        let now = Date()
        let configs = allTasks().filter { $0.enabled && !$0.name.isEmpty && $0.mode != .manual }

        for task in configs {
            guard let expr = CronExpression(task.trigger) else { continue }
            let lastFire = stateDB.lastFire(for: task.name)
            if let next = nextCronDate(after: lastFire ?? now.addingTimeInterval(-60), expr: expr),
               next <= now
            {
                fireTask(task)
                stateDB.setLastFire(now, for: task.name)
            }
        }

        scheduleNext()
    }

    // MARK: - Execute

    private func fireTask(_ task: TaskConfig) {
        DispatchQueue.global(qos: .utility).async { [task] in
            let result = TaskExecutor.execute(task.exec)

            if !result.success {
                let errMsg = result.error.isEmpty ? "exit code != 0" : String(result.error.prefix(200))
                EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                    title: L10n.Menu.taskFailed(task.name), body: errMsg
                ))
            } else {
                EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                    title: L10n.Menu.taskCompleted(task.name), body: ""
                ))
            }
        }
    }

    // MARK: - NSWorkspace sleep/wake

    private func installWakeObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in
            self?.timer?.invalidate()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            self?.handleMissed()
            self?.scheduleNext()
        }
    }

    // MARK: - Cron logic

    private struct CronExpression {
        let minutes: Set<Int>
        let hours: Set<Int>
        let days: Set<Int>
        let months: Set<Int>
        let weekdays: Set<Int>

        init?(_ expr: String) {
            let parts = expr.split(separator: " ").map(String.init)
            guard parts.count == 5 else { return nil }
            guard let m = parseField(parts[0], min: 0, max: 59),
                  let h = parseField(parts[1], min: 0, max: 23),
                  let d = parseField(parts[2], min: 1, max: 31),
                  let mo = parseField(parts[3], min: 1, max: 12),
                  let w = parseField(parts[4], min: 0, max: 6)
            else { return nil }
            minutes = m
            hours = h
            days = d
            months = mo
            weekdays = w
        }
    }

    private func nextCronDate(after date: Date, expr: CronExpression) -> Date? {
        let calendar = Calendar.current
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        comps.second = 0
        guard var current = calendar.date(from: comps) else { return nil }
        current = current.addingTimeInterval(60) // 从下一分钟开始搜

        // 最多搜索 366 天
        for _ in 0 ..< 527_040 {
            let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: current)
            guard let min = c.minute, let hr = c.hour, let day = c.day,
                  let mon = c.month, let wd = c.weekday
            else { break }
            let cronWD = wd - 1

            if expr.minutes.contains(min), expr.hours.contains(hr),
               expr.days.contains(day), expr.months.contains(mon),
               expr.weekdays.contains(cronWD)
            {
                return current
            }
            current = current.addingTimeInterval(60)
        }
        return nil
    }
}

// MARK: - Field parser

private func parseField(_ s: String, min: Int, max: Int) -> Set<Int>? {
    if s == "*" { return Set(min ... max) }
    var result = Set<Int>()
    for part in s.split(separator: ",") {
        let p = String(part)
        if p.contains("/") {
            let sp = p.split(separator: "/")
            guard sp.count == 2, let step = Int(sp[1]), step > 0 else { return nil }
            let range =
                sp[0] == "*" ? min ... max : (parseRange(String(sp[0]), min: min, max: max) ?? min ... max)
            for i in stride(from: range.lowerBound, through: range.upperBound, by: step) {
                result.insert(i)
            }
        } else if p.contains("-") {
            guard let r = parseRange(p, min: min, max: max) else { return nil }
            result.formUnion(r)
        } else {
            guard let v = Int(p), v >= min, v <= max else { return nil }
            result.insert(v)
        }
    }
    return result.isEmpty ? nil : result
}

private func parseRange(_ s: String, min: Int, max: Int) -> ClosedRange<Int>? {
    let sp = s.split(separator: "-")
    guard sp.count == 2, let lo = Int(sp[0]), let hi = Int(sp[1]),
          lo >= min, hi <= max, lo <= hi
    else { return nil }
    return lo ... hi
}
