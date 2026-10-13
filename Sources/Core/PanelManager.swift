import Cocoa

/// Global panel manager — the hub, the only place that calls a panel's showPanel/closePanel
/// Receives requestShow/requestClose/requestPaste events via pub/sub
public final class PanelManager {
    public static let shared = PanelManager()

    private var stack: [PanelProtocol] = []
    private var observers: [String: [NSObjectProtocol]] = [:]
    private let lock = NSLock()

    private init() {
        EventBus.shared.subscribe(PanelEvent.requestShow) { [weak self] payload in
            let dict = payload as? [String: Any]
            let panel = dict?["panel"] as? PanelProtocol ?? payload as? PanelProtocol
            guard let self, let panel else { return }
            onRequestShow(panel, context: dict)
        }
        EventBus.shared.subscribe(PanelEvent.requestClose) { [weak self] payload in
            guard let self, let panel = payload as? PanelProtocol else { return }
            onRequestClose(panel)
        }
        EventBus.shared.subscribe(PanelEvent.requestPaste) { [weak self] payload in
            guard let self, let panel = payload as? PanelProtocol else { return }
            onRequestPaste(panel)
        }
    }

    // MARK: - Request handlers

    private func onRequestShow(_ panel: PanelProtocol, context: [String: Any]?) {
        lock.lock()
        stack.removeAll { $0.panelID == panel.panelID }
        stack.append(panel)
        lock.unlock()

        if let window = panel.panelWindow {
            observe(window: window, for: panel.panelID)
        }
        panel.showPanel(context: context)
    }

    private func onRequestClose(_ panel: PanelProtocol) {
        remove(panel.panelID)
        panel.closePanel()
        hideIfEmpty()
    }

    private func onRequestPaste(_ panel: PanelProtocol) {
        lock.lock()
        let idx = stack.firstIndex(where: { $0.panelID == panel.panelID })
        let nextPanel: PanelProtocol? = (idx ?? 0) > 0 ? stack[(idx ?? 0) - 1] : nil
        lock.unlock()

        if nextPanel != nil {
            cgEventPaste()
        } else {
            schedulePaste(attempts: 9)
        }

        remove(panel.panelID)
        panel.closePanel()
        hideIfEmpty()
    }

    // MARK: - Internal

    private func remove(_ panelID: String) {
        unobserve(panelID)
        lock.lock()
        stack.removeAll { $0.panelID == panelID }
        lock.unlock()
    }

    private func hideIfEmpty() {
        lock.lock()
        defer { lock.unlock() }
        if stack.isEmpty {
            DispatchQueue.main.async {
                NSApplication.shared.hide(nil)
            }
        }
    }

    // MARK: - Window focus tracking

    private func observe(window: NSWindow, for panelID: String) {
        unobserve(panelID)
        let becomeKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main,
        ) { [weak self] _ in
            self?.lock.lock()
            if let i = self?.stack.firstIndex(where: { $0.panelID == panelID }) {
                let p = self?.stack.remove(at: i)
                if let p { self?.stack.append(p) }
            }
            self?.lock.unlock()
        }
        let resignKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                let keyWin = NSApplication.shared.keyWindow
                self.lock.lock()
                let ours = self.stack.contains { $0.panelWindow === keyWin }
                self.lock.unlock()
                if !ours {
                    self.lock.lock()
                    let closable = self.stack.filter(\.closesOnResignKey)
                    self.lock.unlock()
                    for panel in closable {
                        self.remove(panel.panelID)
                        panel.closePanel()
                    }
                    self.hideIfEmpty()
                }
            }
        }
        observers[panelID] = [becomeKey, resignKey]
    }

    private func unobserve(_ panelID: String) {
        for o in observers.removeValue(forKey: panelID) ?? [] {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: - KeyDispatcher

    func dispatchKey(_ event: NSEvent) -> Bool {
        lock.lock()
        let panels = stack.reversed().filter(\.isPanelVisible)
        lock.unlock()
        for panel in panels {
            if panel.handleKeyEvent(event) {
                return true
            }
        }
        return false
    }
}
