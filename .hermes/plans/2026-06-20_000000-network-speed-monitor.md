# 菜单栏网速监控 实施计划

> **For the agent:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** 在 Utility 菜单栏用自定义 NSView 上下两行显示实时网速（上行↑ / 下行↓），不保留图标

**Architecture:** 新增 `NetworkSpeedMonitor` 单例每 3 秒轮询网卡字节计数器。MenuBarManager 用自定义 `NSView`（内含两个 `NSTextField` 垂直 StackView，间距 2pt）替换原有 `NSStatusBarButton`，10pt 等宽字体，速度保留最多 3 位小数。用 `autosaveName` 固定位置（需手动 Cmd+拖一次到左侧）。

**Tech Stack:** Swift 5.9+, Darwin (`getifaddrs`, `if_data`), Dispatch Timer，无外部依赖

**Memory Impact:** +0.5~1MB（Timer + queue + transient allocations + 2 个 NSTextField），baseline ~17MB → ~18MB

---

## 内存占用分析

| 新增组件 | 估算 |
|----------|------|
| DispatchSourceTimer | ~1KB |
| Serial DispatchQueue | ~2KB |
| NetworkSpeedMonitor 实例 + 闭包 | ~2KB |
| 2 个 NSTextField + StackView | ~3KB |
| getifaddrs() 每次 poll 临时分配 | ~几KB（瞬态，立即释放） |
| **总计 physical footprint 增量** | **~0.5-1MB** |

---

## 菜单栏左侧定位说明

macOS 没有 API 强制 NSStatusItem 到最左侧。标准做法：

1. 设 `statusItem.autosaveName` — 系统记住拖拽位置
2. 首次启动后 **Cmd+拖拽** 网速 item 到菜单栏最左侧
3. 之后重启自动归位

---

## 实施步骤

### Task 1: 创建 NetworkSpeedMonitor

**Objective:** 新建 `NetworkSpeedMonitor` 单例，核心轮询逻辑。回调分别提供上行/下行格式化文本。

**Files:**
- Create: `Sources/Network/NetworkSpeedMonitor.swift`

**Step 1: 写文件**

```swift
import Darwin
import Foundation

/// 每秒轮询 enX 网卡流量，计算上行/下行速度
final class NetworkSpeedMonitor {
    static let shared = NetworkSpeedMonitor()

    private var timer: DispatchSourceTimer?
    private var previous: (rx: UInt64, tx: UInt64)?
    private let queue = DispatchQueue(label: "utility.network-monitor", qos: .utility)

    /// 回调在主线程，(上行文本, 下行文本)，如 ("↑256K", "↓1.2M")
    var onUpdate: ((_ up: String, _ down: String) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 3.0)
        t.setEventHandler { [weak self] in
            self?.poll()
        }
        t.resume()
        timer = t
        debugLog("[Network] Monitoring started")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        previous = nil
        debugLog("[Network] Monitoring stopped")
    }

    // MARK: - Poll

    private func poll() {
        guard let current = interfaceBytes() else { return }
        defer { previous = current }

        guard let prev = previous else { return }

        let down = current.rx > prev.rx ? current.rx - prev.rx : 0
        let up   = current.tx > prev.tx ? current.tx - prev.tx : 0

        let upText   = "↑" + format(up)
        let downText = "↓" + format(down)
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(upText, downText)
        }
    }

    // MARK: - Formatting

    /// ≥1MB → X.XXXM, ≥1KB → X.XXXK, else → XB
    private func format(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.3fM", Double(bytes) / 1_000_000.0)
        } else if bytes >= 1_000 {
            return String(format: "%.3fK", Double(bytes) / 1_000.0)
        } else {
            return "\(bytes)B"
        }
    }

    // MARK: - getifaddrs

    /// 汇总所有 enX (en0, en1, ...) 的 ifi_ibytes / ifi_obytes
    private func interfaceBytes() -> (rx: UInt64, tx: UInt64)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en"), name.dropFirst(2).allSatisfy({ $0.isNumber }) else { continue }

            let sa = ptr.pointee.ifa_addr.pointee
            guard sa.sa_family == UInt8(AF_LINK), let data = ptr.pointee.ifa_data else { continue }

            let ifd = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(ifd.ifi_ibytes)
            tx += UInt64(ifd.ifi_obytes)
        }

        return (rx, tx)
    }
}
```

**Step 2: Build 验证**

```bash
cd "$(git rev-parse --show-toplevel)" && swift build 2>&1 | tail -5
```

Expected: `Build complete!`

---

### Task 2: 重写 MenuBarManager — NSView 替换 NSStatusBarButton

**Objective:** 用自定义 NSView（两个 NSTextField 上下排列）替换原有 statusItem.button，去掉图标，保留菜单点击

**Files:**
- Modify: `Sources/Core/MenuBarManager.swift`

**Step 1: 重写 setupStatusItem()**

