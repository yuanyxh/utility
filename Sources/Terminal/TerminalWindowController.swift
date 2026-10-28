import Cocoa

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate
{
    var onNew: (() -> Void)?
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onActivate: (() -> Void)?

    private let tableView = NSTableView()
    private let terminalContainer = NSView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let plusButton = NSButton()
    private var sessions: [TerminalSession] = []
    private var selectedID: String?
    private var currentView: NSView?
    private var isUpdatingSelection = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false,
        )
        window.title = L10n.Terminal.title
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = VSTheme.windowBackground
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        AppWindowRegistry.register(window)
        window.delegate = self
        setupUI()
        if !window.setFrameAutosaveName("utility.terminal-window") {
            window.center()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
    }

    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: - Public

    func reload(sessions: [TerminalSession], selectedID: String?) {
        self.sessions = sessions
        self.selectedID = selectedID
        isUpdatingSelection = true
        tableView.reloadData()
        if let selectedID,
           let index = sessions.firstIndex(where: { $0.id == selectedID })
        {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
        isUpdatingSelection = false
        if sessions.isEmpty {
            showEmptyState()
        }
    }

    func reloadRow(session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: index),
            columnIndexes: IndexSet(integer: 0),
        )
    }

    /// Size a session view gets inside the container (10pt padding per side).
    var terminalContentSize: NSSize {
        let bounds = terminalContainer.bounds
        return NSSize(width: max(1, bounds.width - 20), height: max(1, bounds.height - 20))
    }

    func showTerminal(_ view: NSView) {
        emptyLabel.isHidden = true
        guard currentView !== view else {
            window?.makeFirstResponder(view)
            return
        }
        currentView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor, constant: 10),
            view.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor, constant: -10),
            view.topAnchor.constraint(equalTo: terminalContainer.topAnchor, constant: 10),
            view.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor, constant: -10),
        ])
        currentView = view
        window?.makeFirstResponder(view)
    }

    func showEmptyState() {
        currentView?.removeFromSuperview()
        currentView = nil
        emptyLabel.isHidden = false
    }

    func focusTerminal(sessionID: String) {
        guard selectedID == sessionID, let currentView else { return }
        window?.makeFirstResponder(currentView)
    }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = VSTheme.windowBackground.cgColor

        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = VSTheme.sidebarBackground.cgColor

        plusButton.image = NSImage(
            systemSymbolName: "plus", accessibilityDescription: L10n.Terminal.new,
        )
        plusButton.contentTintColor = VSTheme.text
        plusButton.isBordered = false
        plusButton.target = self
        plusButton.action = #selector(newSession)
        plusButton.toolTip = L10n.Terminal.new
        plusButton.translatesAutoresizingMaskIntoConstraints = false

        let headerTitle = NSTextField(labelWithString: L10n.Terminal.title)
        headerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        headerTitle.textColor = VSTheme.text
        headerTitle.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("terminal"))
        column.width = 220
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 58
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let listScroll = NSScrollView()
        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(plusButton)
        sidebar.addSubview(headerTitle)
        sidebar.addSubview(listScroll)

        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = VSTheme.windowBackground.cgColor
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.stringValue = L10n.Terminal.empty
        emptyLabel.textColor = VSTheme.secondaryText
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(emptyLabel)

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = VSTheme.separator.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(sidebar)
        contentView.addSubview(separator)
        contentView.addSubview(terminalContainer)

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),

            plusButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            plusButton.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),
            plusButton.widthAnchor.constraint(equalToConstant: 20),
            plusButton.heightAnchor.constraint(equalToConstant: 20),

            headerTitle.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 6),
            headerTitle.centerYAnchor.constraint(equalTo: plusButton.centerYAnchor),

            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: plusButton.bottomAnchor, constant: 8),
            listScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: contentView.topAnchor),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            terminalContainer.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            terminalContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: terminalContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: terminalContainer.centerYAnchor),
        ])
    }

    @objc private func newSession() {
        onNew?()
    }

    @objc private func onLanguageChanged() {
        window?.title = L10n.Terminal.title
        plusButton.toolTip = L10n.Terminal.new
        emptyLabel.stringValue = L10n.Terminal.empty
        tableView.reloadData()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_: Notification) {
        onActivate?()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in _: NSTableView) -> Int {
        sessions.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int,
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("terminal-row")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: self)
            as? TerminalSessionRowView ?? TerminalSessionRowView()
        rowView.identifier = identifier
        let session = sessions[row]
        rowView.configure(with: session)
        rowView.onClose = { [weak self] in
            self?.onClose?(session.id)
        }
        return rowView
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        TerminalTableRowView()
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !isUpdatingSelection else { return }
        let row = tableView.selectedRow
        guard sessions.indices.contains(row) else { return }
        onSelect?(sessions[row].id)
    }
}

// MARK: - Row chrome

@MainActor
private final class TerminalTableRowView: NSTableRowView {
    override func drawSelection(in _: NSRect) {
        let color = window?.isKeyWindow == true
            ? VSTheme.selectionActive : VSTheme.selectionInactive
        color.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 4, yRadius: 4,
        ).fill()
    }
}

// MARK: - Row

@MainActor
private final class TerminalSessionRowView: NSTableCellView {
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badge = TerminalUnreadBadge()
    private let closeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func configure(with session: TerminalSession) {
        titleLabel.stringValue = session.title
        subtitleLabel.stringValue = session.cwd
        badge.count = session.unread
        closeButton.toolTip = L10n.Terminal.close
    }

    private func setup() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = VSTheme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = VSTheme.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        for label in [titleLabel, subtitleLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: L10n.Terminal.close,
        )
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.contentTintColor = VSTheme.secondaryText
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -6),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            badge.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 16),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

// MARK: - Unread badge

@MainActor
private final class TerminalUnreadBadge: NSView {
    var count: Int = 0 {
        didSet {
            isHidden = count == 0
            label.stringValue = count > 99 ? "99+" : "\(count)"
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VSTheme.badge.cgColor
        layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let width = max(16, label.intrinsicContentSize.width + 10)
        return NSSize(width: width, height: 16)
    }
}
