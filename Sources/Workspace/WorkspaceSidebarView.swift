import Cocoa

@MainActor
final class WorkspaceSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((String) -> Void)?
    var onCreate: (() -> Void)?
    var onRename: ((String, String) -> Void)?
    var onRemove: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let addButton = PointerButton()
    private let tableView = PersistentSelectionTableView()
    private let scrollView = OverlayScrollView()
    private var workspaces: [Workspace] = []
    private var selectedID: String?
    private var isUpdatingSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VSTheme.sidebarBackground.cgColor
        setup()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func reload(workspaces: [Workspace], selectedID: String?) {
        self.workspaces = workspaces
        self.selectedID = selectedID
        isUpdatingSelection = true
        tableView.reloadData()
        if let selectedID, let index = workspaces.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
        isUpdatingSelection = false
    }

    // MARK: - UI

    private func setup() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = VSTheme.text
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(
            systemSymbolName: "plus", accessibilityDescription: L10n.Workspace.create,
        )
        addButton.contentTintColor = VSTheme.text
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(newWorkspace)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("workspace"))
        column.width = 220
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.intercellSpacing = .zero
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(renameClicked)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(addButton)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            addButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            addButton.widthAnchor.constraint(equalToConstant: 20),
            addButton.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        onLanguageChanged()
    }

    @objc private func onLanguageChanged() {
        titleLabel.stringValue = L10n.Workspace.title
        addButton.toolTip = L10n.Workspace.create
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func newWorkspace() {
        onCreate?()
    }

    @objc private func renameClicked() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard workspaces.indices.contains(row) else { return }
        promptRename(workspaces[row])
    }

    @objc private func renameFromMenu() {
        guard workspaces.indices.contains(tableView.selectedRow) else { return }
        promptRename(workspaces[tableView.selectedRow])
    }

    @objc private func removeFromMenu() {
        guard workspaces.indices.contains(tableView.selectedRow) else { return }
        confirmRemove(workspaces[tableView.selectedRow])
    }

    private func promptRename(_ workspace: Workspace) {
        let alert = NSAlert()
        alert.messageText = L10n.Workspace.renameTitle
        alert.addButton(withTitle: L10n.Workspace.rename)
        alert.addButton(withTitle: L10n.Workspace.cancel)
        let field = NSTextField(string: workspace.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onRename?(workspace.id, name)
    }

    private func confirmRemove(_ workspace: Workspace) {
        let count = (workspace.mainSessionID == nil ? 0 : 1) + workspace.subSessionIDs.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Workspace.removeConfirmTitle
        alert.informativeText = L10n.Workspace.removeConfirmBody(count: count)
        alert.addButton(withTitle: L10n.Workspace.remove)
        alert.addButton(withTitle: L10n.Workspace.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onRemove?(workspace.id)
    }

    // MARK: - Context menu

    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        let rename = NSMenuItem(
            title: L10n.Workspace.rename, action: #selector(renameFromMenu), keyEquivalent: "",
        )
        rename.target = self
        menu.addItem(rename)
        let remove = NSMenuItem(
            title: L10n.Workspace.remove, action: #selector(removeFromMenu), keyEquivalent: "",
        )
        remove.target = self
        menu.addItem(remove)
        return menu
    }()

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: tableView.convert(point, from: self))
        guard row >= 0 else { return nil }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return contextMenu
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in _: NSTableView) -> Int {
        workspaces.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int,
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("workspace-row")
        let rowView =
            tableView.makeView(withIdentifier: identifier, owner: self)
            as? WorkspaceRowView ?? WorkspaceRowView()
        rowView.identifier = identifier
        rowView.configure(with: workspaces[row])
        return rowView
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        WorkspaceTableRowView()
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !isUpdatingSelection else { return }
        let row = tableView.selectedRow
        guard workspaces.indices.contains(row) else { return }
        onSelect?(workspaces[row].id)
    }
}

// MARK: - Row chrome

@MainActor
private final class WorkspaceTableRowView: PointerRowView {
    override func drawSelection(in _: NSRect) {
        let color =
            window?.isKeyWindow == true
            ? VSTheme.selectionActive : VSTheme.selectionInactive
        color.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 4, yRadius: 4,
        ).fill()
    }
}

@MainActor
private final class WorkspaceRowView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = VSTheme.text
        nameLabel.lineBreakMode = .byTruncatingTail
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = VSTheme.secondaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle

        for label in [nameLabel, pathLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func configure(with workspace: Workspace) {
        nameLabel.stringValue = workspace.name
        pathLabel.stringValue = workspace.path
        let exists = FileManager.default.fileExists(atPath: workspace.path)
        pathLabel.textColor = exists ? VSTheme.secondaryText : VSTheme.error
    }
}
