# utility EventBus 重构计划

> **For the agent:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** 引入 EventBus 发布订阅管理器解耦 utility 代码库中的单例交叉引用，遵循最小暴露原则，消除 class A 直接持有 class B 的硬依赖。

**Architecture:** 新建 `EventBus` — 泛型线程安全 pub/sub 管理器（枚举 key → 多 subscriber），新建 `AppEvent` 事件枚举。所有"发通知/错误"的调用方改为 publish event，`NotificationManager` 改为订阅 event。`ConfigManager → TaskScheduler` 的直接调用链改为 event 驱动。`NetworkSpeedMonitor` 的闭包回调改为 pub/sub。

**Tech Stack:** Swift 5.10+, NSLock (线程安全), Hashable enum with associated values

---

## 当前架构问题诊断

### 硬耦合清单

| 调用方 | 被调用方 | 调用方式 | 应改为 |
|--------|---------|---------|--------|
| `ConfigManager.reload()` | `TaskScheduler.shared.reschedule()` + `TaskStateDB.shared.*` | 直接调用 | publish `configDidReload` |
| `HotkeyManager.register()` | `NotificationManager.shared.error()` | 直接调用 | publish `hotkeyRegistrationFailed` |
| `TaskScheduler.fireTask()` | `NotificationManager.shared.error()` | 直接调用 | publish `taskDidFail` |
| `MenuBarManager.rssFetch()` | `NotificationManager.shared.error()` | 直接调用 | publish `rssFetchFailed` |
| `MenuBarManager.reloadConfig()` | `NotificationManager.shared.error()` | 直接调用 | publish `configReloadFailed` |
| `MenuBarManager.toggleLaunchAtLogin()` | `NotificationManager.shared.error()` | 直接调用 | publish `launchAtLoginFailed` |
| `AppDelegate.applicationDidFinishLaunching` | `NotificationManager.shared.error()` ×2 | 直接调用 | publish `configLoadFailed` / `databaseInitFailed` |
| `MenuBarManager` | `NetworkSpeedMonitor.shared.onUpdate` | 闭包赋值 | subscribe `networkSpeedUpdated` |
| `L10n.loadJSON()` | `NotificationCenter.default.post` | ✅ 已解耦 | 保持不变 |

### 单例图（13 个 .shared）
```
ConfigManager ←── AppDelegate, MenuBarManager, ClipboardWatcher, TaskScheduler,
                  RSSManager, StageWindowController, TranslationPanelController, L10n
NotificationManager ←── AppDelegate, MenuBarManager, HotkeyManager, TaskScheduler
HotkeyManager ←── AppDelegate
TaskScheduler ←── AppDelegate, ConfigManager
TaskStateDB ←── TaskScheduler, ConfigManager
AppDatabase ←── AppDelegate, RSSManager, StageManager, StageDropMonitor
RSSManager ←── MenuBarManager
StageManager ←── StageWindowController, StageDropMonitor
StageDropMonitor ←── StageWindowController
NetworkSpeedMonitor ←── MenuBarManager
Translator ←── TranslationPanelController
```

### 已有的良性模式
- `L10n.languageDidChange` 已用 `NotificationCenter` pub/sub → 保持不动
- `TaskExecutor.execute()` 是纯函数（静态方法、无副作用）→ 保持不动
- `debugLog()` 是全局工具函数 → 保持不动
- `schedulePaste()` 是全局工具函数 → 保持不动

---

### Task 1: 创建 EventBus 发布订阅管理器

**Objective:** 新建线程安全的泛型 EventBus，枚举 key 映射到多个 subscriber，支持单个/批量取消订阅

**Files:**
- Create: `Sources/Core/EventBus.swift`

**Step 1: 写入完整实现**

