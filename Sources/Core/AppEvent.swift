import Foundation

/// Notification payload — the publisher builds title/body itself
struct NotificationPayload {
    let title: String
    let body: String
    var sessionID: String?
}

/// App-level event enum
enum AppEvent: String, Hashable, CaseIterable {
    case configDidLoad
    case notify // payload: NotificationPayload
    case networkSpeedUpdated
    case terminalOpenSession // payload: session id
}

/// Panel events — pub/sub string keys, the payload carries parameters
enum PanelEvent {
    /// Request to show the panel, payload: a PanelProtocol instance
    static let requestShow = "panel.requestShow"
    /// Request to close the panel, payload: a PanelProtocol instance
    static let requestClose = "panel.requestClose"
    /// Request to paste and close, payload: a PanelProtocol instance
    /// PanelManager gets originatingApp → schedulePaste → close the panel
    static let requestPaste = "panel.requestPaste"
}
