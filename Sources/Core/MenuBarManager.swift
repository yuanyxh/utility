import Cocoa
import ServiceManagement

public final class MenuBarManager: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var reloadItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var rssMenuItem: NSMenuItem!
    private var mcpMenuItem: NSMenuItem!
    private var proxyMenuItem: NSMenuItem!
    private var tasksMenuItem: NSMenuItem!
    private var knowledgeMenuItem: NSMenuItem!
    private var clearItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var rssFetchTask: Task<Void, Never>?
    private var runningProcesses: [String: Process] = [:]

    /// 知识面板实例由 AppDelegate 注入 —— PanelManager 靠对象标识区分面板，不能有第二个实例。
    weak var knowledgePanel: PanelProtocol?

    override public init() {
        super.init()
        setupStatusItem()
        buildMenu()
        startNetworkMonitor()
        startMCPSateMonitor()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLanguageChanged),
            name: L10n.languageDidChange, object: nil,
        )
    }

    @objc private func onLanguageChanged() {
        refreshAllTitles()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "utility-network-speed"

        let view = NetworkSpeedView()
        view.onClick = { [weak self] event in
            guard let self, let menu = statusItem.menu,
                  let v = statusItem.value(forKey: "view") as? NSView
            else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: v)
        }
        statusItem.setValue(view, forKey: "view")
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        reloadItem = NSMenuItem(
            title: L10n.Menu.reloadConfig, action: #selector(reloadConfig), keyEquivalent: "r",
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())

        launchAtLoginItem = NSMenuItem(
            title: L10n.Menu.launchAtLogin, action: #selector(toggleLaunchAtLogin), keyEquivalent: "",
        )
        launchAtLoginItem.target = self
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        // ── MCP ──
        let initialState = MCPProcessManager.shared.state
        mcpMenuItem = NSMenuItem(title: mcpTitleText(initialState), action: nil, keyEquivalent: "")
        mcpMenuItem.submenu = NSMenu()
        menu.addItem(mcpMenuItem)

        menu.addItem(NSMenuItem.separator())

        // ── Proxy ──
        proxyMenuItem = NSMenuItem(title: proxyTitleText(), action: nil, keyEquivalent: "")
        proxyMenuItem.submenu = NSMenu()
        menu.addItem(proxyMenuItem)

        menu.addItem(NSMenuItem.separator())

        // ── Knowledge ──
        knowledgeMenuItem = NSMenuItem(title: L10n.Knowledge.title, action: nil, keyEquivalent: "")
        knowledgeMenuItem.submenu = NSMenu()
        menu.addItem(knowledgeMenuItem)

        menu.addItem(NSMenuItem.separator())

        // ── RSS ──
        rssMenuItem = NSMenuItem(title: L10n.Menu.rss, action: nil, keyEquivalent: "")
        rssMenuItem.submenu = NSMenu()
        menu.addItem(rssMenuItem)

        menu.addItem(NSMenuItem.separator())

        // ── Tasks ──
        tasksMenuItem = NSMenuItem(title: L10n.Menu.tasks, action: nil, keyEquivalent: "")
        tasksMenuItem.submenu = NSMenu()
        menu.addItem(tasksMenuItem)

        menu.addItem(NSMenuItem.separator())

        clearItem = NSMenuItem(
            title: L10n.Menu.clearClipboard, action: #selector(clearClipboard), keyEquivalent: "",
        )
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        quitItem = NSMenuItem(title: L10n.Menu.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    public func menuWillOpen(_: NSMenu) {
        debugLog("[MenuBar] menuWillOpen")
        refreshRSSItem()
        refreshMCPItem()
        refreshProxyItem()
        refreshTasksItem()
        refreshKnowledgeItem()
    }

    private func refreshKnowledgeItem() {
        knowledgeMenuItem.title = L10n.Knowledge.title
        let sub = NSMenu()

        let showItem = NSMenuItem(
            title: L10n.Menu.knowledgeShow, action: #selector(showKnowledgePanel), keyEquivalent: "",
        )
        showItem.target = self
        sub.addItem(showItem)

        let refillItem = NSMenuItem(
            title: L10n.Menu.knowledgeRefill, action: #selector(refillKnowledge), keyEquivalent: "",
        )
        refillItem.target = self
        sub.addItem(refillItem)

        knowledgeMenuItem.submenu = sub
    }

    @objc private func showKnowledgePanel() {
        guard let knowledgePanel else {
            debugLog("[Knowledge] menu 'show knowledge panel' failed: panel reference not injected")
            return
        }
        EventBus.shared.publish(PanelEvent.requestShow, payload: knowledgePanel)
    }

    @objc private func refillKnowledge() {
        KnowledgeService.shared.launchRefill()
    }

    private func refreshRSSItem() {
        let count = (try? RSSManager.shared.unreadCount()) ?? 0
        let sub = NSMenu()

        let fetchItem = NSMenuItem(
            title: L10n.Menu.rssFetch, action: #selector(rssFetch), keyEquivalent: "",
        )
        fetchItem.target = self
        sub.addItem(fetchItem)

        let markReadItem = NSMenuItem(
            title: L10n.Menu.rssMarkAllRead, action: #selector(rssMarkAllRead), keyEquivalent: "",
        )
        markReadItem.target = self
        sub.addItem(markReadItem)

        rssMenuItem.title = count > 0 ? L10n.Menu.rssUnread(count: count) : L10n.Menu.rss
        rssMenuItem.submenu = sub
    }

    // MARK: - MCP menu

    private func refreshMCPItem() {
        let isEnabled = ConfigManager.shared.config.mcp?.enabled ?? false
        let state = MCPProcessManager.shared.state
        let sub = NSMenu()

        if isEnabled {
            // State indicator (disabled, informational)
            let stateItem = NSMenuItem(title: mcpStateText(state), action: nil, keyEquivalent: "")
            stateItem.isEnabled = false
            sub.addItem(stateItem)

            sub.addItem(NSMenuItem.separator())

            // Restart action (available when MCP is active or crashed/stopped)
            let canRestart = state != .initializing && state != .restarting
            let restartItem = NSMenuItem(
                title: L10n.Menu.mcpRestart, action: #selector(restartMCPService), keyEquivalent: "",
            )
            restartItem.target = self
            restartItem.isEnabled = canRestart
            sub.addItem(restartItem)

            sub.addItem(NSMenuItem.separator())

            // Data paths
            if let mcp = ConfigManager.shared.config.mcp {
                let pathItems = [
                    L10n.Menu.mcpQdrantPath(path: mcp.qdrantPath),
                    L10n.Menu.mcpKnowledgeBase(path: mcp.knowledgeBasePath),
                    L10n.Menu.mcpModelCache(path: mcp.fastembedCacheDir),
                ]
                for text in pathItems {
                    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    sub.addItem(item)
                }
            }
        } else {
            let disabledItem = NSMenuItem(title: L10n.Menu.mcpDisabled, action: nil, keyEquivalent: "")
            disabledItem.isEnabled = false
            sub.addItem(disabledItem)
        }

        mcpMenuItem.submenu = sub
    }

    private func mcpStateText(_ state: MCPProcessManager.State) -> String {
        switch state {
        case .running: L10n.Menu.mcpStateRunning
        case .initializing: L10n.Menu.mcpStateInitializing
        case .restarting: L10n.Menu.mcpStateRestarting
        case .stopped: L10n.Menu.mcpStateStopped
        case .crashed: L10n.Menu.mcpStateCrashed
        }
    }

    private func mcpTitleText(_ state: MCPProcessManager.State) -> String {
        let dot = switch state {
        case .running: "●"
        case .initializing,
             .restarting: "◐"
        case .stopped: "○"
        case .crashed: "✕"
        }
        return "\(dot) MCP"
    }

    // MARK: - Proxy menu

    private func refreshProxyItem() {
        let proxyEnabled = ConfigManager.shared.config.modelProxy?.enabled ?? false
        let state = TokenProxyManager.shared.state
        let sub = NSMenu()

        if proxyEnabled {
            let stateItem = NSMenuItem(title: proxyStateText(state), action: nil, keyEquivalent: "")
            stateItem.isEnabled = false
            sub.addItem(stateItem)

            // providers routing table: the default (providers[0]) is checked; clicking switches the default
            if let providers = ConfigManager.shared.config.modelProxy?.providers, !providers.isEmpty {
                sub.addItem(NSMenuItem.separator())
                let defaultName = providers.first?.name ?? ""
                for provider in providers {
                    let item = NSMenuItem(
                        title: provider.models.isEmpty
                            ? provider.name
                            : "\(provider.name) · \(provider.models.joined(separator: ", "))",
                        action: #selector(selectDefaultProvider(_:)),
                        keyEquivalent: "",
                    )
                    item.target = self
                    item.representedObject = provider.name
                    item.state = provider.name == defaultName ? .on : .off
                    sub.addItem(item)
                }
            }

            sub.addItem(NSMenuItem.separator())

            // Asynchronously fetch today's usage
            let summaryItem = NSMenuItem(title: L10n.Menu.loading, action: nil, keyEquivalent: "")
            summaryItem.isEnabled = false
            sub.addItem(summaryItem)

            Task { @MainActor [summaryItem, sub] in
                let summary = await TokenProxyManager.shared.fetchTodaySummary()

                let inputK = Double(summary.input_tokens) / 1000
                let outputK = Double(summary.output_tokens) / 1000
                summaryItem.title = L10n.Menu.proxyToday(inputK: inputK, outputK: outputK)

                if summary.total_requests > 0 {
                    sub.addItem(NSMenuItem.separator())
                    let invalidPct = summary.total_requests > 0
                        ? Double(summary.invalid_requests) / Double(summary.total_requests) * 100
                        : 0
                    let infoItem = NSMenuItem(
                        title: L10n.Menu.proxyRequests(
                            total: summary.total_requests,
                            invalid: summary.invalid_requests,
                            pct: invalidPct,
                        ),
                        action: nil, keyEquivalent: "",
                    )
                    infoItem.isEnabled = false
                    sub.addItem(infoItem)
                }
            }
        } else {
            let disabledItem = NSMenuItem(title: L10n.Menu.proxyDisabled, action: nil, keyEquivalent: "")
            disabledItem.isEnabled = false
            sub.addItem(disabledItem)
        }

        proxyMenuItem.submenu = sub
    }

    private func proxyStateText(_ state: TokenProxyManager.State) -> String {
        switch state {
        case .running: L10n.Menu.proxyStateRunning
        case .stopped: L10n.Menu.proxyStateStopped
        case .crashed: L10n.Menu.proxyStateCrashed
        }
    }

    private func proxyTitleText() -> String {
        let dot = switch TokenProxyManager.shared.state {
        case .running: "●"
        case .stopped: "○"
        case .crashed: "✕"
        }
        return "\(dot) Proxy"
    }

    /// Click a provider item → set it as default (move to providers[0]) and restart the proxy
    @objc private func selectDefaultProvider(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        do {
            try ConfigManager.shared.setDefaultProvider(named: name)
            TokenProxyManager.shared.forceRestart()
            refreshProxyItem()
        } catch {
            debugLog("[MenuBar] set default provider failed: \(error)")
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: "Switch Default Failed", body: error.localizedDescription,
            ))
        }
    }

    // MARK: - EventBus subscription

    private func startMCPSateMonitor() {
        EventBus.shared.subscribe("mcp_state_changed") { [weak self] payload in
            guard let self else { return }
            let raw = payload as? String ?? ""
            let state = MCPProcessManager.State(rawValue: raw) ?? .stopped
            DispatchQueue.main.async {
                self.mcpMenuItem?.title = self.mcpTitleText(state)
            }
        }
        EventBus.shared.subscribe("token_proxy_state_changed") { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.proxyMenuItem?.title = self.proxyTitleText()
            }
        }
    }

    // MARK: - MCP Actions

    @objc private func restartMCPService() {
        MCPProcessManager.shared.forceRestart()
    }

    private func refreshTasksItem() {
        let configTasks = ConfigManager.shared.config.tasks
        let internalTasks = TaskScheduler.shared.internalTasks
        debugLog("[MenuBar] refreshTasksItem config=\(configTasks.map(\.name)) internal=\(internalTasks.map(\.name)) runningKeys=\(Array(runningProcesses.keys))")
        let sub = NSMenu()

        for task in configTasks {
            let item = NSMenuItem(
                title: task.name,
                action: task.enabled ? #selector(taskTrigger(_:)) : nil,
                keyEquivalent: "",
            )
            item.target = task.enabled ? self : nil
            item.isEnabled = task.enabled
            item.representedObject = task.name
            item.state = (runningProcesses[task.name] != nil) ? .on : .off
            sub.addItem(item)
        }

        if !configTasks.isEmpty && !internalTasks.isEmpty {
            sub.addItem(NSMenuItem.separator())
        }

        for task in internalTasks {
            let item = NSMenuItem(
                title: task.name,
                action: task.enabled ? #selector(taskTrigger(_:)) : nil,
                keyEquivalent: "",
            )
            item.target = task.enabled ? self : nil
            item.isEnabled = task.enabled
            item.representedObject = task.name
            item.state = (runningProcesses[task.name] != nil) ? .on : .off
            sub.addItem(item)
        }

        // 知识补货**不注册进 TaskScheduler**（它的 handleMissed 会把 sub-daily 的 cron 静默退化成
        // 每天一次）；这里只借「任务」子菜单做入口与状态显示,起进程仍走 KnowledgeService 的闸门 ——
        // 交给 TaskExecutor 会多出一个不受防重保护的补货进程。
        var total = configTasks.count + internalTasks.count
        if ConfigManager.shared.config.knowledge.enabled {
            sub.addItem(NSMenuItem.separator())
            let refillItem = NSMenuItem(
                title: "\(L10n.Knowledge.taskRefill) · \(KnowledgeService.shared.statusText)",
                action: #selector(refillKnowledge), keyEquivalent: "",
            )
            refillItem.target = self
            refillItem.state = KnowledgeService.shared.isRefillRunning ? .on : .off
            sub.addItem(refillItem)
            total += 1
        }

        tasksMenuItem.title = total == 0 ? L10n.Menu.tasks : L10n.Menu.tasksCount(count: total)
        tasksMenuItem.submenu = sub
    }

    // MARK: - Network

    private func startNetworkMonitor() {
        EventBus.shared.subscribe(AppEvent.networkSpeedUpdated) { [weak self] payload in
            guard let (up, down) = payload as? (String, String) else { return }
            guard let view = self?.statusItem.value(forKey: "view") as? NetworkSpeedView else { return }
            view.update(up: up, down: down)
        }
        NetworkSpeedMonitor.shared.start()
    }

    // MARK: - RSS Actions

    @objc private func rssFetch() {
        rssFetchTask?.cancel()
        rssFetchTask = Task {
            do {
                _ = try await RSSManager.shared.fetchAll()
                guard !Task.isCancelled else { return }
            } catch {
                guard !Task.isCancelled else { return }
                debugLog("[MenuBar] RSS fetch failed: \(error)")
                EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                    title: L10n.Notify.rssFetchFailed, body: error.localizedDescription,
                ))
            }
        }
    }

    @objc private func rssMarkAllRead() {
        do {
            try RSSManager.shared.markAllAsRead()
        } catch {
            debugLog("[MenuBar] RSS mark all read failed: \(error)")
        }
    }

    // MARK: - Task lifecycle

    /// Terminate all running task processes (called on app exit)
    func terminateAllTasks() {
        for (name, process) in runningProcesses {
            process.terminate()
            debugLog("[MenuBar] Terminated task on exit: \(name)")
        }
        runningProcesses.removeAll()
    }

    /// Clean up running processes that no longer exist in config or internal tasks
    private func cleanupOrphanProcesses() {
        let configNames = Set(ConfigManager.shared.config.tasks.map(\.name))
        let internalNames = Set(TaskScheduler.shared.internalTasks.map(\.name))
        let activeNames = configNames.union(internalNames)
        for name in runningProcesses.keys where !activeNames.contains(name) {
            runningProcesses[name]?.terminate()
            runningProcesses.removeValue(forKey: name)
            debugLog("[MenuBar] Terminated orphan task: \(name)")
        }
    }

    // MARK: - Task Actions

    @objc private func taskTrigger(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let task = (ConfigManager.shared.config.tasks + TaskScheduler.shared.internalTasks)
              .first(where: { $0.name == name && $0.enabled })
        else {
            debugLog("[MenuBar] taskTrigger early-return represented=\(String(describing: sender.representedObject))")
            return
        }

        // Already running → terminate
        if let process = runningProcesses[name] {
            process.terminate()
            runningProcesses.removeValue(forKey: name)
            sender.state = .off
            debugLog("[MenuBar] taskTrigger terminate name=\(name) runningKeys=\(Array(runningProcesses.keys))")
            return
        }

        // Start execution (streaming API, obtains the Process handle to support termination)
        sender.state = .on
        let process = TaskExecutor.execute(
            task.exec,
            onOutput: nil,
            onComplete: { [weak self] result in
                DispatchQueue.main.async {
                    self?.runningProcesses.removeValue(forKey: name)
                    if result.success {
                        EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                            title: L10n.Notify.taskCompleted(name: name), body: "",
                        ))
                    } else {
                        let errMsg = result.error.isEmpty ? "exit code != 0" : String(result.error.prefix(200))
                        EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                            title: L10n.Notify.taskFailed(name: name), body: errMsg,
                        ))
                    }
                }
            },
        )
        runningProcesses[name] = process
        debugLog("[MenuBar] taskTrigger start name=\(name) runningKeys=\(Array(runningProcesses.keys))")
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                launchAtLoginItem.state = .off
            } else {
                try SMAppService.mainApp.register()
                launchAtLoginItem.state = .on
            }
        } catch {
            debugLog("[LoginItem] Failed: \(error)")
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Notify.launchAtLoginFailed, body: error.localizedDescription,
            ))
        }
    }

    // MARK: - Title Refresh

    func refreshAllTitles() {
        reloadItem.title = L10n.Menu.reloadConfig
        launchAtLoginItem.title = L10n.Menu.launchAtLogin
        rssMenuItem.title = L10n.Menu.rss
        mcpMenuItem.title = mcpTitleText(MCPProcessManager.shared.state)
        proxyMenuItem.title = proxyTitleText()
        tasksMenuItem.title = L10n.Menu.tasks
        clearItem.title = L10n.Menu.clearClipboard
        quitItem.title = L10n.Menu.quit
    }

    @objc private func reloadConfig() {
        do {
            try ConfigManager.shared.reload()
            cleanupOrphanProcesses()
            refreshAllTitles()
            refreshRSSItem()
            refreshTasksItem()
        } catch {
            debugLog("[MenuBar] Reload failed: \(error)")
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Notify.configReloadFailed, body: error.localizedDescription,
            ))
        }
    }

    @objc private func clearClipboard() {
        let db = AppDatabase.shared.dbQueue
        try? db?.write { db in
            try db.execute(literal: "DELETE FROM clipboard_item")
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NetworkSpeedView

private final class NetworkSpeedView: NSView {
    private let upLabel = NSTextField(labelWithString: "")
    private let downLabel = NSTextField(labelWithString: "")

    var onClick: ((NSEvent) -> Void)?

    override init(frame _: NSRect) {
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setup() {
        upLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        downLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        upLabel.alignment = .right
        downLabel.alignment = .right

        let stack = NSStackView(views: [upLabel, downLabel])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .trailing
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        update(up: "--", down: "--")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event)
    }

    override var intrinsicContentSize: NSSize {
        let upSz = upLabel.intrinsicContentSize
        let downSz = downLabel.intrinsicContentSize
        return NSSize(
            width: max(upSz.width, downSz.width),
            height: upSz.height + downSz.height,
        )
    }

    func update(up: String, down: String) {
        let (paddedUp, paddedDown) = pad(up: up, down: down)
        upLabel.stringValue = paddedUp
        downLabel.stringValue = paddedDown
        invalidateIntrinsicContentSize()
        superview?.layoutSubtreeIfNeeded()
    }

    // MARK: - Padding

    private func pad(up: String, down: String) -> (String, String) {
        let upInt = String(up.prefix(while: { $0 != "." }))
        let downInt = String(down.prefix(while: { $0 != "." }))
        let upRest = String(up.dropFirst(upInt.count))
        let downRest = String(down.dropFirst(downInt.count))

        let maxLen = max(upInt.count, downInt.count)
        let padUp = String(repeating: "0", count: maxLen - upInt.count) + upInt
        let padDown = String(repeating: "0", count: maxLen - downInt.count) + downInt

        return ("↑ " + padUp + upRest, "↓ " + padDown + downRest)
    }
}
