# 面板/热键统一管理重构计划

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** 用栈结构统一管理所有面板生命周期和键盘事件派发，实现隔离的独立弹出/关闭，支持面板间互调。

**Architecture:** 新增 `PanelManager`（栈结构面板生命周期管理）和 `KeyDispatcher`（责任链键盘事件派发），AppDelegate 改为通过 PanelManager 间接持有面板。每个面板遵循统一协议，可独立注册、弹出、关闭。

**Tech Stack:** Swift 5.9+ / AppKit / Carbon EventHotKey / NSWindow+NSPanel

---

## 当前问题

- AppDelegate 硬持有所有面板引用，生命周期耦合
- 热键直接 dispatch 到特定面板，无栈顶优先逻辑
- 面板关闭时的焦点返回逻辑分散在各面板 close() 中
- 无法从翻译面板打开 chat 面板，反之亦然
- 键盘事件（如 ESC、Enter）依赖各面板自己的 performKeyEquivalent，缺乏统一派发

---

## 目标架构

```
NSApplication (KeyDispatcher — local event monitor)
  └─ PanelManager (栈结构)
       ├─ [0] ClipboardPanel  ← 最早打开
       ├─ [1] TranslationPanel
       └─ [2] ChatPanel  ← 栈顶（最后聚焦）

KeyDispatcher: NSEvent → PanelManager.stackTop → handleKeyEvent(event)
  → 捕获: 消费，不向下传播
  → 未捕获: 下一层，直到栈底
  → 全部未捕获: NSApp.sendEvent (系统默认)
```

---

## 文件变更总览

| 操作 | 文件 |
|------|------|
| **新建** | `Sources/Core/PanelManager.swift` |
| **新建** | `Sources/Core/KeyDispatcher.swift` |
| **新建** | `Sources/Core/PanelProtocol.swift` |
| **修改** | `Sources/App/AppDelegate.swift` |
| **修改** | `Sources/Chat/ChatPanelController.swift` |
| **修改** | `Sources/Translation/TranslationPanelController.swift` |
| **修改** | `Sources/Clipboard/ClipboardPanelController.swift` |
| **修改** | `Sources/Stage/StageWindowController.swift` |
| **修改** | `Sources/Core/HotkeyManager.swift` |

---

### Task 1: 定义 PanelProtocol

**Objective:** 定义统一面板协议，PanelManager 和 KeyDispatcher 依赖此协议

**Files:**
- Create: `Sources/Core/PanelProtocol.swift`

**Step 1: 写协议定义**

```swift
import Cocoa

/// 可被 PanelManager 管理的面板协议
protocol PanelProtocol: AnyObject {
    /// 唯一标识（如 "clipboard", "translation", "chat", "stage"）
    var panelID: String { get }
    
    /// 面板窗口
    var panelWindow: NSWindow? { get }
    
    /// 显示面板
    func showPanel()
    
    /// 关闭面板
    func closePanel()
    
    /// 处理键盘事件，返回 true 表示已消费（不向下传播）
    /// 默认实现：返回 false
    func handleKeyEvent(_ event: NSEvent) -> Bool
    
    /// 面板是否可见
    var isPanelVisible: Bool { get }
}
```

**Step 2: Build 验证**

```bash
cd /Users/yuanyxh/Documents/it/project/utility && swift build 2>&1 | tail -5
```

预期: `Build complete!`（仅有协议定义，不会破坏现有代码）

**Step 3: 提交**

```bash
git add Sources/Core/PanelProtocol.swift
git commit -m "feat: 定义 PanelProtocol 统一面板协议"
```

---

### Task 2: 实现 PanelManager 栈结构

**Objective:** 实现栈结构的面板生命周期管理器

**Files:**
- Create: `Sources/Core/PanelManager.swift`

**Step 1: 写 PanelManager**

