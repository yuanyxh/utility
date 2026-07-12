# Task Executor + Notification Manager 实现方案

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** 为 Utility 菜单栏 app 添加任务调度执行器和统一通知管理，支持 cron 定时触发多种执行类型，任务失败时自动推送异常通知。

**Architecture:** 新增 `TaskScheduler` 定时轮询 cron 表达式，`TaskExecutor` 按类型分发执行（sh/appscript/shortcuts/py），`NotificationManager` 统一管理三类通知（成功/警告/异常）。任务失败时 executor 通过 notification manager 推送异常通知。所有配置通过 YAML 的 `tasks` + `notifications` 节点声明。

**Tech Stack:** Swift 5.9+, AppKit (NSUserNotification), Foundation (Process, Timer, RunLoop), Yams, YAML 配置

---

## 设计要点

- **Cron 补触发**：使用「上次触发时间戳」持久化到文件（`~/.config/utility/task_state.yaml`），每轮检查时若 `lastFire < 今天 && cron 应已触发` 则补执行一次。补触发后更新 `lastFire` 为本轮时间。
- **执行类型自动识别**：`exec` 可为字符串或字典。字符串：包含换行或 `*.sh`→sh，包含 `tell app`/`on run`→appscript，纯单行→快捷指令名，`.py`/`def `/`import `→py。字典：`{type: "sh", command: "..."}` 显式声明。
- **通知**：macOS 14+ 使用 `UserNotifications` 框架（需授权），降级到旧 `NSUserNotification`。失败时自动调用 `NotificationManager.shared.post(.error, title, body)`。

---

## 新增文件

```
Sources/
  Task/
    TaskScheduler.swift    — 调度器主循环、cron 匹配、补触发逻辑
    TaskExecutor.swift     — 执行分发（sh/appscript/shortcuts/py）
    TaskStateStore.swift   — 上次触发时间戳持久化
  Notification/
    NotificationManager.swift — 统一通知封装（success/warning/error）
```

修改文件：
- `Sources/Core/ConfigTypes.swift` — 新增 `TaskConfig`、`NotificationConfig`
- `Sources/Core/Constants.swift` — 新增 state 文件路径
- `Sources/App/AppDelegate.swift` — 启动 scheduler + 请求通知权限
- `Sources/Resources/default-config.yaml` — 新增 `tasks` 和 `notifications` 配置段

---

### Task 1: 定义 TaskConfig 与 NotificationConfig 数据模型

**Objective:** 在 ConfigTypes.swift 中添加任务和通知的配置结构体，挂载到 AppConfig。

**Files:**
- Modify: `Sources/Core/ConfigTypes.swift`

**Step 1: 添加类型定义**

在 `AppConfig` 中新增两个字段：
```swift
// AppConfig 新增
var tasks: [TaskConfig] = []
var notifications: NotificationConfig = .init()
```

在文件末尾新增：

