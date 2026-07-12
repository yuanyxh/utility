# 三层封装重构方案 — 面向未来扩展

> **For Hermes:** 使用 subagent-driven-development 逐任务实现，每任务 TDD 循环。

**目标:** 将 utility 中分散的 HTTP 请求、脚本执行、窗口定位三块逻辑封装为通用工具，消除 consumer 中的手写 URLRequest/Process/定位代码。

**不改的模块（全局）:** OpenAIClient、AIChatService、Translator、SSEParser — 保留自有 URLSession 不变

---

## Task 1: HTTP 请求工具（类似 axios）

**Objective:** 创建 `HTTP` enum，统一 User-Agent/Content-Type/超时/重试/请求方法，为后续所有网络请求提供一致入口。

**Files:**
- Create: `Sources/Core/HTTP.swift` — ~80 行

**API 设计:**

```swift
/// 统一 HTTP 请求工具，类似 axios
/// - 默认 User-Agent、超时、JSON Content-Type
/// - 重定向由 URLSession 自动跟随
/// - 非 2xx 状态码抛 HTTPError
/// - 失败自动重试（retryCount > 0 时）
enum HTTP {
    struct Response { let data: Data; let statusCode: Int; let headers: [AnyHashable: Any] }
    enum Method: String { case get="GET", post="POST", put="PUT", delete="DELETE" }

    /// 请求配置 — 一个 struct 收束所有控制参数
    struct RequestConfig {
        var method: Method = .get
        var url: URL
        var headers: [String: String] = [:]
        var body: Data? = nil
        var timeout: TimeInterval = 30
        var retryCount: Int = 0
    }

    /// 唯一入口：接受完整的 RequestConfig
    static func request(_ config: RequestConfig) async throws -> Response

    /// 便捷方法 — 内部转为 RequestConfig 后调 request
    static func get(url: URL, configure: (inout RequestConfig) -> Void = { _ in }) async throws -> Response
    static func post(url: URL, body: Data? = nil, configure: (inout RequestConfig) -> Void = { _ in }) async throws -> Response
}
```

**行为说明：**
- `retryCount = 0`（默认）：失败即抛，不重试
- 重定向：URLSession 默认自动跟随，最终只返回最终 2xx 或抛异常
- 非 2xx statusCode：抛 `HTTPError.httpError(code, body)`
- 网络层失败（超时/断网）：重试次数耗尽才抛

**实现要点：**

```swift
static func request(_ config: RequestConfig) async throws -> Response {
    var lastError: Error?
    let maxAttempts = config.retryCount + 1
    for _ in 0..<maxAttempts {
        do {
            var req = URLRequest(url: config.url)
            req.httpMethod = config.method.rawValue
            req.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = config.timeout
            for (key, value) in config.headers { req.setValue(value, forHTTPHeaderField: key) }
            if let body = config.body {
                req.httpBody = body
                if config.headers["Content-Type"] == nil {
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                throw HTTPError.httpError(httpResponse.statusCode, bodyStr)
            }
            return Response(data: data, statusCode: httpResponse.statusCode, headers: httpResponse.allHeaderFields)
        } catch {
            lastError = error
        }
    }
    throw lastError ?? HTTPError.unknown
}

static func get(url: URL, configure: (inout RequestConfig) -> Void = { _ in }) async throws -> Response {
    var cfg = RequestConfig(method: .get, url: url)
    configure(&cfg)
    return try await request(cfg)
}

static func post(url: URL, body: Data? = nil, configure: (inout RequestConfig) -> Void = { _ in }) async throws -> Response {
    var cfg = RequestConfig(method: .post, url: url, body: body)
    configure(&cfg)
    return try await request(cfg)
}
```

**使用示例：**
```swift
// 最简
let resp = try await HTTP.get(url: url)

// 自定义超时 + 重试
let resp = try await HTTP.get(url: url) { cfg in
    cfg.timeout = 60
    cfg.retryCount = 2
}

// 直接传 RequestConfig（未来新方法同理）
let resp = try await HTTP.request(.init(method: .post, url: url, body: jsonData, timeout: 15))
// resp.data, resp.statusCode 已保证是 2xx
```

**Step 1: 创建文件**

写入 `Sources/Core/HTTP.swift`

**Step 2: Build 验证**

Run: `cd /Users/yuanyxh/Documents/it/project/utility && rm -rf .build && swift build 2>&1`
Expected: Build succeeds.

**不改:** OpenAIClient、AIChatService、Translator、SSEParser、RSSManager

---

## Task 2: TaskExecConfig 加 toProcess 方法

**Objective:** 在 `TaskExecConfig` 上添加 `func toProcess() -> Process`，收束 Process 构造逻辑。TaskExecutor 内部不再手写 executableURL/arguments。

