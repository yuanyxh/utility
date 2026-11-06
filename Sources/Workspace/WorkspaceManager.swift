import Cocoa

@MainActor
protocol WorkspaceManagerObserving: AnyObject {
    func workspaceStateDidChange(_ manager: WorkspaceManager)
}

struct WorkspaceSessionSummary: Equatable {
    let id: String
    let title: String
    let cwd: String
    let role: TerminalRole
}

struct WorkspaceState {
    let document: WorkspaceDocument
    let sessions: [WorkspaceSessionSummary]
    let mountedMainID: String?
    let mountedSubID: String?
    let mainView: NSView?
    let subView: NSView?

    var workspaces: [Workspace] { document.workspaces }
    var selectedWorkspaceID: String? { document.selectedWorkspaceID }

    var selectedWorkspace: Workspace? {
        document.workspaces.first { $0.id == document.selectedWorkspaceID }
    }

    var mainSession: WorkspaceSessionSummary? {
        sessions.first { $0.role == .main }
    }

    var subSessions: [WorkspaceSessionSummary] {
        sessions.filter { $0.role == .sub }
    }
}

/// Owns workspace documents, tmux session lifetime and persistence.
///
/// Only the selected workspace keeps SwiftTerm clients attached; the others stay as
/// ids in `workspaces.json` so the tmux sessions survive without running views.
@MainActor
final class WorkspaceManager {
    static let shared = WorkspaceManager()

    weak var observer: WorkspaceManagerObserving?

    /// Supplies the size a fresh terminal view gets before the pty starts.
    var viewSize: () -> NSSize = { NSSize(width: 760, height: 520) }
    var isWindowVisible: () -> Bool = { false }
    var isWindowFocused: () -> Bool = { false }

    private(set) var document = WorkspaceDocument()
    private(set) var mountedSessions: [TerminalSession] = []

    private let store = WorkspaceStore()
    private let sessionStore = TerminalSessionStore()
    private var windowController: WorkspaceWindowController?
    private var backend: TmuxBackend?
    private var storedByID: [String: StoredTerminalSession] = [:]
    private var didLoad = false
    private var didRestore = false
    private var isShuttingDown = false
    private var didReportMissingTmux = false
    private var didOfferDrafts = false
    private var pathTimer: Timer?
    /// Some prompts emit the same notification twice; keep one banner per burst.
    private var lastNotification: (sessionID: String, at: Date)?

    private var config: TerminalConfig {
        ConfigManager.shared.config.terminal
    }

    private init() {
        EventBus.shared.subscribe(AppEvent.terminalOpenSession) { [weak self] payload in
            guard let id = payload as? String else { return }
            Task { @MainActor in self?.reveal(sessionID: id) }
        }
    }

    // MARK: - State

    var state: WorkspaceState {
        ensureLoaded()
        var summaries: [WorkspaceSessionSummary] = []
        if let workspace = selectedWorkspace {
            if let main = workspace.mainSessionID {
                summaries.append(summary(id: main, role: .main, workspace: workspace))
            }
            for sub in workspace.subSessionIDs {
                summaries.append(summary(id: sub, role: .sub, workspace: workspace))
            }
        }
        return WorkspaceState(
            document: document,
            sessions: summaries,
            mountedMainID: mountedMainSession?.id,
            mountedSubID: mountedSubSession?.id,
            mainView: mountedMainSession?.view,
            subView: mountedSubSession?.view,
        )
    }

    func mainTerminalView() -> NSView? {
        mountedMainSession?.view
    }

    func subTerminalView(sessionID: String) -> NSView? {
        mountedSession(id: sessionID)?.view
    }

    // MARK: - Lifecycle

    func restoreIfNeeded() {
        ensureLoaded()
        guard !didRestore else { return }
        guard config.restoreSessions else {
            didRestore = true
            notifyObserver()
            return
        }
        // Leave didRestore false so a later call retries once tmux is available.
        guard let backend = resolvedBackend() else { return }
        let plan = WorkspaceRestorePlan(document: document, liveIDs: backend.liveIDs())
        apply(plan)
        didRestore = true
        persist()
        mountSelectedWorkspace()
    }

    func shutdown() {
        guard didLoad else { return }
        windowController?.persistUIStateNow()
        isShuttingDown = true
        persist()
        detachMountedSessions()
    }