```swift
import Cocoa

/// 全局面板管理器 — 栈结构
/// 最后聚焦的面板在栈顶，键事件从栈顶开始派发
public final class PanelManager {
    public static let shared = PanelManager()
    
    private var stack: [PanelProtocol] = []
    private let lock = NSLock()
    
    private init() {}
    
    // MARK: - Registration
    
    /// 注册面板（启动时调用，不弹出）
    func register(_ panel: PanelProtocol) {
        lock.lock()
        defer { lock.unlock() }
        // 避免重复注册
        guard !stack.contains(where: { $0.panelID == panel.panelID }) else { return }
        stack.append(panel)
    }
    
    // MARK: - Show / Close
    
    /// 弹出面板，移到栈顶
    func show(_ panel: PanelProtocol) {
        lock.lock()
        // 移到栈顶
        stack.removeAll { $0.panelID == panel.panelID }
        stack.append(panel)
        lock.unlock()
        panel.showPanel()
    }
    
    /// 关闭面板，从栈中移除
    func close(_ panel: PanelProtocol) {
        lock.lock()
        stack.removeAll { $0.panelID == panel.panelID }
        let remaining = stack
        lock.unlock()
        panel.closePanel()
        // 栈空 → 返回系统焦点
        if remaining.isEmpty {
            DispatchQueue.main.async {
                NSApplication.shared.hide(nil)
            }
        }
    }
    
    /// 通知面板获得焦点（用户点击面板标题栏等）
    func didBecomeKey(_ panel: PanelProtocol) {
        lock.lock()
        stack.removeAll { $0.panelID == panel.panelID }
        stack.append(panel)
        lock.unlock()
    }
    
    // MARK: - Query
    
    /// 栈顶面板（最后聚焦的）
    var topPanel: PanelProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return stack.last
    }
    
    /// 按 ID 查找面板
    func panel(id: String) -> PanelProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return stack.first { $0.panelID == id }
    }
    
    /// 所有可见面板（从栈顶到栈底）
    var visiblePanels: [PanelProtocol] {
        lock.lock()
        defer { lock.unlock() }
        return stack.reversed().filter { $0.isPanelVisible }
    }
}
```

**Step 2: Build 验证**

```bash
cd /Users/yuanyxh/Documents/it/project/utility && swift build 2>&1 | tail -5
```

**Step 3: 提交**

```bash
git add Sources/Core/PanelManager.swift
git commit -m "feat: PanelManager 栈结构面板生命周期管理"
```

---

### Task 3: 实现 KeyDispatcher 责任链键盘派发

**Objective:** 拦截 NSEvent，从栈顶派发，未消费的传给系统

**Files:**
- Create: `Sources/Core/KeyDispatcher.swift`

**Step 1: 写 KeyDispatcher**

```swift
import Cocoa

/// 全局键盘事件派发器 — 责任链模式
/// 从 PanelManager 栈顶开始，逐层询问 handleKeyEvent，
/// 第一个返回 true 的面板消费事件，全部未消费则交给系统。
final class KeyDispatcher {
    static let shared = KeyDispatcher()
    private var monitor: Any?
    
    private init() {}
    
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.dispatch(event)
        }
    }
    
    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
    
    /// 从栈顶派发键盘事件
    /// - Returns: 若面板消费了事件返回 nil（阻止系统处理），否则返回原事件
    private func dispatch(_ event: NSEvent) -> NSEvent? {
        // 从栈顶开始遍历可见面板
        for panel in PanelManager.shared.visiblePanels {
            if panel.handleKeyEvent(event) {
                return nil // 事件已消费
            }
        }
        return event // 交给系统
    }
}
```

**Step 2: Build 验证**

```bash
cd /Users/yuanyxh/Documents/it/project/utility && swift build 2>&1 | tail -5
```

**Step 3: 提交**

```bash
git add Sources/Core/KeyDispatcher.swift
git commit -m "feat: KeyDispatcher 责任链键盘事件派发"
```

---

### Task 4: 各面板实现 PanelProtocol

**Objective:** Chat、Translation、Clipboard、Stage 四个面板遵循 PanelProtocol

**Files:**
- Modify: `Sources/Chat/ChatPanelController.swift`
- Modify: `Sources/Translation/TranslationPanelController.swift`
- Modify: `Sources/Clipboard/ClipboardPanelController.swift`
- Modify: `Sources/Stage/StageWindowController.swift`

**Step 1: ChatPanelController 遵循协议**

在类声明后添加 extension：

```swift
// MARK: - PanelProtocol

extension ChatPanelController: PanelProtocol {
    var panelID: String { "chat" }
    var panelWindow: NSWindow? { window }
    
    func showPanel() { show() }
    func closePanel() { close() }
    
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // ESC → 关闭
        if event.keyCode == 53 {
            close()
            return true
        }
        // Cmd+Enter → 发送
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            triggerChat()
            return true
        }
        return false
    }
}
```

