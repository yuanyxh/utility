# Infotainer — 聚合信息服务 Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** 实现可配置的信息聚合架构——支持 HTTP API 直调和任意脚本命令两种模式，用户可在 YAML 配置中定义数据源，自动拉取并展示在菜单栏「聚合信息」子菜单中。

**Architecture:** 分层设计，可插拔数据源——

```
                    ┌─────────────────────┐
                    │  InfotainerFetcher  │  ← 编排：选 source → fetch → 交 Parser
                    └────────┬────────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
       ┌────────────┐ ┌────────────┐ ┌────────────┐
       │ HTTPSource │ │ShellSource │ │  Future...  │  ← InfotainerSource 协议
       └────────────┘ └─────┬──────┘ └────────────┘
              │              │
              │              ▼
              │     ┌────────────────┐
              │     │  TaskExecutor  │  ← 复用已有 Process 封装
              │     └────────────────┘
              ▼              ▼
       ┌──────────────────────────────┐
       │       JSONPathParser         │  ← 独立解析层，可单测
       └──────────────────────────────┘
```

- **`InfotainerSource` 协议**：`func fetch() async throws -> String` — 数据源只负责返回原始 JSON 字符串
- **`HTTPSource`**：URLSession HTTP 调用
- **`ShellSource`**：内部委托给 `TaskExecutor.execute(.sh(cmd))`，零重复
- **`JSONPathParser`**：纯函数，输入 JSON string + `[InfotainerField]` → 输出 `[String: String]`，不和任何 source 耦合
- **`InfotainerFetcher`** 退化为编排层：根据 config 选 source → `source.fetch()` → `JSONPathParser.parse()`

**Tech Stack:** Swift 5.9+, AppKit (NSMenu), Foundation (URLSession + Process), Yams (已有依赖)

---

## 设计概述

### 配置 Schema

```yaml
infotainers:
  # 模式 A：HTTP 直调
  - name: DeepSeek
    request:
      url: https://api.deepseek.com/v1/balance
      method: GET
      headers:
        Authorization: "Bearer sk-xxx"
    interval: 600
    fields:
      - key: balance
        label: 剩余金额
        prefix: "¥"

  # 模式 B：command — 运行任意脚本，stdout 必须是合法 JSON
  - name: 搬瓦工
    command:
      script: |
        curl -s -H "API-Key: xxx" https://api.example.com/account
    interval: 3600
    fields:
      - key: data.traffic
        label: 剩余流量
        suffix: " GB"
      - key: data.expires_at
        label: 过期时间

  # 模式 C：command 处理非 API 场景（爬网页、读本地文件、多步聚合）
  - name: 某服务状态
    command:
      script: |
        status=$(curl -s https://status.example.com | grep -oP 'Status: \K\w+')
        echo "{\"status\": \"$status\"}"
    interval: 600
    fields:
      - key: status
        label: 状态
```

- **request / command**：二选一。`request` 是标准 HTTP 请求定义（method 默认 GET，`toURLRequest()` 方法封装 URLRequest 构建）；`command` 是 shell 命令封装（`script` 字段为命令体，内部通过 `toExecConfig()` → `TaskExecutor.execute()` 执行），stdout 必须是合法 JSON 字符串。
- **interval**: 后台定时刷新间隔（秒），0 = 不自动刷新，仅在启动时拉取一次。
- **fields**: JSON 点号路径取值（如 `data.traffic.used`），`label` 显示名称，`prefix`/`suffix` 可选装饰。

### 菜单结构

```
菜单栏
├── 重载配置
├── ──────────────
├── 开机自启
├── ──────────────
├── RSS >
├── ──────────────
├── 聚合信息 >          ← 新增
│   ├── 搬瓦工 >
│   │   ├── 剩余流量: 342.5 GB
│   │   └── 过期时间: 2026-12-31
│   └── DeepSeek >
│       └── 剩余金额: ¥42.50
├── ──────────────
├── 任务 >
├── ──────────────
├── 清空剪切板
├── ──────────────
├── 退出
```

