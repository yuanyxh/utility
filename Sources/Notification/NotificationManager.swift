import Cocoa

#if !DEBUG
    import UserNotifications
#endif

/// Unified notification manager
/// DEBUG: NSUserNotificationCenter (native binary debug compatibility)
/// RELEASE: UNUserNotificationCenter (official .app bundle)
/// No longer called directly from outside — instead subscribes to EventBus events to auto-forward system notifications
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
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                self.granted = granted
                debugLog("[Notify] Authorization granted=\(granted) error=\(error?.localizedDescription ?? "nil")")
            }
        #endif

        subscribeToEvents()
    }

    // MARK: - Event subscriptions

    private func subscribeToEvents() {
        EventBus.shared.subscribe(AppEvent.notify) { [weak self] payload in
            guard let self, let note = payload as? NotificationPayload else { return }
            post(title: note.title, body: note.body)
        }
    }

    // MARK: - Post (private)

    private func post(title: String, body: String) {
        guard ConfigManager.shared.config.notifications.enabled else {
            debugLog("[Notify] Dropped (notifications disabled): \(title)")
            return
        }
        #if DEBUG
            guard enabled else {
                debugLog("[Notify] Dropped (debug center unavailable): \(title)")
                return
            }
            let note = NSUserNotification()
            note.title = title
            note.informativeText = body
            note.soundName = NSUserNotificationDefaultSoundName
            note.deliveryDate = Date()
            NSUserNotificationCenter.default.scheduleNotification(note)
        #else
            guard granted else {
                debugLog("[Notify] Dropped (authorization not granted): \(title)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil,
            )
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
            shouldPresent _: NSUserNotification,
        ) -> Bool {
            true
        }
    }
#else
    extension NotificationManager: UNUserNotificationCenterDelegate {
        public func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent _: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void,
        ) {
            completionHandler([.banner, .sound])
        }
    }
#endif
