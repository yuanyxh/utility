import Cocoa

/// 剪切板快速粘贴面板
/// NSPanel + NSTableView
public final class ClipboardPanelController: NSWindowController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [ClipboardItem] = []
    private let storage: ClipboardStorage
    private var eventMonitor: Any?
    /// 面板打开前的前台 app（粘贴时恢复到该 app）
    private var previousFrontmostApp: NSRunningApplication?

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
        panel.collectionBehavior = [.transient, .ignoresCycle]

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
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .mini

        // 布局：顶部留 44px 给原生按钮
        let stack = NSStackView(views: [scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 8, bottom: 2, right: 8)
        panel.contentView = stack

        // 键盘事件
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isVisible == true else {
                return event
            }
            switch event.keyCode {
            case 36 where !event.modifierFlags.contains(.command): // return
                self.selectItem()
                return nil
            case 53: // esc
                self.close()
                return nil
            default:
                return event
            }
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

    @objc private func selectItem() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < items.count else { return }
        let item = items[tableView.selectedRow]
        try? storage.moveToTop(item.id)

        // 翻译面板打开 → 仅文本插入原文区
        if let trans = translationPanelIfVisible(),
           item.type == "text",
           let text = String(data: item.content, encoding: .utf8) {
            trans.insertText(text)
            close()
            return
        }

        paste(item: item)
        close()
    }

    private func translationPanelIfVisible() -> TranslationPanelController? {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        let panel = delegate.translationPanel
        return panel.isPanelVisible ? panel : nil
    }

    private func paste(item: ClipboardItem) {
        debugLog("[utility] clipboard paste: type=\(item.type) id=\(item.id)")

        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.type {
        case "text":
            guard let str = String(data: item.content, encoding: .utf8) else { return }
            pb.setString(str, forType: .string)
        case "file":
            guard let info = try? JSONDecoder().decode([String: String].self, from: item.content),
                  let path = info["path"] else { return }
            let url = URL(fileURLWithPath: path)
            let pbItem = NSPasteboardItem()
            pbItem.setString(url.absoluteString, forType: .fileURL)
            pb.writeObjects([pbItem])
        case "file_batch":
            guard let info = try? JSONDecoder().decode([String: [String]].self, from: item.content),
                  let paths = info["paths"] else { return }
            let pbItems: [NSPasteboardItem] = paths.compactMap { path in
                let url = URL(fileURLWithPath: path)
                let pbItem = NSPasteboardItem()
                pbItem.setString(url.absoluteString, forType: .fileURL)
                return pbItem
            }
            guard !pbItems.isEmpty else { return }
            pb.writeObjects(pbItems)
        case "html":
            guard let html = String(data: item.content, encoding: .utf8) else { return }
            pb.setString(html, forType: .html)
            // 同时写纯文本，让不支持富文本的目标也能粘贴
            if let plainText = item.application {
                pb.setString(plainText, forType: .string)
            }
        default:
            return
        }

        debugLog("[utility] clipboard paste: pasteboard written")

        guard let target = previousFrontmostApp ?? NSWorkspace.shared.frontmostApplication else {
            debugLog("[utility] clipboard paste: no target app")
            window?.orderOut(nil)
            NSApplication.shared.hide(nil)
            return
        }
        debugLog("[utility] clipboard paste: target PID=\(target.processIdentifier) bundle=\(target.bundleIdentifier ?? "nil")")

        window?.orderOut(nil)
        NSApplication.shared.hide(nil)
        debugLog("[utility] clipboard paste: hide done, frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")

        schedulePaste(to: target, logPrefix: "clipboard")
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
        case 125: // down — 下移选择
            let next = min(tableView.selectedRow + 1, items.count - 1)
            tableView.selectRowIndexes(.init(integer: max(next, 0)), byExtendingSelection: false)
            tableView.scrollRowToVisible(max(next, 0))
            return nil
        case 126: // up — 上移选择
            let prev = tableView.selectedRow - 1
            tableView.selectRowIndexes(.init(integer: max(prev, 0)), byExtendingSelection: false)
            tableView.scrollRowToVisible(max(prev, 0))
            return nil
        default:
            break
        }
        return event
    }

    // MARK: - Show / Close

    public func show() {
        items = (try? storage.all()) ?? []
        tableView.reloadData()

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

        // 清理过期的粘贴缓存文件（>1天）
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/utility/clip")
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.creationDateKey]) {
            let cutoff = Date().addingTimeInterval(-86400)
            for url in files {
                if let attrs = try? url.resourceValues(forKeys: [.creationDateKey]),
                   let date = attrs.creationDate, date < cutoff {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        // 记录当前前台 app，粘贴时恢复到它
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication

        window?.makeKeyAndOrderFront(nil)
        if !items.isEmpty {
            tableView.selectRowIndexes(.init(integer: 0), byExtendingSelection: false)
        }
    }

    public override func close() {
        window?.orderOut(nil)
        NSApplication.shared.hide(nil)
        items = []
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension ClipboardPanelController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("ClipboardCell")

        // 选中背景（cell 层绘制，替代 LighterSelectionRowView）
        let isSelected = tableView.isRowSelected(row)
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 4
        cell.layer?.backgroundColor = isSelected
            ? NSColor(red: 0xCB / 255, green: 0xCC / 255, blue: 0xCC / 255, alpha: 0.36).cgColor
            : NSColor.clear.cgColor

        // 序号圆圈
        let circleView = NumberCircleView()
        circleView.number = row + 1
        circleView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(circleView)

        // 文件图标（仅 file/file_batch/html 显示）
        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iconView)

        let showIcon: Bool
        switch item.type {
        case "file":
            iconView.image = Self.fileIcon(for: item.content)
            showIcon = true
        case "file_batch":
            iconView.image = NSWorkspace.shared.icon(forFileType: "public.folder")
            showIcon = true
        case "html":
            iconView.image = NSWorkspace.shared.icon(forFileType: "public.html")
            showIcon = true
        default:
            iconView.isHidden = true
            showIcon = false
        }

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
        cell.textField = label
        cell.addSubview(label)

        if showIcon {
            NSLayoutConstraint.activate([
                circleView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                circleView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                circleView.widthAnchor.constraint(equalToConstant: 16),
                circleView.heightAnchor.constraint(equalToConstant: 16),

                iconView.leadingAnchor.constraint(equalTo: circleView.trailingAnchor, constant: 4),
                iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),

                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -1),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.heightAnchor.constraint(equalToConstant: 16),
            ])
        } else {
            NSLayoutConstraint.activate([
                circleView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                circleView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                circleView.widthAnchor.constraint(equalToConstant: 16),
                circleView.heightAnchor.constraint(equalToConstant: 16),

                label.leadingAnchor.constraint(equalTo: circleView.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -1),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.heightAnchor.constraint(equalToConstant: 16),
            ])
        }

        circleView.isHighlighted = isSelected

        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTableView else { return }
        tv.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? NSTableCellView else { return }
            let selected = tv.isRowSelected(row)
            cell.layer?.backgroundColor = selected
                ? NSColor(red: 0xCB / 255, green: 0xCC / 255, blue: 0xCC / 255, alpha: 0.36).cgColor
                : NSColor.clear.cgColor
            for sub in cell.subviews {
                if let circle = sub as? NumberCircleView {
                    circle.isHighlighted = selected
                }
            }
        }
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 32 }

    private func displayText(for item: ClipboardItem) -> String {
        switch item.type {
        case "text":
            return String(data: item.content, encoding: .utf8) ?? "(不可读)"
        case "file":
            return item.application ?? "文件"
        case "file_batch":
            if let json = try? JSONDecoder().decode([String: [String]].self, from: item.content),
               let paths = json["paths"] {
                return "\(paths.count) 个文件"
            }
            return "文件"
        case "html":
            // 显示纯文本摘要
            if let text = item.application, !text.isEmpty {
                let line = text.prefix(80).replacingOccurrences(of: "\n", with: " ")
                return String(line)
            }
            return "网页内容"
        default:
            return "(未知)"
        }
    }
}