### 数据流

```
ConfigManager.load()
  → InfotainerManager 读取 infotainers 配置
  → 为每个 interval>0 的 pod 启动 DispatchSourceTimer
  → InfotainerFetcher.fetch(pod):
      → config.request != nil → HTTPSource.fetch()
      → config.command != nil → ShellSource.fetch() → TaskExecutor.execute(.sh(cmd))
      → JSONPathParser.parse(rawJSON, fields)
  → 写入内存缓存
  → menuWillOpen 时 MenuBarManager 读缓存渲染菜单
```

---

## 详细任务

### Task 1: 定义 Config 类型 + InfotainerSource 协议

**Objective:** 在 ConfigTypes.swift 中添加 `InfotainerConfig` / `InfotainerRequest` / `InfotainerField` 并接入 `AppConfig`；在 Infotainer 目录定义 `InfotainerSource` 协议

**Files:**
- Modify: `Sources/Core/ConfigTypes.swift`
- Create: `Sources/Infotainer/InfotainerSource.swift`

**Step 1: 在 ConfigTypes.swift 末尾添加 Infotainer 类型**

```swift
// MARK: - Infotainer

public struct InfotainerRequest: Codable {
    var url: String
    var method: String
    var headers: [String: String]

    public init(url: String, method: String = "GET", headers: [String: String] = [:]) {
        self.url = url; self.method = method; self.headers = headers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }

    /// 封装 URLRequest 构建逻辑，不在 HTTPSource 里散落
    func toURLRequest() throws -> URLRequest {
        guard let url = URL(string: url) else {
            throw InfotainerError.invalidURL(url)
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 15
        for (k, v) in headers {
            r.setValue(v, forHTTPHeaderField: k)
        }
        return r
    }
}

/// Shell 命令封装：内部委托给 TaskExecutor
public struct InfotainerCommand: Codable {
    var script: String

    public init(script: String) { self.script = script }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        script = try c.decode(String.self, forKey: .script)
    }

    /// 转为 TaskExecutor 可消费的执行配置
    func toExecConfig() -> TaskExecConfig {
        .sh(script)
    }
}

public struct InfotainerField: Codable {
    var key: String       // JSON 点号路径，如 "data.traffic.remaining"
    var label: String     // 菜单显示名
    var prefix: String
    var suffix: String

    public init(key: String, label: String, prefix: String = "", suffix: String = "") {
        self.key = key; self.label = label; self.prefix = prefix; self.suffix = suffix
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
    }
}

public struct InfotainerConfig: Codable {
    var name: String
    var request: InfotainerRequest?     // 二选一
    var command: InfotainerCommand?     // 二选一
    var interval: Int
    var fields: [InfotainerField]

    /// 有效数据源（request 或 command 至少有一个）
    var sourceIsValid: Bool {
        request != nil || command != nil
    }

    public init(name: String, request: InfotainerRequest? = nil, command: InfotainerCommand? = nil, interval: Int = 0, fields: [InfotainerField] = []) {
        self.name = name; self.request = request; self.command = command; self.interval = interval; self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        request = try c.decodeIfPresent(InfotainerRequest.self, forKey: .request)
        command = try c.decodeIfPresent(InfotainerCommand.self, forKey: .command)
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 0
        fields = try c.decodeIfPresent([InfotainerField].self, forKey: .fields) ?? []
    }
}
```

**Step 2: 在 AppConfig 中添加 infotainers 属性**

在 `AppConfig` struct 中添加属性：
```swift
var infotainers: [InfotainerConfig] = []
```

在 `init(from decoder:)` 中添加解码：
```swift
infotainers = (try? c.decode([InfotainerConfig].self, forKey: .infotainers)) ?? []
```

**Step 3: 创建 InfotainerSource 协议**

创建 `Sources/Infotainer/InfotainerSource.swift`：

