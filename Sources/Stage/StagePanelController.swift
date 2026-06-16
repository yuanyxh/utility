import Cocoa

/// 暂存查看面板
/// 列表显示所有暂存项目，可点击查看详情或重新拖出
public final class StagePanelController: NSWindowController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [StageItem] = []

    public init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
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

        let col = NSTableColumn(identifier: .init("item"))
        col.title = "暂存项目"
        col.minWidth = 360
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.target = self
        tableView.doubleAction = #selector(openItem)
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        // 标题
        let titleLabel = NSTextField(labelWithString: "拖拽文件/文本到菜单栏图标即可暂存")
        titleLabel.font = NSFont.systemFont(ofSize: 11)
        titleLabel.textColor = NSColor.secondaryLabelColor
        titleLabel.alignment = .center

        let stack = NSStackView(views: [titleLabel, scrollView])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        panel.contentView = stack
    }

    @objc private func openItem() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < items.count else { return }
        let item = items[tableView.selectedRow]

        if item.type == "fileURL", let url = item.resolveFileURL() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if item.type == "text", let str = String(data: item.content, encoding: .utf8) {
            // 复制到剪切板
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(str, forType: .string)
        }
    }

    public func show() {
        items = (try? StageManager.shared.all()) ?? []
        tableView.reloadData()

        let mouse = NSEvent.mouseLocation
        var frame = window?.frame ?? .zero
        frame.origin.x = mouse.x - 200
        frame.origin.y = mouse.y - frame.height + 30
        window?.setFrame(frame, display: true)

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

extension StagePanelController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let text: String
        if item.type == "fileURL", let url = item.resolveFileURL() {
            text = "📁 \(url.lastPathComponent)"
        } else if item.type == "text" {
            let str = String(data: item.content, encoding: .utf8) ?? ""
            text = str.prefix(80) + (str.count > 80 ? "…" : "")
        } else {
            text = "(未知)"
        }

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: 12)
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
}