```swift
// MARK: - Task

public struct TaskConfig: Codable {
    var name: String = ""
    var trigger: String = ""   // cron 表达式 或 事件名
    var exec: TaskExecConfig = .sh("")
    var enabled: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name      = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        trigger   = try c.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        enabled   = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // exec 可能是字符串或字典
        if let str = try? c.decode(String.self, forKey: .exec) {
            exec = TaskExecConfig.infer(from: str)
        } else if let dict = try? c.decode(TaskExecConfig.self, forKey: .exec) {
            exec = dict
        } else {
            exec = .sh("")
        }
    }
}

// MARK: - Exec Config

public enum TaskExecConfig: Codable {
    case sh(String)
    case appscript(String)
    case shortcuts(String)
    case py(String)

    enum CodingKeys: String, CodingKey { case type, command }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let cmd  = try c.decode(String.self, forKey: .command)
        switch type {
        case "sh":        self = .sh(cmd)
        case "appscript": self = .appscript(cmd)
        case "shortcuts": self = .shortcuts(cmd)
        case "py":        self = .py(cmd)
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown exec type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sh(let v):        try c.encode("sh",        forKey: .type); try c.encode(v, forKey: .command)
        case .appscript(let v): try c.encode("appscript", forKey: .type); try c.encode(v, forKey: .command)
        case .shortcuts(let v): try c.encode("shortcuts", forKey: .type); try c.encode(v, forKey: .command)
        case .py(let v):        try c.encode("py",        forKey: .type); try c.encode(v, forKey: .command)
        }
    }

    /// 从字符串自动推断执行类型
    static func infer(from raw: String) -> TaskExecConfig {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 包含换行 + shell 特征 → sh
        if t.contains("\n") {
            if t.contains("tell app") || t.contains("on run") {
                return .appscript(t)
            }
            if t.contains("def ") || t.contains("import ") || t.hasSuffix(".py") {
                return .py(t)
            }
            return .sh(t)
        }
        // 单行：路径含 .sh → sh
        if t.hasSuffix(".sh") { return .sh(t) }
        // 单行：含 tell app → appscript
        if t.contains("tell app") { return .appscript(t) }
        // 单行：含 def/import → py
        if t.contains("def ") || t.contains("import ") { return .py(t) }
        // 默认：快捷指令名
        return .shortcuts(t)
    }
}

// MARK: - Notification

public struct NotificationConfig: Codable {
    var enabled: Bool = true

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
```

**Step 2: Build 验证**

```bash
cd ~/Documents/it/project/utility && rm -rf .build && swift build
```

Expected: BUILD SUCCESS

---

### Task 2: 添加 task_state 持久化路径到 Constants

**Objective:** 在 Constants.swift 添加任务状态文件路径。

**Files:**
- Modify: `Sources/Core/Constants.swift`

**Step 1: 添加路径**

在 `AppPaths` 中追加：

```swift
/// ~/.config/utility/task_state.yaml
static let taskState: URL = {
    configDir.appendingPathComponent("task_state.yaml")
}()
```

**Step 2: Build 验证**

```bash
cd ~/Documents/it/project/utility && swift build
```

Expected: BUILD SUCCESS

---

### Task 3: 实现 TaskStateStore

**Objective:** 持久化每个任务的 `lastFireDate`，支持 YAML 读写。

**Files:**
- Create: `Sources/Task/TaskStateStore.swift`

**Step 1: 编写文件**

```swift
import Foundation
import Yams

struct TaskState: Codable {
    var lastFire: [String: Date] = [:]  // taskName → lastFireDate
}

final class TaskStateStore {
    static let shared = TaskStateStore()
    private let fileURL = AppPaths.taskState
    private let fileManager = FileManager.default

    private var state: TaskState = .init()

    private init() {
        load()
    }

    func lastFireDate(for taskName: String) -> Date? {
        state.lastFire[taskName]
    }

    func setLastFireDate(_ date: Date, for taskName: String) {
        state.lastFire[taskName] = date
        save()
    }

    // MARK: - Private

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = YAMLDecoder()
        state = (try? decoder.decode(TaskState.self, from: data)) ?? TaskState()
    }

    private func save() {
        let encoder = YAMLEncoder()
        guard let yaml = try? encoder.encode(state),
              let data = yaml.data(using: .utf8) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

**Step 2: Build 验证**

```bash
cd ~/Documents/it/project/utility && swift build
```

Expected: BUILD SUCCESS

---

### Task 4: 实现 NotificationManager

**Objective:** 统一通知接口——成功（无感知？先做轻量 banner）、警告、异常。

**Files:**
- Create: `Sources/Notification/NotificationManager.swift`

**Step 1: 编写文件**

```swift
import UserNotifications
import Cocoa

public final class NotificationManager: NSObject {
    public static let shared = NotificationManager()

    public enum Level { case success, warning, error }

    private var granted = false

    private override init() {
        super.init()
    }