**Files:**
- Modify: `Sources/Core/ConfigTypes.swift:197-237` — `TaskExecConfig` 加 `toProcess()` 方法
- Modify: `Sources/Task/TaskExecutor.swift` — 简化 runShell/runJS/runShortcuts/runPython 为统一入口

**Step 1: Add toProcess() to TaskExecConfig**

```swift
extension TaskExecConfig {
    /// 将配置转为已配置好 stdin/stdout/stderr 的 Process
    func toProcess() -> Process {
        let task = Process()
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        switch self {
        case .sh(let cmd):
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-c", cmd]
        case .js(let code):
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-l", "JavaScript", "-e", code]
        case .shortcuts(let name):
            task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            task.arguments = ["run", name]
        case .py(let code):
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["python3", "-c", code]
        }

        return task
    }
}
```

**Step 2: Simplify TaskExecutor**

```swift
public enum TaskExecutor {
    public struct Result {
        let success: Bool
        let output: String
        let error: String
    }

    public static func execute(_ config: TaskExecConfig) -> Result {
        let task = config.toProcess()
        return runProcess(task)
    }

    private static func runProcess(_ task: Process) -> Result {
        // 保持现有 runProcess 实现不变
        let outPipe = task.standardOutput as! Pipe
        let errPipe = task.standardError as! Pipe
        do {
            try task.run()
            task.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8) ?? ""
            let error = String(data: errData, encoding: .utf8) ?? ""
            return Result(success: task.terminationStatus == 0, output: output, error: error)
        } catch {
            return Result(success: false, output: "", error: error.localizedDescription)
        }
    }
}
```

整体删除 runShell/runJS/runShortcuts/runPython 四个 private 方法。

**Step 3: Build verification**

Run: `cd /Users/yuanyxh/Documents/it/project/utility && rm -rf .build && swift build 2>&1`
Expected: Build succeeds.

**无需改动:** TaskScheduler（fireTask 已委托给 TaskExecutor）、TaskConfig 的 decoding 逻辑。

---

## Task 3: WindowPositioning 工具

**Objective:** 将散落在三个 PanelController 中的窗口定位逻辑抽离为 `WindowPositioning` 工具，提供命名策略函数。每个面板保留调用，但不再自行实现定位算法。

**Files:**
- Create: `Sources/Core/WindowPositioning.swift` — 定位工具
- Modify: `Sources/Clipboard/ClipboardPanelController.swift` — 替换 `show()` 中的 inline 定位
- Modify: `Sources/Chat/ChatPanelController.swift` — 替换 `positionPanel()`
- Modify: `Sources/Translation/TranslationPanelController.swift` — 替换 `show(with:)` / `showEmpty()` / `fallbackPosition()`

**Step 1: Create WindowPositioning struct**

```swift
import Cocoa

/// 窗口定位工具 — 纯函数，无视图依赖
enum WindowPositioning {

    /// 鼠标附近四象限智能定位（Clipboard 用）
    static func nearMouseQuadrant(
        windowSize: NSSize,
        padding: CGFloat = 12,
        screen: NSScreen?,
        mouseLocation: NSPoint? = nil
    ) -> NSPoint {
        let mouse = mouseLocation ?? NSEvent.mouseLocation
        guard let screenFrame = screen?.visibleFrame else {
            return NSPoint(x: mouse.x + padding, y: mouse.y - windowSize.height - padding)
        }
        // 尝试顺序：右下 → 左下 → 右上 → 左上
        let candidates: [(x: CGFloat, y: CGFloat)] = [
            (mouse.x + padding, mouse.y - windowSize.height - padding),
            (mouse.x - windowSize.width - padding, mouse.y - windowSize.height - padding),
            (mouse.x + padding, mouse.y + padding),
            (mouse.x - windowSize.width - padding, mouse.y + padding),
        ]
        for candidate in candidates {
            let rect = NSRect(origin: NSPoint(x: candidate.x, y: candidate.y), size: windowSize)
            if screenFrame.contains(rect) {
                return NSPoint(x: candidate.x, y: candidate.y)
            }
        }
        return NSPoint(x: mouse.x + padding, y: mouse.y - windowSize.height - padding)
    }

    /// 屏幕居中偏上（Chat 用）
    static func screenCenter(
        windowSize: NSSize,
        offsetFraction: CGFloat = 0.2,
        screen: NSScreen?
    ) -> NSPoint {
        guard let frame = screen?.visibleFrame else { return .zero }
        let x = frame.midX - windowSize.width / 2
        let y = frame.midY + frame.height * offsetFraction - windowSize.height / 2
        return NSPoint(x: x, y: y)
    }

    /// 记忆位置 → 鼠标位置回退（Translation 用）
    static func savedOrNearMouse(
        windowSize: NSSize,
        key: String,
        screen: NSScreen?
    ) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: key) {
            let savedPoint = NSPointFromString(saved)
            if !NSEqualPoints(savedPoint, .zero) {
                return savedPoint
            }
        }
        return nearMouseQuadrant(windowSize: windowSize, padding: 12, screen: screen)
    }

    /// 保存记忆位置
    static func savePosition(_ origin: NSPoint, forKey key: String) {
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: key)
    }
}
```

