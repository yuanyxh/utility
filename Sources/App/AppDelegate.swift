import Carbon
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let menuBar = MenuBarManager()
    private let hotkeyManager = HotkeyManager.shared
    let clipboardPanel = ClipboardPanelController()
    lazy var translationPanel = TranslationPanelController()
    let knowledgePanel = KnowledgePanelController()
    private let stageWindow = StageWindowController()

    func applicationDidFinishLaunching(_: Notification) {
        debugLog("[Utility] Starting up...")

        NSApplication.shared.setActivationPolicy(.accessory)

        do { try ConfigManager.shared.load() } catch {
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Notify.configLoadFailed, body: error.localizedDescription,
            ))
        }
        do { try AppDatabase.shared.setup() } catch {
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Notify.dbInitFailed, body: error.localizedDescription,
            ))
        }

        NotificationManager.shared.requestAuthorization()

        // Force-initialize PanelManager (registers EventBus subscriptions)
        _ = PanelManager.shared
        KeyDispatcher.shared.start()
        TaskScheduler.shared.start()

        // Subscribe to config reload to re-evaluate the MCP service + summary task
        EventBus.shared.subscribe(AppEvent.configDidLoad) { [weak self] _ in
            self?.onConfigReloaded()
        }

        // Start the MCP service
        startMCPService()

        // Start the Token proxy monitor
        startTokenProxy()

        // Register the built-in RSS daily task
        updateRSSDailyTask()

        // Register the manual article-generation task
        updateGenArticlesTask()

        KnowledgeService.shared.panel = knowledgePanel
        KnowledgeService.shared.start()
        // 菜单入口走这个引用;漏赋值时 showKnowledgePanel 的 guard 会静默 return(点了没反应、无日志)
        menuBar.knowledgePanel = knowledgePanel

        registerAllHotkeys()
        installEventHandler()

        debugLog("[Utility] Ready")
    }

    func applicationWillTerminate(_: Notification) {
        MCPProcessManager.shared.stop()
        TokenProxyManager.shared.stop()
        menuBar.terminateAllTasks()
    }

    /// Start MCP Python server if enabled in config.
    private func startMCPService() {
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

        // Article generation: manual task bound to Gen_Articles/config.json
        updateGenArticlesTask()
    }

    /// Register/unregister the built-in memory summary task. Idempotent: unregister when disabled; register directly when enabled.
    /// Note: when enabled, do not unregister first — unregister clears last_fire, and after register,
    /// handleMissed would misjudge "already fired at today 17:00" as not fired, causing an extra summary run
    /// after every restart/reload past 17:00 each day.
    private func updateMCPSummaryTask() {
        guard let mcp = ConfigManager.shared.config.mcp,
              mcp.summaryEnabled,
              mcp.enabled,
              let scriptPath = PythonScriptRunner.findScript(named: PythonScripts.summarize)
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
            script: scriptPath,
            // Values come from the **same source** as the MCP service process (`PythonScriptRunner.taskEnvironmentOverrides`).
            // This used to keep its own whitelist, so newly added `AI_LLM_TIMEOUT` / `UTILITY_LANG` were only added on
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
        guard daily.enabled,
              let scriptPath = PythonScriptRunner.findScript(named: PythonScripts.rssDaily)
        else {
            TaskScheduler.shared.unregisterInternalTask(named: "rss-daily")
            debugLog("[RSS] Daily task disabled or unavailable")
            return
        }

        let mcp = ConfigManager.shared.config.mcp
        let overrides = PythonScriptRunner.taskEnvironmentOverrides(
            memoryServerURL: HTTP.localBaseURL(port: mcp?.port ?? 0),
            excludeTags: mcp?.excludeTags.joined(separator: ",") ?? "",
        )
        let cmd = PythonScriptRunner.shellCommand(script: scriptPath, environmentOverrides: overrides)

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

    /// Manual-only article task. Code is bundled; configuration is always
    /// `<dir>/config.json`, so only the directory is configurable.
    private func updateGenArticlesTask() {
        let cfg = ConfigManager.shared.config.genArticles
        guard cfg.enabled,
              let scriptPath = PythonScriptRunner.findScript(named: PythonScripts.genArticles)
        else {
            TaskScheduler.shared.unregisterInternalTask(named: "gen-articles")
            debugLog("[GenArticles] Task disabled or script unavailable")
            return
        }

        let rawDir = cfg.dir.isEmpty
            ? "~/Documents/selfdata/notes/Gen_Articles"
            : cfg.dir
        let dir = (rawDir as NSString).expandingTildeInPath
        let configPath = (dir as NSString).appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath) else {
            TaskScheduler.shared.unregisterInternalTask(named: "gen-articles")
            debugLog("[GenArticles] Missing config: \(configPath)")
            return
        }

        let mcp = ConfigManager.shared.config.mcp
        var overrides = PythonScriptRunner.taskEnvironmentOverrides(
            memoryServerURL: HTTP.localBaseURL(port: mcp?.port ?? 0),
            excludeTags: mcp?.excludeTags.joined(separator: ",") ?? "",
        )
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            overrides["UTILITY_VERSION"] = version
        }
        let cmd = PythonScriptRunner.shellCommand(
            script: scriptPath,
            arguments: ["--dir", PythonScriptRunner.shellQuote(dir)],
            environmentOverrides: overrides,
        )
        let task = TaskConfig(
            name: "gen-articles",
            trigger: "",
            exec: .sh(cmd),
            enabled: true,
            mode: .manual,
        )
        TaskScheduler.shared.registerInternalTask(task)
        debugLog("[GenArticles] Manual task registered (dir: \(dir))")
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
            EventBus.shared.publish(PanelEvent.requestShow, payload: knowledgePanel)
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
