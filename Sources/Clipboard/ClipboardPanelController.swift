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
        paste(item: item)
        close()
    }

    private func paste(item: ClipboardItem) {
        // 先把内容写入粘贴板
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.type {
        case "text":
            guard let str = String(data: item.content, encoding: .utf8) else { return }
            pb.setString(str, forType: .string)
        case "file":
            pb.setData(item.content, forType: .fileURL)
        case "image":
            // 解码格式信息（新格式：dict；旧格式：raw data 兜底）
            let format: String
            let imageData: Data
            if let dict = try? NSKeyedUnarchiver.unarchiveObject(with: item.content) as? [String: Any],
               let fmt = dict["format"] as? String,
               let dat = dict["data"] as? Data {
                format = fmt
                imageData = dat
            } else {
                format = "public.tiff"
                imageData = item.content
            }
            let ext = Self.extensionForUTI(format)
            let cacheDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/utility/clip")
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let cacheFile = cacheDir
                .appendingPathComponent("clip_\(Int(Date().timeIntervalSince1970)).\(ext)")
            try? imageData.write(to: cacheFile)
            let pbItem = NSPasteboardItem()
            pbItem.setData(imageData, forType: .init(format))
            pbItem.setString(cacheFile.absoluteString, forType: .fileURL)
            pbItem.setPropertyList([cacheFile.path], forType: .init("NSFilenamesPboardType"))
            pb.writeObjects([pbItem])
        case "image_batch":
            guard let dicts = try? NSKeyedUnarchiver.unarchiveObject(with: item.content) as? [[String: Any]] else { return }
            let cacheDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/utility/clip")
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let now = Int(Date().timeIntervalSince1970)
            let pbItems: [NSPasteboardItem] = dicts.enumerated().compactMap { (i, dict) in
                guard let format = dict["format"] as? String,
                      let data = dict["data"] as? Data else { return nil }
                let ext = Self.extensionForUTI(format)
                let cacheFile = cacheDir
                    .appendingPathComponent("clip_\(now)_\(i).\(ext)")
                try? data.write(to: cacheFile)
                let pbItem = NSPasteboardItem()
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(format))
                pbItem.setString(cacheFile.absoluteString, forType: .fileURL)
                pbItem.setPropertyList([cacheFile.path], forType: .init("NSFilenamesPboardType"))
                return pbItem
            }
            guard !pbItems.isEmpty else { return }
            pb.writeObjects(pbItems)
        default:
            return
        }

        // 隐藏面板，直接激活目标 app（不走 hide(nil)，LSUIElement 可能不触发目标激活）
        guard let target = previousFrontmostApp ?? NSWorkspace.shared.frontmostApplication else {
            window?.orderOut(nil)
            return
        }

        window?.orderOut(nil)
        target.activate(options: .activateIgnoringOtherApps)

        // 两路并进：AX 轮询（主流 app）+ didActivate（Electron 等不暴露 AX 的 app）
        var didPaste = false
        let pasteNow = {
            guard !didPaste else { return }
            didPaste = true
            let source = CGEventSource(stateID: .combinedSessionState)
            guard let kd = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let ku = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
            kd.flags = .maskCommand
            ku.flags = .maskCommand
            kd.post(tap: .cghidEventTap)
            ku.post(tap: .cghidEventTap)
        }

        // 路 1: didActivateApplicationNotification 兜底
        var notifToken: NSObjectProtocol?
        notifToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == target.processIdentifier else { return }
            if let token = notifToken { NSWorkspace.shared.notificationCenter.removeObserver(token); notifToken = nil }
            pasteNow()
        }

        // 路 2: AX 焦点轮询
        var attempts = 0
        func pollFocus(for app: NSRunningApplication) {
            attempts += 1
            guard attempts < 150 else {
                // AX 超时，清理通知观察者
                if let token = notifToken { NSWorkspace.shared.notificationCenter.removeObserver(token); notifToken = nil }
                return
            }
            let appRef = AXUIElementCreateApplication(app.processIdentifier)
            var focused: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focused)
            if result == .success, focused != nil {
                if let token = notifToken { NSWorkspace.shared.notificationCenter.removeObserver(token); notifToken = nil }
                pasteNow()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
                pollFocus(for: app)
            }
        }
        pollFocus(for: target)
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
        items = []
        tableView.reloadData()
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
        let cell = NSTableCellView()
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
        cell.textField = label
        cell.addSubview(label)

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
            return "📄 \(item.application ?? "图片")"
        case "image_batch":
            if let dicts = try? NSKeyedUnarchiver.unarchiveObject(with: item.content) as? [[String: Any]] {
                return "📁 \(dicts.count) 个文件"
            }
            return "📁 文件"
        default:
            return "(未知)"
        }
    }
}

// MARK: - Image helpers

private extension ClipboardPanelController {
    static func extensionForUTI(_ uti: String) -> String {
        switch uti {
        case "public.png": return "png"
        case "public.jpeg": return "jpg"
        case "public.tiff": return "tiff"
        case "public.heic": return "heic"
        case "com.compuserve.gif": return "gif"
        case "public.webp": return "webp"
        case "public.bmp": return "bmp"
        default: return "png"
        }
    }
}

// MARK: - Lighter Selection Row View

private final class LighterSelectionRowView: NSTableRowView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) { nil }

    override var isSelected: Bool {
        didSet {
            enumerateCircleViews(in: self) { $0.isHighlighted = isSelected }
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(red: 0xCB / 255, green: 0xCC / 255, blue: 0xCC / 255, alpha: 0.36).setFill()
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
