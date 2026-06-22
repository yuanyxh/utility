import Cocoa

/// 全局键盘事件拦截 — 委托 PanelManager 从栈顶派发
final class KeyDispatcher {
    static let shared = KeyDispatcher()
    private var monitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            PanelManager.shared.dispatchKey(event) ? nil : event
        }
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
