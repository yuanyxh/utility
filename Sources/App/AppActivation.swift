import AppKit

/// macOS ties the Dock icon, app menu bar and Cmd+Tab to the activation policy, so
/// `app.hideDockIcon` hides the icon only while the terminal window is closed.
@MainActor
enum AppActivation {
    private static var mainWindowActive = false

    static func setMainWindowActive(_ active: Bool) {
        guard mainWindowActive != active else { return }
        mainWindowActive = active
        apply()
    }

    static func apply() {
        let hide = ConfigManager.shared.config.app.hideDockIcon && !mainWindowActive
        let policy: NSApplication.ActivationPolicy = hide ? .accessory : .regular
        NSApplication.shared.setActivationPolicy(policy)
        debugLog(
            "[Utility] activation policy=\(policy == .regular ? "regular" : "accessory") mainWindowActive=\(mainWindowActive)",
        )
    }
}