    /// 请求通知权限（应用启动时调用一次）
    public func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            self.granted = granted
            Log.debug("[Notify] Authorization \(granted ? "granted" : "denied")")
        }
    }

    /// 发送通知
    public func post(_ level: Level, title: String, body: String) {
        guard ConfigManager.shared.config.notifications.enabled, granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        switch level {
        case .error:   content.sound = .defaultCritical
        case .warning: content.sound = .default
        case .success: content.sound = nil
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // 立即发送
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let e = error { Log.debug("[Notify] Post failed: \(e)") }
        }
    }

    // 便捷方法
    public func success(_ title: String, _ body: String = "") { post(.success, title: title, body: body) }
    public func warning(_ title: String, _ body: String = "") { post(.warning, title: title, body: body) }
    public func error(_ title: String, _ body: String = "")   { post(.error,   title: title, body: body) }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 即使在前台也显示
        completionHandler([.banner, .sound])
    }
}
```

**Step 2: Build 验证**

```bash
cd ~/Documents/it/project/utility && swift build
```

Expected: BUILD SUCCESS

---

### Task 5: 实现 TaskExecutor

**Objective:** 按类型分发执行任务，返回成功/失败及输出。

**Files:**
- Create: `Sources/Task/TaskExecutor.swift`

**Step 1: 编写文件**

```swift
import Foundation
import Carbon

public final class TaskExecutor {
    public struct Result {
        let success: Bool
        let output: String
        let error: String
    }

    public static func execute(_ config: TaskExecConfig) -> Result {
        switch config {
        case .sh(let cmd):        return runShell(cmd)
        case .appscript(let cmd): return runAppScript(cmd)
        case .shortcuts(let cmd): return runShortcuts(cmd)
        case .py(let cmd):        return runPython(cmd)
        }
    }

    // MARK: - Shell

    private static func runShell(_ cmd: String) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", cmd]
        return runProcess(task)
    }

    // MARK: - AppleScript

    private static func runAppScript(_ script: String) -> Result {
        // osascript 执行
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        return runProcess(task)
    }

    // MARK: - Shortcuts

    private static func runShortcuts(_ name: String) -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["run", name]
        return runProcess(task)
    }

    // MARK: - Python

    private static func runPython(_ code: String) -> Result {
        let task = Process()
        // 优先用 python3
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", "-c", code]
        return runProcess(task)
    }

    // MARK: - Process runner

    private static func runProcess(_ task: Process) -> Result {
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8) ?? ""
            let error  = String(data: errData, encoding: .utf8) ?? ""

            return Result(success: task.terminationStatus == 0, output: output, error: error)
        } catch {
            return Result(success: false, output: "", error: error.localizedDescription)
        }
    }
}
```

**Step 2: Build 验证**

```bash
cd ~/Documents/it/project/utility && swift build
```

Expected: BUILD SUCCESS

---

### Task 6: 实现 TaskScheduler（cron 解析 + 调度循环 + 补触发）

**Objective:** 主调度器：解析 cron、每 60s 轮询、计算下次触发时间、处理电脑离线补触发。

**Files:**
- Create: `Sources/Task/TaskScheduler.swift`

**Step 1: 编写文件**

```swift
import Foundation

public final class TaskScheduler {
    public static let shared = TaskScheduler()

    private var timer: Timer?
    private let store = TaskStateStore.shared

    private init() {}

    public func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 启动时立即执行一轮
        tick()
        Log.debug("[Scheduler] Started")
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    private func tick() {
        let now = Date()
        let configs = ConfigManager.shared.config.tasks.filter { $0.enabled }

        for task in configs {
            guard shouldFire(task, now: now) else { continue }

            Log.debug("[Scheduler] Firing: \(task.name)")
            let result = TaskExecutor.execute(task.exec)

            if result.success {
                Log.debug("[Scheduler] \(task.name) OK")
            } else {
                Log.debug("[Scheduler] \(task.name) FAILED: \(result.error)")
                NotificationManager.shared.error(
                    "任务失败: \(task.name)",
                    result.error.isEmpty ? "exit code != 0" : String(result.error.prefix(200))
                )
            }

            store.setLastFireDate(now, for: task.name)
        }
    }

    // MARK: - Cron logic

