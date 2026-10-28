import Foundation

enum TerminalBackendKind: String {
    case tmux, screen, local
}

struct TerminalLaunch {
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let environment: [String]
    let createsSession: Bool
}

/// Backends are stateless apart from their kind, so they cross queues safely.
protocol TerminalBackend: AnyObject, Sendable {
    var kind: TerminalBackendKind { get }
    func prepare(id: String, cwd: String, shell: String) throws
    func launch(id: String, cwd: String, shell: String) -> TerminalLaunch
    func kill(id: String)
    func liveIDs() -> Set<String>
    /// Fixup for sessions created by an earlier app run; call while detached.
    func prepareAttach(id: String)
    /// Whether a client is attached; only screen can report this reliably.
    func isAttached(id: String) -> Bool
    /// Starts raw-output capture for OSC notifications; returns the log path.
    func startNotificationLog(id: String) -> String?
    /// Stops the capture; only safe while a client is attached.
    func stopNotificationLog(id: String)
}

extension TerminalBackend {
    func prepareAttach(id _: String) {}
    func isAttached(id _: String) -> Bool {
        true
    }

    func startNotificationLog(id _: String) -> String? {
        nil
    }

    func stopNotificationLog(id _: String) {}
}

enum TerminalBackendError: LocalizedError {
    case unavailable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(tool): "\(tool) is not available"
        case let .commandFailed(message): message
        }
    }
}

// MARK: - Shell helpers

enum TerminalShell {
    static let screenPath = "/usr/bin/screen"
    static let sessionPrefix = "utility-term-"
    /// GUI PATH is minimal; include Homebrew for tmux/shell tools.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static var homeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func resolvedShell(configured: String) -> String {
        if !configured.isEmpty { return NSString(string: configured).expandingTildeInPath }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    static func resolvedWorkingDirectory(configured: String) -> String {
        let raw = configured.isEmpty ? homeDirectory : NSString(string: configured).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raw, isDirectory: &isDirectory),
              isDirectory.boolValue else { return homeDirectory }
        return raw
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Claude Code only emits OSC notifications to terminals it recognises;
        // "ghostty" selects OSC 777, which the log tap below can parse.
        env["TERM_PROGRAM"] = "ghostty"
        // GUI launches have no locale; without UTF-8 screen shows <00xx>.
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

// MARK: - Backends

/// tmux on a private socket; survives app quits and offers truecolor + mouse.
final class TmuxBackend: TerminalBackend {
    let kind: TerminalBackendKind = .tmux
    private let socket = "utility"

    static func isAvailable() -> Bool {
        TerminalShell.run("/usr/bin/env", ["tmux", "-V"]).status == 0
    }

    private func name(_ id: String) -> String {
        "\(TerminalShell.sessionPrefix)\(id)"
    }

    private func tmux(_ arguments: [String]) -> (status: Int32, output: String) {
        TerminalShell.run("/usr/bin/env", ["tmux", "-L", socket] + arguments)
    }

    func prepare(id: String, cwd: String, shell: String) throws {
        if liveIDs().contains(id) { return }
        let result = TerminalShell.run(
            "/usr/bin/env",
            [
                "tmux", "-L", socket, "-f", "/dev/null", "new-session",
                "-d", "-s", name(id), "-c", cwd, shell,
            ],
        )
        guard result.status == 0 else {
            throw TerminalBackendError.commandFailed(result.output)
        }
        _ = tmux(["set-option", "-g", "status", "off"])
        _ = tmux(["set-option", "-g", "default-terminal", "xterm-256color"])
        _ = tmux(["set-option", "-g", "history-limit", "20000"])
    }

    func launch(id: String, cwd _: String, shell _: String) -> TerminalLaunch {
        TerminalLaunch(
            executable: "/usr/bin/env",
            arguments: ["tmux", "-L", socket, "attach-session", "-d", "-t", name(id)],
            workingDirectory: nil,
            environment: TerminalShell.environmentArray(),
            createsSession: false,
        )
    }

    func kill(id: String) {
        _ = tmux(["kill-session", "-t", name(id)])
    }

    func liveIDs() -> Set<String> {
        let result = tmux(["list-sessions", "-F", "#{session_name}"])
        guard result.status == 0 else { return [] }
        return Set(result.output.split(separator: "\n").compactMap { line in
            let name = String(line)
            guard name.hasPrefix(TerminalShell.sessionPrefix) else { return nil }
            return String(name.dropFirst(TerminalShell.sessionPrefix.count))
        })
    }
}

/// System screen: zero-install persistence; 256 colors, no truecolor.
final class ScreenBackend: TerminalBackend {
    let kind: TerminalBackendKind = .screen

