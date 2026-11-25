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

    private(set) var document = WorkspaceDocument()
    private(set) var mountedSessions: [TerminalSession] = []

    private let store = WorkspaceStore()
    private let sessionStore = TerminalSessionStore()
    private let notificationTap = TmuxNotificationTap()
    private var windowController: WorkspaceWindowController?
    private var backend: TmuxBackend?
    private var storedByID: [String: StoredTerminalSession] = [:]
    private var didLoad = false
    private var didRestore = false
    private var isShuttingDown = false
    private var didReportMissingTmux = false
    private var pathTimer: Timer?
    private var meshRetry: Timer?
    private var protocolWatch: Timer?
    private var statusWatch: Timer?
    private var meshRetryAttempts = 0
    private static let meshRetryLimit = 30
    private let mesh = WorkspaceMeshCoordinator()
    private let inboxWatcher = WorkspaceInboxWatcher()
    private var inboxDirectories: [String: URL] = [:]
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
        notificationTap.onNotification = { [weak self] sessionID, title, body in
            self?.handleNotification(sessionID: sessionID, title: title, body: body)
        }
        mesh.onRegistered = { [weak self] _, _ in
            self?.syncInboxDirectories()
        }
        EventBus.shared.subscribe("mcp_state_changed") { [weak self] payload in
            let raw = payload as? String ?? ""
            let state = MCPProcessManager.State(rawValue: raw) ?? .stopped
            Task { @MainActor in
                guard let self else { return }
                if state == .running {
                    self.refreshMesh()
                } else {
                    self.meshRetry?.invalidate()
                    self.meshRetry = nil
                    self.mesh.stop()
                    self.inboxDirectories = [:]
                    self.inboxWatcher.stop()
                }
            }
        }
        protocolWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.reloadProtocolsFromDisk() }
        }
        statusWatch = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, MeshGate.isEnabled else { return }
                self.refreshMesh()
            }
        }
        inboxWatcher.onMessage = { [weak self] serviceID, text in
            self?.handleMeshMessage(serviceID: serviceID, text: text)
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
            mainView: mountedMainSession?.view,
            subView: mountedSubSession?.view,
        )
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
        syncNotificationTaps()
        refreshMesh()
    }

    func shutdown() {
        guard didLoad else { return }
        isShuttingDown = true
        notificationTap.stopAll()
        persist()
        detachMountedSessions(keepNotificationTap: false)
        meshRetry?.invalidate()
        meshRetry = nil
        protocolWatch?.invalidate()
        protocolWatch = nil
        statusWatch?.invalidate()
        statusWatch = nil
        mesh.stop()
        inboxWatcher.stop()
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
        if state.mainSession == nil, !TmuxBackend.isAvailable() {
            controller.showEmptyState(message: L10n.Terminal.tmuxMissingBody)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.focusTerminalIfNeeded()
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
        controller.window?.layoutIfNeeded()
        observer = controller
        viewSize = { [weak controller] in
            controller?.terminalContentSize ?? NSSize(width: 760, height: 520)
        }
        isWindowVisible = { [weak controller] in controller?.window?.isVisible == true }
        windowController = controller
        return controller
    }

    // MARK: - Workspace CRUD

    @discardableResult
    func createWorkspace(path: String) -> Workspace? {
        ensureLoaded()
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
        refreshMesh()
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
        refreshMesh()
        return true
    }

    func removeWorkspace(id: String) {
        ensureLoaded()
        guard let workspace = document.workspaces.first(where: { $0.id == id }) else { return }
        detachMountedSessions(keepNotificationTap: false)
        for sessionID in sessionIDs(in: workspace) {
            notificationTap.stop(id: sessionID)
            backend?.kill(id: sessionID)
        }
        document.workspaces.removeAll { $0.id == id }
        if document.selectedWorkspaceID == id {
            document.selectedWorkspaceID = document.workspaces.first?.id
        }
        persist()
        mountSelectedWorkspace()
        refreshMesh()
    }

    func selectWorkspace(id: String) {
        ensureLoaded()
        guard document.workspaces.contains(where: { $0.id == id }) else { return }
        guard id != document.selectedWorkspaceID || mountedSessions.isEmpty else { return }
        detachMountedSessions()
        document.selectedWorkspaceID = id
        persist()
        mountSelectedWorkspace()
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
        detachMountedSessions(keepNotificationTap: false, matching: { $0.id == id })
        notificationTap.stop(id: id)
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

    /// Covers sessions restored outside the selected workspace, which never
    /// pass through `detachMountedSessions` during startup.
    private func syncNotificationTaps() {
        guard let backend else { return }
        let live = backend.liveIDs()
        let mounted = Set(mountedSessions.map(\.id))
        for workspace in document.workspaces {
            for id in sessionIDs(in: workspace)
            where live.contains(id) && !mounted.contains(id) {
                notificationTap.start(id: id)
            }
        }
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
                initialCommand: workspace.protocolConfig?.startCommand,
                environment: meshEnvironment(for: workspace),
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
        initialCommand: String? = nil, environment: [String: String] = [:],
    ) -> TerminalSession? {
        let shell = TerminalShell.resolvedShell(configured: config.shell)
        notificationTap.stop(id: id)
        if !tmuxExists {
            do {
                try backend.prepare(
                    id: id, cwd: cwd, shell: shell,
                    initialCommand: initialCommand, environment: environment,
                )
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

    /// Detached tmux sessions keep running, so they switch to the pipe-pane tap
    /// to keep delivering notifications while another workspace is selected.
    private func detachMountedSessions(
        keepNotificationTap: Bool = true,
        matching predicate: (TerminalSession) -> Bool = { _ in true },
    ) {
        let removed = mountedSessions.filter(predicate)
        for session in removed {
            session.terminate()
            session.view.removeFromSuperview()
            if keepNotificationTap { notificationTap.start(id: session.id) }
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
            notificationTap.stop(id: session.id)
            detachMountedSessions(keepNotificationTap: false) { $0.id == session.id }
            persist()
            notifyObserver()
        }
        session.onTitleChange = { [weak self] session in
            self?.updateStoredTitle(session)
            self?.notifyObserver()
        }
    }

    private func handleNotification(_ session: TerminalSession, title: String, body: String) {
        handleNotification(sessionID: session.id, title: title, body: body)
    }

    private func handleNotification(sessionID: String, title: String, body: String) {
        if let mounted = mountedSession(id: sessionID), isSessionFocused(mounted) {
            debugLog("[Workspace] notify suppressed focused=true title=\(title)")
            return
        }
        let now = Date()
        if let last = lastNotification, last.sessionID == sessionID,
            now.timeIntervalSince(last.at) < 3
        {
            debugLog("[Workspace] notify deduplicated title=\(title) body=\(body)")
            return
        }
        lastNotification = (sessionID, now)
        debugLog("[Workspace] notify delivered id=\(sessionID) title=\(title)")
        notify(
            title: title.isEmpty ? L10n.Terminal.notifyTitle : title,
            body: body.isEmpty
                ? L10n.Terminal.notifyBody(
                    title: self.title(for: sessionID, fallback: L10n.Terminal.notifyTitle),
                )
                : body,
            sessionID: sessionID,
        )
    }

    /// Suppress only when the emitting terminal itself holds focus in the key window.
    private func isSessionFocused(_ session: TerminalSession) -> Bool {
        guard NSApplication.shared.isActive,
            let window = windowController?.window, window.isKeyWindow
        else { return false }
        var responder = window.firstResponder
        while let current = responder {
            if current === session.view { return true }
            responder = current.nextResponder
        }
        return false
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

    // MARK: - Mesh

    private func refreshMesh() {
        let enabled = MeshGate.isEnabled
        let port = MCPProcessManager.shared.currentPort
        let live = liveSessionIDs()
        let entries = document.workspaces.compactMap {
            workspace -> (workspace: Workspace, status: String)? in
            guard workspace.protocolConfig?.enabled != false else { return nil }
            let ready = workspace.mainSessionID.map { live.contains($0) } ?? false
            return (workspace, ready ? "ready" : "offline")
        }
        debugLog(
            "[Mesh] refresh enabled=\(enabled) port=\(port) count=\(entries.count)")
        mesh.sync(entries: entries, port: port, enabled: enabled)
        if !enabled {
            inboxDirectories = [:]
            inboxWatcher.stop()
            meshRetry?.invalidate()
            meshRetry = nil
            meshRetryAttempts = 0
            return
        }
        syncInboxDirectories()
        let pending = port <= 0 || mesh.endpoints.count < entries.count
        if pending, meshRetryAttempts < Self.meshRetryLimit {
            meshRetryAttempts += 1
            scheduleMeshRetry()
        } else {
            meshRetry?.invalidate()
            meshRetry = nil
            meshRetryAttempts = 0
        }
    }

    private func syncInboxDirectories() {
        inboxDirectories = mesh.endpoints
        inboxWatcher.setDirectories(inboxDirectories)
    }

    private func liveSessionIDs() -> Set<String> {
        guard let backend = resolvedBackend() else { return [] }
        return Set(backend.liveIDs())
    }

    /// The CLI edits protocol fields on disk; merge them so a running app follows.
    private func reloadProtocolsFromDisk() {
        let url = AppPaths.configDir.appendingPathComponent("workspaces.json")
        guard didLoad, !isShuttingDown,
            let data = try? Data(contentsOf: url),
            let disk = try? WorkspaceJSON.decode(data)
        else { return }
        var changed = false
        for workspace in disk.workspaces {
            guard
                let index = document.workspaces.firstIndex(where: {
                    $0.id == workspace.id
                })
            else { continue }
            if document.workspaces[index].protocolConfig != workspace.protocolConfig {
                document.workspaces[index].protocolConfig = workspace.protocolConfig
                changed = true
            }
        }
        guard changed else { return }
        debugLog("[Mesh] protocols reloaded from disk")
        refreshMesh()
        notifyObserver()
    }

    /// The gateway reports a port only after it starts; keep polling until it does.
    private func scheduleMeshRetry() {
        guard meshRetry == nil else { return }
        meshRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.refreshMesh() }
        }
    }

    private func handleMeshMessage(serviceID: String, text: String) {
        guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]
        if json["kind"] as? String == "control", payload["action"] as? String == "start" {
            debugLog("[Mesh] start request for \(serviceID)")
            selectWorkspace(id: serviceID)
            let live = liveSessionIDs()
            let workspace = document.workspaces.first { $0.id == serviceID }
            let ready = workspace?.mainSessionID.map { live.contains($0) } ?? false
            mesh.report(serviceID: serviceID, status: ready ? "ready" : "offline")
            refreshMesh()
            return
        }
        let sender = json["sender"] as? String ?? serviceID
        debugLog("[Mesh] message from \(sender)")
        mesh.report(serviceID: serviceID, status: "ready")
        notify(title: sender, body: payload["text"] as? String ?? text)
    }

    /// Exported to the agent so it can call `service_*` tools with its own id.
    private func meshEnvironment(for workspace: Workspace) -> [String: String] {
        guard MeshGate.isEnabled else { return [:] }
        var environment = ["MESH_SERVICE_ID": workspace.id]
        let port = MCPProcessManager.shared.currentPort
        if port > 0 {
            environment["MESH_GATEWAY_URL"] = HTTP.localBaseURL(port: port)
        }
        return environment
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
