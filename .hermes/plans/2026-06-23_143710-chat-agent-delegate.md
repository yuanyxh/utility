# Chat 面板 Agent 委托 Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Chat 面板支持 `@agentname` 前缀语法，将 prompt 委托给外部 CLI agent（Hermes/Claude Code/Codex/OpenCode），复用其 tools/skills/mcp/记忆。默认无前缀走现有 AIChatService，向后兼容。

**Architecture:**

```
ChatPanelController
  → triggerChat()
    → 检测 @agentname 前缀
      ├── 无前缀 → AIChatService.chat()         → OpenAI API (现有，不动)
      └── 有前缀 → AgentExecutor.run()          → Process 子进程 → stdout
                  └── TaskExecutor.execute(.sh())  (复用已有)
```

- **`AgentConfig`** — YAML 配置：`@name` → CLI 模板 `{prompt}` 占位符
- **`AgentExecutor`** — 纯逻辑层：取 config → 拼命令 → `TaskExecutor.execute()` → 返回 stdout
- **`ChatPanelController`** — 输入解析 `@name` 前缀，路由到不同后端

---

## 配置 Schema

```yaml
agents:
  hermes:
    command: hermes chat -q "{prompt}"
  claude:
    command: claude -p "{prompt}" --max-turns 5
  codex:
    command: codex exec "{prompt}"
  opencode:
    command: opencode run "{prompt}"
```

- **`{prompt}`** 占位符，运行时替换为用户输入（去除 `@name ` 前缀后）
- 命令行自带的引号由模板管理（`"{prompt}"` 处理空格）
- 未配置 command 的 agent 回退到 AIChatService

---

## 详细任务

### Task 1: AgentConfig 类型 + AppConfig 集成

**Objective:** 定义 `AgentConfig` struct，接入 `AppConfig`

**Files:**
- Modify: `Sources/Core/ConfigTypes.swift`

**Step 1: 在 ConfigTypes.swift 末尾添加**

```swift
// MARK: - Agent

public struct AgentConfig: Codable {
    var name: String
    var command: String   // CLI 模板，{prompt} 占位

    public init(name: String, command: String) {
        self.name = name; self.command = command
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
    }
}
```

**Step 2: AppConfig 添加 agents 属性**

```swift
var agents: [AgentConfig] = []
```

```swift
agents = (try? c.decode([AgentConfig].self, forKey: .agents)) ?? []
```

**Verification:**
- `swift build` 通过

---

### Task 2: AgentExecutor — 命令执行 + stdout 捕获

**Objective:** 纯逻辑层，取 agent name + prompt → 查 config → 拼命令 → `TaskExecutor.execute(.sh(cmd))` → 返回输出

**Files:**
- Create: `Sources/Chat/AgentExecutor.swift`

```swift
import Foundation

/// Agent 委托执行器：CLI 子进程，复用 TaskExecutor
enum AgentExecutor {
    struct Result {
        let output: String
        let error: String?
    }

    /// 执行 agent 命令，返回 stdout
    /// - Parameters:
    ///   - agentName: "@hermes" 中的 hermes
    ///   - prompt: 去掉 @name 前缀后的用户输入
    ///   - config: AppConfig（惰性读取，不持有引用）
    static func run(agentName: String, prompt: String, agents: [AgentConfig]) -> Result {
        guard let cfg = agents.first(where: { $0.name == agentName }),
              !cfg.command.isEmpty
        else {
            return Result(output: "", error: "Agent '@\(agentName)' not configured")
        }

        // ShellQuote：防止 prompt 中的引号/特殊字符破坏命令
        let escaped = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = cfg.command.replacingOccurrences(of: "{prompt}", with: "\"\(escaped)\"")

        let execResult = TaskExecutor.execute(.sh(cmd))
        if execResult.success {
            let trimmed = execResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return Result(output: "", error: "Empty response from @\(agentName)")
            }
            return Result(output: trimmed, error: nil)
        } else {
            let msg = execResult.error.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = msg.isEmpty ? "exit code != 0" : String(msg.prefix(300))
            return Result(output: "", error: "@\(agentName): \(err)")
        }
    }
}
```

**Verification:**
- `swift build` 通过
- `AgentExecutor` 引用 `TaskExecutor.execute(.sh(...))` — 确认零 Process 重复代码

---

### Task 3: ChatPanelController 路由 — 检测 @agentname 前缀

**Objective:** `triggerChat()` 中检测输入是否以 `@name` 开头。是 → 异步调 `AgentExecutor`，否 → 走现有 `AIChatService`

**Files:**
- Modify: `Sources/Chat/ChatPanelController.swift`

**Step 1: 修改 triggerChat()**

替换现有 `triggerChat()` 方法：

