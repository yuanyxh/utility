import Cocoa

public final class TaskScheduler {
    public static let shared = TaskScheduler()

    private var timer: Timer?
    private let stateDB = TaskStateDB.shared

    private init() {
        EventBus.shared.subscribe(AppEvent.configDidLoad) { [weak self] _ in
            self?.reschedule()
        }
        installWakeObserver()
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
        let configuredNames = Set(ConfigManager.shared.config.tasks.map { $0.name })
        let dbNames = stateDB.allTaskNames()
        let stale = dbNames.filter { !configuredNames.contains($0) }
        for name in stale {
            stateDB.remove(taskName: name)
            debugLog("[Scheduler] Removed stale task state: \(name)")
        }
    }

    // MARK: - Missed catch-up

    private func handleMissed() {
        let now = Date()
        let configs = ConfigManager.shared.config.tasks.filter { $0.enabled && !$0.name.isEmpty }

        for task in configs {
            guard let expr = CronExpression(task.trigger) else { continue }

            // 只补触发已有记录的（未运行过的不存在"错过"）
            guard let lastFire = stateDB.lastFire(for: task.name) else { continue }
            let nextFire = nextCronDate(after: lastFire, expr: expr)
            guard let next = nextFire, next <= now else { continue }

            debugLog("[Scheduler] Catch-up fire: \(task.name)")
            fireTask(task)
            stateDB.setLastFire(now, for: task.name)
        }
        debugLog("[Scheduler] Missed catch-up done")
    }

    // MARK: - Schedule next

    private func scheduleNext() {
        let now = Date()
        let configs = ConfigManager.shared.config.tasks.filter { $0.enabled && !$0.name.isEmpty }
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

        guard let fireAt = earliest else {
            debugLog("[Scheduler] No upcoming tasks")
            return
        }

        let interval = fireAt.timeIntervalSince(now)
        debugLog("[Scheduler] Next fire at \(fireAt) (in \(Int(interval))s)")

        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.1), repeats: false) { [weak self] _ in
            self?.onTimerFired()
        }
    }

    // MARK: - Timer fired

    private func onTimerFired() {
        let now = Date()
        let configs = ConfigManager.shared.config.tasks.filter { $0.enabled && !$0.name.isEmpty }

        for task in configs {
            guard let expr = CronExpression(task.trigger) else { continue }
            let lastFire = stateDB.lastFire(for: task.name)
            // nil 时从当前分钟开始搜（nextCronDate 内部 +60s 会跳过当前分钟）
            if let next = nextCronDate(after: lastFire ?? now.addingTimeInterval(-60), expr: expr),
               next <= now
            {
                debugLog("[Scheduler] Fire: \(task.name)")
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

            if result.success {
                debugLog("[Scheduler] \(task.name) OK")
            } else {
                let errMsg = result.error.isEmpty ? "exit code != 0" : String(result.error.prefix(200))
                debugLog("[Scheduler] \(task.name) FAILED: \(errMsg)")
                EventBus.shared.publish(AppEvent.taskDidFail, payload: (task.name, errMsg))
            }
        }
    }

    // MARK: - NSWorkspace sleep/wake

    private func installWakeObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            debugLog("[Scheduler] System going to sleep — invalidating timer")
            self?.timer?.invalidate()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            debugLog("[Scheduler] System woke up — rescheduling")
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
                  let w = parseField(parts[4], min: 0, max: 6) else { return nil }
            minutes = m; hours = h; days = d; months = mo; weekdays = w
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
                  let mon = c.month, let wd = c.weekday else { break }
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
            let range = sp[0] == "*" ? min ... max : (parseRange(String(sp[0]), min: min, max: max) ?? min ... max)
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
          lo >= min, hi <= max, lo <= hi else { return nil }
    return lo ... hi
}
