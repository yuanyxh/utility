import Cocoa

@MainActor
final class TerminalManager {
    static let shared = TerminalManager()

    private(set) var sessions: [TerminalSession] = []
    private(set) var selectedID: String?

    private let store = TerminalSessionStore()
    private var backend: TerminalBackend?
    private var windowController: TerminalWindowController?
    private var didRestore = false
    private var isShuttingDown = false

    private var config: TerminalConfig {
        ConfigManager.shared.config.terminal
    }

    private init() {
        EventBus.shared.subscribe(AppEvent.terminalOpenSession) { [weak self] payload in
            guard let id = payload as? String else { return }
            Task { @MainActor in self?.reveal(sessionID: id) }
        }
    }

    // MARK: - Window

    func toggleWindow() {
        guard let window = ensureWindow().window else { return }
        if window.isVisible, window.isKeyWindow {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    func showWindow() {
        let controller = ensureWindow()
        controller.window?.makeKeyAndOrderFront(nil)
        // Lay out first so restored views start at the size they will keep;
        // a later resize makes screen shift the whole buffer.
        controller.window?.layoutIfNeeded()
        restoreIfNeeded()
        controller.reload(sessions: sessions, selectedID: selectedID)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let selectedID, let session = sessions.first(where: { $0.id == selectedID }) {
            controller.showTerminal(session.view)
            controller.focusTerminal(sessionID: selectedID)
        }
    }

    private func ensureWindow() -> TerminalWindowController {
        if let windowController { return windowController }
        let controller = TerminalWindowController()
        controller.onNew = { [weak self] in self?.createSession() }
        controller.onSelect = { [weak self] id in self?.selectSession(id: id) }
        controller.onClose = { [weak self] id in self?.closeSession(id: id) }
        controller.onActivate = { [weak self] in self?.clearSelectedUnread() }
        windowController = controller
        return controller
    }

    // MARK: - Sessions

    func createSession() {
        let cfg = config
        guard sessions.count < cfg.maxSessions else {
            notify(
                title: L10n.Terminal.limitTitle,
                body: L10n.Terminal.limitBody(count: cfg.maxSessions),
            )
            return
        }

        let backend = resolvedBackend()
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
            .lowercased()
        let cwd = TerminalShell.resolvedWorkingDirectory(configured: cfg.workingDirectory)
        let shell = TerminalShell.resolvedShell(configured: cfg.shell)

        do {
            try backend.prepare(id: id, cwd: cwd, shell: shell)
        } catch {
            notify(
                title: L10n.Terminal.startFailed,
                body: error.localizedDescription,
            )
            return
        }

        let title = (cwd as NSString).lastPathComponent
        let session = TerminalSession(
            id: id,
            title: title.isEmpty ? L10n.Terminal.title : title,
            cwd: cwd,
            shell: shell,
            backend: backend,
            fontSize: cfg.fontSize,
        )
        wire(session)

        sessions.append(session)
        selectedID = session.id
        persist()
        windowController?.reload(sessions: sessions, selectedID: selectedID)
        windowController?.showTerminal(session.view)
        windowController?.window?.layoutIfNeeded()

        do {
            try session.start(launch: backend.launch(id: id, cwd: cwd, shell: shell))
        } catch {
            backend.kill(id: id)
            remove(session)
            notify(
                title: L10n.Terminal.startFailed,
                body: error.localizedDescription,
            )
        }
    }

    func selectSession(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        selectedID = id
        session.unread = 0
        windowController?.reload(sessions: sessions, selectedID: id)
        windowController?.showTerminal(session.view)
    }

    func closeSession(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.backend.kill(id: id)
        session.terminate()
        remove(session)
    }

    private func reveal(sessionID: String) {
        showWindow()
        selectSession(id: sessionID)
    }

    // MARK: - Restore / shutdown

    private func restoreIfNeeded() {
        guard !didRestore else { return }
        didRestore = true

        let backend = resolvedBackend()
        guard config.restoreSessions, backend.kind != .local else {
            if backend.kind == .local { store.save([]) }
            return
        }

        let live = backend.liveIDs()
        let stored = store.load()
        let contentSize: NSSize = {
            let size = windowController?.terminalContentSize ?? .zero
            guard size.width > 100, size.height > 100 else {
                return NSSize(width: 760, height: 520)
            }
            return size
        }()
        for item in stored where live.contains(item.id) {
            let session = TerminalSession(
                id: item.id,
                title: item.title,
                cwd: item.cwd,
                shell: TerminalShell.resolvedShell(configured: config.shell),
                backend: backend,
                fontSize: config.fontSize,
                createdAt: item.createdAt,
            )
            wire(session)
            // Give the view its final size before the pty is created.
            session.view.frame = NSRect(origin: .zero, size: contentSize)
            backend.prepareAttach(id: item.id)
            do {
                try session.start(launch: backend.launch(
                    id: item.id, cwd: item.cwd, shell: session.shell,
                ))
                sessions.append(session)
            } catch {
                debugLog("[Terminal] restore failed id=\(item.id): \(error)")
            }
        }
        selectedID = sessions.first?.id
        persist()
    }

    /// Keeps screen/tmux sessions alive by only detaching their clients.
    func shutdown() {
        isShuttingDown = true
        persist()
        for session in sessions {
            session.terminate()
        }
        if resolvedBackend().kind == .local {
            store.save([])
        }
    }

    // MARK: - Session events

    private func wire(_ session: TerminalSession) {
        session.onOutput = { [weak self] session in
            self?.handleOutput(session)
        }
        session.onNotification = { [weak self] session, title, body in
            self?.handleNotification(session, title: title, body: body)
        }
        session.onExit = { [weak self] session in
            self?.remove(session)
        }
        session.onTitleChange = { [weak self] session in
            self?.windowController?.reloadRow(session: session)
        }
    }

    private func clearSelectedUnread() {
        guard let selectedID,
              let session = sessions.first(where: { $0.id == selectedID }),
              session.unread > 0 else { return }
        session.unread = 0
        windowController?.reloadRow(session: session)
    }

    private func isFocused(_ session: TerminalSession) -> Bool {
        let window = windowController?.window
        return window?.isVisible == true
            && window?.isKeyWindow == true
            && selectedID == session.id
    }

    /// Output only raises the dot; counts come from explicit notifications.
    private func handleOutput(_ session: TerminalSession) {
        guard !isFocused(session), session.unread == 0 else { return }
        session.unread = 1
        windowController?.reloadRow(session: session)
    }

    /// Explicit OSC notifications: no guessing from output patterns.
    private func handleNotification(_ session: TerminalSession, title: String, body: String) {
        guard !isFocused(session) else { return }
        session.unread = min(session.unread + 1, 99)
        windowController?.reloadRow(session: session)
        notify(
            title: title.isEmpty ? L10n.Terminal.notifyTitle : title,
            body: body.isEmpty ? L10n.Terminal.notifyBody(title: session.title) : body,
            sessionID: session.id,
        )
    }

    private func remove(_ session: TerminalSession) {
        // Detach on quit must not prune screen/tmux metadata.
        guard !isShuttingDown else { return }
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        sessions.removeAll { $0.id == session.id }
        session.view.removeFromSuperview()
        if selectedID == session.id {
            selectedID = sessions.first?.id
        }
        persist()
        windowController?.reload(sessions: sessions, selectedID: selectedID)
        if let selectedID,
           let next = sessions.first(where: { $0.id == selectedID })
        {
            windowController?.showTerminal(next.view)
        } else {
            windowController?.showEmptyState()
        }
    }

    // MARK: - Helpers

    private func resolvedBackend() -> TerminalBackend {
        if let backend { return backend }
        let resolved = TerminalBackends.make(preference: config.backend)
        debugLog("[Terminal] backend=\(resolved.kind.rawValue)")
        backend = resolved
        return resolved
    }

    private func persist() {
        store.save(sessions.map {
            StoredTerminalSession(
                id: $0.id,
                title: $0.title,
                cwd: $0.cwd,
                backend: $0.backend.kind.rawValue,
                createdAt: $0.createdAt,
            )
        })
    }

    private func notify(title: String, body: String, sessionID: String? = nil) {
        EventBus.shared.publish(
            AppEvent.notify,
            payload: NotificationPayload(title: title, body: body, sessionID: sessionID),
        )
    }
}
