import Foundation

enum PanelID: String, CaseIterable, Sendable {
    case mainTerminal
    case subTerminals
    case fileTree
    case gitList
    case editor
}

struct FileTreeUIState: Equatable {
    var root: URL?
    var ignoredPaths: Set<String> = []
    var selectedPath: String?
}

struct GitUIState: Equatable {
    var root: URL?
    var isRepository = false
    var files: [GitFileStatus] = []
    var collapsed: Set<GitSectionKind> = []
    var selectedPath: String?
}

struct EditorUIState: Equatable {
    var url: URL?
    var isDirty = false
    var externalChange: ExternalChange = .unchanged
    var previewMode: EditorPreviewMode = .source
}

struct TerminalUIState: Equatable {
    var mainSessionID: String?
    var sessions: [WorkspaceSessionSummary] = []
    var selectedSubSessionID: String?
    var branch: String?
}

struct WorkspaceSnapshot: Equatable {
    var ui = WorkspaceUIState()
    var fileTree = FileTreeUIState()
    var git = GitUIState()
    var editor = EditorUIState()
    var terminals = TerminalUIState()
}
