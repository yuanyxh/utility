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

enum GitStatusModel {
    /// Parses `git status --porcelain=v1 -z`. Rename records carry the new path
    /// followed by the original path, so the extra field is skipped.
    static func parse(_ raw: String) -> [GitFileStatus] {
        let records = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var items: [GitFileStatus] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count >= 4 else { continue }

            let x = record[record.startIndex]
            let y = record[record.index(after: record.startIndex)]
            guard x != "!" else { continue }

            if x == "R" || x == "C" || y == "R" || y == "C", index < records.count {
                index += 1
            }
            let untracked = x == "?"
            items.append(
                GitFileStatus(
                    path: String(record.dropFirst(3)),
                    code: String([x, y]),
                    staged: !untracked && x != " ",
                    unstaged: !untracked && y != " ",
                    untracked: untracked,
                ),
            )
        }
        return items
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
