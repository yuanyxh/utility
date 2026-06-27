import Carbon
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
  private let menuBar = MenuBarManager()
  private let hotkeyManager = HotkeyManager.shared
  let clipboardPanel = ClipboardPanelController()
  lazy var translationPanel = TranslationPanelController()
  lazy var chatPanel = ChatPanelController()
  private let stageWindow = StageWindowController()

  func applicationDidFinishLaunching(_: Notification) {
    debugLog("[Utility] Starting up...")

    NSApplication.shared.setActivationPolicy(.accessory)

    do { try ConfigManager.shared.load() } catch {
      EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
        title: L10n.Menu.configLoadFailed, body: error.localizedDescription))
    }
    do { try AppDatabase.shared.setup() } catch {
      EventBus.shared.publish(AppEvent.notify, payload: NotificationPayload(
        title: L10n.Menu.dbInitFailed, body: error.localizedDescription))
    }

    NotificationManager.shared.requestAuthorization()

    // 强制初始化 PanelManager（注册 EventBus 订阅）
    _ = PanelManager.shared
    KeyDispatcher.shared.start()
    TaskScheduler.shared.start()

    registerAllHotkeys()
    installEventHandler()

    debugLog("[Utility] Ready")
  }

  func applicationWillTerminate(_: Notification) {
    menuBar.terminateAllTasks()
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
              ])
          }
        }
      }
    }

    hotkeyManager.register(hotkey: config.chat.hotkey, id: "chat") { [weak self] in
      guard let self = self else { return }
      EventBus.shared.publish(PanelEvent.requestShow, payload: self.chatPanel)
    }
  }

  private func installEventHandler() {
    let eventSpec = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed))
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
