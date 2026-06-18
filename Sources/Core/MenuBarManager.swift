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
        let icon = Bundle.module.image(forResource: "menubar-icon")
        icon?.isTemplate = true
        statusItem.button?.image = icon
    }

    private func buildMenu() {
        let menu = NSMenu()

        let reloadItem = NSMenuItem(title: "重载配置", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "清空剪切板", action: #selector(clearClipboard), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
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
}