```swift
import Foundation

/// 轻量发布订阅管理器
/// - 枚举 Key（Hashable）→ 多个 (ID, Handler)
/// - 线程安全（NSLock）
/// - 支持按 key 清除全部、按 ID 取消单个
public final class EventBus {
    public static let shared = EventBus()

    private var handlers: [AnyHashable: [(id: AnyHashable, handler: (Any?) -> Void)]] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: - Subscribe

    /// 订阅指定 key 的事件
    /// - Parameters:
    ///   - key: 事件键（枚举，需 Hashable）
    ///   - id: subscriber 标识，用于后续取消订阅（默认 UUID）
    ///   - handler: 事件处理闭包，payload 为发布方传入的可选数据
    @discardableResult
    public func subscribe<Key: Hashable>(
        _ key: Key,
        id: AnyHashable = UUID(),
        handler: @escaping (Any?) -> Void
    ) -> AnyHashable {
        lock.lock()
        defer { lock.unlock() }
        let anyKey = AnyHashable(key)
        if handlers[anyKey] == nil {
            handlers[anyKey] = []
        }
        handlers[anyKey]?.append((id: id, handler: handler))
        return id
    }

    // MARK: - Unsubscribe

    /// 取消指定 key 下的单个 subscriber
    public func unsubscribe<Key: Hashable>(_ key: Key, id: AnyHashable) {
        lock.lock()
        defer { lock.unlock() }
        handlers[AnyHashable(key)]?.removeAll { $0.id == id }
    }

    /// 清除指定 key 的全部 subscriber
    public func unsubscribeAll<Key: Hashable>(for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        handlers[AnyHashable(key)] = nil
    }

    // MARK: - Publish

    /// 发布事件到所有订阅者
    /// - Parameters:
    ///   - key: 事件键
    ///   - payload: 可选负载数据
    public func publish<Key: Hashable>(_ key: Key, payload: Any? = nil) {
        lock.lock()
        let subs = handlers[AnyHashable(key)] ?? []
        lock.unlock()
        for sub in subs {
            sub.handler(payload)
        }
    }
}
```

**Step 2: Build 验证**

```bash
cd "$(git rev-parse --show-toplevel)"
rm -rf .build && swift build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

---

### Task 2: 创建 AppEvent 事件枚举

**Objective:** 定义所有应用级事件，enum with associated values, Hashable

**Files:**
- Create: `Sources/Core/AppEvent.swift`

**Step 1: 写入完整实现**

```swift
import Foundation

/// 应用级事件枚举
/// 仅定义事件标识和负载数据，不包含行为逻辑
enum AppEvent: Hashable {
    // MARK: - Config
    case configDidLoad
    case configDidReload
    case configLoadFailed(String)
    case configReloadFailed(String)

    // MARK: - Database
    case databaseInitFailed(String)

    // MARK: - Hotkey
    case hotkeyParseFailed(id: String, hotkey: String)
    case hotkeyRegistrationFailed(id: String, hotkey: String)

    // MARK: - Task
    case taskDidFail(name: String, error: String)
    case launchAtLoginFailed(String)

    // MARK: - RSS
    case rssFetchFailed(String)

    // MARK: - Network
    case networkSpeedUpdated(up: String, down: String)
}
```

**Step 2: Build 验证**

```bash
cd "$(git rev-parse --show-toplevel)"
rm -rf .build && swift build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

---

### Task 3: NotificationManager 改为 EventBus 订阅者

**Objective:** NotificationManager 不再被外部直接调用 `.error()`/`.success()`/`.warning()`，改为订阅 `EventBus` 自动转发系统通知

**Files:**
- Modify: `Sources/Notification/NotificationManager.swift:1-87`

**Step 1: 重构 NotificationManager**

将 `NotificationManager` 改为：
- 移除 `success()`, `warning()`, `error()` 的 `public` 修饰（改为 `private` 或内部使用）
- 在 `requestAuthorization()` 中订阅 EventBus 所有错误事件
- 定义映射：EventBus event → 通知标题/正文

```swift
import Cocoa
#if !DEBUG
import UserNotifications
#endif

/// 统一通知管理器
/// DEBUG: NSUserNotificationCenter
/// RELEASE: UNUserNotificationCenter
/// 不再被外部直接调用 — 改为订阅 EventBus 事件
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
            self.post(title: "热键解析失败", body: "\(id): \(hotkey)")
        }
        bus.subscribe(AppEvent.hotkeyRegistrationFailed) { payload in
            guard let (id, hotkey) = payload as? (String, String) else { return }
            self.post(title: "热键注册失败", body: "\(id): \(hotkey) — 可能被其他应用占用")
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
```

