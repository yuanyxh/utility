import Cocoa

/// 暂存窗口 — 屏幕左下角垂直列表
public final class StageWindowController: NSWindowController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [StageItem] = []
    private let clearButton = NSButton()

    public init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 320),
                             styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.alphaValue = 0.01   // 始终在线，拖拽目标可被系统扫描到

        super.init(window: panel)
        setupUI()
        addVisualEffectView()
        // 预显示，确保系统已将其纳入拖拽目标列表
        panel.orderFront(nil)
    }

    required init?(coder: NSCoder) { nil }

    private func setupUI() {
        guard let panel = window else { return }

        // 清空按钮（右上角）
        clearButton.title = "清空"
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

        // tableView 注册拖入
        tableView.registerForDraggedTypes([
            .string, .fileURL, .tiff, .png,
            .init("public.jpeg"), .init("public.heic"),
            .init("NSFilenamesPboardType"), .init("NSPasteboardTypeFileURL"),
        ])

        // 窗口层也注册（保底，borderless 窗口不会被拖拽系统扫描）
        panel.registerForDraggedTypes([
            .string, .fileURL, .tiff, .png,
            .init("public.jpeg"), .init("public.heic"),
            .init("NSFilenamesPboardType"), .init("NSPasteboardTypeFileURL"),
        ])

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

    public func reload() {
        items = (try? StageManager.shared.all()) ?? []
        tableView.reloadData()
        clearButton.isHidden = items.isEmpty
    }

    public func positionAtBottomLeft() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = window?.frame.size ?? NSSize(width: 200, height: 320)
        let x = screenFrame.minX
        let y = screenFrame.minY
        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }

    public func show() {
        reload()
        positionAtBottomLeft()
        window?.alphaValue = 1.0
        window?.hasShadow = true
        window?.orderFront(nil)
    }

    public override func close() {
        window?.alphaValue = 0.01
        window?.hasShadow = false
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
        if items.isEmpty { close() }
    }

    @objc private func deleteItem(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        try? StageManager.shared.remove(item.id)
        reload()
        if items.isEmpty { close() }
    }
}

// MARK: - TableView

extension StageWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        cell.identifier = .init("StageCell")

        // 图标
        let icon = NSTextField(labelWithString: item.icon)
        icon.font = NSFont.systemFont(ofSize: 14)
        icon.translatesAutoresizingMaskIntoConstraints = false

        // 文本
        let label = NSTextField(labelWithString: item.displayText)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = NSColor.labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label

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

        cell.addSubview(icon)
        cell.addSubview(label)
        cell.addSubview(del)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 0),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            del.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: 0),
            del.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            del.widthAnchor.constraint(equalToConstant: 32),
        ])

        return cell
    }

    // MARK: - Drag into window

    public func tableView(_: NSTableView, validateDrop info: NSDraggingInfo, proposedRow _: Int, proposedDropOperation _: NSTableView.DropOperation) -> NSDragOperation {
        return .copy
    }

    public func tableView(_: NSTableView, acceptDrop info: NSDraggingInfo, row _: Int, dropOperation _: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        var added = false

        let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        for url in urls {
            let fileURL = url.standardizedFileURL
            if fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                try? StageManager.shared.add(fileURL: fileURL)
                added = true
            } else {
                try? StageManager.shared.add(url: url)
                added = true
            }
        }

        if !added {
            for type in [NSPasteboard.PasteboardType.tiff, .png, .init("public.jpeg"), .init("public.heic")] {
                if let data = pb.data(forType: type) {
                    try? StageManager.shared.add(imageData: data)
                    added = true
                    break
                }
            }
        }

        if !added, let str = pb.string(forType: .string) {
            try? StageManager.shared.add(text: str)
            added = true
        }

        if added {
            DispatchQueue.main.async { [weak self] in
                self?.reload()
            }
        }
        return added
    }

    // MARK: - Drag out of window

    public func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        guard let row = rowIndexes.first, row < items.count else { return false }
        let item = items[row]
        pboard.clearContents()

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
        case "image":
            pboard.setData(item.content, forType: .tiff)
        case "url":
            if let str = String(data: item.content, encoding: .utf8) {
                pboard.setString(str, forType: .string)
            }
        default:
            return false
        }

        // 拖出后删除
        try? StageManager.shared.remove(item.id)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.reload()
        }
        return true
    }
}