```swift
fileprivate func triggerChat() {
    if isStreaming {
        AIChatService.shared.cancel()
    }
    outputTextView.string = ""
    accumulatedOutput = ""
    hideOutput()

    let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // 检测 @agentname 前缀
    if let agentName = parseAgentPrefix(text) {
        delegateToAgent(name: agentName, text: text)
    } else {
        startChat()
    }
}

/// 解析 @name 前缀，返回 agent 名；无匹配返回 nil
private func parseAgentPrefix(_ text: String) -> String? {
    guard text.hasPrefix("@") else { return nil }
    let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard let namePart = parts.first else { return nil }
    let name = String(namePart.dropFirst())  // 移除 @
    guard !name.isEmpty else { return nil }
    // 查找是否在 agents 配置中
    let agents = ConfigManager.shared.config.agents
    guard agents.contains(where: { $0.name == name }) else { return nil }
    return name
}

/// 提取 @name 之后的 prompt 文本
private func extractPrompt(_ text: String) -> String {
    let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    if parts.count > 1 {
        return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
}

/// 委托给外部 agent
private func delegateToAgent(name: String, text: String) {
    let prompt = extractPrompt(text)
    let agents = ConfigManager.shared.config.agents

    isStreaming = true
    loadingIndicator.startAnimation(nil)

    DispatchQueue.global(qos: .utility).async { [weak self] in
        let result = AgentExecutor.run(agentName: name, prompt: prompt, agents: agents)
        DispatchQueue.main.async {
            guard let self else { return }
            self.isStreaming = false
            self.loadingIndicator.stopAnimation(nil)

            if let err = result.error, result.output.isEmpty {
                self.outputTextView.string = err
            } else {
                self.outputTextView.string = result.output
            }
            if !self.outputTextView.string.isEmpty {
                self.showOutput()
                self.accumulatedOutput = self.outputTextView.string
            }
        }
    }
}
```

**Step 2: 添加 AgentExecutor 的头信息显示（可选增强）**

在 `delegateToAgent` 的 output 前加来源标记：

```swift
let header = "[@\(name)]\n"
self.outputTextView.string = header + result.output
```

**Verification:**
- `swift build` 通过
- `@hermes 你好` 不匹配未配置的 agent → 走 AIChatService
- `@hermes 你好` 匹配已配置的 agent → 走 AgentExecutor

---

### Task 4: 更新 default-config.yaml 示例

**Files:**
- Modify: `Sources/Resources/default-config.yaml`

在文件末尾添加：

```yaml
# ------------------------------------------------------------------
# Chat 面板 Agent 委托：@agentname 前缀触发外部 CLI agent
agents: []
  # - name: hermes
  #   command: hermes chat -q "{prompt}"
  # - name: claude
  #   command: claude -p "{prompt}" --max-turns 5
  # - name: codex
  #   command: codex exec "{prompt}"
  # - name: opencode
  #   command: opencode run "{prompt}"
```

**Verification:**
- `python3 -c "import yaml; yaml.safe_load(open('Sources/Resources/default-config.yaml'))"` 语法合法

---

### Task 5: Build + 验证

**Step 1: Clean build**

```bash
cd /Users/yuanyxh/Documents/it/project/utility
rm -rf .build && swift build
```

**Step 2: 验证符号**

```bash
strings .build/debug/utility | grep -i "agent"
```

Expected: `AgentExecutor`、`AgentConfig`、`parseAgentPrefix` 等字符串。

**Step 3: 功能测试**

1. 启动 utility，打开 Chat 面板
2. 输入 `hello` → Enter → 走 AIChatService（现有行为不变）
3. 在配置中启用 hermes agent → 输入 `@hermes 今天几号` → AgentExecutor 调 hermes CLI → 显示 stdout
4. 输入 `@unknown 测试` → 无配置 → 走 AIChatService

---

## 文件变更汇总

| 文件 | 操作 |
|------|------|
| `Sources/Core/ConfigTypes.swift` | 添加 `AgentConfig` + `AppConfig.agents` |
| `Sources/Chat/AgentExecutor.swift` | **新建** — `TaskExecutor.execute(.sh(...))` 封装 |
| `Sources/Chat/ChatPanelController.swift` | 修改 `triggerChat()` + 添加前缀检测/路由方法 |
| `Sources/Resources/default-config.yaml` | 添加 `agents: []` 示例注释 |

**不动的文件：**
- `AIChatService.swift` — Agent 委托是完全独立的链路
- `OpenAIClient.swift` — 同上
- `TaskExecutor.swift` — API 已经满足需求
- `MenuBarManager.swift` — 不涉及菜单
- `AppDelegate.swift` — 不需要额外初始化（惰性读取 config）

---

## 设计约束

1. **TaskExecutor 同步阻塞**：`AgentExecutor.run()` 跑在 `DispatchQueue.global(.utility)`，ChatPanelController 的 `delegateToAgent()` 负责异步调度
2. **向后兼容**：`@unknown` 或无前缀全部走 AIChatService
3. **惰性读取 config**：不做 EventBus 订阅，每次触发时读 `ConfigManager.shared.config.agents`
4. **无缓存**：每次触发独立调用 CLI 子进程，不缓存历史输出
5. **Shell 注入防护**：prompt 中的引号 escape 为 `\"`，命令模板用 `"{prompt}"` 双引号包裹

---

## 后续扩展（不在本次范围）

- stdout 流式输出（`--output-format stream-json`，边跑边显示）
- 多轮对话（连续 `@hermes` 保持 session）
- 常用 agent 记忆（最近使用的 agent 预设）
- `@agent:file` 语法附加上下文文件