```swift
import Foundation

/// 数据源协议：所有 infotainer source 的唯一职责是返回原始 JSON 字符串
protocol InfotainerSource {
    func fetch() async throws -> String
}
```

**Verification:**
- `swift build` 通过
- `strings .build/debug/utility | grep "Infotainer"` 能看到类型名

---

### Task 2: 添加 AppEvent 事件

**Objective:** 定义 infotainer 相关事件：数据更新、拉取失败

**Files:**
- Modify: `Sources/Core/AppEvent.swift`

**Step 1: 添加事件枚举**

在 `AppEvent` enum 中添加：
```swift
case infotainerUpdated, infotainerFetchFailed
```

**Verification:**
- `swift build` 通过（因为 EventBus 用 `AnyHashable` 包装，新增 case 天然可用）

---

### Task 3: 实现 HTTPSource + ShellSource

**Objective:** 两个数据源实现 `InfotainerSource` 协议。`HTTPSource` 做 URLSession 调用，`ShellSource` 委托给 `TaskExecutor.execute(.sh(cmd))` 而不是重写 Process 逻辑。

**Files:**
- Create: `Sources/Infotainer/HTTPSource.swift`
- Create: `Sources/Infotainer/ShellSource.swift`

**Step 1: HTTPSource.swift**

```swift
import Foundation

/// HTTP 数据源：由 InfotainerRequest.toURLRequest() 封装请求构建
struct HTTPSource: InfotainerSource {
    let request: InfotainerRequest

    func fetch() async throws -> String {
        let r = try request.toURLRequest()
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw InfotainerError.httpStatus(code)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Infotainer 通用错误类型
enum InfotainerError: LocalizedError {
    case invalidURL(String)
    case httpStatus(Int)
    case commandFailed(String)
    case emptyOutput
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "Invalid URL: \(u)"
        case .httpStatus(let c): return "HTTP \(c)"
        case .commandFailed(let m): return m
        case .emptyOutput: return "Empty stdout"
        case .invalidJSON: return "Invalid JSON"
        }
    }
}
```

**Step 2: ShellSource.swift**

```swift
import Foundation

/// Shell 数据源：command.toExecConfig() → TaskExecutor.execute()
/// TaskExecutor 无需任何改动——已有 runProcess + sh/js/py 支持
struct ShellSource: InfotainerSource {
    let command: InfotainerCommand

    func fetch() async throws -> String {
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let result = TaskExecutor.execute(command.toExecConfig())
                if result.success {
                    let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        cont.resume(throwing: InfotainerError.emptyOutput)
                    } else {
                        cont.resume(returning: trimmed)
                    }
                } else {
                    let msg = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    let err = msg.isEmpty ? "exit code != 0" : String(msg.prefix(200))
                    cont.resume(throwing: InfotainerError.commandFailed(err))
                }
            }
        }
    }
}
```

**Verification:**
- `swift build` 通过
- `ShellSource` 一行 `command.toExecConfig()` 委托 `TaskExecutor` → 零 Process 代码

---

### Task 4: 实现 JSONPathParser + InfotainerFetcher（编排层）

**Objective:** `JSONPathParser` 独立解析 JSON 并按 fields 提取值；`InfotainerFetcher` 是薄编排层——选 source → fetch → 交 parser。

**Files:**
- Create: `Sources/Infotainer/JSONPathParser.swift`
- Create: `Sources/Infotainer/InfotainerFetcher.swift`

**Step 1: JSONPathParser.swift**

```swift
import Foundation

/// 纯函数：JSON 字符串 + 字段定义 → [key: 格式化值]
enum JSONPathParser {
    struct ParseResult {
        let values: [String: String]  // field.key → 格式化值（含 prefix/suffix）
        let error: String?            // nil = 成功
    }

    static func parse(_ rawJSON: String, fields: [InfotainerField]) -> ParseResult {
        guard let data = rawJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ParseResult(values: [:], error: "Invalid JSON")
        }

        var values: [String: String] = [:]
        for field in fields {
            if let raw = valueAt(json: json, path: field.key) {
                values[field.key] = "\(field.prefix)\(raw)\(field.suffix)"
            } else {
                values[field.key] = "—"
            }
        }
        return ParseResult(values: values, error: nil)
    }

    /// JSON 点号路径取值：`"data.traffic.used"` → json["data"]["traffic"]["used"]
    static func valueAt(json: [String: Any], path: String) -> Any? {
        let keys = path.split(separator: ".").map(String.init)
        var current: Any = json
        for key in keys {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current
    }
}
```

