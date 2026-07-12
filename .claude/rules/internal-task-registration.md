---
description: TaskScheduler 内部任务注册约定 — 添加内置定时任务时使用
globs: ["Sources/**/*.swift"]
triggers: ["registerInternalTask", "internal-task", "内置任务", "mcp-summary"]
---

## TaskScheduler 内部任务

- 内置任务通过 `TaskScheduler.shared.registerInternalTask(_:)` 注册
- 与用户配置任务分离，不受 config.tasks 影响
- 对 config 重载幂等：先 `unregisterInternalTask(named:)` 再注册
- 所有环境变量通过内联 cmd 字符串传入，不使用 buildEnv()

示例模式（AppDelegate.swift）：
```swift
TaskScheduler.shared.unregisterInternalTask(named: "mcp-summary")

guard let mcp = ConfigManager.shared.config.mcp /* ... */ else { return }

let cmd = [
  "KEY=\(value)",
  "python3", scriptPath,
].joined(separator: " ")

let task = TaskConfig(name: "mcp-summary", trigger: trigger, exec: .sh(cmd), ...)
TaskScheduler.shared.registerInternalTask(task)
```
