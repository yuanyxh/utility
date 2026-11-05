import Foundation

enum TerminalRole: String, Codable, Sendable {
    case main
    case sub
}

struct WindowLayout: Codable, Equatable, Sendable {
    var sidebarWidth: Double = 220
    var rightPaneWidth: Double = 580
    var fileListWidth: Double = 200
    var subTerminalHeight: Double = 260
    var subListWidth: Double = 180

    static let minimum = WindowLayout(
        sidebarWidth: 180,
        rightPaneWidth: 525,
        fileListWidth: 160,
        subTerminalHeight: 120,
        subListWidth: 140,
    )

    func clamped() -> WindowLayout {
        WindowLayout(
            sidebarWidth: max(sidebarWidth, Self.minimum.sidebarWidth),
            rightPaneWidth: max(rightPaneWidth, Self.minimum.rightPaneWidth),
            fileListWidth: max(fileListWidth, Self.minimum.fileListWidth),
            subTerminalHeight: max(subTerminalHeight, Self.minimum.subTerminalHeight),
            subListWidth: max(subListWidth, Self.minimum.subListWidth),
        )
    }
}

struct Workspace: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var path: String
    var mainSessionID: String?
    var subSessionIDs: [String]
    var selectedSubSessionID: String?
    var lastOpenedRelativePath: String?
    let createdAt: Date

    init(
        id: String,
        name: String,
        path: String,
        mainSessionID: String? = nil,
        subSessionIDs: [String] = [],
        selectedSubSessionID: String? = nil,
        lastOpenedRelativePath: String? = nil,
        createdAt: Date = Date(),
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.mainSessionID = mainSessionID
        self.subSessionIDs = subSessionIDs
        self.selectedSubSessionID = selectedSubSessionID
        self.lastOpenedRelativePath = lastOpenedRelativePath
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try c.decode(String.self, forKey: .path)
        mainSessionID = try c.decodeIfPresent(String.self, forKey: .mainSessionID)
        subSessionIDs = try c.decodeIfPresent([String].self, forKey: .subSessionIDs) ?? []
        selectedSubSessionID = try c.decodeIfPresent(String.self, forKey: .selectedSubSessionID)
        lastOpenedRelativePath = try c.decodeIfPresent(String.self, forKey: .lastOpenedRelativePath)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    /// Standardized absolute path; empty input falls back to the home directory.
    static func standardizedPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? NSHomeDirectory() : trimmed
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Stable identifier so a rebuilt document keeps the same workspace id.
    static func identifier(forPath path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "ws-\(String(hash, radix: 16))"
    }
}

struct WorkspaceDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var selectedWorkspaceID: String?
    var layout: WindowLayout
    var workspaces: [Workspace]

    init(
        version: Int = currentVersion,
        selectedWorkspaceID: String? = nil,
        layout: WindowLayout = WindowLayout(),
        workspaces: [Workspace] = [],
    ) {
        self.version = version
        self.selectedWorkspaceID = selectedWorkspaceID
        self.layout = layout
        self.workspaces = workspaces
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        selectedWorkspaceID = try c.decodeIfPresent(String.self, forKey: .selectedWorkspaceID)
        layout = try c.decodeIfPresent(WindowLayout.self, forKey: .layout) ?? WindowLayout()
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
    }

    /// Drops duplicate ids or paths and repairs dangling selection references.
    func normalized() -> WorkspaceDocument {
        var seenIDs: Set<String> = []
        var seenPaths: Set<String> = []
        var cleaned: [Workspace] = []
        for workspace in workspaces {
            let path = Workspace.standardizedPath(workspace.path)
            guard !seenIDs.contains(workspace.id), !seenPaths.contains(path) else { continue }
            seenIDs.insert(workspace.id)
            seenPaths.insert(path)

            var subs = workspace.subSessionIDs
            if let main = workspace.mainSessionID {
                subs.removeAll { $0 == main }
            }
            var seenSubs: Set<String> = []
            subs = subs.filter { seenSubs.insert($0).inserted }

            var selectedSub = workspace.selectedSubSessionID
            if let value = selectedSub, !subs.contains(value) {
                selectedSub = nil
            }

            cleaned.append(
                Workspace(
                    id: workspace.id,
                    name: workspace.name.isEmpty
                        ? (path as NSString).lastPathComponent : workspace.name,
                    path: path,
                    mainSessionID: workspace.mainSessionID,
                    subSessionIDs: subs,
                    selectedSubSessionID: selectedSub ?? subs.first,
                    lastOpenedRelativePath: workspace.lastOpenedRelativePath,
                    createdAt: workspace.createdAt,
                ),
            )
        }

        let selected =
            cleaned.contains { $0.id == selectedWorkspaceID }
            ? selectedWorkspaceID : cleaned.first?.id
        return WorkspaceDocument(
            version: max(version, Self.currentVersion),
            selectedWorkspaceID: selected,
            layout: layout.clamped(),
            workspaces: cleaned,
        )
    }

    var sessionCount: Int {
        workspaces.reduce(0) { $0 + ($1.mainSessionID == nil ? 0 : 1) + $1.subSessionIDs.count }
    }
}

enum WorkspaceJSON {
    static func decode(_ data: Data) throws -> WorkspaceDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspaceDocument.self, from: data)
    }

    static func encode(_ document: WorkspaceDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }
}
