import Foundation

struct TerminalLaunch {
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let environment: [String]
}

enum TmuxBackendError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        }
    }
}

// MARK: - Shell helpers

enum TerminalShell {
    static let sessionPrefix = "utility-term-"
    /// GUI PATH is minimal; include Homebrew for tmux/shell tools.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func resolvedShell(configured: String) -> String {
        if !configured.isEmpty { return NSString(string: configured).expandingTildeInPath }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Claude Code only emits OSC notifications to terminals it recognises;
        // "ghostty" selects OSC 777, which tmux forwards to the client.
        env["TERM_PROGRAM"] = "ghostty"
        // GUI launches have no locale; without UTF-8 the shell prints <00xx>.
        if env["LANG"] == nil, env["LC_ALL"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        if env["LC_CTYPE"] == nil, env["LC_ALL"] == nil {
            env["LC_CTYPE"] = env["LANG"] ?? "en_US.UTF-8"
        }
        return env
    }

    static func environmentArray() -> [String] {
        environment().map { "\($0.key)=\($0.value)" }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    static func run(
        _ executable: String, _ arguments: [String],
        environment: [String: String] = environment(),
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Backend

/// tmux on a private socket; survives app quits and offers truecolor + mouse.
final class TmuxBackend: Sendable {
    /// Written into `terminal-sessions.json`; old builds require the key.
    static let storageName = "tmux"
    private let socket = "utility"

    static func isAvailable() -> Bool {
        TerminalShell.run("/usr/bin/env", ["tmux", "-V"]).status == 0
    }

    static func makeIfAvailable() -> TmuxBackend? {
        isAvailable() ? TmuxBackend() : nil
    }

    private func name(_ id: String) -> String {
        "\(TerminalShell.sessionPrefix)\(id)"
    }

    private func tmux(_ arguments: [String]) -> (status: Int32, output: String) {
        TerminalShell.run("/usr/bin/env", ["tmux", "-L", socket] + arguments)
    }

    func prepare(
        id: String, cwd: String, shell: String,
        initialCommand: String? = nil, environment: [String: String] = [:],
    ) throws {
        if liveIDs().contains(id) { return }
        // tmux rewrites TERM_PROGRAM to "tmux" inside the pane; Claude only
        // emits OSC 777 for known terminals, so the value must be restored.
        var paneCommand = ["env", "TERM_PROGRAM=ghostty"]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            paneCommand.append("\(key)=\(value)")
        }
        paneCommand.append(shell)
        if let initialCommand, !initialCommand.isEmpty {
            paneCommand.append("-lc")
            paneCommand.append(initialCommand)
        }
        let result = TerminalShell.run(
            "/usr/bin/env",
            [
                "tmux", "-L", socket, "-f", "/dev/null", "new-session",
                "-d", "-s", name(id), "-c", cwd,
            ] + paneCommand,
        )
        guard result.status == 0 else {
            throw TmuxBackendError.commandFailed(result.output)
        }
        for (option, value) in [
            ("status", "off"),
            ("default-terminal", "xterm-256color"),
            ("history-limit", "20000"),
            // Wheel over a pane without mouse reporting enters copy-mode.
            ("mouse", "on"),
            // Prompt TUIs may emit OSC through DCS passthrough.
            ("allow-passthrough", "on"),
        ] {
            _ = tmux(["set-option", "-g", option, value])
        }
        _ = tmux(["set-option", "-g", "terminal-features", "xterm-256color:RGB"])
    }

    /// Mirrors pane output to a log file for sessions without an attached
    /// client: tmux only forwards OSC 777 to attached clients, so unmounted
    /// workspaces would otherwise drop every notification.
    static let notifyLogDir = AppPaths.cacheDir.appendingPathComponent(
        "terminal-notify", isDirectory: true,
    )

    func notificationLogPath(id: String) -> String {
        "\(Self.notifyLogDir.path)/\(id).log"
    }

    @discardableResult
    func startNotificationTap(id: String) -> Bool {
        try? FileManager.default.createDirectory(
            at: Self.notifyLogDir, withIntermediateDirectories: true,
        )
        let command = "cat >> \(TerminalShell.quote(notificationLogPath(id: id)))"
        let result = tmux(["pipe-pane", "-O", "-t", name(id), command])
        guard result.status == 0 else {
            debugLog("[Terminal] pipe-pane failed id=\(id): \(result.output)")
            return false
        }
        return true
    }

    func stopNotificationTap(id: String) {
        _ = tmux(["pipe-pane", "-t", name(id)])
    }

    /// tmux 3.8 forwards OSC 777 to the client, so attached sessions use the
    /// SwiftTerm observer; the pipe-pane tap covers only detached sessions.
    func launch(id: String, cwd _: String, shell _: String) -> TerminalLaunch {
        TerminalLaunch(
            executable: "/usr/bin/env",
            arguments: ["tmux", "-L", socket, "attach-session", "-d", "-t", name(id)],
            workingDirectory: nil,
            environment: TerminalShell.environmentArray(),
        )
    }

    func kill(id: String) {
        let result = tmux(["kill-session", "-t", name(id)])
        guard result.status != 0 else { return }
        guard !result.output.contains("can't find session"),
            !result.output.contains("no server running")
        else { return }
        debugLog("[Terminal] kill-session failed id=\(id): \(result.output)")
    }

    /// tmux consumes the shell's OSC 7 itself, so pane paths are the only source.
    func currentPaths() -> [String: String] {
        let result = tmux(["list-panes", "-a", "-F", "#{session_name}\t#{pane_current_path}"])
        guard result.status == 0 else { return [:] }
        var paths: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0].hasPrefix(TerminalShell.sessionPrefix) else {
                continue
            }
            let id = String(parts[0].dropFirst(TerminalShell.sessionPrefix.count))
            paths[id] = String(parts[1])
        }
        return paths
    }

    /// Foreground process per session; tells a running agent from a plain shell.
    func foregroundCommands() -> [String: String] {
        let result = tmux(["list-panes", "-a", "-F", "#{session_name}\t#{pane_current_command}"])
        guard result.status == 0 else { return [:] }
        var commands: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            guard name.hasPrefix(TerminalShell.sessionPrefix) else { continue }
            let id = String(name.dropFirst(TerminalShell.sessionPrefix.count))
            if commands[id] == nil { commands[id] = String(parts[1]) }
        }
        return commands
    }

    /// Types a command into an existing session; the extra Enter submits it.
    /// Agent TUIs absorb the newline of a send-keys batch as pasted text.
    @discardableResult
    func sendCommand(_ command: String, to id: String) -> Bool {
        let text = tmux(["send-keys", "-t", name(id), command])
        guard text.status == 0 else {
            debugLog("[Terminal] send-keys failed id=\(id): \(text.output)")
            return false
        }
        for _ in 0..<2 {
            usleep(150_000)
            let enter = tmux(["send-keys", "-t", name(id), "Enter"])
            guard enter.status == 0 else {
                debugLog("[Terminal] submit failed id=\(id): \(enter.output)")
                return false
            }
        }
        return true
    }

    func liveIDs() -> Set<String> {
        let result = tmux(["list-sessions", "-F", "#{session_name}"])
        guard result.status == 0 else { return [] }
        return Set(
            result.output.split(separator: "\n").compactMap { line in
                let name = String(line)
                guard name.hasPrefix(TerminalShell.sessionPrefix) else { return nil }
                return String(name.dropFirst(TerminalShell.sessionPrefix.count))
            })
    }
}
