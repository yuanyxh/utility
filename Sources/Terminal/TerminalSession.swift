import Cocoa
import SwiftTerm

@MainActor
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let id: String
    let createdAt: Date
    var title: String
    var cwd: String
    let shell: String
    let view: LocalProcessTerminalView
    var isRunning = true

    /// Fired for OSC 9 / 777 sent by the program in the terminal.
    var onNotification: ((TerminalSession, String, String) -> Void)?
    var onExit: ((TerminalSession) -> Void)?
    var onTitleChange: ((TerminalSession) -> Void)?

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
            guard
                let message = TerminalNotificationParser.parse(
                    payload: "\(event.code);\(text)",
                )
            else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.onNotification?(self, message.title, message.body)
                }
            }
        }
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
        if case .failure(let error) = result {
            throw error
        }
    }

    func terminate() {
        isRunning = false
        view.process.terminate()
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