**Step 2: Update ClipboardPanelController**

替换 `show()` 中的 inline 定位：
```swift
// old: 手动 4 候选 + 循环 + contains 判断
let mouse = NSEvent.mouseLocation
let panelSize = ...
let candidates = [...]
var origin = ...
window?.setFrameOrigin(origin)

// new:
let panelSize = window?.frame.size ?? NSSize(width: 360, height: 380)
let origin = WindowPositioning.nearMouseQuadrant(
    windowSize: panelSize, padding: 12, screen: window?.screen
)
window?.setFrameOrigin(origin)
```

**Step 3: Update ChatPanelController**

替换 `positionPanel()`：
```swift
// old:
let x = screenFrame.midX - panelSize.width / 2
let y = screenFrame.midY + screenFrame.height * 0.2 - panelSize.height / 2

// new:
let origin = WindowPositioning.screenCenter(
    windowSize: panelSize, offsetFraction: 0.2, screen: screen
)
window?.setFrameOrigin(origin)
```

同时删除 `private func positionPanel()` 方法。

**Step 4: Update TranslationPanelController**

- `show(with:)` / `showEmpty()` 中的 inline 定位替换为：
  ```swift
  let origin = WindowPositioning.savedOrNearMouse(
      windowSize: frame.size, key: UDKey.translationPanelOrigin, screen: window?.screen
  )
  window?.setFrameOrigin(origin)
  ```
- `fallbackPosition()` 替换为：
  ```swift
  let origin = WindowPositioning.nearMouseQuadrant(
      windowSize: window?.frame.size ?? .zero, padding: 12, screen: window?.screen
  )
  window?.setFrameOrigin(origin)
  ```
  可删除 `fallbackPosition()` 方法
- `savePosition()` 替换为 `WindowPositioning.savePosition(origin, forKey: UDKey.translationPanelOrigin)`
- 删除 `@objc private func savePosition()` 方法

**Step 5: Build verification**

Run: `cd /Users/yuanyxh/Documents/it/project/utility && rm -rf .build && swift build 2>&1`
Expected: Build succeeds.

**验证改动进二进制：** `strings .build/debug/utility | grep "nearMouseQuadrant\|savedOrNearMouse\|screenCenter\|WindowPositioning"`

**无需改动:** PanelManager、KeyDispatcher、EventBus、AppDelegate、PanelProtocol。

---

## 不改的模块汇总

| 模块 | 理由 |
|------|------|
| `OpenAIClient` | 持有自有 URLSession + 回调式 API，与 HTTP 工具不兼容 |
| `AIChatService` | 委托给 OpenAIClient，不直接涉及 URLRequest 构造 |
| `Translator` | 同 AIChatService |
| `SSEParser` | 纯 parsing，不涉及网络 |
| `NetworkSpeedMonitor` | 自有 ping 逻辑 |
| `RSSManager`、`RSSParser` | 暂时不改，后续可迁移到 HTTP.get |
| `ClipboardWatcher`、`ClipboardStorage` | 不涉及 |
| `Stage` 相关 | 暂存窗口独立 |
| `HotkeyManager`、`MenuBarManager` | 不涉及 |
| `Database`、`TaskStateDB` | 数据层 |
| `EventBus`、`PanelManager`、`KeyDispatcher` | 架构基础设施 |
| `AppDelegate` | 入口 |
| `L10n`、`Log`、`Constants` | 工具类型 |

---

## 输出检查清单

- [ ] Task1: `HTTP.swift` 含 `Response`、`get`/`post`/`request` 方法、默认 User-Agent、30s 超时、retryCount 参数
- [ ] Task1: Build 通过
- [ ] Task2: `TaskExecConfig.toProcess()` 返回已配置 Process
- [ ] Task2: `TaskExecutor` 删除 runShell/runJS/runShortcuts/runPython，统一走 `toProcess()`
- [ ] Task2: Build 通过
- [ ] Task3: `WindowPositioning` 含 savedOrNearMouse、screenCenter、nearMouseQuadrant 三种策略
- [ ] Task3: ClipboardPanelController 改用 nearMouseQuadrant
- [ ] Task3: ChatPanelController 改用 screenCenter
- [ ] Task3: TranslationPanelController 改用 savedOrNearMouse
- [ ] Task3: Build 通过 + string grep 确认新符号入二进制
