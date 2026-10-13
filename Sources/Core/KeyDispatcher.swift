import Cocoa

/// Global keyboard event interception — delegates to PanelManager to dispatch from the top of the stack
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
