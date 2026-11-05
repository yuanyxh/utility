import Cocoa

/// Right pane: activity bar plus the workspace file tree. The content area stays a
/// placeholder until the editor lands.
@MainActor
final class FileExplorerPane: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onOpenFile: ((URL) -> Void)?

    var listWidth: CGFloat = 200 {
        didSet { listWidthConstraint?.constant = listWidth }
    }

    private let activityBar = WorkspaceActivityBar(frame: .zero)
    private let outline = FileOutlineView()
    private let scrollView = OverlayScrollView()
    private let separator = NSView()
    private let contentContainer = NSView()
    private let contentLabel = NSTextField(labelWithString: "")
    private let gitPane = GitPane()
    private let diffView = DiffView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private var listWidthConstraint: NSLayoutConstraint?

    private var contentView: NSView?
    private var model: FileTreeModel?
    private var roots: [FileNode] = []
    private var nodesByPath: [String: FileNode] = [:]
    private var currentRoot: URL?
    private var expansionByRoot: [String: Set<String>] = [:]
    private var pendingExpansion: Set<String> = []
    private var mode: WorkspaceActivityBar.Mode = .files
    private var treeTruncated = false
    private let watcher = FileTreeWatcher()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VSTheme.windowBackground.cgColor
        setup()
        watcher.onChange = { [weak self] paths in self?.handleChanges(paths) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
        onLanguageChanged()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: - Public

    func showContent(_ view: NSView?) {
        contentView?.removeFromSuperview()
        contentView = view
        contentLabel.isHidden = view != nil || mode == .git
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = mode == .git
        contentContainer.addSubview(view, positioned: .below, relativeTo: diffView)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    func reload(root: URL?) {
        guard root != currentRoot else { return }
        saveExpansion()
        currentRoot = root
        pendingExpansion =
            root.map {
                expansionByRoot[$0.standardizedFileURL.path] ?? []
            } ?? []
        diffView.clear()
        roots = []
        nodesByPath.removeAll()
        let config = ConfigManager.shared.config.workspace
        if let root {
            watcher.start(root: root, showHidden: config.showHiddenFiles)
        } else {
            watcher.stop()
        }
        outline.reloadData()
        emptyLabel.isHidden = true
        footerLabel.isHidden = true

        guard let root else {
            model = nil
            gitPane.reload(root: nil)
            diffView.clear()
            emptyLabel.stringValue = L10n.Workspace.treeEmpty
            emptyLabel.isHidden = false
            return
        }
        let model = FileTreeModel(
            root: root, showHidden: config.showHiddenFiles,
            extraIgnores: config.ignoredDirectories,
        )
        self.model = model
        gitPane.reload(root: root)
        model.loadRoot { [weak self] nodes, truncated in
            guard let self, self.model === model else { return }
            roots = merge(existing: roots, scanned: nodes)
            outline.reloadData()
            rebuildNodeIndex()
            emptyLabel.stringValue = L10n.Workspace.treeEmpty
            emptyLabel.isHidden = !nodes.isEmpty
            showTruncation(truncated)
            restoreExpansion()
        }
    }

    private func saveExpansion() {
        guard let root = currentRoot else { return }
        var set = Set<String>()
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? FileNode, node.isDirectory,
                outline.isItemExpanded(node),
                let relative = relativePath(of: node.url, root: root)
            else { continue }
            set.insert(relative)
        }
        expansionByRoot[root.standardizedFileURL.path] = set
    }

    /// Expands saved folders level by level; children load asynchronously, so
    /// deeper entries are picked up by the next pass. Each path is consumed once:
    /// a folder that cannot expand (empty directory) would otherwise keep the
    /// recursion alive and block the main thread.
    private func restoreExpansion() {
        guard !pendingExpansion.isEmpty, let root = currentRoot else { return }
        var targets: [(FileNode, String)] = []
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? FileNode, node.isDirectory,
                !outline.isItemExpanded(node),
                let relative = relativePath(of: node.url, root: root),
                pendingExpansion.contains(relative)
            else { continue }
            targets.append((node, relative))
        }
        guard !targets.isEmpty else { return }
        for (node, relative) in targets {
            pendingExpansion.remove(relative)
            outline.expandItem(node)
        }
        restoreExpansion()
    }

    // MARK: - UI

    private func setup() {
        activityBar.translatesAutoresizingMaskIntoConstraints = false
        activityBar.onSelect = { [weak self] mode in self?.apply(mode: mode) }

        let column = NSTableColumn(identifier: .init("file"))
        column.width = listWidth
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.headerView = nil
        outline.rowHeight = 26
        outline.indentationPerLevel = 14
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.intercellSpacing = .zero
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openClicked)
        outline.onRowClick = { [weak self] row in self?.handleRowClick(atRow: row) }
        outline.autoresizingMask = [.width]

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 16, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        separator.wantsLayer = true
        separator.layer?.backgroundColor = VSTheme.separator.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = VSTheme.windowBackground.cgColor
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        contentLabel.font = .systemFont(ofSize: 12)
        contentLabel.textColor = VSTheme.secondaryText
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(contentLabel)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = VSTheme.secondaryText
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = VSTheme.secondaryText
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.isHidden = true
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        gitPane.translatesAutoresizingMaskIntoConstraints = false
        gitPane.isHidden = true
        gitPane.onOpenDiff = { [weak self] status in self?.openDiff(status) }
        gitPane.onCountChange = { [weak self] count in self?.activityBar.setGitCount(count) }
        diffView.translatesAutoresizingMaskIntoConstraints = false
        diffView.isHidden = true
        contentContainer.addSubview(diffView)

        addSubview(activityBar)
        addSubview(scrollView)
        addSubview(gitPane)
        addSubview(separator)
        addSubview(contentContainer)
        addSubview(emptyLabel)
        addSubview(footerLabel)

        let widthConstraint = scrollView.widthAnchor.constraint(equalToConstant: listWidth)
        listWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            activityBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            activityBar.topAnchor.constraint(equalTo: topAnchor),
            activityBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            activityBar.widthAnchor.constraint(equalToConstant: 44),

            scrollView.leadingAnchor.constraint(equalTo: activityBar.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,

            gitPane.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            gitPane.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            gitPane.topAnchor.constraint(equalTo: topAnchor),
            gitPane.bottomAnchor.constraint(equalTo: bottomAnchor),

            diffView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            diffView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            diffView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            separator.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            contentLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.trailingAnchor, constant: -8,
            ),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            footerLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -8),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    private func apply(mode: WorkspaceActivityBar.Mode) {
        self.mode = mode
        let showGit = mode == .git
        scrollView.isHidden = showGit
        emptyLabel.isHidden = showGit || !roots.isEmpty
        footerLabel.isHidden = showGit || !treeTruncated
        gitPane.isHidden = !showGit
        contentView?.isHidden = showGit
        diffView.isHidden = !showGit
        contentLabel.isHidden = showGit || contentView != nil
        if showGit {
            gitPane.refresh()
        } else {
            diffView.clear()
        }
        updateContentLabel()
    }

    func refreshGitStatus() {
        gitPane.scheduleRefresh()
    }

    private func openDiff(_ status: GitFileStatus) {
        guard let root = currentRoot else { return }
        let service = GitService(root: root)
        Task { [weak self] in
            let diff =
                (try? await service.diff(path: status.path, untracked: status.untracked)) ?? ""
            guard let self else { return }
            if diff.isEmpty {
                self.diffView.showEmpty(L10n.Workspace.gitClean)
            } else {
                self.diffView.show(diff: diff, path: status.path)
            }
        }
    }

    private func updateContentLabel() {
        contentLabel.stringValue =
            mode == .files ? L10n.Workspace.editorPlaceholder : L10n.Workspace.gitPlaceholder
    }

    private func showTruncation(_ truncated: Bool) {
        treeTruncated = truncated
        footerLabel.isHidden = !truncated
        if truncated {
            footerLabel.stringValue = L10n.Workspace.treeTruncated(
                count: FileTreeScanner.directoryLimit,
            )
        }
    }

    @objc private func onLanguageChanged() {
        emptyLabel.stringValue = L10n.Workspace.treeEmpty
        updateContentLabel()
    }

    /// Document heights are managed by autoresizing; only the scroller needs
    /// a nudge after children load asynchronously.
    private func refreshTreeScroll() {
        let refresh = { [weak self] in
            guard let self else { return }
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
        refresh()
        DispatchQueue.main.async(execute: refresh)
    }

    private func handleRowClick(atRow row: Int) {
        guard let node = outline.item(atRow: row) as? FileNode else { return }
        guard node.isDirectory else {
            onOpenFile?(node.url)
            return
        }
        if outline.isItemExpanded(node) {
            outline.collapseItem(node)
        } else {
            outline.expandItem(node)
        }
    }

    @objc private func openClicked() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, !node.isDirectory else {
            return
        }
        onOpenFile?(node.url)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode, let children = node.children else {
            return roots[index]
        }
        return children[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory == true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(
        _ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any,
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("file-row")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        guard let node = item as? FileNode else { return cell }
        cell.textField?.stringValue = node.name
        let symbol = node.isDirectory ? "folder" : "doc"
        cell.imageView?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: node.name,
        )
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        loadChildrenIfNeeded(node)
    }

    private func loadChildrenIfNeeded(_ node: FileNode) {
        guard node.isDirectory, node.children == nil, !node.isLoading, let model else { return }
        model.loadChildren(of: node) { [weak self] nodes, truncated in
            guard let self, self.model === model else { return }
            node.isLoading = false
            node.children = self.merge(existing: node.children ?? [], scanned: nodes)
            node.truncated = truncated
            self.rebuildNodeIndex()
            self.outline.reloadItem(node, reloadChildren: true)
            self.refreshTreeScroll()
            self.restoreExpansion()
        }
    }

    // MARK: - File system changes

    private func handleChanges(_ paths: [String]) {
        guard let root = currentRoot else { return }
        var directories = Set<String>()
        for path in paths {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
                .standardizedFileURL.path
            directories.insert(directory)
        }
        for directory in directories.sorted(by: { $0.count < $1.count }) {
            reload(directory: URL(fileURLWithPath: directory), root: root)
        }
    }

    private func reload(directory: URL, root: URL) {
        guard let model else { return }
        let directoryPath = directory.standardizedFileURL.path
        if directoryPath == root.standardizedFileURL.path {
            model.loadRoot { [weak self] nodes, truncated in
                guard let self, self.model === model else { return }
                self.roots = self.merge(existing: self.roots, scanned: nodes)
                self.outline.reloadData()
                self.rebuildNodeIndex()
                self.showTruncation(truncated)
            }
            return
        }
        guard let relative = relativePath(of: directory, root: root),
            let node = nodesByPath[relative], node.isDirectory,
            node.children != nil, !node.isLoading
        else { return }
        model.loadChildren(of: node) { [weak self] nodes, truncated in
            guard let self, self.model === model else { return }
            node.isLoading = false
            node.children = self.merge(existing: node.children ?? [], scanned: nodes)
            node.truncated = truncated
            self.rebuildNodeIndex()
            self.outline.reloadItem(node, reloadChildren: true)
            self.refreshTreeScroll()
            self.showTruncation(truncated)
        }
    }

    /// Keeps existing nodes for unchanged paths so expansion state survives a rescan.
    private func merge(existing: [FileNode], scanned: [FileNode]) -> [FileNode] {
        var byPath: [String: FileNode] = [:]
        for node in existing {
            byPath[node.url.standardizedFileURL.path] = node
        }
        var merged: [FileNode] = []
        merged.reserveCapacity(scanned.count)
        for fresh in scanned {
            if let old = byPath[fresh.url.standardizedFileURL.path],
                old.isDirectory == fresh.isDirectory
            {
                merged.append(old)
            } else {
                merged.append(fresh)
            }
        }
        return merged
    }

    private func rebuildNodeIndex() {
        nodesByPath.removeAll(keepingCapacity: true)
        guard let rootPath = currentRoot?.standardizedFileURL.path else { return }
        visit(roots, rootPath: rootPath)
    }

    private func visit(_ nodes: [FileNode], rootPath: String) {
        for node in nodes {
            let path = node.url.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") {
                nodesByPath[String(path.dropFirst(rootPath.count + 1))] = node
            }
            if let children = node.children {
                visit(children, rootPath: rootPath)
            }
        }
    }

    private func relativePath(of url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyDown
        image.contentTintColor = VSTheme.secondaryText
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = VSTheme.text
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(label)
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

private final class FileOutlineView: NSOutlineView {
    var onRowClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hitRow = row(at: point)
        let disclosure = hitRow >= 0 ? frameOfOutlineCell(atRow: hitRow) : .zero
        let onDisclosure = !disclosure.isEmpty && disclosure.contains(point)
        super.mouseDown(with: event)
        guard hitRow >= 0, !onDisclosure else { return }
        onRowClick?(hitRow)
    }
}
