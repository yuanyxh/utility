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
                title: L10n.Menu.configLoadFailed, body: error.localizedDescription
            ))
        }
        do { try AppDatabase.shared.setup() } catch {
            EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
                title: L10n.Menu.dbInitFailed, body: error.localizedDescription
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

        registerAllHotkeys()
        installEventHandler()

        debugLog("[Utility] Ready")
    }

    func applicationWillTerminate(_: Notification) {
        MCPProcessManager.shared.stop()
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

    /// 配置重载：重新评估 MCP 服务 + 总结任务
    /// 无论 enabled/disabled、配置是否变更，都根据当前配置重新建立状态。
    private func onConfigReloaded() {
        let mcpConfig = ConfigManager.shared.config.mcp

        if mcpConfig?.enabled == false {
            // enabled→disabled：停服务 + 清总结任务
            debugLog("[MCP] Disabled by config reload, stopping...")
            MCPProcessManager.shared.stop()
            TaskScheduler.shared.unregisterInternalTask(named: "mcp-summary")
            return
        }

        // enabled 且配置可能已变：强制重启，所有新配置（port/qdrantPath/apiKey 等）
        // 在 MCPProcessManager.buildEnv() 中实时读取
        debugLog("[MCP] Restarting with new config...")
        MCPProcessManager.shared.forceRestart()
        updateMCPSummaryTask()
    }

    /// 注册/注销内置记忆总结任务。幂等：先清旧任务再按配置注册。
    private func updateMCPSummaryTask() {
        // 无论配置如何，先清旧任务
        TaskScheduler.shared.unregisterInternalTask(named: "mcp-summary")

        guard let mcp = ConfigManager.shared.config.mcp,
              mcp.summaryEnabled,
              mcp.enabled,
              let scriptPath = MCPProcessManager.shared.findScript(named: "summarize.py")
        else {
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

        let python = MCPProcessManager.pythonVenvPath
        let cmd = [
            "DEEPSEEK_API_KEY=\(apiKey)",
            "NOTES_DIR=\(notesDir)",
            "SUMMARY_API_URL=\(baseURL)",
            "SUMMARY_MODEL=\(model)",
            "MEMORY_SERVER_URL=\(serverURL)",
            python, scriptPath,
        ].joined(separator: " ")

        let task = TaskConfig(
            name: "mcp-summary",
            trigger: trigger,
            exec: .sh(cmd),
            enabled: true,
            mode: .cron
        )
        TaskScheduler.shared.registerInternalTask(task)
        debugLog("[MCP] Summary task registered (cron: \(trigger))")
    }

    private func registerAllHotkeys() {
        let config = ConfigManager.shared.config

        hotkeyManager.register(hotkey: config.clipboard.hotkey, id: "clip") { [weak self] in
            guard let self = self else { return }
            EventBus.shared.publish(PanelEvent.requestShow, payload: self.clipboardPanel)
        }

        hotkeyManager.register(hotkey: config.translation.hotkey, id: "tran") { [weak self] in
            guard let self = self else { return }
            EventBus.shared.publish(PanelEvent.requestShow, payload: self.translationPanel)
        }

        hotkeyManager.register(hotkey: config.translation.hotkeyOCR, id: "ocrt") { [weak self] in
            guard let self = self else { return }
            Task {
                if let text = await OCRService.selectAndRecognize() {
                    await MainActor.run {
                        EventBus.shared.publish(
                            PanelEvent.requestShow,
                            payload: [
                                "panel": self.translationPanel,
                                "text": text,
                            ]
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
                eventKind: UInt32(kEventHotKeyPressed)
            ),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                let handled = HotkeyManager.shared.handleEvent(event: event)
                return handled ? OSStatus(noErr) : OSStatus(eventNotHandledErr)
            },
            1, eventSpec, nil, nil
        )
    }
}
