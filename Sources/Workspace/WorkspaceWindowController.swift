import Cocoa

/// Hosts the workspace list, the main terminal and the sub-terminal area.
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

    var wantsVisible = false {
        didSet { if wantsVisible { didApplyLayout = false } }
    }

    private let rootSplit = WorkspaceSplitView(isVertical: true, minimums: [180, 360, 320])
    private let sidebar = WorkspaceSidebarView(frame: .zero)
    private let mainHost = TerminalHostView(frame: .zero)
    private let subPane = SubTerminalPane(frame: .zero)
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
        let workspaceChanged = workspace?.id != lastWorkspaceID
        let subID = workspace?.selectedSubSessionID
        let subChanged = subID != lastSubSessionID
        lastSubSessionID = subID
        lastWorkspaceID = workspace?.id
        currentRoot = workspace.map { URL(fileURLWithPath: $0.path) }

        stateStore.update {
            $0.terminals.mainSessionID = state.mainSession?.id
            $0.terminals.sessions = state.subSessions
            $0.terminals.selectedSubSessionID = subID
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

    /// Fetches the branch for the status bar; the pane only renders the snapshot.
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

        sidebar.onSelect = { [weak self] id in self?.onSelectWorkspace?(id) }
        sidebar.onCreate = { [weak self] in self?.presentNewWorkspace() }
        sidebar.onRename = { [weak self] id, name in self?.onRenameWorkspace?(id, name) }
        sidebar.onRemove = { [weak self] id in self?.onRemoveWorkspace?(id) }

        subPane.onAdd = { [weak self] in self?.onAddSubSession?() }
        subPane.onSelect = { [weak self] id in self?.onSelectSubSession?(id) }
        subPane.onClose = { [weak self] id in self?.onCloseSubSession?(id) }

        panels = [mainHost, subPane]
        stateToken = stateStore.observe { [weak self] snapshot in
            guard let self else { return }
            for panel in self.panels { panel.render(snapshot) }
        }

        rootSplit.addSubview(sidebar)
        rootSplit.addSubview(mainHost)
        rootSplit.addSubview(subPane)
        // The main terminal absorbs resizes; side panes keep their width.
        rootSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        rootSplit.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        rootSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 2)

        contentView.addSubview(rootSplit)
        layoutSkeleton(contentView.bounds.size)
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
        let divider = rootSplit.dividerThickness

        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: height)
        mainHost.frame = NSRect(
            x: sidebarWidth + divider, y: 0,
            width: max(1, width - sidebarWidth - right - divider * 2), height: height,
        )
        subPane.frame = NSRect(x: width - right, y: 0, width: right, height: height)
    }

    private func applyLayoutIfNeeded(_ layout: WindowLayout) {
        guard !didApplyLayout, rootSplit.bounds.width > 100, rootSplit.bounds.height > 100 else {
            return
        }
        didApplyLayout = true
        isApplyingLayout = true
        defer { isApplyingLayout = false }

        let divider = rootSplit.dividerThickness
        rootSplit.setPosition(layout.sidebarWidth, ofDividerAt: 0)
        rootSplit.setPosition(
            rootSplit.bounds.width - layout.rightPaneWidth - divider, ofDividerAt: 1,
        )
    }

    private var currentLayout: WindowLayout {
        var layout = lastLayout
        if rootSplit.subviews.count >= 3 {
            layout.sidebarWidth = rootSplit.subviews[0].frame.width
            layout.rightPaneWidth = rootSplit.subviews[2].frame.width
        }
        return layout.clamped()
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
        if window?.isMiniaturized != true {
            scheduleRestoreCheck(after: 0.4)
        }
    }

    func windowDidBecomeKey(_: Notification) {
        let responder = window?.firstResponder.map { "\(type(of: $0))" } ?? "nil"
        debugLog("[Workspace] became key responder=\(responder)")
        refreshBranch()
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
