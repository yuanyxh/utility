import Cocoa

protocol PanelProtocol: AnyObject {
    var panelID: String { get }
    var panelWindow: NSWindow? { get }
    var isPanelVisible: Bool { get }
    var closesOnResignKey: Bool { get }

    func showPanel(context: [String: Any]?)
    func closePanel()
    func handleKeyEvent(_ event: NSEvent) -> Bool
}

extension PanelProtocol {
    var closesOnResignKey: Bool { true }
    func handleKeyEvent(_ event: NSEvent) -> Bool { false }
}
