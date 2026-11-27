import Foundation

/// A workspace card is ready only when its agent is the pane's foreground process.
enum MeshAgentState {
    private static let shells: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "login",
    ]

    /// First token of a launch command: `/opt/homebrew/bin/claude --continue` -> `claude`.
    static func executableName(in command: String) -> String? {
        guard let first = command.split(separator: " ").first else { return nil }
        let name = (String(first) as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func isShell(_ foreground: String?) -> Bool {
        guard let foreground else { return false }
        return shells.contains(foreground)
    }

    static func isRunning(
        startCommand: String?,
        mainSessionID: String?,
        live: Set<String>,
        foreground: [String: String],
    ) -> Bool {
        guard let mainSessionID, live.contains(mainSessionID),
            let startCommand, let expected = executableName(in: startCommand),
            let current = foreground[mainSessionID]
        else { return false }
        return current == expected
    }
}
