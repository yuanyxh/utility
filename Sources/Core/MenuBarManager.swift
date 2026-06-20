import Cocoa
import ServiceManagement

// MARK: - MenuBarManager

public final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem!

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

        launchAtLoginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLoginItem)

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

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                launchAtLoginItem.state = .off
                debugLog("[LoginItem] Unregistered")
            } else {
                try SMAppService.mainApp.register()
                launchAtLoginItem.state = .on
                debugLog("[LoginItem] Registered")
            }
        } catch {
            debugLog("[LoginItem] Failed: \(error)")
            NotificationManager.shared.error("开机自启设置失败", error.localizedDescription)
        }
    }

    @objc private func reloadConfig() {
        do {
            try ConfigManager.shared.reload()
        } catch {
            debugLog("[MenuBar] Reload failed: \(error)")
            NotificationManager.shared.error("配置重载失败", error.localizedDescription)
        }
    }

    @objc private func clearClipboard() {
        let db = AppDatabase.shared.dbQueue
        try? db?.write { db in
            try db.execute(literal: "DELETE FROM clipboard_item")
        }
        debugLog("[MenuBar] Clipboard cleared")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
