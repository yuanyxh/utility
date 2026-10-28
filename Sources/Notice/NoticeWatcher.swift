import AppKit
import Foundation

/// Delivers due notices from `notices.sqlite`; only the app process can post system notifications.
public final class NoticeWatcher {
    public static let shared = NoticeWatcher()

    private var timer: Timer?
    private var observingWake = false
    private let interval: TimeInterval = 300
    /// Anything older than this is summarized instead of replayed after a long sleep.
    private let replayWindow: TimeInterval = 24 * 3600

    private init() {}

    public func start() {
        guard timer == nil else { return }
        installWakeObserver()
        poll()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Timers do not fire while the system sleeps; poll immediately on wake instead of waiting a cycle.
    private func installWakeObserver() {
        guard !observingWake else { return }
        observingWake = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in
            self?.stop()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            self?.start()
        }
    }

    private func poll() {
        // Authorization resolves asynchronously on first launch; keep rows until it does.
        guard NotificationManager.shared.canPost else { return }
        do {
            let due = try NoticeStore.shared.due()
            guard !due.isEmpty else { return }
            let cutoff = Date().addingTimeInterval(-replayWindow)
            let fresh = due.filter { $0.dueAt >= cutoff }
            for record in fresh {
                EventBus.shared.publish(
                    AppEvent.notify,
                    payload: NotificationPayload(title: record.title, body: record.body),
                )
            }
            let missed = due.count - fresh.count
            if missed > 0 {
                EventBus.shared.publish(
                    AppEvent.notify,
                    payload: NotificationPayload(
                        title: L10n.Notify.noticeMissed,
                        body: L10n.Notify.noticeMissedBody(count: missed),
                    ),
                )
            }
            try NoticeStore.shared.remove(due.map(\.id))
            debugLog("[Notice] delivered \(fresh.count), missed \(missed)")
        } catch {
            debugLog("[Notice] poll failed: \(error)")
        }
    }
}
