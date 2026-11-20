import Foundation

/// Read-only git access for the workspace status bar.
struct GitService {
    let root: URL

    private static let gitPath = "/usr/bin/git"

    /// Current branch name; detached HEAD falls back to the short commit hash.
    func branch() async -> String? {
        guard
            let result = try? await ProcessRunner.run(
                executable: Self.gitPath,
                arguments: ["branch", "--show-current"],
                workingDirectory: root,
                timeout: 5,
            ), result.exitCode == 0
        else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        guard
            let head = try? await ProcessRunner.run(
                executable: Self.gitPath,
                arguments: ["rev-parse", "--short", "HEAD"],
                workingDirectory: root,
                timeout: 5,
            ), head.exitCode == 0
        else { return nil }
        let hash = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }
}
