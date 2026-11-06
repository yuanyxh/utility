import Carbon
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let menuBar = MenuBarManager()
    private let hotkeyManager = HotkeyManager.shared
    let clipboardPanel = ClipboardPanelController()
    lazy var translationPanel = TranslationPanelController()
    let knowledgePanel = KnowledgePanelController()
    private let stageWindow = StageWindowController()

    private let terminationLock = NSLock()
    private var terminateRequested = false
    private var terminationAllowed = false

    /// True from the first quit request until the process exits; blocks restarting children.
    private var isTerminating: Bool {
        terminationLock.lock()
        defer { terminationLock.unlock() }
        return terminateRequested
    }

    func applicationDidFinishLaunching(_: Notification) {
        debugLog("[Utility] Starting up...")
        #if DEBUG
            CursorTrace.installIfRequested()
        #endif

        do { try ConfigManager.shared.load() } catch {
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Notify.configLoadFailed, body: error.localizedDescription,
            ))
        }
        applyActivationPolicy()
        MainActor.assumeIsolated { AppMainMenu.install() }
        do { try AppDatabase.shared.setup() } catch {
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Notify.dbInitFailed, body: error.localizedDescription,
            ))
        }

        NotificationManager.shared.requestAuthorization()
        NoticeWatcher.shared.start()

        // Force-initialize PanelManager (registers EventBus subscriptions)
        _ = PanelManager.shared
        KeyDispatcher.shared.start()
        MainActor.assumeIsolated {
            EditingShortcutRouter.install()
        }
        TaskScheduler.shared.start()

        // Subscribe to config reload to re-evaluate the MCP service + summary task
        EventBus.shared.subscribe(AppEvent.configDidLoad) { [weak self] _ in
            self?.onConfigReloaded()
        }

        KnowledgeService.shared.panel = knowledgePanel
        // 菜单入口走这个引用;漏赋值时 showKnowledgePanel 的 guard 会静默 return(点了没反应、无日志)
        menuBar.knowledgePanel = knowledgePanel

        GatewayResources.logResolution()
        // Everything below shells out to the gateway: install the bundled wheel first
        // (no-op after the first launch of a given version).
        GatewayInstaller.ensureInstalled { [weak self] in
            guard let self, !self.isTerminating else { return }
            self.startMCPService()
            self.startTokenProxy()
            self.updateRSSDailyTask()
            KnowledgeService.shared.start()
        }

        registerAllHotkeys()
        installEventHandler()

        if ConfigManager.shared.config.app.showTerminalOnLaunch,
           ConfigManager.shared.config.terminal.enabled
        {
            MainActor.assumeIsolated { WorkspaceManager.shared.showWindow() }
        }

        debugLog("[Utility] Ready")
    }

    /// Stop the children in the background and keep the main thread free: the blocking
    /// `stopAndWait` used to freeze the UI until the SIGTERM grace period expired.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationLock.lock()
        let pendingConfirmation = !terminateRequested
        terminationLock.unlock()
        // Ask before touching terminateRequested so a cancel leaves the app fully alive.
        if pendingConfirmation,
            !MainActor.assumeIsolated({ WorkspaceManager.shared.confirmTermination() })
        {
            return .terminateCancel
        }
        terminationLock.lock()
        let alreadyAsked = terminateRequested
        terminateRequested = true
        let alreadyReplied = terminationAllowed
        terminationLock.unlock()
        // A repeated request rides the pending shutdown; once replied there is nobody left to
        // answer, so quit immediately instead of waiting for a reply that will never come.
        guard !alreadyAsked else {
            return alreadyReplied ? .terminateNow : .terminateLater
        }

        for window in sender.windows {
            window.orderOut(nil)
        }
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            MCPProcessManager.shared.stopAndWait()
        }
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            TokenProxyManager.shared.stopAndWait()
        }
        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            self?.replyTermination()
        }
        // A child that never dies must not keep the app alive past the shutdown budget.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.replyTermination()
        }
        return .terminateLater
    }

    private func replyTermination() {
        terminationLock.lock()
        let alreadyReplied = terminationAllowed
        terminationAllowed = true
        terminationLock.unlock()
        guard !alreadyReplied else { return }
        DispatchQueue.main.async {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    func applicationWillTerminate(_: Notification) {
        menuBar.terminateAllTasks()
        MainActor.assumeIsolated {
            WorkspaceManager.shared.shutdown()
        }
    }

    /// Start MCP Python server if enabled in config.
    private func startMCPService() {
        guard !isTerminating else { return }
        guard ConfigManager.shared.config.mcp?.enabled ?? false else {
            debugLog("[MCP] Disabled by config")
            return
        }
        debugLog("[MCP] Starting service...")
        MCPProcessManager.shared.start()
        updateMCPSummaryTask()
    }

    /// Start the Token proxy monitor
    private func startTokenProxy() {
        guard !isTerminating else { return }
        guard ConfigManager.shared.config.modelProxy?.enabled ?? false else {
            debugLog("[TokenProxy] Disabled by config")
            return
        }
        debugLog("[TokenProxy] Starting service...")
        TokenProxyManager.shared.start()
    }

    /// Config reload: re-evaluate the MCP service + summary task + Token proxy
    /// Regardless of enabled/disabled or whether the config changed, re-establish state from the current config.
    private func onConfigReloaded() {
        guard !isTerminating else { return }
        let mcpConfig = ConfigManager.shared.config.mcp

        if mcpConfig?.enabled == false {
            // enabled→disabled: stop the service + clear the summary task
            debugLog("[MCP] Disabled by config reload, stopping...")
            MCPProcessManager.shared.stop()
            TaskScheduler.shared.unregisterInternalTask(named: "mcp-summary")
        } else {
            // enabled and the config may have changed: force restart; all new config (port/qdrantPath/apiKey, etc.)
            // is read in real time in PythonScriptRunner.baseEnvironment() + serverEnvironment
            debugLog("[MCP] Restarting with new config...")
            MCPProcessManager.shared.forceRestart()
            updateMCPSummaryTask()
        }

        // Token proxy: restart or stop depending on config
        let proxyEnabled = ConfigManager.shared.config.modelProxy?.enabled ?? false
        if proxyEnabled {
            debugLog("[TokenProxy] Restarting with new config...")
            TokenProxyManager.shared.forceRestart()
        } else {
            TokenProxyManager.shared.stop()
        }

        // Knowledge panel: rebuild the two timers per the new intervals / enabled flag
        KnowledgeService.shared.rearm()

        // RSS daily: re-evaluate the built-in task against the new config
        updateRSSDailyTask()

        // App shape: hideDockIcon takes effect without a restart
        applyActivationPolicy()
    }

    /// Delegates to `AppActivation`, which keeps the app regular while the main window is open.
    private func applyActivationPolicy() {
        MainActor.assumeIsolated { AppActivation.apply() }
    }

    /// Dock icon click: bring the main window back when nothing is visible.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainActor.assumeIsolated {
            if ConfigManager.shared.config.terminal.enabled {
                WorkspaceManager.shared.showWindow()
            } else if let window = AppWindowRegistry.frontmostWindow {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    /// Register/unregister the built-in memory summary task. Idempotent: unregister when disabled; register directly when enabled.
    /// Note: when enabled, do not unregister first — unregister clears last_fire, and after register,
    /// handleMissed would misjudge "already fired at today 17:00" as not fired, causing an extra summary run
    /// after every restart/reload past 17:00 each day.
    private func updateMCPSummaryTask() {
        guard let mcp = ConfigManager.shared.config.mcp,
              mcp.summaryEnabled,
              mcp.enabled,
              PythonScriptRunner.isGatewayAvailable
        else {
            TaskScheduler.shared.unregisterInternalTask(named: "mcp-summary")
            debugLog("[MCP] Summary task disabled or unavailable")
            return
        }

        let hour = mcp.summaryHour
        let trigger = "0 \(hour) * * *"
        let serverURL = HTTP.localBaseURL(port: mcp.port)
        let excludeTagsStr = mcp.excludeTags.joined(separator: ",")
        let cmd = PythonScriptRunner.shellCommand(
            entry: GatewayEntry.summarize,
            // Values come from the **same source** as the MCP service process (`PythonScriptRunner.taskEnvironmentOverrides`).
            // This used to keep its own whitelist, so newly added `AI_LLM_TIMEOUT` / `GATEWAY_LANG` were only added on
            // the service-process side, making the scheduled summary always use a 120s timeout and still use the Chinese prompt under an English UI.
            environmentOverrides: PythonScriptRunner.taskEnvironmentOverrides(
                memoryServerURL: serverURL,
                excludeTags: excludeTagsStr,
            ),
        )

        let task = TaskConfig(
            name: "mcp-summary",
            trigger: trigger,
            exec: .sh(cmd),
            enabled: true,
            mode: .cron,
        )
        TaskScheduler.shared.registerInternalTask(task)
        debugLog("[MCP] Summary task registered (cron: \(trigger))")
    }

    /// Register/unregister the built-in RSS daily task. Idempotent: unregister only when disabled;
    /// register directly when enabled (same-name replacement — unregistering first would clear last_fire
    /// and make handleMissed re-fire the task after every restart).
    private func updateRSSDailyTask() {
        let daily = ConfigManager.shared.config.rss.daily
        guard daily.enabled, PythonScriptRunner.isGatewayAvailable else {
            TaskScheduler.shared.unregisterInternalTask(named: "rss-daily")
            debugLog("[RSS] Daily task disabled or unavailable")
            return
        }

        guard let executable = Bundle.main.executablePath else {
            TaskScheduler.shared.unregisterInternalTask(named: "rss-daily")
            debugLog("[RSS] executable path unavailable, daily task disabled")
            return
        }
        let cmd = "\(PythonScriptRunner.shellQuote(executable)) rss --digest --fetch"

        let cron = daily.cron.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = TaskConfig(
            name: "rss-daily",
            trigger: cron,
            exec: .sh(cmd),
            enabled: true,
            mode: cron.isEmpty ? .manual : .cron,
        )
        TaskScheduler.shared.registerInternalTask(task)
        debugLog("[RSS] Daily task registered (\(cron.isEmpty ? "manual" : "cron: \(cron)"))")
    }

    private func registerAllHotkeys() {
        let config = ConfigManager.shared.config

        hotkeyManager.register(hotkey: config.clipboard.hotkey, id: "clip") { [weak self] in
            guard let self else { return }
            EventBus.shared.publish(PanelEvent.requestShow, payload: clipboardPanel)
        }

        hotkeyManager.register(hotkey: config.translation.hotkey, id: "tran") { [weak self] in
            guard let self else { return }
            EventBus.shared.publish(PanelEvent.requestShow, payload: translationPanel)
        }

        hotkeyManager.register(hotkey: config.knowledge.hotkey, id: "know") { [weak self] in
            guard let self else { return }
            let event = knowledgePanel.isPanelVisible ? PanelEvent.requestClose : PanelEvent.requestShow
            EventBus.shared.publish(event, payload: knowledgePanel)
        }

        if config.terminal.enabled {
            hotkeyManager.register(hotkey: config.terminal.hotkey, id: "term") {
                Task { @MainActor in
                    WorkspaceManager.shared.toggleWindow()
                }
            }
        }

        hotkeyManager.register(hotkey: config.translation.hotkeyOCR, id: "ocrt") { [weak self] in
            guard let self else { return }
            Task {
                if let text = await OCRService.selectAndRecognize() {
                    await MainActor.run {
                        EventBus.shared.publish(
                            PanelEvent.requestShow,
                            payload: [
                                "panel": self.translationPanel,
                                "text": text,
                            ],
                        )
                    }
                }
            }
        }
    }

    private func installEventHandler() {
        let eventSpec = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed),
            ),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                let handled = HotkeyManager.shared.handleEvent(event: event)
                return handled ? OSStatus(noErr) : OSStatus(eventNotHandledErr)
            },
            1, eventSpec, nil, nil,
        )
    }
}
