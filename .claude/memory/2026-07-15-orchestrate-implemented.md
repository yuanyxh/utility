---
date: 2026-07-15
tags: [utility, orchestrate, implementation, milestone]
---

## Orchestrate 多 Agent 编排已实现

### 已交付
- `Sources/CLI/PlanManager.swift` — Plan 解析/序列化、状态机、session-id 管理、artifact 路径、active symlink
- `Sources/CLI/OrchestrateCommand.swift` — `utility orchestrate -d <project> --plan <name> [--dry-run] [--list]`
- `Sources/CLI/UtilityCLI.swift` — 注册 OrchestrateCommand 为子命令

### CLI 标志确认（Claude Code v2.1.193）
- `-p` 从 stdin 读 prompt；`--session-id` / `--resume` 管理会话
- `--add-dir` 授目录权限；`--no-session-persistence` 一次性 agent
- `--non-interactive` 不存在（旧设计文档错误）

### 真实测试（2026-07-15）
- wms-front 项目 6 task 编排运行完成
- 19 artifacts 产出 ~584KB，全部 verdict: accepted
- 零源代码变更（旧 prompt 只让写报告）
- 新 prompt 已编译（行动导向），待下次验证

### 关键教训
- Prompt 必须行动导向（"改代码"非"写报告"），否则编排沦为分析工具
- Reviewer 审查的是产物文件而非源文件 diff → 需在 prompt 中明确要求读改动文件
- Session ID 不能从 -p 模式 stdout 提取 → 改由调度循环生成 UUID 传入 --session-id