**Step 2: InfotainerFetcher.swift**

```swift
import Foundation

/// 每个 infotainer pod 的拉取结果
struct InfotainerResult {
    let name: String
    let values: [String: String]
    let error: String?
    let fetchedAt: Date
}

/// 编排层：根据 config 选 source → fetch → JSONPathParser
enum InfotainerFetcher {
    static func fetch(_ config: InfotainerConfig) async -> InfotainerResult {
        guard config.sourceIsValid else {
            return InfotainerResult(name: config.name, values: [:],
                                    error: "No request or command configured", fetchedAt: Date())
        }
        do {
            let raw = try await makeSource(config).fetch()
            let parsed = JSONPathParser.parse(raw, fields: config.fields)
            return InfotainerResult(name: config.name, values: parsed.values,
                                    error: parsed.error, fetchedAt: Date())
        } catch {
            let msg = (error as? InfotainerError)?.errorDescription ?? error.localizedDescription
            return InfotainerResult(name: config.name, values: [:], error: msg, fetchedAt: Date())
        }
    }

    /// 工厂方法——加新数据源只需加一个 case
    private static func makeSource(_ config: InfotainerConfig) -> any InfotainerSource {
        if let req = config.request {
            return HTTPSource(request: req)
        }
        return ShellSource(command: config.command!)
    }
}
```

**Step 1.1: 创建目录**

```bash
mkdir -p Sources/Infotainer
```

**Verification:**
- `swift build` 通过
- `valueAt` 标记为 `static` public 方便后续单测

---

### Task 5: 实现 InfotainerManager — 调度 + 缓存

**Objective:** Manager 单例：订阅 `configDidLoad` → 重建定时器 → 拉取数据 → 写内存缓存 → 发布 `infotainerUpdated`

**Files:**
- Create: `Sources/Infotainer/InfotainerManager.swift`

**Step 1: 写入 InfotainerManager.swift**

```swift
import Foundation

/// 管理所有 infotainer pod 的生命周期：调度、拉取、缓存
final class InfotainerManager {
    static let shared = InfotainerManager()

    /// key: pod name → 最近一次拉取结果
    private var cache: [String: InfotainerResult] = [:]
    private var timers: [String: DispatchSourceTimer] = [:]
    private let queue = DispatchQueue(label: "utility.infotainer", qos: .utility)
    private let lock = NSLock()

    private init() {
        EventBus.shared.subscribe(AppEvent.configDidLoad) { [weak self] _ in
            self?.reschedule()
        }
    }

    /// 注册后首次拉取全部 pod
    func start() {
        reschedule()
    }

    /// 读取缓存（线程安全），menuWillOpen 时调用
    func snapshot() -> [InfotainerResult] {
        lock.lock()
        defer { lock.unlock() }
        return ConfigManager.shared.config.infotainers.compactMap { cache[$0.name] }
    }

    // MARK: - Private

    private func reschedule() {
        lock.lock()
        for (_, t) in timers { t.cancel() }
        timers.removeAll()
        cache.removeAll()
        lock.unlock()

        let pods = ConfigManager.shared.config.infotainers
        for pod in pods {
            fetchAndCache(pod)
            guard pod.interval > 0 else { continue }
            scheduleTimer(for: pod)
        }
    }

    private func fetchAndCache(_ pod: InfotainerConfig) {
        let name = pod.name
        queue.async { [weak self] in
            let result = await InfotainerFetcher.fetch(pod)
            guard let self else { return }
            self.lock.lock()
            self.cache[name] = result
            self.lock.unlock()
            DispatchQueue.main.async {
                if result.error != nil {
                    EventBus.shared.publish(AppEvent.infotainerFetchFailed,
                                            payload: (name, result.error!))
                } else {
                    EventBus.shared.publish(AppEvent.infotainerUpdated, payload: name)
                }
            }
        }
    }

    private func scheduleTimer(for pod: InfotainerConfig) {
        let name = pod.name
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.seconds(pod.interval)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.fetchAndCache(pod)
        }
        t.resume()
        lock.lock()
        timers[name] = t
        lock.unlock()
    }
}
```

