import Cocoa
#if !DEBUG
import UserNotifications
#endif

/// 统一通知管理器
/// DEBUG: NSUserNotificationCenter（原生二进制调试兼容）
/// RELEASE: UNUserNotificationCenter（正式 .app bundle）
public final class NotificationManager: NSObject {
    public static let shared = NotificationManager()

    #if DEBUG
    private var enabled = false
    #else
    private var granted = false
    #endif

    private override init() {
        super.init()
    }

    // MARK: - Auth

    public func requestAuthorization() {
        #if DEBUG
        let center = NSUserNotificationCenter.default
        center.delegate = self
        enabled = true
        debugLog("[Notify] Ready (NSUserNotification, DEBUG)")
        #else
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            self.granted = granted
            debugLog("[Notify] Auth \(granted ? "granted" : "denied")")
        }
        #endif
    }

    // MARK: - Post

    public func success(_ title: String, _ body: String = "") { post(title: title, body: body) }
    public func warning(_ title: String, _ body: String = "") { post(title: title, body: body) }
    public func error(_ title: String, _ body: String = "")   { post(title: title, body: body) }

    private func post(title: String, body: String) {
        #if DEBUG
        guard enabled else { return }
        let note = NSUserNotification()
        note.title = title
        note.informativeText = body
        note.soundName = NSUserNotificationDefaultSoundName
        note.deliveryDate = Date()
        NSUserNotificationCenter.default.scheduleNotification(note)
        debugLog("[Notify] Posted: \(title)")
        #else
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let e = error { debugLog("[Notify] Post failed: \(e)") }
        }
        #endif
    }
}

// MARK: - Delegates

#if DEBUG
extension NotificationManager: NSUserNotificationCenterDelegate {
    public func userNotificationCenter(_ center: NSUserNotificationCenter,
                                        shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }
}
#else
extension NotificationManager: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                        willPresent notification: UNNotification,
                                        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
#endif
