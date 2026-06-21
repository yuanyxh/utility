import Cocoa
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let menuBar = MenuBarManager()
    private let hotkeyManager = HotkeyManager.shared
    private let clipboardStorage = ClipboardStorage()
    private(set) lazy var clipboardWatcher = ClipboardWatcher(storage: clipboardStorage)
    lazy var clipboardPanel = ClipboardPanelController(storage: clipboardStorage)
    lazy var translationPanel = TranslationPanelController()
    private lazy var stageWindow = StageWindowController()
    private lazy var stageMonitor = StageDropMonitor.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("[Utility] Starting up...")

        NSApplication.shared.setActivationPolicy(.accessory)

        do {
            try ConfigManager.shared.load()
        } catch {
            debugLog("[Utility] Config load failed: \(error)")
            NotificationManager.shared.error(L10n.Menu.configLoadFailed, "\(error.localizedDescription)")
        }
        do {
            try AppDatabase.shared.setup()
        } catch {
            debugLog("[Utility] Database setup failed: \(error)")
            NotificationManager.shared.error(L10n.Menu.dbInitFailed, "\(error.localizedDescription)")
        }

        // L10n.setup() 已通过 NotificationCenter 通知所有组件刷新标题
        // 各组件自行 observe L10n.languageDidChange

        clipboardWatcher.start()
        registerAllHotkeys()
        installEventHandler()
        stageMonitor.start(with: stageWindow)

        NotificationManager.shared.requestAuthorization()
        TaskScheduler.shared.installWakeObserver()
        TaskScheduler.shared.start()
        
        debugLog("[Utility] Ready")
    }

    // MARK: - Hotkeys

    private func registerAllHotkeys() {
        let config = ConfigManager.shared.config

        hotkeyManager.register(hotkey: config.clipboard.hotkey, id: "clip") { [weak self] in
            self?.clipboardPanel.show()
        }

        hotkeyManager.register(hotkey: config.translation.hotkey, id: "tran") { [weak self] in
            guard let self = self else { return }

            if self.translationPanel.isPanelVisible {
                guard let app = self.translationPanel.previousFrontmostApp else { return }
                Task { @MainActor in
                    if let text = await SelectedTextService.getSelectedText(from: app) {
                        self.translationPanel.fillAndTranslate(text)
                    }
                }
                return
            }

            let preApp = NSWorkspace.shared.frontmostApplication
            self.translationPanel.previousFrontmostApp = preApp

            if let app = preApp, let text = SelectedTextService.tryAXSelectedText(from: app), !text.isEmpty {
                self.translationPanel.show(with: text)
                self.translationPanel.startTranslation(text: text)
            } else {
                self.translationPanel.showEmpty()
                guard let app = preApp else { return }
                Task { @MainActor in
                    if let text = await SelectedTextService.getSelectedText(from: app), !text.isEmpty {
                        self.translationPanel.activateForInput()
                        self.translationPanel.fillAndTranslate(text)
                    } else {
                        self.translationPanel.activateForInput()
                    }
                }
            }
        }

        hotkeyManager.register(hotkey: config.translation.hotkeyOCR, id: "ocrt") { [weak self] in
            guard let self = self else { return }
            Task {
                if let text = await OCRService.selectAndRecognize() {
                    await MainActor.run {
                        if self.translationPanel.isPanelVisible {
                            self.translationPanel.fillAndTranslate(text)
                        } else {
                            self.translationPanel.show(with: text)
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
}
