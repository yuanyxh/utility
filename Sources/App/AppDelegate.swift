import Carbon
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let menuBar = MenuBarManager()
    private let hotkeyManager = HotkeyManager.shared
    let clipboardPanel = ClipboardPanelController()
    lazy var translationPanel = TranslationPanelController()
    private let stageWindow = StageWindowController()

    func applicationDidFinishLaunching(_: Notification) {
        debugLog("[Utility] Starting up...")

        NSApplication.shared.setActivationPolicy(.accessory)

        do { try ConfigManager.shared.load() } catch {
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Menu.configLoadFailed, body: error.localizedDescription,
            ))
        }
        do { try AppDatabase.shared.setup() } catch {
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Menu.dbInitFailed, body: error.localizedDescription,
            ))
        }

        NotificationManager.shared.requestAuthorization()

        // 强制初始化 PanelManager（注册 EventBus 订阅）
        _ = PanelManager.shared
        KeyDispatcher.shared.start()
        TaskScheduler.shared.start()

        // 订阅配置重载，重新评估 MCP 服务 + 总结任务
        EventBus.shared.subscribe(AppEvent.configDidLoad) { [weak self] _ in
            self?.onConfigReloaded()
        }

        // 启动 MCP 服务
        startMCPService()

        // 启动 Token 代理监控
        startTokenProxy()

        // 注册 gen-article 手动任务
        updateArticleTask()

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

    /// 启动 Token 代理监控
    private func startTokenProxy() {
        guard ConfigManager.shared.config.modelProxy?.enabled ?? false else {
            debugLog("[TokenProxy] Disabled by config")
            return
        }
        debugLog("[TokenProxy] Starting service...")
        TokenProxyManager.shared.start()
    }

    /// 配置重载：重新评估 MCP 服务 + 总结任务 + Token 代理
    /// 无论 enabled/disabled、配置是否变更，都根据当前配置重新建立状态。
    private func onConfigReloaded() {
        let mcpConfig = ConfigManager.shared.config.mcp

        if mcpConfig?.enabled == false {
            // enabled→disabled：停服务 + 清总结任务
            debugLog("[MCP] Disabled by config reload, stopping...")
            MCPProcessManager.shared.stop()
            TaskScheduler.shared.unregisterInternalTask(named: "mcp-summary")
        } else {
            // enabled 且配置可能已变：强制重启，所有新配置（port/qdrantPath/apiKey 等）
            // 在 PythonScriptRunner.baseEnvironment() + serverEnvironment 中实时读取
            debugLog("[MCP] Restarting with new config...")
            MCPProcessManager.shared.forceRestart()
            updateMCPSummaryTask()
        }

        // Token 代理：根据配置重启或停止
        let proxyEnabled = ConfigManager.shared.config.modelProxy?.enabled ?? false
        if proxyEnabled {
            debugLog("[TokenProxy] Restarting with new config...")
            TokenProxyManager.shared.forceRestart()
        } else {
            TokenProxyManager.shared.stop()
        }

        // gen-article 内部任务：按配置注册/注销
        updateArticleTask()
    }

    /// 注册/注销内置记忆总结任务。幂等：disabled 时注销；enabled 时直接注册。
    /// 注意：enabled 时不要先 unregister——unregister 会清掉 last_fire，register 后
    /// handleMissed 会把「今天 17:00 已触发过」误判为未触发，导致每天 17:00 后每次
    /// 重启/reload 配置都重复触发一次总结。
    private func updateMCPSummaryTask() {
        guard let mcp = ConfigManager.shared.config.mcp,
              mcp.summaryEnabled,
              mcp.enabled,
              let scriptPath = PythonScriptRunner.findScript(named: "summarize.py")
        else {
            TaskScheduler.shared.unregisterInternalTask(named: "mcp-summary")
            debugLog("[MCP] Summary task disabled or unavailable")
            return
        }

        let hour = mcp.summaryHour
        let trigger = "0 \(hour) * * *"
        let ai = ConfigManager.shared.config.ai
        let apiKey = ai.apiKey
        let notesDir = (mcp.knowledgeBasePath as NSString).expandingTildeInPath
        let baseURL = ai.baseURL.isEmpty ? "https://api.deepseek.com" : ai.baseURL
        let model = ai.model.isEmpty ? "deepseek-v4-flash" : ai.model
        let serverURL = "http://localhost:\(mcp.port)"

        var args: [String] = []
        if mcp.summaryStatsOnly {
            args.append("--stats-only")
        }
        let excludeTagsStr = mcp.excludeTags.joined(separator: ",")
        let cmd = PythonScriptRunner.shellCommand(
            script: scriptPath,
            arguments: args,
            environmentOverrides: [
                "DEEPSEEK_API_KEY": apiKey,
                "NOTES_DIR": notesDir,
                "SUMMARY_API_URL": baseURL,
                "SUMMARY_MODEL": model,
                "MEMORY_SERVER_URL": serverURL,
                "UTILITY_DATA_DIR": AppPaths.configDir.path,
                "SUMMARY_EXCLUDE_TAGS": excludeTagsStr,
            ],
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

    /// 注册/注销 gen-article 手动任务：素材自动化 + 文章生成一条龙。
    /// 路径一律由 knowledgeBasePath 推导 Gen_Articles/ 工作目录，不做路径配置。
    /// 幂等：disabled 时注销；enabled 时直接注册（内部同名替换）。
    private func updateArticleTask() {
        let article = ConfigManager.shared.config.article
        guard article.enabled,
              let kbPath = ConfigManager.shared.config.mcp?.knowledgeBasePath,
              !kbPath.isEmpty,
              let prepareScript = PythonScriptRunner.findScript(named: "prepare_article_source.py"),
              let genScript = PythonScriptRunner.findScript(named: "gen_article_generic.py")
        else {
            TaskScheduler.shared.unregisterInternalTask(named: "gen-article")
            debugLog("[Article] Task disabled or unavailable")
            return
        }

        let genDir = (kbPath as NSString).expandingTildeInPath + "/Gen_Articles"
        let topicPath = genDir + "/topic.md"
        let factsPath = genDir + "/topic_facts.md"
        let soulPath = genDir + "/SOUL.md"
        let articlesDir = genDir + "/articles"

        let agent = article.agentCli
        let prepareCmd = PythonScriptRunner.shellCommand(
            script: prepareScript,
            arguments: ["--topic", topicPath, "--out", factsPath, "--agent", "'\(agent)'"],
        )
        let genArgs = [
            "--soul", soulPath,
            "--src", factsPath,
            "--topic", "\"$TOPIC\"",
            "--out", articlesDir,
            "--retries", "\(article.retries)",
        ] + (article.judge ? ["--judge"] : []) + ["--agent", "'\(agent)'"]
        let genCmd = PythonScriptRunner.shellCommand(
            script: genScript,
            arguments: genArgs,
        )
        // --topic 取 topic.md 全文（prepare 素材的主题来源），shell 定义变量后传给 gen
        let cmd = prepareCmd + " && TOPIC=\"$(cat \"\(topicPath)\")\" && " + genCmd

        let task = TaskConfig(
            name: "gen-article",
            trigger: "",
            exec: .sh(cmd),
            enabled: true,
            mode: .manual,
        )
        TaskScheduler.shared.registerInternalTask(task)
        debugLog("[Article] gen-article task registered (manual)")
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
