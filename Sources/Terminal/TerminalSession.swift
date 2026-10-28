import Cocoa
import SwiftTerm

/// Coalesces high-frequency PTY output into one main-thread callback per burst.
private final class TerminalActivityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !pending else { return false }
        pending = true
        return true
    }

    func reset() {
        lock.lock()
        pending = false
        lock.unlock()
    }
}

@MainActor
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let id: String
    let createdAt: Date
    var title: String
    var cwd: String
    let shell: String
    let backend: TerminalBackend
    let view: LocalProcessTerminalView
    var unread = 0
    var isRunning = true

    var onOutput: ((TerminalSession) -> Void)?
    /// Fired for OSC 9 / 777 sent by the program in the terminal.
    var onNotification: ((TerminalSession, String, String) -> Void)?
    var onExit: ((TerminalSession) -> Void)?
    var onTitleChange: ((TerminalSession) -> Void)?

    /// Minimum spacing between unread bumps while output keeps streaming.
    private static let activityWindow: TimeInterval = 1.0

    private let activity = TerminalActivityFlag()
    private var activityWork: DispatchWorkItem?
    private var notificationTap: TerminalNotificationTap?
    private var isStartingTap = false
    private var isHandingOff = false
    private var isReattaching = false
    private var ignoredTerminations = 0
    private var attachRetries = 0
    private var attachCheckWork: DispatchWorkItem?

    init(
        id: String, title: String, cwd: String, shell: String,
        backend: TerminalBackend, fontSize: Double, createdAt: Date = Date(),
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.cwd = cwd
        self.shell = shell
        self.backend = backend
        view = TerminalDropView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 520),
        )
        super.init()

        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.nativeBackgroundColor = VSTheme.windowBackground
        view.nativeForegroundColor = VSTheme.terminalForeground
        view.caretColor = VSTheme.terminalCaret
        view.selectedTextBackgroundColor = VSTheme.terminalSelection
        view.processDelegate = self
        let activity = activity
        view.setProcessOutputHandler { [weak self, activity] in
            guard activity.take() else { return }
            DispatchQueue.main.async {
                self?.markOutput()
            }
        }
    }

    func start(launch: TerminalLaunch) throws {
        try launchProcess(launch)
        if launch.createsSession {
            scheduleClientHandoff()
        } else {
            scheduleAttachCheck()
        }
    }

    private func launchProcess(_ launch: TerminalLaunch) throws {
        let result = view.process.startProcessChecked(
            executable: launch.executable,
            args: launch.arguments,
            environment: launch.environment,
            currentDirectory: launch.workingDirectory,
        )
        if case let .failure(error) = result {
            throw error
        }
    }

    /// Exit the creating screen client so its server reparents to launchd;
    /// app-owned servers lose local-network access (empty arp table).
    private func scheduleClientHandoff() {
        isHandingOff = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, isRunning, isHandingOff else { return }
            view.process.terminate()
        }
    }

    private func reattach(attempt: Int = 0) {
        guard isRunning else { return }
        if !backend.liveIDs().contains(id), attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.reattach(attempt: attempt + 1)
            }
            return
        }
        isReattaching = true
        do {
            try launchProcess(backend.launch(id: id, cwd: cwd, shell: shell))
            isReattaching = false
            scheduleAttachCheck()
        } catch {
            guard attempt < 10 else {
                isReattaching = false
                debugLog("[Terminal] reattach failed: \(error)")
                backend.kill(id: id)
                isRunning = false
                onExit?(self)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.reattach(attempt: attempt + 1)
            }
        }
    }

    /// A screen client can hang before attaching; drop it and attach again.
    private func scheduleAttachCheck() {
        guard backend.kind != .local else { return }
        attachCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.verifyAttached() }
        attachCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func verifyAttached() {
        guard isRunning, !isHandingOff, backend.liveIDs().contains(id) else { return }
        if backend.isAttached(id: id) {
            startNotificationTap()
            return
        }
        guard attachRetries < 2, view.process.running else { return }
        attachRetries += 1
        debugLog("[Terminal] attach stalled, reattaching id=\(id)")
        // The stalled client must not be reported as a session exit.
        ignoredTerminations += 1
        view.process.terminate()
        relaunchWhenIdle(attempt: 0)
    }

    private func relaunchWhenIdle(attempt: Int) {
        guard isRunning else { return }
        guard view.process.running else {
            reattach()
            return
        }
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.relaunchWhenIdle(attempt: attempt + 1)
        }
    }

    func terminate() {
        attachCheckWork?.cancel()
        activityWork?.cancel()
        // Still attached here, so `-X log off` lands in the safe window.
        backend.stopNotificationLog(id: id)
        notificationTap?.stop()
        notificationTap = nil
        isRunning = false
        isHandingOff = false
        isReattaching = false
        view.process.terminate()
    }

    /// Screen hides OSC from the client; tail its raw log instead.
    private func startNotificationTap() {
        guard notificationTap == nil, !isStartingTap else { return }
        isStartingTap = true
        let backend = backend
        let id = id
        // Several screen round-trips: never run them on the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let path = backend.startNotificationLog(id: id)
            // `-X` sent as a client dies can wedge the server; verify after.
            let attached = path == nil || backend.isAttached(id: id)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStartingTap = false
                guard self.isRunning, self.notificationTap == nil else { return }
                guard let path else { return }
                guard attached else {
                    self.scheduleAttachCheck()
                    return
                }
                let tap = TerminalNotificationTap(path: path)
                tap.onNotification = { [weak self] title, body in
                    DispatchQueue.main.async {
                        guard let self, self.isRunning else { return }
                        self.onNotification?(self, title, body)
                    }
                }
                tap.start()
                self.notificationTap = tap
            }
        }
    }

    /// Called on the main thread at most once per activity window.
    private func markOutput() {
        onOutput?(self)
        activityWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.activity.reset() }
        activityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activityWindow, execute: work)
    }

    deinit {
        notificationTap?.stop()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source _: LocalProcessTerminalView, newCols _: Int, newRows _: Int) {}

    func setTerminalTitle(source _: LocalProcessTerminalView, title: String) {
        guard !title.isEmpty, title != self.title else { return }
        self.title = title
        onTitleChange?(self)
    }

    func hostCurrentDirectoryUpdate(source _: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        cwd = directory
    }

    func processTerminated(source _: TerminalView, exitCode _: Int32?) {
        guard isRunning else { return }
        if isHandingOff {
            isHandingOff = false
            reattach()
            return
        }
        if ignoredTerminations > 0 {
            ignoredTerminations -= 1
            return
        }
        guard !isReattaching else { return }
        isRunning = false
        onExit?(self)
    }

    func processFailedToStart(source _: TerminalView, error: LocalProcessError) {
        debugLog("[Terminal] launch failed: \(error)")
        guard !isReattaching else { return }
        isRunning = false
        onExit?(self)
    }
}