**Verification:**
- `swift build` 通过

---

### Task 6: 在 AppDelegate 中初始化 InfotainerManager

**Objective:** AppDelegate.applicationDidFinishLaunching 中调 `InfotainerManager.shared.start()`

**Files:**
- Modify: `Sources/App/AppDelegate.swift`

**Step 1: 添加初始化调用**

在 `TaskScheduler.shared.start()` 之后添加：
```swift
InfotainerManager.shared.start()
```

**Verification:**
- `swift build` 通过

---

### Task 7: 添加 L10n 字符串

**Objective:** 为「聚合信息」菜单项添加中英文字符串

**Files:**
- Modify: `Sources/Core/L10n.swift`
- Modify: `Sources/Resources/zh-Hans.json`
- Modify: `Sources/Resources/en.json`

**Step 1: L10n.swift — 添加 Menu.infotainer**

在 `extension L10n { enum Menu {` 中添加：
```swift
static var infotainer: String {
    string("menu.infotainer")
}
```

**Step 2: zh-Hans.json — 添加 key**

```json
"menu.infotainer": "聚合信息",
```

**Step 3: en.json — 添加 key**

```json
"menu.infotainer": "Info",
```

**Step 4: L10n.Menu — 添加 refreshAllTitles 覆盖**

在 `MenuBarManager.refreshAllTitles()` 中后续 Task 8 会补齐。

**Verification:**
- JSON 格式合法（两文件各加一行，确保逗号正确）

---

### Task 8: 在 MenuBarManager 中渲染聚合信息子菜单

**Objective:** 在菜单栏构建「聚合信息」菜单项及其子菜单，`menuWillOpen` 时刷新

**Files:**
- Modify: `Sources/Core/MenuBarManager.swift`

**Step 1: 添加 infotainerMenuItem 属性**

```swift
private var infotainerMenuItem: NSMenuItem!
```

**Step 2: buildMenu() 中添加菜单项**

在 `tasksMenuItem` 之前添加（紧跟 RSS 分隔线之后）：
```swift
// ── Infotainer ──
infotainerMenuItem = NSMenuItem(title: L10n.Menu.infotainer, action: nil, keyEquivalent: "")
infotainerMenuItem.submenu = NSMenu()
menu.addItem(infotainerMenuItem)

menu.addItem(NSMenuItem.separator())
```

**Step 3: menuWillOpen 中刷新 infotainer**

```swift
public func menuWillOpen(_: NSMenu) {
    refreshRSSItem()
    refreshInfotainerItem()
    refreshTasksItem()
}
```

**Step 4: 实现 refreshInfotainerItem()**

```swift
private func refreshInfotainerItem() {
    let results = InfotainerManager.shared.snapshot()
    let sub = NSMenu()

    if results.isEmpty {
        let empty = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
        empty.isEnabled = false
        sub.addItem(empty)
    } else {
        for result in results {
            let podItem: NSMenuItem
            if let err = result.error {
                podItem = NSMenuItem(title: "\(result.name): \(err)", action: nil, keyEquivalent: "")
                podItem.isEnabled = false
            } else {
                podItem = NSMenuItem(title: result.name, action: nil, keyEquivalent: "")
                let fieldMenu = NSMenu()
                for (key, value) in result.values.sorted(by: { $0.key < $1.key }) {
                    // 用 field label 代替 key
                    let pod = ConfigManager.shared.config.infotainers.first(where: { $0.name == result.name })
                    let label = pod?.fields.first(where: { $0.key == key })?.label ?? key
                    let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    fieldMenu.addItem(item)
                }
                podItem.submenu = fieldMenu
            }
            sub.addItem(podItem)
        }
    }

    infotainerMenuItem.submenu = sub
}
```

