import Foundation

/// Turns the legacy flat session list into workspaces, one per working directory.
enum WorkspaceMigration {
    static func plan(sessions: [StoredTerminalSession], now: Date = Date()) -> WorkspaceDocument {
        var unique: [String: StoredTerminalSession] = [:]
        for session in sessions {
            if let existing = unique[session.id], existing.createdAt <= session.createdAt {
                continue
            }
            unique[session.id] = session
        }

        let groups = Dictionary(grouping: unique.values) {
            Workspace.standardizedPath($0.cwd)
        }
        let ordered = groups.sorted { lhs, rhs in
            let lhsCreated = lhs.value.map(\.createdAt).min() ?? now
            let rhsCreated = rhs.value.map(\.createdAt).min() ?? now
            if lhsCreated != rhsCreated { return lhsCreated < rhsCreated }
            return lhs.key < rhs.key
        }

        let workspaces = ordered.map { path, group -> Workspace in
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            let name = (path as NSString).lastPathComponent
            return Workspace(
                id: Workspace.identifier(forPath: path),
                name: name.isEmpty ? path : name,
                path: path,
                mainSessionID: sorted.first?.id,
                subSessionIDs: sorted.dropFirst().map(\.id),
                selectedSubSessionID: sorted.dropFirst().first?.id,
                createdAt: sorted.first?.createdAt ?? now,
            )
        }

        return WorkspaceDocument(
            selectedWorkspaceID: workspaces.first?.id,
            workspaces: workspaces,
        ).normalized()
    }
}

/// Re-attaches legacy sessions that carry no workspace id after an older build wrote them back.
enum WorkspaceReattribution {
    static func apply(
        document: WorkspaceDocument, sessions: [StoredTerminalSession],
    ) -> WorkspaceDocument {
        var doc = document.normalized()
        var referenced = Set(
            doc.workspaces.flatMap { workspace -> [String] in
                var ids = workspace.subSessionIDs
                if let main = workspace.mainSessionID { ids.append(main) }
                return ids
            })
        var pathIndex = Dictionary(
            uniqueKeysWithValues: doc.workspaces.map { ($0.path, $0.id) },
        )

        for session in sessions.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard !referenced.contains(session.id) else { continue }
            let path = Workspace.standardizedPath(session.cwd)
            let targetID =
                session.workspaceID.flatMap { id in
                    doc.workspaces.contains { $0.id == id } ? id : nil
                } ?? pathIndex[path]

            if let targetID, let index = doc.workspaces.firstIndex(where: { $0.id == targetID }) {
                if doc.workspaces[index].mainSessionID == nil {
                    doc.workspaces[index].mainSessionID = session.id
                } else {
                    doc.workspaces[index].subSessionIDs.append(session.id)
                }
            } else {
                let name = (path as NSString).lastPathComponent
                let workspace = Workspace(
                    id: Workspace.identifier(forPath: path),
                    name: name.isEmpty ? path : name,
                    path: path,
                    mainSessionID: session.id,
                    createdAt: session.createdAt,
                )
                doc.workspaces.append(workspace)
                pathIndex[path] = workspace.id
            }
            referenced.insert(session.id)
        }

        return doc.normalized()
    }
}

/// Live tmux sessions that can be re-attached, with dead main terminals marked for rebuild.
struct WorkspaceRestorePlan: Equatable {
    struct WorkspacePlan: Equatable {
        let workspaceID: String
        let mainSessionID: String?
        let subSessionIDs: [String]
        let rebuildMain: Bool
    }

    let workspaces: [WorkspacePlan]

    init(document: WorkspaceDocument, liveIDs: Set<String>) {
        workspaces = document.workspaces.map { workspace in
            let main = workspace.mainSessionID.flatMap { liveIDs.contains($0) ? $0 : nil }
            let subs = workspace.subSessionIDs.filter { liveIDs.contains($0) }
            return WorkspacePlan(
                workspaceID: workspace.id,
                mainSessionID: main,
                subSessionIDs: subs,
                rebuildMain: main == nil,
            )
        }
    }
}
