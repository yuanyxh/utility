import Cocoa

#if !DEBUG
  import UserNotifications
#endif

/// 统一通知管理器
/// DEBUG: NSUserNotificationCenter（原生二进制调试兼容）
/// RELEASE: UNUserNotificationCenter（正式 .app bundle）
/// 不再被外部直接调用 — 改为订阅 EventBus 事件自动转发系统通知
public final class NotificationManager: NSObject {
  public static let shared = NotificationManager()

  #if DEBUG
    private var enabled = false
  #else
    private var granted = false
  #endif

  override private init() {
    super.init()
  }

  // MARK: - Auth

  public func requestAuthorization() {
    #if DEBUG
      let center = NSUserNotificationCenter.default
      center.delegate = self
      enabled = true
    #else
      let center = UNUserNotificationCenter.current()
      center.delegate = self
      center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        self.granted = granted
      }
    #endif

    subscribeToEvents()
  }

  // MARK: - Event subscriptions

  private func subscribeToEvents() {
    let bus = EventBus.shared

    bus.subscribe(AppEvent.configLoadFailed) { payload in
      guard let msg = payload as? String else { return }
      self.post(title: L10n.Menu.configLoadFailed, body: msg)
    }
    bus.subscribe(AppEvent.configReloadFailed) { payload in
      guard let msg = payload as? String else { return }
      self.post(title: L10n.Menu.configReloadFailed, body: msg)
    }
    bus.subscribe(AppEvent.databaseInitFailed) { payload in
      guard let msg = payload as? String else { return }
      self.post(title: L10n.Menu.dbInitFailed, body: msg)
    }
    bus.subscribe(AppEvent.hotkeyParseFailed) { payload in
      guard let (id, hotkey) = payload as? (String, String) else { return }
      self.post(title: L10n.Menu.hotkeyParseFailed, body: "\(id): \(hotkey)")
    }
    bus.subscribe(AppEvent.hotkeyRegistrationFailed) { payload in
      guard let (id, hotkey) = payload as? (String, String) else { return }
      self.post(
        title: L10n.Menu.hotkeyRegisterFailed,
        body: L10n.format("notify.hotkey_register_failed_body", id, hotkey))
    }
    bus.subscribe(AppEvent.taskDidFail) { payload in
      guard let (name, error) = payload as? (String, String) else { return }
      self.post(title: L10n.Menu.taskFailed(name), body: error)
    }
    bus.subscribe(AppEvent.launchAtLoginFailed) { payload in
      guard let msg = payload as? String else { return }
      self.post(title: L10n.Menu.launchAtLoginFailed, body: msg)
    }
    bus.subscribe(AppEvent.rssFetchFailed) { payload in
      guard let msg = payload as? String else { return }
      self.post(title: L10n.Menu.rssFetchFailed, body: msg)
    }
  }

  // MARK: - Post (private)

  private func post(title: String, body: String) {
    #if DEBUG
      guard enabled else { return }
      let note = NSUserNotification()
      note.title = title
      note.informativeText = body
      note.soundName = NSUserNotificationDefaultSoundName
      note.deliveryDate = Date()
      NSUserNotificationCenter.default.scheduleNotification(note)
    #else
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil)
      UNUserNotificationCenter.current().add(request) { error in
        if let e = error { debugLog("[Notify] Post failed: \(e)") }
      }
    #endif
  }
}

// MARK: - Delegates

#if DEBUG
  extension NotificationManager: NSUserNotificationCenterDelegate {
    public func userNotificationCenter(
      _: NSUserNotificationCenter,
      shouldPresent _: NSUserNotification
    ) -> Bool {
      return true
    }
  }
#else
  extension NotificationManager: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
      _: UNUserNotificationCenter,
      willPresent _: UNNotification,
      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
      completionHandler([.banner, .sound])
    }
  }
#endif
