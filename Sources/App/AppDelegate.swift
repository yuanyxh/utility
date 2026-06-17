import Cocoa
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarManager()
    private let hotkeyManager = HotkeyManager.shared
    private let clipboardStorage = ClipboardStorage()
    private lazy var clipboardWatcher = ClipboardWatcher(storage: clipboardStorage)
    private lazy var clipboardPanel = ClipboardPanelController(storage: clipboardStorage)
    private lazy var translationPanel = TranslationPanelController()
    private lazy var stageWindow = StageWindowController()
    private lazy var stageMonitor = StageDropMonitor.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.debug("[Utility] Starting up...")

        // 无 Info.plist LSUIElement，代码设置（无 Dock 图标）
        NSApplication.shared.setActivationPolicy(.accessory)

        // 1. 加载配置
        do {
            try ConfigManager.shared.load()
        } catch {
            Log.debug("[Utility] Config load failed: \(error)")
        }

        // 2. 初始化数据库
        do {
            try AppDatabase.shared.setup()
        } catch {
            Log.debug("[Utility] Database setup failed: \(error)")
        }

        // 3. 启动剪切板监视
        clipboardWatcher.start()

        // 4. 注册热键
        registerAllHotkeys()

        // 5. 安装 Carbon 事件处理器
        installEventHandler()

        // 6. 更新菜单栏显示
        menuBar.updateConfigDisplay()

        // 7. 启动暂存监控
        stageMonitor.start(with: stageWindow)

        Log.debug("[Utility] Ready")
    }

    // MARK: - Hotkeys

    private func registerAllHotkeys() {
        let config = ConfigManager.shared.config

        // 剪切板面板
        hotkeyManager.register(hotkey: config.clipboard.hotkey, id: "clip") { [weak self] in
            self?.clipboardPanel.show()
        }

        // 翻译面板
        hotkeyManager.register(hotkey: config.translation.hotkey, id: "tran") { [weak self] in
            guard let self = self else { return }

            if self.translationPanel.isPanelVisible {
                // 已显示 → 直接填入并翻译
                let selected = self.translationPanel.getSelectedText()
                if let text = selected {
                    self.translationPanel.fillAndTranslate(text)
                }
            } else {
                // 立即弹出空面板（不激活），后台逐步获取选中文本
                self.translationPanel.showEmpty()

                Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
                    // 1. AX 快速路径
                    if let text = self.translationPanel.tryAXSelectedText(), !text.isEmpty {
                        self.translationPanel.fillAndTranslate(text)
                        self.translationPanel.activateForInput()
                        return
                    }
                    // 2. 剪贴板兜底（源 app 仍在前台，cmd+c 有效）
                    if let text = self.translationPanel.clipboardFallbackSelectedText(), !text.isEmpty {
                        self.translationPanel.fillAndTranslate(text)
                        self.translationPanel.activateForInput()
                        return
                    }
                    // 3. 无选中文本 → 激活面板，用户手动输入
                    self.translationPanel.activateForInput()
                }
            }
        }

        // OCR 翻译
        hotkeyManager.register(hotkey: config.translation.hotkeyOCR, id: "ocrt") { [weak self] in
            guard let self = self else { return }
            Task {
                if let text = await OCRService.selectAndRecognize() {
                    await MainActor.run {
                        if self.translationPanel.isPanelVisible {
                            self.translationPanel.fillAndTranslate(text)
                        } else {
                            self.translationPanel.show(with: text)
                            // OCR 识别完成后自动翻译
                            Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
                                self.translationPanel.startTranslation(text: text)
                            }
                        }
                    }
                }
            }
        }
    }

    private func installEventHandler() {
        let eventSpec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed))
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, _) -> OSStatus in
                let handled = HotkeyManager.shared.handleEvent(event: event)
                return handled ? OSStatus(noErr) : OSStatus(eventNotHandledErr)
            },
            1, eventSpec, nil, nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.debug("[Utility] Shutting down...")
    }
}
