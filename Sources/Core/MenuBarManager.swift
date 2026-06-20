import Cocoa
import ServiceManagement

public final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem!

    public override init() {
        super.init()
        setupStatusItem()
        buildMenu()
        startNetworkMonitor()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "utility-network-speed"

        let view = NetworkSpeedView()
        view.onClick = { [weak self] event in
            guard let self, let menu = self.statusItem.menu,
                  let v = self.statusItem.value(forKey: "view") as? NSView else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: v)
        }
        statusItem.setValue(view, forKey: "view")
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

    // MARK: - Network

    private func startNetworkMonitor() {
        let monitor = NetworkSpeedMonitor.shared
        monitor.onUpdate = { [weak self] up, down in
            guard let view = self?.statusItem.value(forKey: "view") as? NetworkSpeedView else { return }
            view.update(up: up, down: down)
        }
        monitor.start()
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

// MARK: - NetworkSpeedView

private final class NetworkSpeedView: NSView {
    private let upLabel   = NSTextField(labelWithString: "")
    private let downLabel = NSTextField(labelWithString: "")

    var onClick: ((NSEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        upLabel.font   = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        downLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        upLabel.alignment   = .right
        downLabel.alignment = .right

        let stack = NSStackView(views: [upLabel, downLabel])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .trailing
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        update(up: "--", down: "--")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event)
    }

    override var intrinsicContentSize: NSSize {
        let upSz   = upLabel.intrinsicContentSize
        let downSz = downLabel.intrinsicContentSize
        return NSSize(
            width: max(upSz.width, downSz.width),
            height: upSz.height + downSz.height
        )
    }

    func update(up: String, down: String) {
        let (paddedUp, paddedDown) = pad(up: up, down: down)
        upLabel.stringValue   = paddedUp
        downLabel.stringValue = paddedDown
        invalidateIntrinsicContentSize()
        superview?.layoutSubtreeIfNeeded()
    }

    // MARK: - Padding

    /// 整数部分等宽补 0，添加箭头，空格分隔。输入始终有 2 位小数。
    /// 如 ("001.23M", "456.78K") → ("↑ 001.23M", "↓ 456.78K")
    private func pad(up: String, down: String) -> (String, String) {
        let upInt   = String(up.prefix(while: { $0 != "." }))
        let downInt = String(down.prefix(while: { $0 != "." }))
        let upRest  = String(up.dropFirst(upInt.count))
        let downRest = String(down.dropFirst(downInt.count))

        let maxLen = max(upInt.count, downInt.count)
        let padUp   = String(repeating: "0", count: maxLen - upInt.count) + upInt
        let padDown = String(repeating: "0", count: maxLen - downInt.count) + downInt

        return ("↑ " + padUp + upRest, "↓ " + padDown + downRest)
    }
}