同步修改 `setupDeactivateObserver`：失焦时通知 PanelManager 而不是直接 close：

```swift
private func setupDeactivateObserver() {
    NotificationCenter.default.addObserver(
        self, selector: #selector(panelDidResignKey),
        name: NSWindow.didResignKeyNotification, object: window
    )
    // 获得焦点时通知 PanelManager 移到栈顶
    NotificationCenter.default.addObserver(
        self, selector: #selector(panelDidBecomeKey),
        name: NSWindow.didBecomeKeyNotification, object: window
    )
}

@objc private func panelDidBecomeKey() {
    PanelManager.shared.didBecomeKey(self)
}

@objc private func panelDidResignKey() {
    PanelManager.shared.close(self)
}
```

删除 `close()` 中的 `DispatchQueue.main.async { ... hide(nil) }` 逻辑（由 PanelManager 统一处理）。

**Step 2: TranslationPanelController 遵循协议**

```swift
extension TranslationPanelController: PanelProtocol {
    var panelID: String { "translation" }
    var panelWindow: NSWindow? { window }
    
    func showPanel() { show() }
    func closePanel() { close() }
    
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { // ESC
            close()
            return true
        }
        return false
    }
}
```

同步修改 `setupDeactivateObserver`（同上），删除 `close()` 中的 hide(nil) 逻辑。

**Step 3: ClipboardPanelController 遵循协议**

类似 Chat/Translation，实现 `panelID = "clipboard"`。

**Step 4: StageWindowController 遵循协议**

实现 `panelID = "stage"`。Stage 不响应失焦关闭（常驻），`handleKeyEvent` 返回 false。

**Step 5: Build 验证**

```bash
cd /Users/yuanyxh/Documents/it/project/utility && swift build 2>&1 | tail -5
```

**Step 6: 提交**

```bash
git add Sources/Chat/ChatPanelController.swift Sources/Translation/TranslationPanelController.swift Sources/Clipboard/ClipboardPanelController.swift Sources/Stage/StageWindowController.swift
git commit -m "feat: 四面板实现 PanelProtocol，焦点通知 PanelManager"
```

---

### Task 5: 重构 AppDelegate — 接入 PanelManager

**Objective:** AppDelegate 不再硬持有面板引用，改为通过 PanelManager 注册和管理，热键回调也走 PanelManager。

**Files:**
- Modify: `Sources/App/AppDelegate.swift`

**Step 1: 重写 AppDelegate**

```swift
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let menuBar = MenuBarManager()
    private let hotkeyManager = HotkeyManager.shared
    
    // 面板实例（PanelManager 只存弱引用？不，用强引用 — 面板生命周期由 PanelManager 管理）
    private let clipboardPanel = ClipboardPanelController()
    private lazy var translationPanel = TranslationPanelController()
    private lazy var chatPanel = ChatPanelController()
    private let stageWindow = StageWindowController()

    func applicationDidFinishLaunching(_: Notification) {
        debugLog("[Utility] Starting up...")
        NSApplication.shared.setActivationPolicy(.accessory)

        // 配置加载
        do { try ConfigManager.shared.load() }
        catch { EventBus.shared.publish(AppEvent.configLoadFailed, payload: error.localizedDescription) }
        do { try AppDatabase.shared.setup() }
        catch { EventBus.shared.publish(AppEvent.databaseInitFailed, payload: error.localizedDescription) }

        // 注册面板到 PanelManager
        PanelManager.shared.register(clipboardPanel)
        PanelManager.shared.register(stageWindow)
        // translationPanel 和 chatPanel 是 lazy，首次访问时注册
        // 实际在热键回调中触发

        // 启动键盘派发
        KeyDispatcher.shared.start()

        registerAllHotkeys()
        installEventHandler()

        NotificationManager.shared.requestAuthorization()
        TaskScheduler.shared.start()
        debugLog("[Utility] Ready")
    }
    
    private func registerAllHotkeys() {
        let config = ConfigManager.shared.config

        hotkeyManager.register(hotkey: config.clipboard.hotkey, id: "clip") { [weak self] in
            guard let self = self else { return }
            if self.clipboardPanel.isPanelVisible {
                PanelManager.shared.close(self.clipboardPanel)
            } else {
                PanelManager.shared.show(self.clipboardPanel)
            }
        }

        hotkeyManager.register(hotkey: config.translation.hotkey, id: "tran") { [weak self] in
            guard let self = self else { return }
            // 首次访问 lazy panel 时注册
            PanelManager.shared.register(self.translationPanel)
            
            if self.translationPanel.isPanelVisible {
                // 已显示 → 尝试获取新选中文本
                guard let app = self.translationPanel.previousFrontmostApp else { return }
                Task { @MainActor in
                    if let text = await SelectedTextService.getSelectedText(from: app) {
                        self.translationPanel.fillAndTranslate(text)
                    }
                }
                return
            }
            // 原有翻译热键逻辑...
            let preApp = NSWorkspace.shared.frontmostApplication
            self.translationPanel.previousFrontmostApp = preApp
            if let app = preApp, let text = SelectedTextService.tryAXSelectedText(from: app), !text.isEmpty {
                self.translationPanel.show(with: text)
                self.translationPanel.startTranslation(text: text)
                PanelManager.shared.show(self.translationPanel)
            } else {
                self.translationPanel.showEmpty()
                PanelManager.shared.show(self.translationPanel)
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
            // ... 同上模式
        }

        hotkeyManager.register(hotkey: config.chat.hotkey, id: "chat") { [weak self] in
            guard let self = self else { return }
            PanelManager.shared.register(self.chatPanel)
            if self.chatPanel.isPanelVisible {
                PanelManager.shared.close(self.chatPanel)
            } else {
                PanelManager.shared.show(self.chatPanel)
            }
        }
    }

    // installEventHandler 不变
}
```

