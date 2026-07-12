import AppKit
import Foundation

/// Manages the MCP status indicator in the menu bar.
/// Shows running/stopped/crashed state via EventBus. (P4: full menu integration)
final class MCPMenuManager {
    static let shared = MCPMenuManager()

    private var stateItem: NSMenuItem?

    func updateState(_ state: MCPProcessManager.State) {
        switch state {
        case .running:
            debugLog("[MCP] ● Running")
        case .initializing, .restarting:
            debugLog("[MCP] ◐ Starting...")
        case .stopped:
            debugLog("[MCP] ○ Stopped")
        case .crashed:
            debugLog("[MCP] ✕ Crashed")
        }
    }
}
