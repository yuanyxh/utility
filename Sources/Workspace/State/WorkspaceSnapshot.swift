import Foundation

enum PanelID: String, CaseIterable, Sendable {
    case mainTerminal
    case subTerminals
}

struct TerminalUIState: Equatable {
    var mainSessionID: String?
    var sessions: [WorkspaceSessionSummary] = []
    var selectedSubSessionID: String?
    var branch: String?
}

struct WorkspaceSnapshot: Equatable {
    var terminals = TerminalUIState()
}
