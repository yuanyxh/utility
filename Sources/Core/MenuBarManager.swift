import Cocoa

/// 菜单栏管理器
/// 创建菜单栏图标，支持拖拽暂存（自动触发），提供重载配置、退出等功能
public final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var configMenuItem: NSMenuItem?
    private var stageMenuItem: NSMenuItem?

    public override init() {
        super.init()
        setupStatusItem()
        buildMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // 使用自定义 NSView 实现拖拽接收
        let dragView = DragTargetView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        dragView.onDropText = { text in
            try? StageManager.shared.add(text: text)
            self.updateStageCount()
        }
        dragView.onDropFile = { url in
            try? StageManager.shared.add(fileURL: url)
            self.updateStageCount()
        }
        statusItem.button?.addSubview(dragView)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2",
                                            accessibilityDescription: "Utility")
    }

    private func buildMenu() {
        let menu = NSMenu()

        // 配置状态
        configMenuItem = NSMenuItem(title: "加载中…", action: nil, keyEquivalent: "")
        configMenuItem?.isEnabled = false
        menu.addItem(configMenuItem!)

        menu.addItem(NSMenuItem.separator())

        // 暂存状态
        stageMenuItem = NSMenuItem(title: "暂存: 0", action: nil, keyEquivalent: "")
        stageMenuItem?.isEnabled = false
        menu.addItem(stageMenuItem!)

        let clipItem = NSMenuItem(title: "剪切板管理 ✓", action: nil, keyEquivalent: "")
        clipItem.isEnabled = false
        menu.addItem(clipItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "查看暂存", action: #selector(showStage), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "清空暂存", action: #selector(clearStage), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "重载配置", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
        updateStageCount()

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
            print("[MenuBar] Reload failed: \(error)")
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func showStage() {
        let panel = StagePanelController()
        panel.show()
    }

    @objc private func clearStage() {
        let items = (try? StageManager.shared.all()) ?? []
        for item in items {
            try? StageManager.shared.remove(item.id)
        }
        updateStageCount()
    }

    @objc func updateConfigDisplay() {
        configMenuItem?.title = ConfigManager.shared.summary()
    }

    @objc func updateStageCount() {
        let count = (try? StageManager.shared.count()) ?? 0
        stageMenuItem?.title = "暂存: \(count)"
    }
}

// MARK: - Drag Target View

private final class DragTargetView: NSView {
    var onDropText: ((String) -> Void)?
    var onDropFile: ((URL) -> Void)?

    override func awakeFromNib() {
        super.awakeFromNib()
        registerForDraggedTypes([.string, .fileURL, .URL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        // 文件拖拽
        if let data = pb.data(forType: .fileURL),
           let urlStr = String(data: data, encoding: .utf8) {
            let url = URL(fileURLWithPath: urlStr.replacingOccurrences(of: "file://", with: ""))
            onDropFile?(url)
            return true
        }

        // 文本拖拽
        if let text = pb.string(forType: .string) {
            onDropText?(text)
            return true
        }

        return false
    }
}
