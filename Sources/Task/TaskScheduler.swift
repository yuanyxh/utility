import Cocoa

public final class TaskScheduler {
    public static let shared = TaskScheduler()

    private var timer: Timer?
    private let stateDB = TaskStateDB.shared

    /// Internal tasks (registered by modules, not user config), take priority over user tasks
    private(set) var internalTasks: [TaskConfig] = []

    private init() {
        EventBus.shared.subscribe(AppEvent.configDidLoad) { [weak self] _ in
            self?.reschedule()
        }
        installWakeObserver()
    }

    // MARK: - Internal task registration

    /// Register an internal task (registered by modules such as MCP), automatically added to the schedule at startup.
    ///
    /// Registration must **not** run stale cleanup: modules register one by one at launch, so
    /// cleaning here treats the internal tasks that have not registered yet as stale and deletes
    /// their `last_fire` — the next registration then catches up and re-fires on every restart.
    public func registerInternalTask(_ task: TaskConfig) {
        // Replace by name
        internalTasks.removeAll { $0.name == task.name }
        internalTasks.append(task)
        reschedule(cleanupStale: false)
    }

    public func unregisterInternalTask(named name: String) {
        internalTasks.removeAll { $0.name == name }
        reschedule()
    }

    /// Merge user config + internal tasks
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

    /// After a config reload: clean up stale task state, catch up missed runs, reschedule the next round.
    /// `cleanupStale: false` is used during internal-task registration, when not every module has
    /// registered yet (see `registerInternalTask`).
    public func reschedule(cleanupStale: Bool = true) {
        timer?.invalidate()
        if cleanupStale {
            cleanupStaleTaskStates()
        }
        handleMissed()
        scheduleNext()
    }

    // MARK: - Stale cleanup

    private func cleanupStaleTaskStates() {
        let configuredNames = Set(allTasks().map(\.name))
        let dbNames = stateDB.allTaskNames()
        let stale = dbNames.filter { !configuredNames.contains($0) }
        for name in stale {
            stateDB.remove(taskName: name)
        }
    }

    // MARK: - Missed catch-up

    private func handleMissed() {
        let now = Date()
        let calendar = Calendar.current
        let configs = allTasks().filter { $0.enabled && !$0.name.isEmpty && $0.mode != .manual }

        for task in configs {
            guard let expr = CronExpression(task.trigger) else { continue }

            // Use "the first cron match point after today 00:00" as the catch-up baseline:
            // - That point has not yet arrived (today's trigger window not reached) → do not catch up, leave it to scheduleNext to wait
            // - That point has passed and it has not fired today → catch up immediately for today
            // No longer uses lastFire as the baseline, to avoid catching up point by point from old historical points when lastFire is days ago
            // (e.g. a task at 10:00 daily that fired the day before yesterday would immediately re-run yesterday's when the app opens today at 09:00).
            guard let todayPoint = nextCronDate(after: calendar.startOfDay(for: now), expr: expr),
                  todayPoint <= now
            else { continue }

            // Already fired today (lastFire is not earlier than today's cron point), do not catch up again
            if let lastFire = stateDB.lastFire(for: task.name), lastFire >= todayPoint { continue }

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
            // Nearest future trigger point: search after now, do not use lastFire as baseline
            // (when lastFire is days ago, nextCronDate would find a past point that gets filtered out by next > now,
            // causing today's cron point to lose scheduling and never fire)
            if let next = nextCronDate(after: now, expr: expr) {
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
        // Reuse handleMissed's catch-up judgment: baseline on "today", fire when the point is reached
        handleMissed()
        scheduleNext()
    }

    // MARK: - Execute

    private func fireTask(_ task: TaskConfig) {
        DispatchQueue.global(qos: .utility).async { [task] in
            let result = TaskExecutor.execute(task.exec)

            if !result.success {
                let reason = result.error.isEmpty ? "exit code != 0" : result.error
                debugLog("[Task] \(task.name) failed:\(String(reason.prefix(2000)))")
                EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                    title: L10n.Notify.taskFailed(name: task.name), body: String(reason.prefix(200)),
                ))
            } else {
                debugLog("[Task] \(task.name) completed.")
                EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                    title: L10n.Notify.taskCompleted(name: task.name), body: "",
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
        current = current.addingTimeInterval(60) // Start searching from the next minute

        // Search at most 366 days
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
