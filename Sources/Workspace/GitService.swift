import Foundation

enum GitError: Error {
    case commandFailed(String)
}

/// Read-only git access for the workspace pane. Commands run directly, never
/// through a shell, with fixed timeouts and output caps.
struct GitService {
    let root: URL

    private static let gitPath = "/usr/bin/git"

    /// Directories whose metadata changes on commit, checkout and stage. Worktrees
    /// keep HEAD and the index apart from the shared refs, so both are returned.
    func metadataDirectories() async -> [URL] {
        var result: [URL] = []
        for flag in ["--absolute-git-dir", "--git-common-dir"] {
            guard
                let out = try? await ProcessRunner.run(
                    executable: Self.gitPath, arguments: ["rev-parse", flag],
                    workingDirectory: root, timeout: 5,
                ), out.exitCode == 0
            else { continue }
            let raw = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let url = URL(fileURLWithPath: raw, relativeTo: root).standardizedFileURL
            if !result.contains(url) { result.append(url) }
        }
        return result
    }

    func isRepository() async -> Bool {
        guard
            let result = try? await ProcessRunner.run(
                executable: Self.gitPath,
                arguments: ["rev-parse", "--is-inside-work-tree"],
                workingDirectory: root,
                timeout: 5,
            )
        else { return false }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && value == "true"
    }

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

    /// Changed files keep per-file listing; ignored paths come from a second pass
    /// because `--untracked-files=all` expands ignored directories into every file.
    func status() async throws -> GitStatusResult {
        let prefix = await workspacePrefix()
        let changed = try await captureStatus(["--untracked-files=all"])
        var result = GitStatusModel.parse(changed)
        do {
            let ignored = try await captureStatus(["--ignored=traditional"])
            result.ignoredPaths = GitStatusModel.parse(ignored).ignoredPaths
        } catch {
            debugLog("[Git] ignored query failed root=\(root.path) error=\(error)")
        }
        return GitStatusModel.scoped(result, prefix: prefix)
    }

    /// Path of the working tree root relative to the repository root; nil when equal.
    private func workspacePrefix() async -> String? {
        guard
            let top = try? await ProcessRunner.run(
                executable: Self.gitPath,
                arguments: ["rev-parse", "--show-toplevel"],
                workingDirectory: root,
                timeout: 5,
            ), top.exitCode == 0
        else { return nil }
        let repoPath = URL(
            fileURLWithPath: top.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
        ).standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard rootPath != repoPath, rootPath.hasPrefix(repoPath + "/") else { return nil }
        return String(rootPath.dropFirst(repoPath.count + 1))
    }

    private func captureStatus(_ extra: [String]) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: Self.gitPath,
            arguments: ["status", "--porcelain=v1", "-z"] + extra,
            workingDirectory: root,
            timeout: 5,
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.stderr)
        }
        guard !result.truncated else {
            throw GitError.commandFailed("git status output exceeded the buffer limit")
        }
        return result.stdout
    }

    func diff(path: String, untracked: Bool = false) async throws -> String {
        if untracked {
            return try await capture(["diff", "--no-index", "/dev/null", path], allowed: [0, 1])
        }
        let head = try? await ProcessRunner.run(
            executable: Self.gitPath,
            arguments: ["rev-parse", "--verify", "HEAD"],
            workingDirectory: root,
            timeout: 5,
        )
        let hasHead = head?.exitCode == 0

        var parts: [String] = []
        if hasHead {
            parts.append(try await capture(["diff", "--cached", "--", path]))
            parts.append(try await capture(["diff", "--", path]))
        } else {
            let worktree = try await capture(["diff", "--", path])
            if worktree.isEmpty {
                parts.append(
                    try await capture(["diff", "--no-index", "/dev/null", path], allowed: [0, 1]),
                )
            } else {
                parts.append(worktree)
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// `git diff --no-index` exits 1 when the files differ, so callers pass the
    /// exit codes that still mean success.
    private func capture(_ arguments: [String], allowed: Set<Int32> = [0]) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: Self.gitPath,
            arguments: arguments,
            workingDirectory: root,
            timeout: 10,
        )
        guard allowed.contains(result.exitCode) else {
            throw GitError.commandFailed(result.stderr)
        }
        return result.stdout
    }
}
