import Cocoa

/// Windows that keep the accessory app alive when transient panels close.
@MainActor
enum AppWindowRegistry {
    private static let windows = NSHashTable<NSWindow>.weakObjects()
    private static let lastKeyWindows = NSHashTable<NSWindow>.weakObjects()

    static func register(_ window: NSWindow) {
        windows.add(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main,
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                lastKeyWindows.removeAllObjects()
                lastKeyWindows.add(window)
            }
        }
    }

    static var hasVisibleWindow: Bool {
        windows.allObjects.contains { $0.isVisible }
    }

    /// Focus target after a panel closes; orderedWindows omits floating panels.
    static var frontmostWindow: NSWindow? {
        if let last = lastKeyWindows.allObjects.first(where: { $0.isVisible }) {
            return last
        }
        if let key = NSApplication.shared.keyWindow,
           windows.contains(key), key.isVisible
        {
            return key
        }
        return nil
    }
}