    // MARK: - Window

    func showWindow() {
        AppActivation.setMainWindowActive(true)
        let controller = ensureWindow()
        controller.wantsVisible = true
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.layoutIfNeeded()
        restoreIfNeeded()
        if state.mainSession == nil, TmuxBackend.isAvailable() {
            mountSelectedWorkspace()
        }
        controller.reload(state: state)
        presentPendingDraftsIfNeeded()
        if state.mainSession == nil, !TmuxBackend.isAvailable() {
            controller.showEmptyState(message: L10n.Terminal.tmuxMissingBody)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.focusTerminalIfNeeded()
    }

    func confirmTermination() -> Bool {
        windowController?.confirmEditorClose() ?? true
    }

    private func presentPendingDraftsIfNeeded() {
        guard !didOfferDrafts else { return }
        didOfferDrafts = true
        let drafts = EditorDraftStore().loadAll()
        guard !drafts.isEmpty else { return }
        debugLog("[Workspace] offering drafts count=\(drafts.count)")
        windowController?.presentDraftRecovery(drafts)
    }

    func toggleWindow() {
        let controller = ensureWindow()
        guard let window = controller.window else { return }
        if window.isVisible, window.isKeyWindow {
            controller.wantsVisible = false
            debugLog(
                "[Workspace] window hidden by hotkey responder=\(String(describing: window.firstResponder))",
            )
            window.orderOut(nil)
            AppActivation.setMainWindowActive(false)
        } else {
            showWindow()
        }
    }

    private func ensureWindow() -> WorkspaceWindowController {
        if let windowController { return windowController }
        let controller = WorkspaceWindowController()
        controller.onSelectWorkspace = { [weak self] id in self?.selectWorkspace(id: id) }
        controller.onCreateWorkspace = { [weak self] path in
            _ = self?.createWorkspace(path: path)
        }
        controller.onRenameWorkspace = { [weak self] id, name in
            _ = self?.renameWorkspace(id: id, name: name)
        }
        controller.onRemoveWorkspace = { [weak self] id in self?.removeWorkspace(id: id) }
        controller.onAddSubSession = { [weak self] in _ = self?.addSubSession() }
        controller.onSelectSubSession = { [weak self] id in self?.selectSubSession(id: id) }
        controller.onCloseSubSession = { [weak self] id in self?.closeSubSession(id: id) }
        controller.onLayoutChanged = { [weak self] layout in self?.updateLayout(layout) }
        controller.onUIStateChanged = { [weak self] ui in self?.updateUIState(ui) }
        controller.onFileOpened = { [weak self] relative in
            self?.setLastOpened(relativePath: relative)
        }
        controller.window?.layoutIfNeeded()
        observer = controller
        viewSize = { [weak controller] in
            controller?.terminalContentSize ?? NSSize(width: 760, height: 520)
        }
        isWindowVisible = { [weak controller] in controller?.window?.isVisible == true }
        isWindowFocused = { [weak controller] in
            guard NSApplication.shared.isActive else { return false }
            return controller?.window?.isVisible == true
        }
        windowController = controller
        return controller
    }

    // MARK: - Workspace CRUD

    @discardableResult
    func createWorkspace(path: String) -> Workspace? {
        ensureLoaded()
        guard confirmTermination() else { return nil }
        let standardized = Workspace.standardizedPath(path)
        guard !document.workspaces.contains(where: { $0.path == standardized }) else {
            debugLog("[Workspace] duplicate path rejected path=\(standardized)")
            notify(title: L10n.Workspace.create, body: L10n.Workspace.duplicatePath)
            return nil
        }
        let name = (standardized as NSString).lastPathComponent
        let workspace = Workspace(
            id: Workspace.identifier(forPath: standardized),
            name: name.isEmpty ? standardized : name,
            path: standardized,
        )
        document.workspaces.append(workspace)
        document.selectedWorkspaceID = workspace.id
        persist()
        mountSelectedWorkspace()
        return workspace
    }

    @discardableResult
    func renameWorkspace(id: String, name: String) -> Bool {
        ensureLoaded()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let index = document.workspaces.firstIndex(where: { $0.id == id })
        else { return false }
        document.workspaces[index].name = trimmed
        persist()
        notifyObserver()
        return true
    }

    func removeWorkspace(id: String) {
        ensureLoaded()
        guard let workspace = document.workspaces.first(where: { $0.id == id }) else { return }
        guard confirmTermination() else { return }
        windowController?.persistUIStateNow()
        detachMountedSessions()
        for sessionID in sessionIDs(in: workspace) {
            backend?.kill(id: sessionID)
        }
        document.workspaces.removeAll { $0.id == id }
        if document.selectedWorkspaceID == id {
            document.selectedWorkspaceID = document.workspaces.first?.id
        }
        persist()
        mountSelectedWorkspace()
    }

    func selectWorkspace(id: String) {
        ensureLoaded()
        guard document.workspaces.contains(where: { $0.id == id }) else { return }
        guard id != document.selectedWorkspaceID || mountedSessions.isEmpty else { return }
        guard confirmTermination() else { return }
        windowController?.persistUIStateNow()
        detachMountedSessions()
        document.selectedWorkspaceID = id
        persist()
        mountSelectedWorkspace()
    }

    func setLastOpened(relativePath: String?) {
        ensureLoaded()
        guard let id = document.selectedWorkspaceID,
            let index = document.workspaces.firstIndex(where: { $0.id == id }),
            document.workspaces[index].lastOpenedRelativePath != relativePath
        else { return }
        document.workspaces[index].lastOpenedRelativePath = relativePath
        persist()
    }

    func updateUIState(_ ui: WorkspaceUIState) {
        ensureLoaded()
        guard let id = document.selectedWorkspaceID,
            let index = document.workspaces.firstIndex(where: { $0.id == id }),
            document.workspaces[index].ui != ui
        else { return }
        document.workspaces[index].ui = ui
        do {
            try store.save(document)
        } catch {
            debugLog("[Workspace] save ui failed: \(error)")
        }
    }

    func updateLayout(_ layout: WindowLayout) {
        ensureLoaded()
        document.layout = layout.clamped()
        persist()
    }

    // MARK: - Terminal sessions

    @discardableResult
    func addSubSession() -> TerminalSession? {
        ensureLoaded()
        guard let workspaceID = document.selectedWorkspaceID,
            let index = document.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return nil }
        guard let backend = resolvedBackend() else {
            reportMissingTmux()
            return nil
        }
        guard document.sessionCount < config.maxSessions else {
            notify(
                title: L10n.Terminal.limitTitle,
                body: L10n.Terminal.limitBody(count: config.maxSessions),
            )
            return nil
        }

        let workspace = document.workspaces[index]
        let id = newSessionID()
        guard
            let session = startSession(
                id: id, cwd: workspace.path, title: workspace.name,
                createdAt: Date(), backend: backend, tmuxExists: false,
            )
        else { return nil }

        document.workspaces[index].subSessionIDs.append(id)
        document.workspaces[index].selectedSubSessionID = id
        mountedSessions.append(session)
        persist()
        notifyObserver()
        return session
    }

