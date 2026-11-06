import Cocoa

/// File list for git status, grouped into staged / unstaged / untracked.
@MainActor
final class GitPane: NSView, WorkspacePanel, NSTableViewDataSource, NSTableViewDelegate {
    let panelID = PanelID.gitList
    var focusTarget: NSView? { table }

    var onOpenDiff: ((GitFileStatus) -> Void)?
    var onCountChange: ((Int) -> Void)?
    var onToggleSection: ((GitSectionKind) -> Void)?
    var onRequestRefresh: (() -> Void)?

    private enum Row {
        case header(GitStatusSection)
        case file(GitFileStatus)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let refreshButton = PointerButton()
    private let scrollView = OverlayScrollView()
    private let table = PersistentSelectionTableView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private var repository = false
    private var sections: [GitStatusSection] = []
    private var collapsed: Set<GitSectionKind> = []
    private var rows: [Row] = []
    private var lastRendered: GitUIState?

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
        guard snapshot.git != lastRendered else { return }
        lastRendered = snapshot.git
        apply(snapshot.git)
    }

    // MARK: - UI

    private func setup() {
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = VSTheme.secondaryText
        titleLabel.stringValue = L10n.Workspace.gitPlaceholder
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = VSTheme.secondaryText
        countLabel.isHidden = true
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: nil,
        )
        refreshButton.isBordered = false
        refreshButton.contentTintColor = VSTheme.secondaryText
        refreshButton.toolTip = L10n.Workspace.gitRefresh
        refreshButton.target = self
        refreshButton.action = #selector(onRefresh)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("git"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 24
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.intercellSpacing = .zero
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(onRowClick)
        table.autoresizingMask = [.width]

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = VSTheme.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(refreshButton)
        addSubview(scrollView)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -6,
            ),

            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 18),
            refreshButton.heightAnchor.constraint(equalToConstant: 18),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
        ])
    }

    private func apply(_ state: GitUIState) {
        repository = state.isRepository
        collapsed = state.collapsed
        guard state.isRepository else {
            sections = []
            rows = []
            countLabel.isHidden = true
            onCountChange?(0)
            table.reloadData()
            emptyLabel.stringValue = L10n.Workspace.gitNotRepository
            emptyLabel.isHidden = false
            return
        }
        sections = GitStatusModel.sections(from: state.files)
        rebuildRows()
        countLabel.stringValue = state.files.count > 99 ? "99+" : "\(state.files.count)"
        countLabel.isHidden = state.files.isEmpty
        onCountChange?(state.files.count)
        emptyLabel.stringValue = L10n.Workspace.gitClean
        emptyLabel.isHidden = !rows.isEmpty
        applySelection(state.selectedPath)
    }

    private func applySelection(_ path: String?) {
        for (index, row) in rows.enumerated() {
            guard case .file(let status) = row, status.path == path else { continue }
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            return
        }
    }

    private func rebuildRows() {
        rows = sections.flatMap { section -> [Row] in
            if collapsed.contains(section.kind) { return [.header(section)] }
            return [.header(section)] + section.items.map { Row.file($0) }
        }
        table.reloadData()
    }

    @objc private func onRefresh() {
        onRequestRefresh?()
    }

    @objc private func onRowClick() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .header(let section):
            onToggleSection?(section.kind)
        case .file(let status):
            onOpenDiff?(status)
        }
    }

    @objc private func onLanguageChanged() {
        titleLabel.stringValue = L10n.Workspace.gitPlaceholder
        refreshButton.toolTip = L10n.Workspace.gitRefresh
        guard let state = lastRendered else { return }
        apply(state)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in _: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if rows.indices.contains(row), case .header = rows[row] { return nil }
        let identifier = NSUserInterfaceItemIdentifier("pointer-row")
        let rowView =
            tableView.makeView(withIdentifier: identifier, owner: self) as? PointerRowView
            ?? PointerRowView()
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let section):
            let cell = NSTableCellView()
            let chevron = NSImageView()
            chevron.image = NSImage(
                systemSymbolName: collapsed.contains(section.kind) ? "chevron.right" : "chevron.down",
                accessibilityDescription: nil,
            )
            chevron.contentTintColor = VSTheme.secondaryText
            chevron.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: section.title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = VSTheme.secondaryText
            label.translatesAutoresizingMaskIntoConstraints = false
            let count = NSTextField(labelWithString: "\(section.items.count)")
            count.font = .systemFont(ofSize: 11)
            count.textColor = VSTheme.secondaryText
            count.alignment = .right
            count.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(chevron)
            cell.addSubview(label)
            cell.addSubview(count)
            cell.textField = label
            NSLayoutConstraint.activate([
                chevron.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                chevron.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 12),
                chevron.heightAnchor.constraint(equalToConstant: 12),
                label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                count.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(
                    lessThanOrEqualTo: count.leadingAnchor, constant: -6,
                ),
            ])
            return cell
        case .file(let status):
            let cell = NSTableCellView()
            let code = NSTextField(
                labelWithString: status.code.trimmingCharacters(in: .whitespaces),
            )
            code.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            code.textColor = status.untracked ? VSTheme.secondaryText : VSTheme.syntaxNumber
            code.translatesAutoresizingMaskIntoConstraints = false
            let name = (status.path as NSString).lastPathComponent
            let path = NSTextField(labelWithString: name)
            path.font = .systemFont(ofSize: 12)
            path.textColor = VSTheme.text
            path.lineBreakMode = .byTruncatingMiddle
            path.toolTip = status.path
            path.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(code)
            cell.addSubview(path)
            cell.textField = path
            NSLayoutConstraint.activate([
                code.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 20),
                code.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                path.leadingAnchor.constraint(equalTo: code.trailingAnchor, constant: 5),
                path.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                path.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    func tableView(_: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .header = rows[row] { return true }
        return false
    }
}
