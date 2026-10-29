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
    let view: LocalProcessTerminalView
    var isRunning = true

    /// Wall clock of the last PTY output burst and of the last burst seen while focused.
    private(set) var lastOutputAt: Date?
    /// Burst before `lastOutputAt`: an OSC notification arrives as output too,
    /// so the notification itself must not count as fresh activity.
    private(set) var previousOutputAt: Date?
    private(set) var lastSeenOutputAt: Date?

    var onOutput: ((TerminalSession) -> Void)?
    /// Fired for OSC 9 / 777 sent by the program in the terminal.
    var onNotification: ((TerminalSession, String, String) -> Void)?
    var onExit: ((TerminalSession) -> Void)?
    var onTitleChange: ((TerminalSession) -> Void)?

    /// Throttles output timestamps to one main-thread hop per burst.
    private static let activityWindow: TimeInterval = 1.0

    private let activity = TerminalActivityFlag()
    private var activityWork: DispatchWorkItem?
    private var oscObservation: TerminalOscObservation?

    init(
        id: String, title: String, cwd: String, shell: String,
        fontSize: Double, createdAt: Date = Date(),
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.cwd = cwd
        self.shell = shell
        view = TerminalDropView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 520),
        )
        super.init()

        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.nativeBackgroundColor = VSTheme.windowBackground
        view.nativeForegroundColor = VSTheme.terminalForeground
        view.caretColor = VSTheme.terminalCaret
        view.selectedTextBackgroundColor = VSTheme.terminalSelection
        // Keep mouse reporting on: Claude's fullscreen TUI only scrolls when
        // the terminal forwards wheel events. Shift+drag still selects locally.
        view.processDelegate = self
        let activity = activity
        view.setProcessOutputHandler { [weak self, activity] in
            guard activity.take() else { return }
            DispatchQueue.main.async {
                self?.noteOutput()
            }
        }
        // Without mouse reporting SwiftTerm turns the wheel into ↑/↓ in the
        // alternate buffer, which prompts read as input history. Programs that
        // want wheel scrolling (Claude fullscreen) enable mouse reporting and
        // take the `.mouse` route instead.
        view.feed(text: "\u{1B}[?1007l")
        // tmux forwards OSC notifications to the attached client, so read them
        // straight from the parser.
        oscObservation = view.observeOscEvents { [weak self] event in
            guard event.code == 777 || event.code == 9 else { return }
            let text = String(decoding: event.payload, as: UTF8.self)
            guard let message = TerminalNotificationParser.parse(
                payload: "\(event.code);\(text)",
            ) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.onNotification?(self, message.title, message.body)
                }
            }
        }
    }

    /// Records one output burst; `seen` means the user was watching this session.
    func markOutput(seen: Bool) {
        let now = Date()
        previousOutputAt = lastOutputAt
        lastOutputAt = now
        if seen { lastSeenOutputAt = now }
    }

    /// True when the output before the notification burst was already watched.
    var hasSeenLatestOutput: Bool {
        guard let lastSeenOutputAt else { return false }
        return lastSeenOutputAt >= (previousOutputAt ?? lastOutputAt ?? lastSeenOutputAt)
    }

    func start(launch: TerminalLaunch) throws {
        try launchProcess(launch)
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

    func terminate() {
        activityWork?.cancel()
        isRunning = false
        view.process.terminate()
    }

    /// Called on the main thread at most once per activity window.
    private func noteOutput() {
        onOutput?(self)
        activityWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.activity.reset() }
        activityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activityWindow, execute: work)
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
        isRunning = false
        onExit?(self)
    }

    func processFailedToStart(source _: TerminalView, error: LocalProcessError) {
        debugLog("[Terminal] launch failed: \(error)")
        guard isRunning else { return }
        isRunning = false
        onExit?(self)
    }
}
