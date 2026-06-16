import Cocoa
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarManager()
    private let hotkeyManager = HotkeyManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Utility] Starting up...")

        // 1. 加载配置
        do {
            try ConfigManager.shared.load()
        } catch {
            print("[Utility] Config load failed: \(error)")
        }

        // 2. 初始化数据库
        do {
            try AppDatabase.shared.setup()
        } catch {
            print("[Utility] Database setup failed: \(error)")
        }

        // 3. 注册热键
        registerAllHotkeys()

        // 4. 安装 Carbon 事件处理器
        installEventHandler()

        // 5. 更新菜单栏显示
        menuBar.updateConfigDisplay()

        print("[Utility] Ready")
    }

    // MARK: - Hotkeys

    private func registerAllHotkeys() {
        let config = ConfigManager.shared.config

        // 剪切板面板 — 后期由 ClipboardManager 接管
        hotkeyManager.register(hotkey: config.clipboard.hotkey, id: "clip") {
            print("[Hotkey] Clipboard panel")
        }

        // 翻译面板
        hotkeyManager.register(hotkey: config.translation.hotkey, id: "tran") {
            print("[Hotkey] Translation panel")
        }

        // OCR 翻译
        hotkeyManager.register(hotkey: config.translation.hotkeyOCR, id: "ocrt") {
            print("[Hotkey] OCR translation")
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
        print("[Utility] Shutting down...")
    }
}
