import Cocoa

/// 菜单栏管理器
public final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!

    public override init() {
        super.init()
        setupStatusItem()
        buildMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2",
                                            accessibilityDescription: "Utility")
    }

    private func buildMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "重载配置", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "清空剪切板", action: #selector(clearClipboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(updateConfigDisplay),
            name: .configDidReload, object: nil
        )
    }

    // MARK: - Actions

    @objc private func reloadConfig() {
        do {
            try ConfigManager.shared.reload()
        } catch {
            Log.debug("[MenuBar] Reload failed: \(error)")
        }
    }

    @objc private func clearClipboard() {
        let db = AppDatabase.shared.dbQueue
        try? db?.write { db in
            try db.execute(literal: "DELETE FROM clipboard_item")
        }
        Log.debug("[MenuBar] Clipboard cleared")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc func updateConfigDisplay() {
        // no-op, kept for notification observer
    }
}