    private func shouldFire(_ task: TaskConfig, now: Date) -> Bool {
        guard let expr = CronExpression(task.trigger) else {
            // 非 cron 格式（事件名），暂不处理
            return false
        }

        let lastFire = store.lastFireDate(for: task.name)
        let nextFire = nextCronDate(after: lastFire ?? .distantPast, expr: expr)

        guard let next = nextFire, next <= now else { return false }

        // 补触发：如果上次触发在今天之前，且 cron 在今天应已触发
        let calendar = Calendar.current
        if let last = lastFire, !calendar.isDate(last, inSameDayAs: now) {
            // 不同天：检查今天是否有应该触发但未触发的时间点
            let todayStart = calendar.startOfDay(for: now)
            let todayNext = nextCronDate(after: todayStart.addingTimeInterval(-1), expr: expr)
            if let tn = todayNext, tn <= now {
                return true
            }
            return false
        }

        return true
    }

    /// 简易 cron 解析：分 时 日 月 周 (5 字段)
    private struct CronExpression {
        let minutes: Set<Int>
        let hours:   Set<Int>
        let days:    Set<Int>
        let months:  Set<Int>
        let weekdays:Set<Int>

        init?(_ expr: String) {
            let parts = expr.split(separator: " ").map(String.init)
            guard parts.count == 5 else { return nil }
            guard let m = parseField(parts[0], min: 0, max: 59),
                  let h = parseField(parts[1], min: 0, max: 23),
                  let d = parseField(parts[2], min: 1, max: 31),
                  let mo = parseField(parts[3], min: 1, max: 12),
                  let w = parseField(parts[4], min: 0, max: 6) else { return nil }
            minutes = m; hours = h; days = d; months = mo; weekdays = w
        }
    }

    private func nextCronDate(after date: Date, expr: CronExpression) -> Date? {
        let calendar = Calendar.current
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        comps.second = 0
        // 向前走 1 分钟开始搜索（不含当前分钟）
        guard var current = calendar.date(from: comps) else { return nil }
        current = current.addingTimeInterval(60)

        // 搜索最多 366 天
        for _ in 0..<527040 { // 366 * 24 * 60
            let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: current)
            guard let min = c.minute, let hr = c.hour, let day = c.day,
                  let mon = c.month, let wd = c.weekday else { break }
            // weekday: Calendar 1=Sunday, cron 0=Sunday, 转换
            let cronWD = (wd + 5) % 7  // Sunday(1)->6, Monday(2)->0 ... Saturday(7)->5... actually let me redo this
            // Calendar: Sun=1 Mon=2 Tue=3 Wed=4 Thu=5 Fri=6 Sat=7
            // Cron:     Sun=0 Mon=1 Tue=2 Wed=3 Thu=4 Fri=5 Sat=6
            // Mapping: cron = (cal - 1 + 7) % 7 = (cal - 1) % 7
            let cronWD = wd - 1

            if expr.minutes.contains(min),
               expr.hours.contains(hr),
               expr.days.contains(day),
               expr.months.contains(mon),
               expr.weekdays.contains(cronWD) {
                return current
            }
            current = current.addingTimeInterval(60)
        }
        return nil
    }
}

// MARK: - Field parser

private func parseField(_ s: String, min: Int, max: Int) -> Set<Int>? {
    if s == "*" { return Set(min...max) }
    var result = Set<Int>()
    for part in s.split(separator: ",") {
        let p = String(part)
        if p.contains("/") {
            let sp = p.split(separator: "/")
            guard sp.count == 2,
                  let val = Int(sp[1]) else { return nil }
            let range = sp[0] == "*" ? min...max : (parseRange(String(sp[0]), min: min, max: max) ?? min...max)
            for i in stride(from: range.lowerBound, through: range.upperBound, by: val) {
                result.insert(i)
            }
        } else if p.contains("-") {
            guard let r = parseRange(p, min: min, max: max) else { return nil }
            result.formUnion(r)
        } else {
            guard let v = Int(p), v >= min, v <= max else { return nil }
            result.insert(v)
        }
    }
    return result.isEmpty ? nil : result
}