// MARK: - Image helpers

private extension ClipboardPanelController {
    /// 从 JSON 编码的文件路径获取文件图标
    static func fileIcon(for content: Data) -> NSImage? {
        guard let dict = try? JSONDecoder().decode([String: String].self, from: content),
              let path = dict["path"] else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

// MARK: - Number Circle View

private final class NumberCircleView: NSView {
    var number: Int = 0 {
        didSet {
            if number >= 100 {
                numberLabel.isHidden = true
            } else {
                numberLabel.isHidden = false
                numberLabel.stringValue = "\(number)"
            }
        }
    }
    var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    private let numberLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 8)
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

        // 外层实心圆
        let path = NSBezierPath(ovalIn: circleRect)
        let fillColor: NSColor = isHighlighted
            ? NSColor(red: 0x34 / 255, green: 0x78 / 255, blue: 0xF6 / 255, alpha: 1.0)
            : NSColor(red: 0xA4 / 255, green: 0xA4 / 255, blue: 0xA4 / 255, alpha: 1.0)
        fillColor.setFill()
        path.fill()

        // >=100：中心白色圆点
        if number >= 100 {
            let dotD: CGFloat = 6
            let dotRect = CGRect(
                x: (bounds.width - dotD) / 2,
                y: (bounds.height - dotD) / 2,
                width: dotD,
                height: dotD
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }
}