原 `setupStatusItem` 删掉，替换为创建自定义 view。`buildMenu()` 中 `statusItem.menu = menu` 保持不变。

新增内嵌 `NetworkSpeedView` 类。

**完整改后文件：**

```swift
import Cocoa
import ServiceManagement

public final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem!

    public override init() {
        super.init()
        setupStatusItem()
        buildMenu()
        startNetworkMonitor()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "utility-network-speed"

        let view = NetworkSpeedView()
        statusItem.view = view
    }

    private func buildMenu() {
        let menu = NSMenu()

        let reloadItem = NSMenuItem(title: "重载配置", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())

        launchAtLoginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "清空剪切板", action: #selector(clearClipboard), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Network

    private func startNetworkMonitor() {
        let monitor = NetworkSpeedMonitor.shared
        monitor.onUpdate = { [weak self] up, down in
            guard let view = self?.statusItem.view as? NetworkSpeedView else { return }
            view.update(up: up, down: down)
        }
        monitor.start()
    }

    // MARK: - Actions

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                launchAtLoginItem.state = .off
                debugLog("[LoginItem] Unregistered")
            } else {
                try SMAppService.mainApp.register()
                launchAtLoginItem.state = .on
                debugLog("[LoginItem] Registered")
            }
        } catch {
            debugLog("[LoginItem] Failed: \(error)")
            NotificationManager.shared.error("开机自启设置失败", error.localizedDescription)
        }
    }

    @objc private func reloadConfig() {
        do {
            try ConfigManager.shared.reload()
        } catch {
            debugLog("[MenuBar] Reload failed: \(error)")
            NotificationManager.shared.error("配置重载失败", error.localizedDescription)
        }
    }

    @objc private func clearClipboard() {
        let db = AppDatabase.shared.dbQueue
        try? db?.write { db in
            try db.execute(literal: "DELETE FROM clipboard_item")
        }
        debugLog("[MenuBar] Clipboard cleared")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NetworkSpeedView

private final class NetworkSpeedView: NSView {
    let upLabel   = NSTextField(labelWithString: "↑--")
    let downLabel = NSTextField(labelWithString: "↓--")

    override init(frame: NSRect) {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        upLabel.font   = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        downLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        upLabel.alignment   = .right
        downLabel.alignment = .right

        let stack = NSStackView(views: [upLabel, downLabel])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .trailing
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func update(up: String, down: String) {
        upLabel.stringValue   = up
        downLabel.stringValue = down
        superview?.layoutSubtreeIfNeeded()
    }
}
```

**Step 2: Build 验证**

```bash
cd "$(git rev-parse --show-toplevel)" && swift build 2>&1 | tail -10
```

Expected: `Build complete!`

---

### Task 3: 验证

**Objective:** 确认功能正确、布局紧凑

**Step 1: Clean build**

```bash
cd "$(git rev-parse --show-toplevel)" && rm -rf .build && swift build 2>&1 | tail -10
```

**Step 2: 检查符号**

```bash
strings .build/debug/utility | grep -i network
```

Expected: `[Network]` 日志字符串

**Step 3: 启动测试**

```bash
pkill -9 -f utility
.build/debug/utility &
```

验证点：
- 菜单栏出现两行文字（↑-- / ↓--），无图标
- 约 3 秒后数字开始更新
- 打开网页/下载文件，数字跟随变化（每 3 秒刷新）
- 上↑是上行（上传），下↓是下行（下载）
- Cmd+拖拽可移到菜单栏最左侧，重启后位置不变
- 点击弹出菜单（重载配置/开机自启/清空剪切板/退出）

**Step 4: 内存验证**

```bash
ps -p $(pgrep -x utility) -o rss=
```

增量 < 2MB

---

## 显示效果示意

```
 菜单栏：  ↑1.234M  ...其他图标...
           ↓0.256K
```

两行右对齐，等宽数字字体，数字变化时宽度不跳。

---

## 风险与注意事项

| 风险 | 缓解 |
|------|------|
| `labelWithString` 的 intrinsicContentSize 导致 CoreText 开销 | 已知问题，但 10pt 文本极小 + 每 3 秒 1 次更新，影响可忽略。如遇卡顿改手动 frame |
| NSView 作为 statusItem.view 时 click 事件 | 系统自动处理 — menu 挂在 statusItem 上即可，NSView 不需要手势识别器 |
| 菜单栏左侧定位 | 无 API 强制，用 autosaveName + 手动 Cmd 拖一次 |
| 第一秒无数据显示 | 等待第二个 tick（约 3 秒），首次显示约 3-6 秒延迟 |
| enX 接口匹配 | 正则 `en`+数字，覆盖 WiFi/以太网/雷电网桥 |

## 未纳入（YAGNI）

- 配置开关
- 自定义轮询间隔
- 历史流量
- 点击切换显示模式