    static func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: TerminalShell.screenPath)
    }

    private func name(_ id: String) -> String {
        "\(TerminalShell.sessionPrefix)\(id)"
    }

    func prepare(id _: String, cwd _: String, shell _: String) throws {}

    func launch(id: String, cwd: String, shell: String) -> TerminalLaunch {
        // Create inside this PTY so the window matches the view; detached
        // `-dmS` sessions start at 80x24 and render centered on attach.
        let exists = liveIDs().contains(id)
        var environment = TerminalShell.environment()
        environment["SHELL"] = shell
        // screen 4.00 is 256-color only; truecolor hints yield bad SGR.
        environment.removeValue(forKey: "COLORTERM")
        let term = "screen-256color"
        return TerminalLaunch(
            executable: TerminalShell.screenPath,
            arguments: exists
                ? ["-U", "-T", term, "-A", "-D", "-r", name(id)]
                : ["-U", "-T", term, "-S", name(id)],
            workingDirectory: exists ? nil : cwd,
            environment: environment.map { "\($0.key)=\($0.value)" },
            createsSession: !exists,
        )
    }

    func kill(id: String) {
        _ = TerminalShell.run(TerminalShell.screenPath, ["-S", name(id), "-X", "quit"])
    }

    /// Must run only while the session is detached: sending it right after a
    /// client exits wedges the server, and new clients then hang unattached.
    func prepareAttach(id: String) {
        _ = TerminalShell.run(
            TerminalShell.screenPath, ["-S", name(id), "-X", "utf8", "on"],
        )
    }

    /// Screen drops OSC before the client sees it, so notifications are read
    /// back from the raw log; only call once a client is attached.
    func startNotificationLog(id: String) -> String? {
        let directory = AppPaths.cacheDir.appendingPathComponent("term-logs", isDirectory: true)
        // The log holds raw terminal output, including anything printed or pasted.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        // A directory created by an earlier run may still be group-readable.
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path,
        )
        let path = directory.appendingPathComponent("\(name(id)).log").path
        let commands = [
            ["logfile", path],
            ["logfile", "flush", "1"],
            ["log", "on"],
        ]
        for command in commands {
            let result = TerminalShell.run(
                TerminalShell.screenPath, ["-S", name(id), "-X"] + command,
            )
            guard result.status == 0 else {
                debugLog("[Terminal] notification log refused: \(command.joined(separator: " "))")
                return nil
            }
        }
        return path
    }

    /// Leaving `log on` behind keeps writing after the app quits.
    func stopNotificationLog(id: String) {
        _ = TerminalShell.run(
            TerminalShell.screenPath, ["-S", name(id), "-X", "log", "off"],
        )
    }

    func isAttached(id: String) -> Bool {
        let result = TerminalShell.run(TerminalShell.screenPath, ["-ls"])
        let tag = ".\(name(id))"
        return result.output.split(separator: "\n").contains { line in
            line.contains(tag) && line.contains("(Attached)")
        }
    }

    func liveIDs() -> Set<String> {
        let result = TerminalShell.run(TerminalShell.screenPath, ["-ls"])
        let pattern = TerminalShell.sessionPrefix + "([0-9A-Za-z]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(result.output.startIndex..., in: result.output)
        let ids = regex.matches(in: result.output, range: range).compactMap {
            Range($0.range(at: 1), in: result.output).map { String(result.output[$0]) }
        }
        return Set(ids)
    }
}

/// No host process: sessions end when the app quits.
final class LocalBackend: TerminalBackend {
    let kind: TerminalBackendKind = .local

    func prepare(id _: String, cwd _: String, shell _: String) throws {}

    func launch(id _: String, cwd: String, shell: String) -> TerminalLaunch {
        let absolute = shell.hasPrefix("/")
        return TerminalLaunch(
            executable: absolute ? shell : "/usr/bin/env",
            arguments: absolute ? [] : [shell],
            workingDirectory: cwd,
            environment: TerminalShell.environmentArray(),
            createsSession: false,
        )
    }

    func kill(id _: String) {}

    func liveIDs() -> Set<String> {
        []
    }
}

enum TerminalBackends {
    static func make(preference: String) -> TerminalBackend {
        switch preference.lowercased() {
        case "tmux":
            if TmuxBackend.isAvailable() { return TmuxBackend() }
            debugLog("[Terminal] tmux unavailable, falling back")
            return ScreenBackend.isAvailable() ? ScreenBackend() : LocalBackend()
        case "screen":
            return ScreenBackend.isAvailable() ? ScreenBackend() : LocalBackend()
        case "local":
            return LocalBackend()
        default:
            if TmuxBackend.isAvailable() { return TmuxBackend() }
            if ScreenBackend.isAvailable() { return ScreenBackend() }
            return LocalBackend()
        }
    }
}
