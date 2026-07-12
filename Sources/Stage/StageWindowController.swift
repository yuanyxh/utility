import Cocoa

/// 暂存窗口 — 屏幕左下角垂直列表
public final class StageWindowController: NSWindowController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [StageItem] = []
    private let clearButton = NSButton()
    private var draggingItemId: String?
    private var draggingItem: StageItem?

    public init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 320),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.transient, .ignoresCycle]

        super.init(window: panel)
        setupUI()
        addVisualEffectView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil
        )
        // 确保 window.frame 已就绪供 StageDropMonitor 判断位置
        panel.orderFront(nil)
        panel.orderOut(nil)

        StageDropMonitor.shared.start(with: self)
    }

    required init?(coder _: NSCoder) {
        nil
    }

    private func setupUI() {
        guard let panel = window else { return }

        // 清空按钮（右上角）
        clearButton.title = L10n.Stage.clear
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.font = NSFont.systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(clearAll)

        // 表格
        let col = NSTableColumn(identifier: .init("item"))
        col.title = ""
        col.width = 180
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 2)

        // 拖拽排序/移出
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        let headerStack = NSStackView(views: [NSView(), clearButton])
        headerStack.orientation = .horizontal

        let stack = NSStackView(views: [headerStack, scrollView])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 4)
        panel.contentView = stack
    }

    // MARK: - Public

    public func refreshTitles() {
        clearButton.title = L10n.Stage.clear
    }

    @objc private func onLanguageChanged() {
        refreshTitles()
    }

    public func reload() {
        items = (try? StageManager.shared.all()) ?? []
        tableView.reloadData()
        clearButton.isHidden = items.isEmpty
    }

    public func positionAtBottomLeft() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.minX
        let y = screenFrame.minY
        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }

    public func show() {
        reload()
        positionAtBottomLeft()
        window?.alphaValue = 1.0
        window?.hasShadow = true
        window?.ignoresMouseEvents = false
        window?.orderFront(nil)
    }

    override public func close() {
        if items.isEmpty {
            window?.orderOut(nil)
        }
    }

    private func addVisualEffectView() {
        guard let cv = window?.contentView else { return }
        let visual = NSVisualEffectView(frame: cv.bounds)
        visual.autoresizingMask = [.width, .height]
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.material = .windowBackground
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 10
        visual.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        visual.layer?.masksToBounds = true
        cv.addSubview(visual, positioned: .below, relativeTo: nil)
    }

    // MARK: - Actions

    @objc private func clearAll() {
        try? StageManager.shared.clearAll()
        reload()
        close()
    }

    @objc private func deleteItem(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        try? StageManager.shared.remove(item.id)
        reload()
        close()
    }
}

// MARK: - TableView

extension StageWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in _: NSTableView) -> Int {
        items.count
    }

    public func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        cell.identifier = .init("StageCell")

        // 图标
        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let img = item.iconImage {
            iconView.image = img
        } else {
            iconView.isHidden = true
        }

        // 文本
        let label = NSTextField(labelWithString: item.displayText)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = NSColor.labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        // 删除按钮
        let del = NSButton()
        del.title = "×"
        del.bezelStyle = .inline
        del.controlSize = .small
        del.font = NSFont.systemFont(ofSize: 16)
        del.tag = row
        del.target = self
        del.action = #selector(deleteItem(_:))
        del.isBordered = false
        del.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(iconView)
        cell.addSubview(label)
        cell.addSubview(del)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 0),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.heightAnchor.constraint(equalToConstant: 16),

            del.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: 0),
            del.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            del.widthAnchor.constraint(equalToConstant: 32),
        ])

        return cell
    }

    // MARK: - Drag out of window (drag IN handled by StageDropMonitor via EventTap)

    public func tableView(
        _ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard
    ) -> Bool {
        guard let row = rowIndexes.first, row < items.count else { return false }
        let item = items[row]
        pboard.clearContents()

        // 拖出操作 mask：moveOnDragOut=true 时允许 Finder 移动（系统级 cmd+option+v）
        let config = ConfigManager.shared.config.stage
        tableView.setDraggingSourceOperationMask(
            config.moveOnDragOut ? [.copy, .move] : .copy, forLocal: false
        )

        switch item.type {
        case "text":
            if let str = String(data: item.content, encoding: .utf8) {
                pboard.setString(str, forType: .string)
            }
        case "fileURL":
            if let url = item.resolveFileURL() {
                pboard.setString(url.absoluteString, forType: .fileURL)
                pboard.setPropertyList([url.path], forType: .init("NSFilenamesPboardType"))
            }
        case "fileGroup":
            let urls = item.resolveFileGroup()
            guard !urls.isEmpty else { return false }
            pboard.setPropertyList(urls.map(\.path), forType: .init("NSFilenamesPboardType"))
            if urls.count == 1 {
                pboard.setString(urls[0].absoluteString, forType: .fileURL)
            }
        case "html":
            if let str = String(data: item.content, encoding: .utf8) {
                pboard.setString(str, forType: .html)
            }
        case "url":
            if let str = String(data: item.content, encoding: .utf8) {
                pboard.setString(str, forType: .string)
            }
        default:
            return false
        }

        // 不在此删除 — 等 draggingSession:endedAt: 确认有效目标后再移除
        draggingItemId = item.id
        draggingItem = item
        return true
    }

    public func tableView(
        _: NSTableView, draggingSession _: NSDraggingSession, endedAt _: NSPoint,
        operation: NSDragOperation
    ) {
        defer {
            draggingItemId = nil
            draggingItem = nil
        }
        guard operation != [] else { return }
        guard let item = draggingItem else { return }
        tryMoveOrRemove(item: item, operation: operation)
        reload()
        close()
    }

    // MARK: - Move on drag out

    private func tryMoveOrRemove(item: StageItem, operation: NSDragOperation) {
        let config = ConfigManager.shared.config.stage
        guard config.moveOnDragOut else {
            try? StageManager.shared.remove(item.id)
            return
        }
        // Finder 已执行移动（cmd+opt+v）→ 只删 DB
        if operation == .move {
            try? StageManager.shared.remove(item.id)
            return
        }
        // operation == .copy: 非磁盘目标（微信/浏览器等），即使配置为 move 也只 copy，不删源文件
        try? StageManager.shared.remove(item.id)
    }
}
