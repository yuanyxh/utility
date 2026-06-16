import Cocoa

/// 菜单栏管理器
/// 创建菜单栏图标，提供重载配置、退出等功能
public final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var configMenuItem: NSMenuItem?

    public override init() {
        super.init()
        setupStatusItem()
        buildMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2",
                                    accessibilityDescription: "Utility")
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        // 配置状态展示
        configMenuItem = NSMenuItem(title: "加载中…", action: nil, keyEquivalent: "")
        configMenuItem?.isEnabled = false
        menu.addItem(configMenuItem!)
        menu.addItem(NSMenuItem.separator())

        // 功能开关占位
        let clipItem = NSMenuItem(title: "剪切板管理 ✓", action: nil, keyEquivalent: "")
        clipItem.isEnabled = false
        menu.addItem(clipItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "重载配置", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu

        // 监听配置重载
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateConfigDisplay),
            name: .configDidReload, object: nil
        )
    }

    @objc private func reloadConfig() {
        do {
            try ConfigManager.shared.reload()
        } catch {
            print("[MenuBar] Reload failed: \(error)")
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc func updateConfigDisplay() {
        configMenuItem?.title = ConfigManager.shared.summary()
    }
}
