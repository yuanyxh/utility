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
    private var clearItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var rssFetchTask: Task<Void, Never>?
    private var runningProcesses: [String: Process] = [:]

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

        rssMenuItem.title = count > 0 ? L10n.Menu.rssUnread(count) : L10n.Menu.rss
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
                title: L10n.MCP.restartService, action: #selector(restartMCPService), keyEquivalent: "",
            )
            restartItem.target = self
            restartItem.isEnabled = canRestart
            sub.addItem(restartItem)

            sub.addItem(NSMenuItem.separator())

            // Data paths
            if let mcp = ConfigManager.shared.config.mcp {
                let pathItems = [
                    L10n.MCP.qdrantPath(mcp.qdrantPath),
                    L10n.MCP.knowledgeBase(mcp.knowledgeBasePath),
                    L10n.MCP.modelCache(mcp.fastembedCacheDir),
                ]
                for text in pathItems {
                    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    sub.addItem(item)
                }
            }
        } else {
            let disabledItem = NSMenuItem(title: L10n.MCP.disabled, action: nil, keyEquivalent: "")
            disabledItem.isEnabled = false
            sub.addItem(disabledItem)
        }

        mcpMenuItem.submenu = sub
    }

    private func mcpStateText(_ state: MCPProcessManager.State) -> String {
        switch state {
        case .running: L10n.MCP.stateRunning
        case .initializing: L10n.MCP.stateInitializing
        case .restarting: L10n.MCP.stateRestarting
        case .stopped: L10n.MCP.stateStopped
        case .crashed: L10n.MCP.stateCrashed
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

            // providers 路由表：默认（providers[0]）勾选，点击切换默认
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

            // 异步获取今日用量
            let summaryItem = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            summaryItem.isEnabled = false
            sub.addItem(summaryItem)

            Task { @MainActor [summaryItem, sub] in
                let summary = await TokenProxyManager.shared.fetchTodaySummary()

                let inputK = Double(summary.input_tokens) / 1000
                let outputK = Double(summary.output_tokens) / 1000
                summaryItem.title = L10n.Proxy.today(inputK, outputK)

                if summary.total_requests > 0 {
                    sub.addItem(NSMenuItem.separator())
                    let invalidPct = summary.total_requests > 0
                        ? Double(summary.invalid_requests) / Double(summary.total_requests) * 100
                        : 0
                    let infoItem = NSMenuItem(
                        title: L10n.Proxy.requests(summary.total_requests, summary.invalid_requests, invalidPct),
                        action: nil, keyEquivalent: "",
                    )
                    infoItem.isEnabled = false
                    sub.addItem(infoItem)
                }
            }
        } else {
            let disabledItem = NSMenuItem(title: L10n.Proxy.disabled, action: nil, keyEquivalent: "")
            disabledItem.isEnabled = false
            sub.addItem(disabledItem)
        }

        proxyMenuItem.submenu = sub
    }

    private func proxyStateText(_ state: TokenProxyManager.State) -> String {
        switch state {
        case .running: L10n.Proxy.stateRunning
        case .stopped: L10n.Proxy.stateStopped
        case .crashed: L10n.Proxy.stateCrashed
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

    /// 点击 provider 项 → 将其设为默认（移到 providers[0]）并重启代理
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

        let total = configTasks.count + internalTasks.count
        tasksMenuItem.title = total == 0 ? L10n.Menu.tasks : L10n.Menu.tasksCount(total)
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
                    title: L10n.Menu.rssFetchFailed, body: error.localizedDescription,
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

    /// 终止所有正在运行的任务进程（应用退出时调用）
    func terminateAllTasks() {
        for (name, process) in runningProcesses {
            process.terminate()
            debugLog("[MenuBar] Terminated task on exit: \(name)")
        }
        runningProcesses.removeAll()
    }

    /// 清理配置和内部任务中已不存在的运行进程
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

        // 已在运行 → 终止
        if let process = runningProcesses[name] {
            process.terminate()
            runningProcesses.removeValue(forKey: name)
            sender.state = .off
            debugLog("[MenuBar] taskTrigger terminate name=\(name) runningKeys=\(Array(runningProcesses.keys))")
            return
        }

        // 启动执行（流式 API，获取 Process 句柄以支持终止）
        sender.state = .on
        let process = TaskExecutor.execute(
            task.exec,
            onOutput: nil,
            onComplete: { [weak self] result in
                DispatchQueue.main.async {
                    self?.runningProcesses.removeValue(forKey: name)
                    if result.success {
                        EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                            title: L10n.Menu.taskCompleted(name), body: "",
                        ))
                    } else {
                        let errMsg = result.error.isEmpty ? "exit code != 0" : String(result.error.prefix(200))
                        EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                            title: L10n.Menu.taskFailed(name), body: errMsg,
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
                title: L10n.Menu.launchAtLoginFailed, body: error.localizedDescription,
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
                title: L10n.Menu.configReloadFailed, body: error.localizedDescription,
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
