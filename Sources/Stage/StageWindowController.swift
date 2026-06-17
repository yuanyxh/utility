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
            label.heightAnchor.constraint(equalToConstant: 16),

            del.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: 0),
            del.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            del.widthAnchor.constraint(equalToConstant: 32),
        ])

        return cell
    }

    // MARK: - Drag out of window (drag IN handled by StageDropMonitor via EventTap)

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
        case "fileGroup":
            let urls = item.resolveFileGroup()
            guard !urls.isEmpty else { return false }
            pboard.setPropertyList(urls.map(\.path), forType: .init("NSFilenamesPboardType"))
            if urls.count == 1 {
                pboard.setString(urls[0].absoluteString, forType: .fileURL)
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

        // 不在此删除 — 等 draggingSession:endedAt: 确认有效目标后再移除
        draggingItemId = item.id
        draggingItem = item
        return true
    }

    public func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { draggingItemId = nil; draggingItem = nil }
        guard operation != [] else { return }
        guard let item = draggingItem else { return }
        tryMoveOrRemove(item: item)
        reload()
        if items.isEmpty { close() }
    }

    // MARK: - Move on drag out

    private func tryMoveOrRemove(item: StageItem) {
        let config = ConfigManager.shared.config.stage
        guard config.moveOnDragOut else {
            try? StageManager.shared.remove(item.id)
            return
        }
        // 获取文件 URL 列表
        let fileURLs: [URL]
        switch item.type {
        case "fileURL":
            if let url = item.resolveFileURL() { fileURLs = [url] } else { return }
        case "fileGroup":
            fileURLs = item.resolveFileGroup()
        default:
            try? StageManager.shared.remove(item.id)
            return
        }
        guard !fileURLs.isEmpty else { return }

        // 备份目录
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let backupDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/utility/stage/\(formatter.string(from: Date()))")
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // 逐文件备份验证 → 移到废纸篓
        var backupOK = true
        for url in fileURLs {
            let dest = backupDir.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.copyItem(at: url, to: dest)
                let srcSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let dstSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard srcSize == dstSize else { backupOK = false; break }
            } catch {
                backupOK = false; break
            }
        }

        guard backupOK else { return }  // 备份失败，不删

        // 移入废纸篓
        for url in fileURLs {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }

        try? StageManager.shared.remove(item.id)

        // 日清过期备份（>1天）
        if let contents = try? fm.contentsOfDirectory(at: backupDir.deletingLastPathComponent(),
                                                       includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-86400)
            for dir in contents {
                if let attrs = try? dir.resourceValues(forKeys: [.contentModificationDateKey]),
                   let date = attrs.contentModificationDate, date < cutoff {
                    try? fm.removeItem(at: dir)
                }
            }
        }
    }
}