**Step 5: refreshAllTitles() 中添加**

```swift
infotainerMenuItem.title = L10n.Menu.infotainer
```

**Verification:**
- `swift build` 通过
- 手动运行 utility 检查菜单栏是否有「聚合信息」入口

---

### Task 9: 更新 default-config.yaml 示例

**Objective:** 在默认配置中添加 infotainers 示例（注释掉，供用户参考）

**Files:**
- Modify: `Sources/Resources/default-config.yaml`

**Step 1: 在文件末尾（tasks 段之后）添加**

```yaml
# ------------------------------------------------------------------
# 聚合信息服务：定时拉取数据，展示在菜单栏
# 支持两种模式：request（HTTP 直调）或 command（shell 脚本，stdout 输出 JSON）
infotainers: []
  # --- request 模式 ---
  # - name: DeepSeek
  #   request:
  #     url: https://api.deepseek.com/v1/balance
  #     method: GET
  #     headers:
  #       Authorization: "Bearer sk-xxx"
  #   interval: 600
  #   fields:
  #     - key: balance
  #       label: 剩余金额
  #       prefix: "¥"
  #
  # --- command 模式（适合无公开 API / 需爬网页 / 多步聚合场景）---
  # - name: 搬瓦工
  #   command:
  #     script: |
  #       curl -s -H "API-Key: xxx" https://api.example.com/account
  #   interval: 3600
  #   fields:
  #     - key: data.traffic
  #       label: 剩余流量
  #       suffix: " GB"
  #     - key: data.expires_at
  #       label: 过期时间
```

**Verification:**
- YAML 语法合法：`python3 -c "import yaml; yaml.safe_load(open('Sources/Resources/default-config.yaml'))"`

---

### Task 10: Build + 验证

**Objective:** 完整编译并确认二进制包含 infotainer 相关符号

**Files:** None (build only)

**Step 1: Clean build**

```bash
cd /Users/yuanyxh/Documents/it/project/utility
rm -rf .build && swift build
```

**Step 2: 验证符号入二进制**

```bash
strings .build/debug/utility | grep -i "infotainer"
strings .build/arm64-apple-macosx/debug/utility | grep -i "infotainer"
```

Expected: 能看到 `InfotainerManager`、`InfotainerFetcher`、`menu.infotainer` 等字符串。

**Step 3: 运行并检查菜单**

手动启动 `./.build/debug/utility`，点击菜单栏图标，确认「聚合信息」子菜单出现（无配置时显示 "—"）。

---

## 文件变更汇总

| 文件 | 操作 |
|------|------|
| `Sources/Core/ConfigTypes.swift` | 添加 `InfotainerConfig` / `InfotainerRequest`（含 `toURLRequest()`）/ `InfotainerCommand`（含 `toExecConfig()`）/ `InfotainerField` + AppConfig 集成 |
| `Sources/Infotainer/InfotainerSource.swift` | **新建** — 数据源协议 `func fetch() async throws -> String` |
| `Sources/Infotainer/InfotainerError.swift` | **新建** — 统一错误类型（含在 HTTPSource.swift） |
| `Sources/Infotainer/HTTPSource.swift` | **新建** — 一行 `request.toURLRequest()` 构建请求 |
| `Sources/Infotainer/ShellSource.swift` | **新建** — 一行 `command.toExecConfig()` 委托 TaskExecutor |
| `Sources/Infotainer/JSONPathParser.swift` | **新建** — 纯函数解析，可单测 |
| `Sources/Infotainer/InfotainerFetcher.swift` | **新建** — 薄编排层 + `InfotainerResult` + `makeSource()` 工厂 |
| `Sources/Infotainer/InfotainerManager.swift` | **新建** — 调度 + 缓存 + EventBus 发布 |
| `Sources/Core/AppEvent.swift` | 添加 `infotainerUpdated` / `infotainerFetchFailed` |
| `Sources/App/AppDelegate.swift` | 添加 `InfotainerManager.shared.start()` |
| `Sources/Core/L10n.swift` | 添加 `Menu.infotainer` 字符串 key |
| `Sources/Resources/zh-Hans.json` | 添加 `menu.infotainer: "聚合信息"` |
| `Sources/Resources/en.json` | 添加 `menu.infotainer: "Info"` |
| `Sources/Core/MenuBarManager.swift` | 添加 infotainer 菜单项 + 渲染逻辑 |
| `Sources/Resources/default-config.yaml` | 添加 infotainers 示例注释 |

