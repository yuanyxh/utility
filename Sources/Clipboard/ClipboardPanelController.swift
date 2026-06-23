import Cocoa
import UniformTypeIdentifiers

/// 剪切板快速粘贴面板
/// NSPanel + NSTableView
public final class ClipboardPanelController: NSWindowController {
  private let tableView = NSTableView()
  private let scrollView = NSScrollView()
  private var items: [ClipboardItem] = []
  private let clipboardStorage = ClipboardStorage()
  private lazy var clipboardWatcher = ClipboardWatcher(storage: clipboardStorage)

  public init() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 312, height: 380),
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
    clipboardWatcher.start()

    EventBus.shared.subscribe(AppEvent.configDidLoad) { [weak self] _ in
      self?.clipboardWatcher.stop()
      self?.clipboardWatcher.start()
    }
  }

  required init?(coder _: NSCoder) {
    nil
  }

  deinit {
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
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
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

    // 键盘事件 — 统一由 KeyDispatcher → handleKeyEvent 派发
  }

  /// 面板是否可见
  var isPanelVisible: Bool {
    window?.isVisible ?? false
  }

  // MARK: - Actions

  @objc private func selectItem() {
    guard tableView.selectedRow >= 0, tableView.selectedRow < items.count else { return }
    let item = items[tableView.selectedRow]
    try? clipboardStorage.moveToTop(item.id)

    paste(item: item)
    EventBus.shared.publish(PanelEvent.requestPaste, payload: self)
  }

  // MARK: - Paste

  private func paste(item: ClipboardItem) {
    let pb = NSPasteboard.general
    pb.clearContents()

    switch item.type {
    case "text":
      guard let str = String(data: item.content, encoding: .utf8) else { return }
      pb.setString(str, forType: .string)
    case "file":
      guard let info = try? JSONDecoder().decode([String: String].self, from: item.content),
        let path = info["path"]
      else { return }
      let url = URL(fileURLWithPath: path)
      let pbItem = NSPasteboardItem()
      pbItem.setString(url.absoluteString, forType: .fileURL)
      pb.writeObjects([pbItem])
    case "file_batch":
      guard let info = try? JSONDecoder().decode([String: [String]].self, from: item.content),
        let paths = info["paths"]
      else { return }
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
      if let plainText = item.application {
        pb.setString(plainText, forType: .string)
      }
    default:
      return
    }

    clipboardWatcher.skipCurrentChange()
  }

  // MARK: - Show / Close

  public func show() {
    items = (try? clipboardStorage.all()) ?? []
    tableView.reloadData()

    // 智能定位：根据鼠标位置选择最佳角落
    let panelSize = window?.frame.size ?? NSSize(width: 360, height: 380)
    let origin = WindowPositioning.nearMouseQuadrant(
      windowSize: panelSize,
      padding: 12,
      screen: window?.screen
    )
    window?.setFrameOrigin(origin)

    // 清理过期的粘贴缓存文件（>1天）
    let cacheDir = AppPaths.clipCacheDir
    if let files = try? FileManager.default.contentsOfDirectory(
      at: cacheDir, includingPropertiesForKeys: [.creationDateKey])
    {
      let cutoff = Date().addingTimeInterval(-86400)
      for url in files {
        if let attrs = try? url.resourceValues(forKeys: [.creationDateKey]),
          let date = attrs.creationDate, date < cutoff
        {
          try? FileManager.default.removeItem(at: url)
        }
      }
    }

    window?.makeKeyAndOrderFront(nil)
    if !items.isEmpty {
      tableView.selectRowIndexes(.init(integer: 0), byExtendingSelection: false)
    }
  }

  override public func close() {
    items = []
    tableView.reloadData()
    EventBus.shared.publish(PanelEvent.requestClose, payload: self)
  }
}

// MARK: - NSTableViewDataSource / Delegate

extension ClipboardPanelController: NSTableViewDataSource, NSTableViewDelegate {
  public func numberOfRows(in _: NSTableView) -> Int {
    items.count
  }

  public func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
    let item = items[row]
    let showIcon = item.type == "file" || item.type == "file_batch" || item.type == "html"
    let identifier = NSUserInterfaceItemIdentifier(showIcon ? "ClipboardIcon" : "ClipboardText")

    if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ClipboardCell {
      cell.showIcon = showIcon
      let isSelected = tableView.isRowSelected(row)
      cell.layer?.backgroundColor = isSelected ? Self.selBG : Self.clearBG
      updateCell(cell, item: item, row: row, isSelected: isSelected)
      return cell
    }

    let cell = ClipboardCell()
    cell.identifier = identifier
    cell.showIcon = showIcon
    cell.wantsLayer = true
    cell.layer?.cornerRadius = 4
    let isSelected = tableView.isRowSelected(row)
    cell.layer?.backgroundColor = isSelected ? Self.selBG : Self.clearBG

    let circleView = NumberCircleView(frame: .zero)
    cell.addSubview(circleView)

    let iconView = NSImageView(frame: .zero)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    cell.addSubview(iconView)

    let label = NSTextField(frame: .zero)
    label.isEditable = false
    label.isBordered = false
    label.drawsBackground = false
    label.lineBreakMode = .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
    label.cell?.usesSingleLineMode = true
    label.maximumNumberOfLines = 1
    label.font = NSFont.systemFont(ofSize: 13)
    label.textColor = NSColor(red: 0x33 / 255, green: 0x33 / 255, blue: 0x33 / 255, alpha: 1.0)
    cell.textField = label
    cell.addSubview(label)

