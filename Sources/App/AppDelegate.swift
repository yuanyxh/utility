import Cocoa
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarManager()
    private let hotkeyManager = HotkeyManager.shared
    private let clipboardStorage = ClipboardStorage()
    private lazy var clipboardWatcher = ClipboardWatcher(storage: clipboardStorage)
    lazy var clipboardPanel = ClipboardPanelController(storage: clipboardStorage)
    lazy var translationPanel = TranslationPanelController()
    private lazy var stageWindow = StageWindowController()
    private lazy var stageMonitor = StageDropMonitor.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.debug("[Utility] Starting up...")

        NSApplication.shared.setActivationPolicy(.accessory)

        do { try ConfigManager.shared.load() } catch { Log.debug("[Utility] Config load failed: \(error)") }
        do { try AppDatabase.shared.setup() } catch { Log.debug("[Utility] Database setup failed: \(error)") }

        clipboardWatcher.start()
        registerAllHotkeys()
        installEventHandler()
        menuBar.updateConfigDisplay()
        stageMonitor.start(with: stageWindow)

        Log.debug("[Utility] Ready")
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
                let selected = self.translationPanel.getSelectedText()
                if let text = selected {
                    self.translationPanel.fillAndTranslate(text)
                }
            } else {
                self.translationPanel.previousFrontmostApp = NSWorkspace.shared.frontmostApplication
                if let text = self.translationPanel.tryAXSelectedText(), !text.isEmpty {
                    self.translationPanel.show(with: text)
                    Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
                        self.translationPanel.startTranslation(text: text)
                    }
                } else {
                    self.translationPanel.showEmpty()
                    Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in
                        if let text = self.translationPanel.clipboardFallbackSelectedText(), !text.isEmpty {
                            self.translationPanel.activateForInput()
                            self.translationPanel.fillAndTranslate(text)
                        } else {
                            self.translationPanel.activateForInput()
                        }
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

    func applicationWillTerminate(_ notification: Notification) {
        Log.debug("[Utility] Shutting down...")
    }
}
