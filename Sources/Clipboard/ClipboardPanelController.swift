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
        col.minWidth = 100
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
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
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
            (mouse.x + padding, mouse.y - panelSize.height - padding),
            (mouse.x - panelSize.width - padding, mouse.y - panelSize.height - padding),
            (mouse.x + padding, mouse.y + padding),
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

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = LighterSelectionRowView()
        view.identifier = NSUserInterfaceItemIdentifier("ClipboardRow")
        return view
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSView()
        cell.identifier = NSUserInterfaceItemIdentifier("ClipboardCell")

        // 序号圆圈
        let circleView = NumberCircleView()
        circleView.number = row + 1
        circleView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(circleView)

        // 文本标签
        let text = displayText(for: item)
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor(red: 0x33 / 255, green: 0x33 / 255, blue: 0x33 / 255, alpha: 1.0)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)

        NSLayoutConstraint.activate([
            circleView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 0),
            circleView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            circleView.widthAnchor.constraint(equalToConstant: 16),
            circleView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: circleView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -1),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.heightAnchor.constraint(equalToConstant: 16),
        ])

        return cell
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 32 }

    private func displayText(for item: ClipboardItem) -> String {
        switch item.type {
        case "text":
            return String(data: item.content, encoding: .utf8) ?? "(不可读)"
        case "file":
            return "📄 \(item.application ?? "文件")"
        case "image":
            return "🖼️ 图片 \(item.application ?? "")"
        default:
            return "(未知)"
        }
    }
}

// MARK: - Lighter Selection Row View

private final class LighterSelectionRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            enumerateCircleViews(in: self) { $0.isHighlighted = isSelected }
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(red: 0xCB / 255, green: 0xCC / 255, blue: 0xCC / 255, alpha: 0.68).setFill()
        bounds.fill()
    }

    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        get { .regular }
        set {}
    }

    private func enumerateCircleViews(in view: NSView, handler: (NumberCircleView) -> Void) {
        for subview in view.subviews {
            if let circle = subview as? NumberCircleView {
                handler(circle)
            }
            enumerateCircleViews(in: subview, handler: handler)
        }
    }
}

// MARK: - Number Circle View

private final class NumberCircleView: NSView {
    var number: Int = 0 {
        didSet { numberLabel.stringValue = "\(number)" }
    }
    var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    private let numberLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .white
        label.alignment = .center
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(numberLabel)
        NSLayoutConstraint.activate([
            numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 16
        let circleRect = CGRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )

        // 实心圆
        let path = NSBezierPath(ovalIn: circleRect)
        let fillColor: NSColor = isHighlighted
            ? NSColor(red: 0x34 / 255, green: 0x78 / 255, blue: 0xF6 / 255, alpha: 1.0)
            : NSColor(red: 0xA4 / 255, green: 0xA4 / 255, blue: 0xA4 / 255, alpha: 1.0)
        fillColor.setFill()
        path.fill()
    }
}
