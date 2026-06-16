import Cocoa

/// 剪切板快速粘贴面板
/// NSPanel + NSTableView + NSSearchField
public final class ClipboardPanelController: NSWindowController {
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private var items: [ClipboardItem] = []
    private let storage: ClipboardStorage

    public init(storage: ClipboardStorage) {
        self.storage = storage
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                             styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.level = NSWindow.Level.floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        setupUI()
    }

    required init?(coder: NSCoder) { nil }

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
        col.minWidth = 380
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

        // 布局
        let stack = NSStackView(views: [searchField, scrollView])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        panel.contentView = stack

        // 键盘事件
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
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

        // 定位到鼠标位置
        let mouse = NSEvent.mouseLocation
        var frame = window?.frame ?? .zero
        frame.origin.x = mouse.x - 210
        frame.origin.y = mouse.y - frame.height + 30
        window?.setFrame(frame, display: true)

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
