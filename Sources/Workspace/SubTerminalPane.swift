import Cocoa

/// Bottom pane: the selected sub-terminal on the left and a vertical session list on the right.
@MainActor
final class SubTerminalPane: NSView, WorkspacePanel, NSTableViewDataSource, NSTableViewDelegate {
    let panelID = PanelID.subTerminals
    var focusTarget: NSView? { currentView }

    var onAdd: (() -> Void)?
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    private let headerLabel = NSTextField(labelWithString: "")
    private let addButton = PointerButton()
    private let listContainer = NSView()
    private let separator = NSView()
    private let contentContainer = NSView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let tableView = PersistentSelectionTableView()
    private let scrollView = OverlayScrollView()
    private let statusBar = WorkspaceStatusBar()

    private var sessions: [WorkspaceSessionSummary] = []
    private var lastRendered: TerminalUIState?
    private var currentView: NSView?
    private var isUpdatingSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VSTheme.windowBackground.cgColor
        setup()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
    }

    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: - WorkspacePanel

    func render(_ snapshot: WorkspaceSnapshot) {
        guard snapshot.terminals != lastRendered else { return }
        lastRendered = snapshot.terminals
        apply(snapshot.terminals)
    }

    private func apply(_ state: TerminalUIState) {
        sessions = state.sessions
        isUpdatingSelection = true
        tableView.reloadData()
        if let id = state.selectedSubSessionID,
            let index = sessions.firstIndex(where: { $0.id == id })
        {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isUpdatingSelection = false
        if currentView == nil {
            emptyLabel.isHidden = !sessions.isEmpty
        }
        statusBar.setBranch(state.branch)
    }

    // MARK: - Public

    func attach(_ view: NSView) {
        emptyLabel.isHidden = true
        guard currentView !== view else { return }
        currentView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -6),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 6),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -6),
        ])
        currentView = view
    }

    func detach() {
        currentView?.removeFromSuperview()
        currentView = nil
        emptyLabel.isHidden = !sessions.isEmpty
    }

    // MARK: - UI

    private func setup() {
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = VSTheme.text
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(
            systemSymbolName: "plus", accessibilityDescription: L10n.Workspace.subNew,
        )
        addButton.contentTintColor = VSTheme.text
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(addSession)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        listContainer.wantsLayer = true
        listContainer.layer?.backgroundColor = VSTheme.sidebarBackground.cgColor
        listContainer.translatesAutoresizingMaskIntoConstraints = false

        separator.wantsLayer = true
        separator.layer?.backgroundColor = VSTheme.separator.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.stringValue = L10n.Workspace.subEmpty
        emptyLabel.textColor = VSTheme.secondaryText
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(emptyLabel)

        let column = NSTableColumn(identifier: .init("sub-session"))
        column.width = 180
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.intercellSpacing = .zero
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.autoresizingMask = [.width]

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        listContainer.addSubview(headerLabel)
        listContainer.addSubview(addButton)
        listContainer.addSubview(scrollView)

        statusBar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentContainer)
        addSubview(separator)
        addSubview(listContainer)
        addSubview(statusBar)

        NSLayoutConstraint.activate([
            listContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            listContainer.topAnchor.constraint(equalTo: topAnchor),
            listContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            listContainer.widthAnchor.constraint(equalToConstant: 180),

            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: WorkspaceStatusBar.height),

            headerLabel.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 10),
            headerLabel.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 8),
            headerLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: addButton.leadingAnchor, constant: -6,
            ),

            addButton.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 18),
            addButton.heightAnchor.constraint(equalToConstant: 18),

            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

            separator.trailingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: separator.leadingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
        ])
        onLanguageChanged()
    }

    @objc private func onLanguageChanged() {
        headerLabel.stringValue = L10n.Terminal.title
        addButton.toolTip = L10n.Workspace.subNew
        emptyLabel.stringValue = L10n.Workspace.subEmpty
        tableView.reloadData()
    }

    @objc private func addSession() {
        onAdd?()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in _: NSTableView) -> Int {
        sessions.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int,
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("sub-session-row")
        let rowView =
            tableView.makeView(withIdentifier: identifier, owner: self)
            as? SubSessionRowView ?? SubSessionRowView()
        rowView.identifier = identifier
        let session = sessions[row]
        rowView.configure(with: session)
        rowView.onClose = { [weak self] in self?.onClose?(session.id) }
        return rowView
    }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("pointer-row")
        let row =
            tableView.makeView(withIdentifier: identifier, owner: self) as? PointerRowView
            ?? PointerRowView()
        row.identifier = identifier
        return row
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !isUpdatingSelection else { return }
        let row = tableView.selectedRow
        guard sessions.indices.contains(row) else { return }
        onSelect?(sessions[row].id)
    }
}

// MARK: - Row

@MainActor
private final class SubSessionRowView: NSTableCellView {
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let cwdLabel = NSTextField(labelWithString: "")
    private let closeButton = PointerButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = VSTheme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        cwdLabel.font = .systemFont(ofSize: 10)
        cwdLabel.textColor = VSTheme.secondaryText
        cwdLabel.lineBreakMode = .byTruncatingMiddle

        for label in [titleLabel, cwdLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

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
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6,
            ),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            cwdLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            cwdLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6,
            ),
            cwdLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func configure(with session: WorkspaceSessionSummary) {
        titleLabel.stringValue = session.title
        cwdLabel.stringValue = session.cwd
        closeButton.toolTip = L10n.Terminal.close
    }

    @objc private func closeTapped() {
        onClose?()
    }
}