    func selectSubSession(id: String) {
        ensureLoaded()
        guard let workspaceID = document.selectedWorkspaceID,
            let index = document.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }
        let workspace = document.workspaces[index]
        guard workspace.subSessionIDs.contains(id) else { return }
        guard mountedSession(id: id) == nil else {
            document.workspaces[index].selectedSubSessionID = id
            persist()
            notifyObserver()
            return
        }
        detachMountedSubSessions()
        document.workspaces[index].selectedSubSessionID = id
        _ = ensureSubSession(id: id, workspace: workspace)
        persist()
        notifyObserver()
    }

    func closeSubSession(id: String) {
        ensureLoaded()
        guard
            let index = document.workspaces.firstIndex(where: {
                $0.subSessionIDs.contains(id)
            })
        else { return }
        backend?.kill(id: id)
        detachMountedSessions(matching: { $0.id == id })
        document.workspaces[index].subSessionIDs.removeAll { $0 == id }
        if document.workspaces[index].selectedSubSessionID == id {
            document.workspaces[index].selectedSubSessionID =
                document.workspaces[index].subSessionIDs.first
        }
        persist()
        notifyObserver()
    }

    // MARK: - Persistence

    func persist() {
        ensureLoaded()
        guard !isShuttingDown || !document.workspaces.isEmpty else { return }
        let current = Dictionary(uniqueKeysWithValues: mountedSessions.map { ($0.id, $0) })
        var entries: [StoredTerminalSession] = []
        for workspace in document.workspaces {
            if let main = workspace.mainSessionID {
                entries.append(entry(id: main, workspace: workspace, role: .main, current))
            }
            for sub in workspace.subSessionIDs {
                entries.append(entry(id: sub, workspace: workspace, role: .sub, current))
            }
        }
        // Restore has not run: keep stored ids so a failed launch does not prune sessions.
        if !didRestore {
            let ids = Set(entries.map(\.id))
            entries += sessionStore.load().filter { !ids.contains($0.id) }
        }
        sessionStore.save(entries)
        do {
            try store.save(document)
        } catch {
            debugLog("[Workspace] save failed: \(error)")
        }
    }

    // MARK: - Loading

    private func ensureLoaded() {
        guard !didLoad else { return }
        didLoad = true
        store.backupSessionsIfNeeded()
        storedByID = Dictionary(
            uniqueKeysWithValues: sessionStore.load().map { ($0.id, $0) },
        )
        do {
            if let loaded = try store.load() {
                document = loaded
            } else {
                let stored = sessionStore.load()
                document = WorkspaceMigration.plan(sessions: stored)
                try? store.save(document)
                debugLog(
                    "[Workspace] migrated sessions=\(stored.count) workspaces=\(document.workspaces.count)",
                )
            }
            let reattributed = WorkspaceReattribution.apply(
                document: document, sessions: sessionStore.load(),
            )
            if reattributed != document {
                document = reattributed
                try? store.save(document)
            }
        } catch {
            debugLog("[Workspace] load failed: \(error)")
            document = WorkspaceMigration.plan(sessions: sessionStore.load())
            try? store.save(document)
        }
        startPathPolling()
    }

    private func startPathPolling() {
        guard pathTimer == nil else { return }
        pathTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWorkingDirectories() }
        }
    }

    private func refreshWorkingDirectories() {
        guard let backend, isWindowVisible() else { return }
        let paths = backend.currentPaths()
        for session in mountedSessions {
            guard let path = paths[session.id], path != session.cwd else { continue }
            session.cwd = path
            notifyObserver()
        }
    }

    // MARK: - Mounting

    private func mountSelectedWorkspace() {
        ensureLoaded()
        guard let workspace = selectedWorkspace else {
            notifyObserver()
            return
        }
        _ = ensureMainSession(workspace: workspace)
        if let subID = workspace.selectedSubSessionID ?? workspace.subSessionIDs.first {
            _ = ensureSubSession(id: subID, workspace: workspace)
        }
        notifyObserver()
    }

    private func ensureMainSession(workspace: Workspace) -> TerminalSession? {
        guard let index = document.workspaces.firstIndex(where: { $0.id == workspace.id }) else {
            return nil
        }
        if let mounted = mountedMainSession { return mounted }
        guard let backend = resolvedBackend() else {
            reportMissingTmux()
            return nil
        }
        let live = backend.liveIDs()
        if let mainID = workspace.mainSessionID, live.contains(mainID) {
            guard
                let session = startSession(
                    id: mainID, cwd: cwd(for: mainID, fallback: workspace.path),
                    title: title(for: mainID, fallback: workspace.name),
                    createdAt: createdAt(for: mainID, fallback: workspace.createdAt),
                    backend: backend, tmuxExists: true,
                )
            else { return nil }
            mountedSessions.append(session)
            return session
        }
        guard document.sessionCount < config.maxSessions else {
            notify(
                title: L10n.Terminal.limitTitle,
                body: L10n.Terminal.limitBody(count: config.maxSessions),
            )
            return nil
        }
        let id = newSessionID()
        document.workspaces[index].mainSessionID = id
        guard
            let session = startSession(
                id: id, cwd: workspace.path, title: workspace.name, createdAt: Date(),
                backend: backend, tmuxExists: false,
            )
        else { return nil }
        mountedSessions.append(session)
        return session
    }

    private func ensureSubSession(id: String, workspace: Workspace) -> TerminalSession? {
        if let mounted = mountedSession(id: id) { return mounted }
        guard let backend = resolvedBackend() else {
            reportMissingTmux()
            return nil
        }
        let live = backend.liveIDs()
        guard live.contains(id) else { return nil }
        guard
            let session = startSession(
                id: id, cwd: cwd(for: id, fallback: workspace.path),
                title: title(for: id, fallback: workspace.name),
                createdAt: createdAt(for: id, fallback: workspace.createdAt),
                backend: backend, tmuxExists: true,
            )
        else { return nil }
        mountedSessions.append(session)
        return session
    }

    private func startSession(
        id: String, cwd: String, title: String, createdAt: Date,
        backend: TmuxBackend, tmuxExists: Bool,
    ) -> TerminalSession? {
        let shell = TerminalShell.resolvedShell(configured: config.shell)
        if !tmuxExists {
            do {
                try backend.prepare(id: id, cwd: cwd, shell: shell)
            } catch {
                notify(title: L10n.Terminal.startFailed, body: error.localizedDescription)
                return nil
            }
        }
        let session = TerminalSession(
            id: id, title: title, cwd: cwd, shell: shell,
            fontSize: config.fontSize, createdAt: createdAt,
        )
        wire(session)
        session.view.frame = NSRect(origin: .zero, size: viewSize())
        do {
            try session.start(launch: backend.launch(id: id, cwd: cwd, shell: shell))
        } catch {
            if !tmuxExists { backend.kill(id: id) }
            notify(title: L10n.Terminal.startFailed, body: error.localizedDescription)
            return nil
        }
        return session
    }

    private func detachMountedSessions(matching predicate: (TerminalSession) -> Bool = { _ in true }) {
        let removed = mountedSessions.filter(predicate)
        for session in removed {
            session.terminate()
            session.view.removeFromSuperview()
        }
        mountedSessions.removeAll(where: predicate)
    }

    private func detachMountedSubSessions() {
        let subIDs = Set(selectedWorkspace?.subSessionIDs ?? [])
        detachMountedSessions { subIDs.contains($0.id) }
    }

    // MARK: - Session events

    private func wire(_ session: TerminalSession) {
        session.onNotification = { [weak self] session, title, body in
            self?.handleNotification(session, title: title, body: body)
        }
        session.onExit = { [weak self] session in
            guard let self else { return }
            if !isShuttingDown {
                backend?.kill(id: session.id)
            }
            removeReference(to: session.id)
            detachMountedSessions { $0.id == session.id }
            persist()
            notifyObserver()
        }
        session.onTitleChange = { [weak self] session in
            self?.updateStoredTitle(session)
            self?.notifyObserver()
        }
    }

    private func handleNotification(_ session: TerminalSession, title: String, body: String) {
        guard !isWindowFocused() else {
            debugLog("[Workspace] notify suppressed focused=true title=\(title)")
            return
        }
        let now = Date()
        if let last = lastNotification, last.sessionID == session.id,
            now.timeIntervalSince(last.at) < 3
        {
            debugLog("[Workspace] notify deduplicated title=\(title) body=\(body)")
            return
        }
        lastNotification = (session.id, now)
        notify(
            title: title.isEmpty ? L10n.Terminal.notifyTitle : title,
            body: body.isEmpty ? L10n.Terminal.notifyBody(title: session.title) : body,
            sessionID: session.id,
        )
    }

    private func removeReference(to sessionID: String) {
        for index in document.workspaces.indices {
            if document.workspaces[index].mainSessionID == sessionID {
                document.workspaces[index].mainSessionID = nil
            }
            document.workspaces[index].subSessionIDs.removeAll { $0 == sessionID }
            if document.workspaces[index].selectedSubSessionID == sessionID {
                document.workspaces[index].selectedSubSessionID =
                    document.workspaces[index].subSessionIDs.first
            }
        }
    }

    private func updateStoredTitle(_ session: TerminalSession) {
        guard let stored = storedByID[session.id] else { return }
        storedByID[session.id] = StoredTerminalSession(
            id: stored.id, title: session.title, cwd: session.cwd,
            backend: stored.backend, createdAt: stored.createdAt,
            workspaceID: stored.workspaceID, role: stored.role,
        )
    }

    // MARK: - Helpers

    private var selectedWorkspace: Workspace? {
        document.workspaces.first { $0.id == document.selectedWorkspaceID }
    }

    private var mountedMainSession: TerminalSession? {
        guard let mainID = selectedWorkspace?.mainSessionID else { return nil }
        return mountedSessions.first { $0.id == mainID }
    }

    private var mountedSubSession: TerminalSession? {
        guard let subID = selectedWorkspace?.selectedSubSessionID else { return nil }
        return mountedSessions.first { $0.id == subID }
    }

    private func mountedSession(id: String) -> TerminalSession? {
        mountedSessions.first { $0.id == id }
    }

    private func summary(
        id: String, role: TerminalRole, workspace: Workspace,
    ) -> WorkspaceSessionSummary {
        let mounted = mountedSession(id: id)
        return WorkspaceSessionSummary(
            id: id,
            title: mounted?.title ?? title(for: id, fallback: workspace.name),
            cwd: mounted?.cwd ?? cwd(for: id, fallback: workspace.path),
            role: role,
        )
    }

    private func cwd(for id: String, fallback: String) -> String {
        mountedSession(id: id)?.cwd ?? storedByID[id]?.cwd ?? fallback
    }

    private func title(for id: String, fallback: String) -> String {
        mountedSession(id: id)?.title ?? storedByID[id]?.title ?? fallback
    }

    private func createdAt(for id: String, fallback: Date) -> Date {
        storedByID[id]?.createdAt ?? fallback
    }

    private func entry(
        id: String, workspace: Workspace, role: TerminalRole,
        _ current: [String: TerminalSession],
    ) -> StoredTerminalSession {
        if let stored = storedByID[id] {
            return StoredTerminalSession(
                id: id, title: stored.title, cwd: stored.cwd, backend: stored.backend,
                createdAt: stored.createdAt, workspaceID: workspace.id, role: role,
            )
        }
        let session = current[id]
        return StoredTerminalSession(
            id: id,
            title: session?.title ?? workspace.name,
            cwd: session?.cwd ?? workspace.path,
            backend: TmuxBackend.storageName,
            createdAt: session?.createdAt ?? workspace.createdAt,
            workspaceID: workspace.id,
            role: role,
        )
    }

    private func sessionIDs(in workspace: Workspace) -> [String] {
        var ids = workspace.subSessionIDs
        if let main = workspace.mainSessionID { ids.append(main) }
        return ids
    }

    private func apply(_ plan: WorkspaceRestorePlan) {
        for index in document.workspaces.indices {
            guard
                let workspacePlan = plan.workspaces.first(where: {
                    $0.workspaceID == document.workspaces[index].id
                })
            else { continue }
            if workspacePlan.rebuildMain {
                document.workspaces[index].mainSessionID = nil
            }
            document.workspaces[index].subSessionIDs = workspacePlan.subSessionIDs
            if let selected = document.workspaces[index].selectedSubSessionID,
                !workspacePlan.subSessionIDs.contains(selected)
            {
                document.workspaces[index].selectedSubSessionID =
                    workspacePlan.subSessionIDs.first
            }
        }
    }

    private func reveal(sessionID: String) {
        ensureLoaded()
        guard
            let workspace = document.workspaces.first(where: {
                $0.mainSessionID == sessionID || $0.subSessionIDs.contains(sessionID)
            })
        else { return }
        selectWorkspace(id: workspace.id)
        if workspace.subSessionIDs.contains(sessionID) {
            selectSubSession(id: sessionID)
        }
        notifyObserver()
    }

    private func newSessionID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    private func resolvedBackend() -> TmuxBackend? {
        if let backend { return backend }
        guard let resolved = TmuxBackend.makeIfAvailable() else {
            debugLog("[Workspace] tmux unavailable")
            return nil
        }
        backend = resolved
        return resolved
    }

    private func reportMissingTmux() {
        guard !didReportMissingTmux else { return }
        didReportMissingTmux = true
        notify(title: L10n.Terminal.tmuxMissingTitle, body: L10n.Terminal.tmuxMissingBody)
    }

    private func notifyObserver() {
        observer?.workspaceStateDidChange(self)
    }

    private func notify(title: String, body: String, sessionID: String? = nil) {
        EventBus.shared.publish(
            AppEvent.notify,
            payload: NotificationPayload(title: title, body: body, sessionID: sessionID),
        )
    }
}
