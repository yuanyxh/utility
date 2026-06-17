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

        let dragView = DragTargetView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        dragView.onDropText = { text in
            try? StageManager.shared.add(text: text)
        }
        dragView.onDropFile = { url in
            try? StageManager.shared.add(fileURL: url)
        }
        statusItem.button?.addSubview(dragView)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2",
                                            accessibilityDescription: "Utility")
    }

    private func buildMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "重载配置", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "清空剪切板", action: #selector(clearClipboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "暂存窗口", action: #selector(toggleStage), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "清空暂存", action: #selector(clearStage), keyEquivalent: ""))
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

    @objc private func toggleStage() {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate,
              let wc = delegate.value(forKey: "stageWindow") as? StageWindowController else { return }
        if wc.window?.isVisible == true {
            wc.close()
        } else {
            wc.show()
        }
    }

    @objc private func clearStage() {
        try? StageManager.shared.clearAll()
    }

    @objc func updateConfigDisplay() {
        // no-op, kept for notification observer
    }
}

// MARK: - Drag Target View

private final class DragTargetView: NSView {
    var onDropText: ((String) -> Void)?
    var onDropFile: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .string, .fileURL, .URL,
            .init("NSFilenamesPboardType"),
            .init("public.file-url"),
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([
            .string, .fileURL, .URL,
            .init("NSFilenamesPboardType"),
            .init("public.file-url"),
        ])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var handled = false

        // 文件 — readObjects 统一处理所有类型
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                let fileURL = url.standardizedFileURL
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    onDropFile?(fileURL)
                }
            }
            handled = true
        }

        // 文本
        if !handled, let text = pb.string(forType: .string) {
            onDropText?(text)
            handled = true
        }

        return handled
    }
}