**Step 2: Build 验证**

```bash
cd "$(git rev-parse --show-toplevel)"
rm -rf .build && swift build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED（注意现在调用方还没改，会有编译错误，等后续任务一起修）

---

### Task 4: 重构 HotkeyManager — publish event 代替直接调 NotificationManager

**Objective:** `HotkeyManager.register()` 中的错误通知改为 publish `AppEvent`

**Files:**
- Modify: `Sources/Core/HotkeyManager.swift:13-38`

**Step 1: 修改 HotkeyManager**

找到两处 `NotificationManager.shared.error(...)` 调用，改为 `EventBus.shared.publish(...)`:

```swift
// 行 18 — 热键解析失败
// 旧:
// NotificationManager.shared.error("热键解析失败", "\(id): \(hotkey)")
// 新:
EventBus.shared.publish(AppEvent.hotkeyParseFailed(id: id, hotkey: hotkey))

// 行 32 — 热键注册失败
// 旧:
// NotificationManager.shared.error("热键注册失败", "\(id): \(hotkey) — 可能被其他应用占用")
// 新:
EventBus.shared.publish(AppEvent.hotkeyRegistrationFailed(id: id, hotkey: hotkey))
```

**Step 2: Build 验证**

---

### Task 5: 重构 TaskScheduler — publish event 代替直接调 NotificationManager

**Objective:** `TaskScheduler.fireTask()` 中的任务失败通知改为 publish `AppEvent`

**Files:**
- Modify: `Sources/Task/TaskScheduler.swift:108-120`

**Step 1: 修改 fireTask 方法**

```swift
// 行 117 — 旧:
// NotificationManager.shared.error("任务失败: \(task.name)", errMsg)
// 新:
EventBus.shared.publish(AppEvent.taskDidFail(name: task.name, error: errMsg))
```

**Step 2: Build 验证**

---

### Task 6: 重构 MenuBarManager — publish event 代替直接调 NotificationManager + 订阅 networkSpeedUpdated

**Objective:** MenuBarManager 中 3 处 `NotificationManager.shared.error()` 改为 publish event；`NetworkSpeedMonitor.onUpdate` 闭包改为通过 EventBus 订阅

**Files:**
- Modify: `Sources/Core/MenuBarManager.swift`

**Step 1: 修改 rssFetch() — 行 152**

```swift
// 旧:
// NotificationManager.shared.error(L10n.Menu.rssFetchFailed, error.localizedDescription)
// 新:
EventBus.shared.publish(AppEvent.rssFetchFailed(error.localizedDescription))
```

**Step 2: 修改 reloadConfig() — 行 225**

```swift
// 旧:
// NotificationManager.shared.error(L10n.Menu.configReloadFailed, error.localizedDescription)
// 新:
EventBus.shared.publish(AppEvent.configReloadFailed(error.localizedDescription))
```

**Step 3: 修改 toggleLaunchAtLogin() — 行 202**

```swift
// 旧:
// NotificationManager.shared.error(L10n.Menu.launchAtLoginFailed, error.localizedDescription)
// 新:
EventBus.shared.publish(AppEvent.launchAtLoginFailed(error.localizedDescription))
```

**Step 4: 重构 startNetworkMonitor() — 行 131-138**

将 `NetworkSpeedMonitor.shared.onUpdate` 闭包改为 EventBus 订阅：

```swift
private func startNetworkMonitor() {
    EventBus.shared.subscribe(AppEvent.networkSpeedUpdated) { [weak self] payload in
        guard let (up, down) = payload as? (String, String) else { return }
        guard let view = self?.statusItem.value(forKey: "view") as? NetworkSpeedView else { return }
        view.update(up: up, down: down)
    }
    NetworkSpeedMonitor.shared.start()
}
```

**Step 5: Build 验证**

---

### Task 7: 重构 NetworkSpeedMonitor — onUpdate 闭包改为 publish event

**Objective:** 移除 `NetworkSpeedMonitor.onUpdate` 闭包属性，改为 publish `AppEvent.networkSpeedUpdated`

**Files:**
- Modify: `Sources/Network/NetworkSpeedMonitor.swift`

**Step 1: 移除 onUpdate 属性，修改 poll()**

```swift
// 行 13 — 删除:
// var onUpdate: ((_ up: String, _ down: String) -> Void)?

