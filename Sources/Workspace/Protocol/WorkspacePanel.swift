import Cocoa

/// A pane that renders from the shared snapshot and never fetches data itself.
@MainActor
protocol WorkspacePanel: AnyObject {
    var panelID: PanelID { get }
    var focusTarget: NSView? { get }
    func render(_ snapshot: WorkspaceSnapshot)
}