**Step 2: Build 验证**

```bash
cd /Users/yuanyxh/Documents/it/project/utility && swift build 2>&1 | tail -5
```

**Step 3: 提交**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "refactor: AppDelegate 接入 PanelManager/KeyDispatcher"
```

---

### Task 6: 面板间互调支持

**Objective:** 通过 `PanelManager.panel(id:)` 实现面板间互相打开

**Files:**
- Modify: 各面板 Controller（按需）

**实现方式:**

任何面板内可以通过以下方式打开其他面板：

```swift
// 从翻译面板打开剪贴板
if let clipboard = PanelManager.shared.panel(id: "clipboard") {
    PanelManager.shared.show(clipboard)
}

// 从 chat 面板打开翻译面板
if let translation = PanelManager.shared.panel(id: "translation") {
    PanelManager.shared.show(translation)
}
```

**Step 1: 编译验证**

```bash
cd /Users/yuanyxh/Documents/it/project/utility && swift build 2>&1 | tail -5
```

**Step 2: 提交**（如无额外代码变更则跳过）

---

### Task 7: 更新 AGENTS.md

**Objective:** 同步文档

**Files:**
- Modify: `AGENTS.md`

架构表新增：

```
| `PanelManager` | 栈结构面板生命周期管理：注册/弹出/关闭/焦点追踪 |
| `KeyDispatcher` | 责任链键盘事件派发：栈顶→栈底→系统 |
| `PanelProtocol` | 面板统一协议：panelID / showPanel / closePanel / handleKeyEvent |
```

版本号: 1.0.2 → 1.1.0（架构级变更）

---

## 验证清单

- [ ] 四个面板可同时弹出，互不干扰
- [ ] 点击任一面板标题栏 → 该面板移到栈顶
- [ ] ESC 键 → 当前栈顶面板关闭（逐层关闭）
- [ ] 所有面板关闭 → 焦点返回系统
- [ ] Cmd+Enter 在 chat 面板中 → 发送，不会穿透到其他面板
- [ ] 热键 toggle 行为不变（option+space 切换 chat 显示/隐藏）
- [ ] 翻译面板中可手动调用 `PanelManager.shared.show(panel(id: "chat"))`

---

## 风险与注意事项

1. **Stage 面板特殊处理**：Stage 不应失焦关闭（常驻），`handleKeyEvent` 返回 false 即可
2. **粘贴流程不受影响**：`pasteAndClose()` 逻辑不变，仅关闭由 PanelManager 代理
3. **NSPanel didResignKey 触发时机**：多面板同时存在时，点击面板 A → 面板 B 收到 didResignKey → PanelManager.close(B) → B 关闭。这是预期行为（一次只聚焦一个）
4. **local event monitor 与 performKeyEquivalent 的优先级**：`NSEvent.addLocalMonitorForEvents` 在 performKeyEquivalent 之前触发，需要确保不会拦截系统快捷键（如 Cmd+C/V）