    updateCell(cell, item: item, row: row, isSelected: isSelected)
    return cell
  }

  private func updateCell(_ cell: NSTableCellView, item: ClipboardItem, row: Int, isSelected: Bool)
  {
    // 圆圈
    if let circle = cell.subviews.first(where: { $0 is NumberCircleView }) as? NumberCircleView {
      circle.number = row + 1
      circle.isHighlighted = isSelected
    }
    // 图标
    if let icon = cell.subviews.first(where: { $0 is NSImageView }) as? NSImageView {
      switch item.type {
      case "file": icon.image = Self.fileIcon(for: item.content)
      case "file_batch": icon.image = NSWorkspace.shared.icon(for: .folder)
      case "html": icon.image = NSWorkspace.shared.icon(for: .html)
      default: break
      }
    }
    // 文本
    cell.textField?.stringValue = displayText(for: item)
  }

  public func tableViewSelectionDidChange(_ notification: Notification) {
    guard let tv = notification.object as? NSTableView else { return }
    tv.enumerateAvailableRowViews { rowView, row in
      guard let cell = rowView.view(atColumn: 0) as? NSTableCellView else { return }
      let selected = tv.isRowSelected(row)
      cell.layer?.backgroundColor = selected ? Self.selBG : Self.clearBG
      for sub in cell.subviews {
        if let circle = sub as? NumberCircleView {
          circle.isHighlighted = selected
        }
      }
    }
  }

  public func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
    32
  }

  private func displayText(for item: ClipboardItem) -> String {
    switch item.type {
    case "text":
      return String(data: item.content, encoding: .utf8) ?? L10n.Clipboard.unreadable
    case "file":
      return item.application ?? L10n.Clipboard.file
    case "file_batch":
      if let json = try? JSONDecoder().decode([String: [String]].self, from: item.content),
        let paths = json["paths"]
      {
        return L10n.Clipboard.fileCount(paths.count)
      }
      return L10n.Clipboard.file
    case "html":
      if let text = item.application, !text.isEmpty {
        let line = text.prefix(80).replacingOccurrences(of: "\n", with: " ")
        return String(line)
      }
      return L10n.Clipboard.webContent
    default:
      return L10n.Clipboard.unknown
    }
  }

  // 缓存颜色，避免每帧创建 NSColor
  private static let selBG = NSColor(
    red: 0xCB / 255, green: 0xCC / 255, blue: 0xCC / 255, alpha: 0.36
  ).cgColor
  private static let clearBG = NSColor.clear.cgColor
}

// MARK: - Clipboard Cell (frame layout, no Auto Layout)

private final class ClipboardCell: NSTableCellView {
  var showIcon = false

  override func layout() {
    super.layout()
    let w = bounds.width
    for sub in subviews {
      if sub is NumberCircleView {
        sub.frame = NSRect(x: 6, y: 8, width: 16, height: 16)
      } else if sub is NSImageView {
        sub.isHidden = !showIcon
        sub.frame = NSRect(x: 26, y: 8, width: 16, height: 16)
      } else if sub is NSTextField {
        let labelX: CGFloat = showIcon ? 46 : 28
        sub.frame = NSRect(x: labelX, y: 8, width: max(w - labelX - 4, 0), height: 16)
      }
    }
  }
}

// MARK: - Image helpers

extension ClipboardPanelController {
  /// 从 JSON 编码的文件路径获取文件图标
  fileprivate static func fileIcon(for content: Data) -> NSImage? {
    guard let dict = try? JSONDecoder().decode([String: String].self, from: content),
      let path = dict["path"]
    else { return nil }
    return NSWorkspace.shared.icon(forFile: path)
  }
}

// MARK: - Number Circle View

private final class NumberCircleView: NSView {
  var number: Int = 0 {
    didSet {
      let over99 = number >= 100
      numberLabel.alphaValue = over99 ? 0 : 1
      whiteDot.alphaValue = over99 ? 1 : 0
      if !over99 { numberLabel.stringValue = "\(number)" }
    }
  }

  var isHighlighted = false {
    didSet {
      layer?.backgroundColor = isHighlighted ? Self.hlColor : Self.noColor
    }
  }

  private static let hlColor = NSColor(
    red: 0x34 / 255, green: 0x78 / 255, blue: 0xF6 / 255, alpha: 1.0
  ).cgColor
  private static let noColor = NSColor(
    red: 0xA4 / 255, green: 0xA4 / 255, blue: 0xA4 / 255, alpha: 1.0
  ).cgColor

  private let numberLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = NSFont.systemFont(ofSize: 8)
    label.textColor = .white
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let whiteDot: NSView = {
    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.backgroundColor = NSColor.white.cgColor
    dot.layer?.cornerRadius = 3
    dot.alphaValue = 0
    dot.translatesAutoresizingMaskIntoConstraints = false
    return dot
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.masksToBounds = true
    layer?.backgroundColor = Self.noColor

    addSubview(numberLabel)
    addSubview(whiteDot)
    NSLayoutConstraint.activate([
      numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      whiteDot.centerXAnchor.constraint(equalTo: centerXAnchor),
      whiteDot.centerYAnchor.constraint(equalTo: centerYAnchor),
      whiteDot.widthAnchor.constraint(equalToConstant: 6),
      whiteDot.heightAnchor.constraint(equalToConstant: 6),
    ])
  }

  required init?(coder _: NSCoder) {
    nil
  }
}

// MARK: - PanelProtocol

extension ClipboardPanelController: PanelProtocol {
  var panelID: String { "clipboard" }
  var panelWindow: NSWindow? { window }

  func showPanel(context: [String: Any]?) { show() }

  func closePanel() {
    window?.orderOut(nil)
    items = []
    tableView.reloadData()
  }

  func handleKeyEvent(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 {
      EventBus.shared.publish(PanelEvent.requestClose, payload: self)
      return true
    }
    if event.keyCode == 36, !event.modifierFlags.contains(.command) {
      selectItem()
      return true
    }
    return false
  }
}
