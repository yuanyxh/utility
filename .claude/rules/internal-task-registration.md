---
description: TaskScheduler 内部任务注册约定 — 添加内置定时任务时使用
globs: ["Sources/**/*.swift"]
triggers: ["registerInternalTask", "internal-task", "内置任务", "mcp-summary"]
---

## TaskScheduler 内部任务

- 内置任务通过 `TaskScheduler.shared.registerInternalTask(_:)` 注册
- 与用户配置任务分离，不受 config.tasks 影响
- **对 config 重载幂等：enabled 时直接 register（内部同名替换），不要先 unregister**
  - ⚠️ 坑：先 `unregisterInternalTask(named:)` 会触发 `cleanupStaleTaskStates()` 删掉该任务的
    `last_fire`；再 register 后 `handleMissed()` 以「今天 00:00」为基准补触发——每天 cron 时刻
    之后每次重启 / reload 配置都会重复触发一次（mcp-summary 曾因此每天跑多次）
  - disabled / 条件不满足时才 unregister
- 所有环境变量通过内联 cmd 字符串传入，不使用 buildEnv()
- **任务子进程环境坑**：`TaskExecConfig.toProcess()` 不设置环境变量，子进程完整继承 Utility.app（launchd 启动的 GUI 进程）的受限 PATH——**缺 homebrew 路径**。凡命令依赖 PATH 找可执行文件（如 claude）的任务，`agentCli`/cmd 必须写**全路径**（如 `/opt/homebrew/bin/claude`），否则运行时 `FileNotFoundError` 秒退（2026-08-19 实测崩溃，该任务后因管线整体移除已不存在，但坑本身与任务无关）

示例模式（AppDelegate.swift，mcp-summary）：
```swift
guard let mcp = ConfigManager.shared.config.mcp /* ... */ else {
    TaskScheduler.shared.unregisterInternalTask(named: "mcp-summary")
    return
}

let cmd = [
  "KEY=\(value)",
  "python3", scriptPath,
].joined(separator: " ")

let task = TaskConfig(name: "mcp-summary", trigger: trigger, exec: .sh(cmd), ...)
TaskScheduler.shared.registerInternalTask(task)
```
