import Cocoa
import SwiftUI

/// Single settings window; closed instances stay alive so reopening is cheap.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let model = SettingsModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false,
        )
        window.title = L10n.Settings.title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 460)
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))

        super.init(window: window)
        AppWindowRegistry.register(window)
        if !window.setFrameAutosaveName("utility.settings-window") {
            window.center()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func show() {
        let start = CFAbsoluteTimeGetCurrent()
        if window?.isVisible != true {
            model.reload()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if elapsed > 1 {
            debugLog("[Settings] open slow \(Int(elapsed * 1000))ms")
        }
    }

    @objc private func onLanguageChanged() {
        window?.title = L10n.Settings.title
    }
}
