import Cocoa

/// 剪切板快速粘贴面板
/// NSPanel + NSTableView + NSSearchField
public final class ClipboardPanelController: NSWindowController {
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private var items: [ClipboardItem] = []
    private let storage: ClipboardStorage
    private var eventMonitor: Any?

    public init(storage: ClipboardStorage) {
        self.storage = storage
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 312, height: 380),
                             styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.level = NSWindow.Level.floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        setupUI()
        setupDeactivateObserver()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupUI() {
        guard let panel = window else { return }

        // 搜索框
        searchField.placeholderString = "搜索剪切板…"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsWholeSearchString = false
        searchField.bezelStyle = .roundedBezel
        searchField.font = NSFont.systemFont(ofSize: 13)

        // 表格
        let col = NSTableColumn(identifier: .init("content"))
        col.title = ""
        col.minWidth = 256
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.target = self
        tableView.doubleAction = #selector(selectItem)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = NSColor.controlBackgroundColor

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        // 滚动条：overlay 模式 = 自动隐藏 + 细条
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .small

        // 布局：顶部留 44px 给原生按钮
        let stack = NSStackView(views: [searchField, scrollView])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 12, bottom: 12, right: 12)
        panel.contentView = stack

        // 键盘事件
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
    }

    /// 失焦自动关闭
    private func setupDeactivateObserver() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(close),
            name: NSWindow.didResignKeyNotification, object: window
        )
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        items = (try? (query.isEmpty ? storage.all() : storage.search(query))) ?? []
        tableView.reloadData()
        if !items.isEmpty { tableView.selectRowIndexes(.init(integer: 0), byExtendingSelection: false) }
    }

    @objc private func selectItem() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < items.count else { return }
        let item = items[tableView.selectedRow]
        try? storage.moveToTop(item.id)
        paste(item: item)
        close()
    }

    private func paste(item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.type {
        case "text":
            guard let str = String(data: item.content, encoding: .utf8) else { return }
            pb.setString(str, forType: .string)
        case "file":
            pb.setData(item.content, forType: .fileURL)
        case "image":
            pb.setData(item.content, forType: .tiff)
        default:
            return
        }

        // 模拟 cmd+v
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) else { return }
        keyDown.flags = .maskCommand
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // esc — 关闭
            close()
            return nil
        case 36: // return — 粘贴选中
            if !event.modifierFlags.contains(.command) {
                selectItem()
                return nil
            }
        case 3: // f — cmd+f 搜索
            if event.modifierFlags.contains(.command) {
                searchField.becomeFirstResponder()
                return nil
            }
        case 125: // down
            if searchField.currentEditor() == nil {
                let next = min(tableView.selectedRow + 1, items.count - 1)
                tableView.selectRowIndexes(.init(integer: max(next, 0)), byExtendingSelection: false)
                tableView.scrollRowToVisible(max(next, 0))
                return nil
            }
        case 126: // up
            if searchField.currentEditor() == nil {
                let prev = tableView.selectedRow - 1
                tableView.selectRowIndexes(.init(integer: max(prev, 0)), byExtendingSelection: false)
                tableView.scrollRowToVisible(max(prev, 0))
                return nil
            }
        default:
            break
        }
        return event
    }

    // MARK: - Show / Close

    public func show() {
        items = (try? storage.all()) ?? []
        tableView.reloadData()
        searchField.stringValue = ""

        // 智能定位：根据鼠标位置选择最佳角落
        let mouse = NSEvent.mouseLocation
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = window?.frame.size ?? NSSize(width: 360, height: 380)
        let padding: CGFloat = 12

        // 尝试顺序：右下 → 左下 → 右上 → 左上
        let candidates: [(x: CGFloat, y: CGFloat)] = [
            // 右下：鼠标右下角
            (mouse.x + padding, mouse.y - panelSize.height - padding),
            // 左下：鼠标左下角
            (mouse.x - panelSize.width - padding, mouse.y - panelSize.height - padding),
            // 右上：鼠标右上角
            (mouse.x + padding, mouse.y + padding),
            // 左上：鼠标左上角
            (mouse.x - panelSize.width - padding, mouse.y + padding),
        ]

        var origin: NSPoint = NSPoint(x: mouse.x + padding, y: mouse.y - panelSize.height - padding)
        for candidate in candidates {
            let rect = NSRect(origin: NSPoint(x: candidate.x, y: candidate.y),
                              size: panelSize)
            if screenFrame.contains(rect) {
                origin = NSPoint(x: candidate.x, y: candidate.y)
                break
            }
        }

        window?.setFrameOrigin(origin)

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !items.isEmpty { tableView.selectRowIndexes(.init(integer: 0), byExtendingSelection: false) }
        tableView.becomeFirstResponder()
    }

    public override func close() {
        window?.orderOut(nil)
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension ClipboardPanelController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]

        let cell = NSTableCellView()
        let text: String
        switch item.type {
        case "text":
            text = String(data: item.content, encoding: .utf8) ?? "(不可读)"
        case "file":
            text = "📄 \(item.application ?? "文件")"
        case "image":
            text = "🖼️ 图片 \(item.application ?? "")"
        default:
            text = "(未知)"
        }

        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: 13)
        label.cell?.truncatesLastVisibleLine = true
        cell.textField = label
        cell.addSubview(label)

        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 32 }
}
