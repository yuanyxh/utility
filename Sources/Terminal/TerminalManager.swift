import Cocoa

@MainActor
final class TerminalManager {
    static let shared = TerminalManager()

    private(set) var sessions: [TerminalSession] = []
    private(set) var selectedID: String?

    private let store = TerminalSessionStore()
    private var backend: TmuxBackend?
    private var windowController: TerminalWindowController?
    private var didRestore = false
    private var isShuttingDown = false
    private var didReportMissingTmux = false
    private var pathTimer: Timer?
    /// Some prompts emit the same notification twice; keep one banner per burst.
    private var lastNotification: (sessionID: String, at: Date)?

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
        let controller = ensureWindow()
        guard let window = controller.window else { return }
        if window.isVisible, window.isKeyWindow {
            controller.wantsVisible = false
            debugLog(
                "[Terminal] window hidden by hotkey responder=\(String(describing: window.firstResponder))",
            )
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    func showWindow() {
        let controller = ensureWindow()
        controller.wantsVisible = true
        controller.window?.makeKeyAndOrderFront(nil)
        // Lay out first so restored views start at the size they will keep;
        // a later resize makes screen shift the whole buffer.
        controller.window?.layoutIfNeeded()
        restoreIfNeeded()
        startPathPolling()
        // An empty panel has nothing to type into; open a session right away.
        if sessions.isEmpty {
            createSession()
        }
        controller.reload(sessions: sessions, selectedID: selectedID)
        if sessions.isEmpty, backend == nil, !TmuxBackend.isAvailable() {
            controller.showEmptyState(message: L10n.Terminal.tmuxMissingBody)
        }
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

        guard let backend = resolvedBackend() else {
            windowController?.showEmptyState(message: L10n.Terminal.tmuxMissingBody)
            reportMissingTmux()
            return
        }
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
        windowController?.reload(sessions: sessions, selectedID: id)
        windowController?.showTerminal(session.view)
    }

    func closeSession(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        backend?.kill(id: id)
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

        guard config.restoreSessions else { return }
        guard let backend = resolvedBackend() else { return }

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
                fontSize: config.fontSize,
                createdAt: item.createdAt,
            )
            wire(session)
            // Give the view its final size before the pty is created.
            session.view.frame = NSRect(origin: .zero, size: contentSize)
            do {
                try session.start(
                    launch: backend.launch(
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

    /// Keeps tmux sessions alive by only detaching their clients.
    func shutdown() {
        isShuttingDown = true
        persist()
        for session in sessions {
            session.terminate()
        }
    }

    // MARK: - Session events

    private func wire(_ session: TerminalSession) {
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

    /// `isKeyWindow` cannot be used here: the IME candidate window takes key
    /// status while the user types, which would mark visible output as unseen.
    private func isFocused(_ session: TerminalSession) -> Bool {
        guard NSApp.isActive, let window = windowController?.window, window.isVisible else {
            return false
        }
        return selectedID == session.id
    }

    /// Forward explicit OSC notifications as-is. Skip only the session the user
    /// is currently looking at; other sessions still notify.
    private func handleNotification(_ session: TerminalSession, title: String, body: String) {
        guard !isFocused(session) else {
            debugLog("[Terminal] notify suppressed focused=true title=\(title)")
            return
        }
        let now = Date()
        if let last = lastNotification, last.sessionID == session.id,
            now.timeIntervalSince(last.at) < 3
        {
            debugLog("[Terminal] notify deduplicated title=\(title) body=\(body)")
            return
        }
        lastNotification = (session.id, now)
        notify(
            title: title.isEmpty ? L10n.Terminal.notifyTitle : title,
            body: body.isEmpty ? L10n.Terminal.notifyBody(title: session.title) : body,
            sessionID: session.id,
        )
    }

    private func remove(_ session: TerminalSession) {
        // Detach on quit must not prune tmux metadata.
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

    /// tmux keeps the shell's OSC 7 to itself, so the pane path is polled instead.
    private func startPathPolling() {
        guard pathTimer == nil else { return }
        pathTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWorkingDirectories() }
        }
    }

    private func refreshWorkingDirectories() {
        guard let backend, windowController?.window?.isVisible == true else { return }
        let paths = backend.currentPaths()
        for session in sessions {
            guard let path = paths[session.id], path != session.cwd else { continue }
            session.cwd = path
            windowController?.reloadRow(session: session)
        }
    }

    private func resolvedBackend() -> TmuxBackend? {
        if let backend { return backend }
        guard let resolved = TmuxBackend.makeIfAvailable() else {
            debugLog("[Terminal] tmux unavailable")
            return nil
        }
        backend = resolved
        return resolved
    }

    private func reportMissingTmux() {
        guard !didReportMissingTmux else { return }
        didReportMissingTmux = true
        notify(title: L10n.Terminal.tmuxMissingTitle, body: L10n.Terminal.tmuxMissingBody)
    }

    private func persist() {
        store.save(
            sessions.map {
                StoredTerminalSession(
                    id: $0.id,
                    title: $0.title,
                    cwd: $0.cwd,
                    backend: TmuxBackend.storageName,
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