// 行 51-53 — 旧:
// DispatchQueue.main.async { [weak self] in
//     self?.onUpdate?(upText, downText)
// }
// 新:
DispatchQueue.main.async {
    EventBus.shared.publish(AppEvent.networkSpeedUpdated(up: upText, down: downText))
}
```

**Step 2: Build 验证**

---

### Task 8: 重构 AppDelegate — publish event 代替直接调 NotificationManager

**Objective:** AppDelegate 中 2 处 `NotificationManager.shared.error()` 改为 publish event

**Files:**
- Modify: `Sources/App/AppDelegate.swift:19-21, 25-27`

**Step 1: 修改 config load 失败 — 行 20**

```swift
// 旧:
// NotificationManager.shared.error(L10n.Menu.configLoadFailed, "\(error.localizedDescription)")
// 新:
EventBus.shared.publish(AppEvent.configLoadFailed(error.localizedDescription))
```

**Step 2: 修改 database setup 失败 — 行 26**

```swift
// 旧:
// NotificationManager.shared.error(L10n.Menu.dbInitFailed, "\(error.localizedDescription)")
// 新:
EventBus.shared.publish(AppEvent.databaseInitFailed(error.localizedDescription))
```

**Step 3: Build 验证**

---

### Task 9: 解耦 ConfigManager → TaskScheduler 直接调用链

**Objective:** `ConfigManager.reload()` 不再直接调用 `TaskScheduler.shared.reschedule()`，改为 publish `configDidReload`，TaskScheduler 订阅该事件

**Files:**
- Modify: `Sources/Core/ConfigManager.swift:28-32`
- Modify: `Sources/Task/TaskScheduler.swift:22-28`

**Step 1: ConfigManager.reload() — 改为 publish event**

```swift
// 行 28-32 — 旧:
// public func reload() throws {
//     try load()
//     cleanupStaleTaskStates()
//     TaskScheduler.shared.reschedule()
// }
// 新:
public func reload() throws {
    try load()
    cleanupStaleTaskStates()
    EventBus.shared.publish(AppEvent.configDidReload)
}
```

**Step 2: TaskScheduler — 订阅 configDidReload**

在 `TaskScheduler` 的 `init()` 或 `start()` 中订阅：

```swift
// 在 init() 中添加订阅
private init() {
    EventBus.shared.subscribe(AppEvent.configDidReload) { [weak self] _ in
        self?.reschedule()
    }
}
```

但 `reschedule()` 当前是 `public` — 需要保留 public（ConfigManager 不再调它，但其他地方可能用）。

**Step 3: Build 验证**

---

### Task 10: 全量 Build + 验证编译通过

**Objective:** 确保所有修改点编译通过，无未解析符号

**Files:** 全部以上修改过的文件

**Step 1: Clean build**

```bash
cd "$(git rev-parse --show-toplevel)"
rm -rf .build && swift build 2>&1
```

Expected: BUILD SUCCEEDED, 0 errors

**Step 2: 确认二进制中包含 EventBus 符号**

```bash
strings .build/arm64-apple-macosx/debug/utility | grep -i "eventbus"
```

Expected: 有输出（确认 EventBus 被链接进二进制）

**Step 3: 搜索残留的 NotificationManager 直接调用**

```bash
cd "$(git rev-parse --show-toplevel)"
grep -rn "NotificationManager.shared" Sources/ --include="*.swift" | grep -v "Notification/NotificationManager.swift"
```

Expected: 0 结果（所有外部调用已改为 EventBus）

---

### Task 11: 清理 — 移除 NotificationManager 的 public success/warning/error 方法

**Objective:** 确认 NotificationManager 不再对外暴露 `success/warning/error`（Task 3 中已改），验证外部无调用残留

**Files:**
- Modify: `Sources/Notification/NotificationManager.swift`（已在 Task 3 完成）

**Step 1: 验证 NotificationManager 方法可见性**

```bash
grep -n "public func success\|public func warning\|public func error" Sources/Notification/NotificationManager.swift
```

Expected: 0 结果（这些方法已改为 private 或移除）

**Step 2: 全局搜索残留调用**

```bash
grep -rn "NotificationManager.shared\.\(success\|warning\|error\)" Sources/ --include="*.swift"
```

Expected: 0 结果

---

## 重构前后对比

### 重构前
```
AppDelegate ──直接调用──→ NotificationManager.shared.error()
HotkeyManager ──直接调用──→ NotificationManager.shared.error()
TaskScheduler ──直接调用──→ NotificationManager.shared.error()
MenuBarManager ──直接调用──→ NotificationManager.shared.error()  ×3
ConfigManager ──直接调用──→ TaskScheduler.shared.reschedule()
MenuBarManager ──闭包赋值──→ NetworkSpeedMonitor.shared.onUpdate
```

### 重构后
```
AppDelegate ──publish──→ EventBus ──subscribe──→ NotificationManager
HotkeyManager ──publish──→ EventBus ──subscribe──→ NotificationManager
TaskScheduler ──publish──→ EventBus ──subscribe──→ NotificationManager
MenuBarManager ──publish──→ EventBus ──subscribe──→ NotificationManager
ConfigManager ──publish──→ EventBus ──subscribe──→ TaskScheduler
NetworkSpeedMonitor ──publish──→ EventBus ──subscribe──→ MenuBarManager
```

所有组件只依赖 `EventBus.shared`，不再持有对方的单例引用。

---

## 风险与开放问题

1. **通知标题中文化**：`AppEvent.hotkeyParseFailed` 和 `hotkeyRegistrationFailed` 的通知标题仍是硬编码中文（"热键解析失败"/"热键注册失败"），未接入 L10n。建议后续将这几个字符串加入 L10n JSON。

2. **L10n.setup() 仍然直接访问 ConfigManager.shared**：`L10n.setup()` 在 ConfigManager.load() 中被调用，这是合理的（L10n 需要读配置决定语言），但方向是 ConfigManager → L10n 而非反向，耦合度可接受。

3. **EventBus payload 类型安全**：当前 payload 是 `Any?`，订阅方需要 `as?` 转换。这是 pub/sub 模式固有的取舍 — 类型安全由 `AppEvent` enum 的 associated values 在 publish 侧保证，subscribe 侧通过约定匹配。

4. **测试**：EventBus 是纯逻辑组件（无 AppKit 依赖），容易单元测试。建议后续添加 `EventBusTests.swift` 覆盖 subscribe/unsubscribe/publish 的线程安全场景。

5. **StageDropMonitor 直接调用 AppDatabase.shared.dbQueue**：第 172 行 `try? AppDatabase.shared.dbQueue.write { ... }` 是绕过 StageManager 直接写库。应改为通过 `StageManager.shared.add(type:content:)` 统一入口，但这是另一层问题，不在此次 EventBus 重构范围内。

---

## 验证清单

- [ ] `swift build` 零错误
- [ ] `grep -rn "NotificationManager.shared" Sources/ --include="*.swift" | grep -v Notification/` 零结果
- [ ] `grep -rn "NetworkSpeedMonitor.shared.onUpdate" Sources/ --include="*.swift"` 零结果
- [ ] `grep -rn "TaskScheduler.shared.reschedule()" Sources/ --include="*.swift" | grep -v TaskScheduler` 零结果
- [ ] EventBus 符号存在于二进制
- [ ] AppEvent enum 所有 case 在 NotificationManager.subscribeToEvents() 中有对应订阅