private func parseRange(_ s: String, min: Int, max: Int) -> ClosedRange<Int>? {
    let sp = s.split(separator: "-")
    guard sp.count == 2, let lo = Int(sp[0]), let hi = Int(sp[1]),
          lo >= min, hi <= max, lo <= hi else { return nil }
    return lo...hi
}
```

**Step 2: Build 验证**

```bash
cd ~/Documents/it/project/utility && swift build
```

Expected: BUILD SUCCESS

---

### Task 7: 更新 default-config.yaml 添加配置示例

**Objective:** 添加 tasks 和 notifications 配置段样例。

**Files:**
- Modify: `Sources/Resources/default-config.yaml`

**Step 1: 追加配置段**

在文件末尾追加：

```yaml
# ------------------------------------------------------------------
# 任务调度
tasks: []
  # - name: 日报提醒
  #   trigger: '0 18 * * *'       # cron: 每天 18:00
  #   exec: shortcuts://日报汇总    # 快捷指令名
  #   enabled: true
  # - name: 清理临时文件
  #   trigger: '0 3 * * 1'
  #   exec:
  #     type: sh
  #     command: rm -rf /tmp/myapp-*

notifications:
  enabled: true
```

注意：`tasks: []` 放在 `prompts.templates` 之后、`notifications` 之前。

更精确的插入位置（在现有 `prompts:\n  templates: {}\n` 之后）：

```yaml
  templates: {}
tasks: []
  # - name: 示例任务
  #   trigger: '0 9 * * *'
  #   exec: echo "hello"
  #   enabled: true

notifications:
  enabled: true
```

**Step 2: Build 验证**

```bash
cd ~/Documents/it/project/utility && swift build
```

Expected: BUILD SUCCESS

---

### Task 8: 集成到 AppDelegate——启动 scheduler + 请求通知权限

**Objective:** 在 AppDelegate 中初始化 TaskScheduler 和 NotificationManager。

**Files:**
- Modify: `Sources/App/AppDelegate.swift`

**Step 1: 添加启动代码**

在 `applicationDidFinishLaunching` 中，于 `stageMonitor.start(...)` 之后添加：

```swift
NotificationManager.shared.requestAuthorization()
TaskScheduler.shared.start()
```

完整位置参考：

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // ... 现有代码 ...
    stageMonitor.start(with: stageWindow)

    NotificationManager.shared.requestAuthorization()
    TaskScheduler.shared.start()

    Log.debug("[Utility] Ready")
}
```

**Step 2: Build 验证**

```bash
cd ~/Documents/it/project/utility && rm -rf .build && swift build
```

Expected: BUILD SUCCESS, 检查二进制包含 scheduler 字符串：

```bash
strings .build/debug/utility | grep -i scheduler
```

Expected: 有匹配输出

---

## 验证步骤

1. **配置测试任务** — 编辑 `~/.config/utility/config.yaml`，添加一个 1 分钟后触发的任务：
   ```yaml
   tasks:
     - name: test
       trigger: '* * * * *'   # 每分钟
       exec: echo "scheduler test"
       enabled: true
   ```

2. **启动 app** — 菜单栏「重载配置」或重启 app

3. **观察日志** — `tail -f ~/.cache/utility/debug.log`，应在下一分钟看到 `[Scheduler] Firing: test` 和 `[Scheduler] test OK`

4. **验证失败通知** — 将 exec 改为 `exit 1`，重载配置，确认收到异常通知

5. **验证补触发** — 将 `task_state.yaml` 中的 `lastFire` 改为昨天，重启 app，确认任务被补触发一次

---

## 风险 & 未覆盖

- **事件触发**：本次只实现 cron 定时触发。事件触发（如「文件变更」「应用启动」）留待后续迭代。
- **Cron 精度**：轮询间隔 60s，最小触发精度为分钟级，秒级 cron 不支持。
- **任务并发**：当前顺序执行，同一 tick 内不会并行跑多个任务。
- **执行超时**：未设超时，长时间任务会阻塞调度循环。后续可改为后台队列 + 超时控制。