---

## 已有代码变更清单（除新建文件外）

| 文件 | 变更 | 理由 |
|------|------|------|
| `ConfigTypes.swift` | 新增 4 个 struct + `AppConfig` 加 `infotainers` 属性 | 配置驱动的设计起点 |
| `AppEvent.swift` | 新增 2 个 enum case | Infotainer 状态事件 |
| `AppDelegate.swift` | 加一行 `InfotainerManager.shared.start()` | Manager 初始化 |
| `L10n.swift` | 加 `Menu.infotainer` 计算属性 | i18n 全覆盖 |
| `zh-Hans.json` | 加 `"menu.infotainer": "聚合信息"` | 中文字符串 |
| `en.json` | 加 `"menu.infotainer": "Info"` | 英文字符串 |
| `MenuBarManager.swift` | 加 `infotainerMenuItem` 属性 + `buildMenu()` 加菜单项 + `menuWillOpen` 加刷新 + `refreshInfotainerItem()` 方法 + `refreshAllTitles()` 加覆盖 | 菜单栏渲染 |
| `default-config.yaml` | 加 `infotainers: []` 及注释示例 | 配置模板 |

**不动的文件：**
- `TaskExecutor.swift` — API 已有 `execute(.sh(...))` 足够 ShellSource 使用，不改
- `EventBus.swift` — 已有 pub/sub 完全够用
- `ConfigManager.swift` — 只管 YAML I/O + 发布 `configDidLoad`，不改业务
- `PanelManager.swift` — Infotainer 是只读菜单渲染，不涉及面板，无关

## 风险 & 注意事项

1. **密钥安全性**：API key / token 明文存在 YAML 中，用户需自行管理配置文件权限（`chmod 600 ~/.config/utility/config.yaml`）
2. **ShellSource 复用 TaskExecutor**：`TaskExecutor.execute` 是同步调用，`ShellSource` 用 `withCheckedThrowingContinuation` 桥接到 async，跑在 `DispatchQueue.global(.utility)`，不阻塞主线程
3. **开闭原则**：`makeSource()` 工厂方法集中管理 source 选择。加第三个数据源（如 `DBSource`）只需：建新 struct conform 协议 → 加一个 `if let` 分支
4. **JSONPathParser 可单测**：纯函数 `parse(String, [Field]) -> ParseResult`，不依赖任何外部状态
5. **JSON 路径只支持字典嵌套**：不支持数组索引（如 `items[0].value`），后续可按需扩展
6. **不与现有 Task 系统耦合**：Infotainer 是独立的数据聚合服务——Task 系统执行外部脚本产生副作用，Infotainer 只读数据
7. **Config 变更后重调度**：`configDidLoad` 会触发 `reschedule()` 重建所有定时器 + 清空缓存 + 重新拉取

---

## 后续扩展（不在本次范围）

- 数组索引 JSON 路径：`items[0].balance`
- 菜单项点击触发手动刷新
- command 超时控制（Process 原生超时或 dispatch 超时）
- 数据变动通知（如余额低于阈值）
- 非 JSON 输出解析（正则/行匹配）
