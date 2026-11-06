import Foundation

struct GitFileStatus: Equatable {
    let path: String
    let code: String
    let staged: Bool
    let unstaged: Bool
    let untracked: Bool
}

enum GitSectionKind: String, CaseIterable {
    case staged
    case unstaged
    case untracked
}

struct GitStatusSection {
    let kind: GitSectionKind
    let title: String
    let items: [GitFileStatus]
}

/// Porcelain output split into changed files and paths ignored by .gitignore.
struct GitStatusResult: Equatable {
    var files: [GitFileStatus] = []
    var ignoredPaths: Set<String> = []
}

enum GitStatusModel {
    /// Parses `git status --porcelain=v1 -z`. Rename records carry the new path
    /// followed by the original path, so the extra field is skipped.
    static func parse(_ raw: String) -> GitStatusResult {
        let records = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result = GitStatusResult()
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count >= 4 else { continue }

            let x = record[record.startIndex]
            let y = record[record.index(after: record.startIndex)]
            if x == "!" {
                var path = String(record.dropFirst(3))
                while path.hasSuffix("/") { path.removeLast() }
                if !path.isEmpty { result.ignoredPaths.insert(path) }
                continue
            }

            if x == "R" || x == "C" || y == "R" || y == "C", index < records.count {
                index += 1
            }
            let untracked = x == "?"
            result.files.append(
                GitFileStatus(
                    path: String(record.dropFirst(3)),
                    code: String([x, y]),
                    staged: !untracked && x != " ",
                    unstaged: !untracked && y != " ",
                    untracked: untracked,
                ),
            )
        }
        return result
    }

    /// Keeps entries inside the workspace subtree and rewrites them to
    /// workspace-relative paths; porcelain always reports repo-root paths.
    static func scoped(_ result: GitStatusResult, prefix: String?) -> GitStatusResult {
        guard let prefix, !prefix.isEmpty else { return result }
        let head = prefix + "/"
        func relative(_ path: String) -> String? {
            guard path.hasPrefix(head) else { return nil }
            let value = String(path.dropFirst(head.count))
            return value.isEmpty ? nil : value
        }
        var scoped = GitStatusResult()
        scoped.files = result.files.compactMap { file in
            guard let path = relative(file.path) else { return nil }
            return GitFileStatus(
                path: path, code: file.code, staged: file.staged,
                unstaged: file.unstaged, untracked: file.untracked,
            )
        }
        scoped.ignoredPaths = Set(result.ignoredPaths.compactMap(relative))
        return scoped
    }

    static func sections(from items: [GitFileStatus]) -> [GitStatusSection] {
        let staged = items.filter { $0.staged }
        let unstaged = items.filter { $0.unstaged }
        let untracked = items.filter { $0.untracked }
        var sections: [GitStatusSection] = []
        if !staged.isEmpty {
            sections.append(
                GitStatusSection(
                    kind: .staged, title: L10n.Workspace.gitStaged, items: staged,
                ),
            )
        }
        if !unstaged.isEmpty {
            sections.append(
                GitStatusSection(
                    kind: .unstaged, title: L10n.Workspace.gitUnstaged, items: unstaged,
                ),
            )
        }
        if !untracked.isEmpty {
            sections.append(
                GitStatusSection(
                    kind: .untracked, title: L10n.Workspace.gitUntracked, items: untracked,
                ),
            )
        }
        return sections
    }
}
