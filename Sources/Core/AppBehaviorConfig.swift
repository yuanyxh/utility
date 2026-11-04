import Foundation

// MARK: - App

/// `app` section: activation policy and startup window.
struct AppBehaviorConfig: Codable {
    /// true = hide the Dock icon while no main window is open.
    var hideDockIcon: Bool = false
    /// Open the terminal window after launch.
    var showTerminalOnLaunch: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideDockIcon = try c.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? false
        showTerminalOnLaunch =
            try c.decodeIfPresent(Bool.self, forKey: .showTerminalOnLaunch) ?? true
    }
}
