import Cocoa

/// Hosts the four-pane workspace layout. The file pane starts as a placeholder;
/// later tasks replace it without changing the window lifecycle.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate,
    NSSplitViewDelegate, WorkspaceManagerObserving
{
    var onSelectWorkspace: ((String) -> Void)?
    var onCreateWorkspace: ((String) -> Void)?
    var onRenameWorkspace: ((String, String) -> Void)?
    var onRemoveWorkspace: ((String) -> Void)?
    var onAddSubSession: (() -> Void)?
    var onSelectSubSession: ((String) -> Void)?
    var onCloseSubSession: ((String) -> Void)?
    var onLayoutChanged: ((WindowLayout) -> Void)?
    var onFileOpened: ((String?) -> Void)?
    var onUIStateChanged: ((WorkspaceUIState) -> Void)?

    var wantsVisible = false {
        didSet { if wantsVisible { didApplyLayout = false } }
    }

    private let rootSplit = WorkspaceSplitView(isVertical: true, minimums: [180, 360, 525])
    private let rightSplit = WorkspaceSplitView(isVertical: false, minimums: [120, 260])
    private let sidebar = WorkspaceSidebarView(frame: .zero)
    private let mainHost = TerminalHostView(frame: .zero)
    private let filePane = FileExplorerPane(frame: .zero)
    private let subPane = SubTerminalPane(frame: .zero)
    private let editor = FileEditorPane(frame: .zero)
    private let stateStore = WorkspaceStateStore()
    private var panels: [WorkspacePanel] = []
    private var stateToken: UUID?
    private var currentRoot: URL?
    private var lastWorkspaceID: String?
    private var lastSubSessionID: String?
    private var branchGeneration = 0

    private var lastLayout = WindowLayout()
    private var didApplyLayout = false
    private var isApplyingLayout = false
    private var layoutWorkItem: DispatchWorkItem?
    private var uiPersistWorkItem: DispatchWorkItem?
    private var lastPersistedUI: WorkspaceUIState?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false,
        )
        window.title = L10n.Terminal.title
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = VSTheme.windowBackground
        window.minSize = NSSize(width: 1120, height: 680)
        window.isReleasedWhenClosed = false
        // An accessory app must keep its window on screen without focus.
        window.hidesOnDeactivate = false
        // Clicking a menu-bar item activates that app; keep this window above its windows.
        window.level = ConfigManager.shared.config.terminal.alwaysOnTop ? .floating : .normal

        super.init(window: window)
        AppWindowRegistry.register(window)
        window.delegate = self
        rootSplit.delegate = self
        rightSplit.delegate = self
        setupUI()
        if !window.setFrameAutosaveName("utility.terminal-window") {
            window.center()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(didResignActive),
            name: NSApplication.didResignActiveNotification, object: nil,
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil,
        )
        onLanguageChanged()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: - Public

    var terminalContentSize: NSSize {
        mainHost.terminalContentSize
    }

    func reload(state: WorkspaceState) {
        guard let contentView = window?.contentView else { return }
        lastLayout = state.document.layout
        if rootSplit.frame.size != contentView.bounds.size {
            layoutSkeleton(contentView.bounds.size)
        }
        applyLayoutIfNeeded(lastLayout)

        sidebar.reload(workspaces: state.workspaces, selectedID: state.selectedWorkspaceID)

        let workspace = state.selectedWorkspace
        let rootURL = workspace.map { URL(fileURLWithPath: $0.path) }
        let workspaceChanged = workspace?.id != lastWorkspaceID
        let subID = workspace?.selectedSubSessionID
        let subChanged = subID != lastSubSessionID
        lastSubSessionID = subID
        currentRoot = rootURL
        if workspaceChanged {
            lastWorkspaceID = workspace?.id
            editor.close()
            let restoredUI = workspace?.ui ?? WorkspaceUIState()
            stateStore.update {
                $0.editor = EditorUIState()
                $0.ui = restoredUI
                $0.fileTree.root = rootURL
                $0.fileTree.ignoredPaths = []
                $0.git = GitUIState()
                $0.terminals.branch = nil
            }
            if let workspace, let rootURL, let relative = workspace.lastOpenedRelativePath {
                let url = rootURL.appendingPathComponent(relative)
                editor.open(
                    url: url, root: rootURL, focus: false,
                    position: (restoredUI.caretLocation, restoredUI.scrollY),
                )
                stateStore.update {
                    $0.editor.url = url
                    $0.fileTree.selectedPath = relative
                }
            }
            refreshGitStatus()
        } else {
            stateStore.update { $0.fileTree.root = rootURL }
        }

        stateStore.update {
            $0.terminals.mainSessionID = state.mainSession?.id
            $0.terminals.sessions = state.subSessions
            $0.terminals.selectedSubSessionID = workspace?.selectedSubSessionID
        }
        if workspaceChanged {
            refreshBranch()
        }

        if let view = state.mainView {
            mainHost.attach(view)
        } else {
            mainHost.detach()
        }

        if let view = state.subView {
            subPane.attach(view)
        } else {
            subPane.detach()
        }

        if workspaceChanged {
            mainHost.focus()
        } else if subChanged {
            focus(.subTerminals)
        }
    }

    private func focus(_ panel: PanelID) {
        guard let target = panels.first(where: { $0.panelID == panel })?.focusTarget else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(target)
        }
    }

    /// Fetches the branch for the status bar; the panel only renders the snapshot.
    private func refreshBranch() {
        branchGeneration += 1
        let generation = branchGeneration
        guard let root = currentRoot else {
            stateStore.update { $0.terminals.branch = nil }
            return
        }
        Task { [weak self] in
            let branch = await GitService(root: root).branch()
            guard let self, self.branchGeneration == generation else { return }
            stateStore.update { $0.terminals.branch = branch }
        }
    }

    func showEmptyState(message: String? = nil) {
        mainHost.showEmptyState(message: message)
    }

    func focusTerminalIfNeeded() {
        guard let view = mainHost.terminalView else { return }
        window?.makeFirstResponder(view)
    }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = VSTheme.windowBackground.cgColor

        filePane.showContent(editor)
        filePane.onOpenFile = { [weak self] url in self?.openFile(url) }
        filePane.onModeChange = { [weak self] mode in
            guard let self else { return }
            stateStore.update { $0.ui.activeList = mode }
            if mode == .git { refreshGitStatus() }
        }
        filePane.gitPane.onRequestRefresh = { [weak self] in self?.refreshGitStatus() }
        filePane.gitPane.onToggleSection = { [weak self] kind in
            self?.stateStore.update { snapshot in
                if snapshot.git.collapsed.contains(kind) {
                    snapshot.git.collapsed.remove(kind)
                } else {
                    snapshot.git.collapsed.insert(kind)
                }
            }
        }
        filePane.gitPane.onOpenDiff = { [weak self] status in
            self?.stateStore.update { $0.git.selectedPath = status.path }
            self?.filePane.showDiff(status)
        }
        filePane.onExpandedPathsChange = { [weak self] paths in
            self?.stateStore.update { $0.ui.expandedPaths = paths }
        }
        filePane.onFileSystemChange = { [weak self] root in self?.refreshGitStatus(for: root) }
        editor.onDidSave = { [weak self] in self?.refreshGitStatus() }
        editor.onDirtyChange = { [weak self] dirty in
            self?.stateStore.update { $0.editor.isDirty = dirty }
        }
        editor.onExternalChange = { [weak self] change in
            self?.stateStore.update { $0.editor.externalChange = change }
        }
        editor.onPreviewModeChange = { [weak self] mode in
            self?.stateStore.update { $0.ui.previewMode = mode }
        }
        editor.onPositionChange = { [weak self] caret, scrollY in
            self?.stateStore.update { snapshot in
                snapshot.ui.caretLocation = caret
                snapshot.ui.scrollY = scrollY
            }
        }
        GitStatusProvider.shared.onUpdate = { [weak self] root, result in
            guard let self, root.standardizedFileURL == self.currentRoot?.standardizedFileURL
            else { return }
            self.stateStore.update { $0.fileTree.ignoredPaths = result.ignoredPaths }
        }

        sidebar.onSelect = { [weak self] id in self?.onSelectWorkspace?(id) }
        sidebar.onCreate = { [weak self] in self?.presentNewWorkspace() }
        sidebar.onRename = { [weak self] id, name in self?.onRenameWorkspace?(id, name) }
        sidebar.onRemove = { [weak self] id in self?.onRemoveWorkspace?(id) }

        subPane.onAdd = { [weak self] in self?.onAddSubSession?() }
        subPane.onSelect = { [weak self] id in self?.onSelectSubSession?(id) }
        subPane.onClose = { [weak self] id in self?.onCloseSubSession?(id) }

        panels = [mainHost, subPane, filePane, filePane.gitPane, editor]
        stateToken = stateStore.observe { [weak self] snapshot in
            guard let self else { return }
            for panel in self.panels { panel.render(snapshot) }
            scheduleUIPersist(snapshot.ui)
        }

        rootSplit.addSubview(sidebar)
        rootSplit.addSubview(mainHost)
        rootSplit.addSubview(rightSplit)
        // The main terminal absorbs resizes; side panes keep their width.
        rootSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        rootSplit.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        rootSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        // A non-vertical NSSplitView stacks subviews top-down in insertion order.
        rightSplit.addSubview(filePane)
        rightSplit.addSubview(subPane)

        contentView.addSubview(rootSplit)
        layoutSkeleton(contentView.bounds.size)
    }

    private func openFile(_ url: URL) {
        guard let root = currentRoot else { return }
        guard editor.confirmClose() else { return }
        editor.open(url: url, root: root)
        let relative = relativePath(for: url)
        stateStore.update {
            $0.fileTree.selectedPath = relative
            $0.editor.url = url
        }
        onFileOpened?(relative)
    }

    /// Re-queries git status after a save, a tab switch or a file-system change burst.
    private func refreshGitStatus(for root: URL? = nil) {
        guard let root = root ?? currentRoot else {
            stateStore.update {
                $0.git = GitUIState()
                $0.fileTree.ignoredPaths = []
            }
            return
        }
        GitStatusProvider.shared.invalidate(root: root)
        Task { [weak self] in
            let result = await GitStatusProvider.shared.result(for: root)
            guard let self, root.standardizedFileURL == self.currentRoot?.standardizedFileURL
            else { return }
            stateStore.update { snapshot in
                snapshot.git.root = root
                snapshot.git.isRepository = result.isRepository
                snapshot.git.files = result.files
                snapshot.fileTree.ignoredPaths = result.ignoredPaths
            }
        }
    }

    private func relativePath(for url: URL) -> String? {
        guard let root = currentRoot else { return nil }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// Called before switching workspaces or quitting; false aborts the operation.
    func confirmEditorClose() -> Bool {
        editor.confirmClose()
    }

    /// Offers crash drafts one at a time; the first restore wins and the rest stay queued.
    func presentDraftRecovery(_ drafts: [EditorDraft]) {
        let store = EditorDraftStore()
        for draft in drafts {
            var pending = true
            while pending {
                let alert = NSAlert()
                alert.messageText = L10n.Workspace.draftTitle
                alert.informativeText = L10n.Workspace.draftBody(
                    name: draft.fileURL.lastPathComponent,
                )
                alert.addButton(withTitle: L10n.Workspace.draftRestore)
                alert.addButton(withTitle: L10n.Workspace.draftDiscard)
                alert.addButton(withTitle: L10n.Workspace.draftCompare)
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    editor.restore(draft, root: currentRoot)
                    let relative = relativePath(for: draft.fileURL)
                    stateStore.update {
                        $0.editor.url = draft.fileURL
                        $0.fileTree.selectedPath = relative
                    }
                    onFileOpened?(relative)
                    pending = false
                    return
                case .alertSecondButtonReturn:
                    store.delete(draft)
                    pending = false
                default:
                    presentDraftComparison(draft)
                }
            }
        }
    }

    private func presentDraftComparison(_ draft: EditorDraft) {
        let maxBytes =
            max(1, ConfigManager.shared.config.workspace.maxFileSizeMB) * 1024 * 1024
        let diskText: String
        if case .text(let fresh) = FileDocument.load(url: draft.fileURL, maxBytes: maxBytes) {
            diskText = fresh.text
        } else {
            diskText = ""
        }
        EditorDraftDiffWindow.present(
            title: L10n.Workspace.draftCompare, name: draft.fileURL.lastPathComponent,
            diskText: diskText, localText: draft.text,
        )
    }

    private func presentNewWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onCreateWorkspace?(url.path)
    }

    private func layoutSkeleton(_ size: NSSize) {
        let width = max(size.width, window?.minSize.width ?? 1120)
        let height = max(size.height, window?.minSize.height ?? 680)
        guard rootSplit.frame.size != NSSize(width: width, height: height) else { return }
        rootSplit.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))

        let sidebarWidth = lastLayout.sidebarWidth
        let right = lastLayout.rightPaneWidth
        let sub = lastLayout.subTerminalHeight
        let divider = rootSplit.dividerThickness

        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: height)
        mainHost.frame = NSRect(
            x: sidebarWidth + divider, y: 0,
            width: max(1, width - sidebarWidth - right - divider * 2), height: height,
        )
        rightSplit.frame = NSRect(x: width - right, y: 0, width: right, height: height)
        filePane.frame = NSRect(
            x: 0, y: sub + divider, width: right, height: max(1, height - sub - divider),
        )
        subPane.frame = NSRect(x: 0, y: 0, width: right, height: sub)
    }

    private func applyLayoutIfNeeded(_ layout: WindowLayout) {
        guard !didApplyLayout, rootSplit.bounds.width > 100, rootSplit.bounds.height > 100 else {
            return
        }
        didApplyLayout = true
        isApplyingLayout = true
        defer { isApplyingLayout = false }

        filePane.listWidth = layout.fileListWidth
        let divider = rootSplit.dividerThickness
        rootSplit.setPosition(layout.sidebarWidth, ofDividerAt: 0)
        rootSplit.setPosition(
            rootSplit.bounds.width - layout.rightPaneWidth - divider, ofDividerAt: 1,
        )
        rightSplit.setPosition(
            rightSplit.bounds.height - layout.subTerminalHeight - divider,
            ofDividerAt: 0,
        )
    }

    private var currentLayout: WindowLayout {
        var layout = lastLayout
        if rootSplit.subviews.count >= 3 {
            layout.sidebarWidth = rootSplit.subviews[0].frame.width
            layout.rightPaneWidth = rootSplit.subviews[2].frame.width
        }
        if rightSplit.subviews.count >= 2 {
            layout.subTerminalHeight = rightSplit.subviews[1].frame.height
        }
        layout.fileListWidth = filePane.listWidth
        return layout.clamped()
    }

    /// Persists the UI state after a short quiet period; focus loss flushes it.
    private func scheduleUIPersist(_ ui: WorkspaceUIState) {
        guard ui != lastPersistedUI else { return }
        lastPersistedUI = ui
        uiPersistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.uiPersistWorkItem = nil
            self?.onUIStateChanged?(ui)
        }
        uiPersistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func flushUIPersist() {
        uiPersistWorkItem?.cancel()
        uiPersistWorkItem = nil
        onUIStateChanged?(stateStore.snapshot.ui)
    }

    /// Called before switching workspaces or quitting so the pending debounce is not lost.
    func persistUIStateNow() {
        flushUIPersist()
    }

    private func scheduleLayoutPersist() {
        layoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let layout = currentLayout
            lastLayout = layout
            onLayoutChanged?(layout)
        }
        layoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - WorkspaceManagerObserving

    func workspaceStateDidChange(_ manager: WorkspaceManager) {
        reload(state: manager.state)
    }

    // MARK: - NSSplitViewDelegate

    func splitViewDidResizeSubviews(_: Notification) {
        guard !isApplyingLayout else { return }
        scheduleLayoutPersist()
    }

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat,
        ofSubviewAt dividerIndex: Int,
    ) -> CGFloat {
        (splitView as? WorkspaceSplitView)?.constrainedMin(proposed, at: dividerIndex)
            ?? proposed
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat,
        ofSubviewAt dividerIndex: Int,
    ) -> CGFloat {
        (splitView as? WorkspaceSplitView)?.constrainedMax(proposed, at: dividerIndex)
            ?? proposed
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        debugLog("[Workspace] window closed by user")
        wantsVisible = false
        sender.orderOut(nil)
        AppActivation.setMainWindowActive(false)
        return false
    }

    func windowDidResignKey(_: Notification) {
        let newKey = NSApp.keyWindow.map { "\(type(of: $0)) '\($0.title)'" } ?? "nil"
        debugLog(
            "[Workspace] resigned key visible=\(window?.isVisible == true) appHidden=\(NSApp.isHidden) active=\(NSApp.isActive) newKey=\(newKey)",
        )
        flushUIPersist()
        if window?.isMiniaturized != true {
            scheduleRestoreCheck(after: 0.4)
        }
    }

    func windowDidBecomeKey(_: Notification) {
        let responder = window?.firstResponder.map { "\(type(of: $0))" } ?? "nil"
        debugLog("[Workspace] became key responder=\(responder)")
        editor.checkExternalChange()
        refreshBranch()
    }

    @objc private func didBecomeActive() {
        editor.checkExternalChange()
    }

    @objc private func didResignActive() {
        // A regular app hides its windows on Cmd+H; restoring would undo that.
        guard NSApp.activationPolicy() == .accessory else { return }
        scheduleRestoreCheck(after: 0.3)
        scheduleRestoreCheck(after: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let front = NSWorkspace.shared.frontmostApplication
            debugLog(
                "[Workspace] app deactivated frontmost=\(front?.localizedName ?? "nil") bundle=\(front?.bundleIdentifier ?? "nil")",
            )
        }
    }

    /// A miniaturized window reports `isVisible == false`; restoring it would undo Cmd+M.
    private func scheduleRestoreCheck(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard NSApp.activationPolicy() == .accessory else { return }
            guard let self, wantsVisible, let window else { return }
            guard !window.isMiniaturized else { return }
            guard !window.isVisible || NSApp.isHidden else { return }
            debugLog(
                "[Workspace] restoring after focus loss isVisible=\(window.isVisible) appHidden=\(NSApp.isHidden)",
            )
            NSApp.unhideWithoutActivation()
            window.orderFront(nil)
        }
    }

    // MARK: - Localization

    @objc private func onLanguageChanged() {
        window?.title = L10n.Terminal.title
        mainHost.refreshLocalizedText()
    }
}
