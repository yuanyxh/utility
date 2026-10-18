# 设计沉淀（Orchestrate / Claude Code CLI 标志）

> 从 `.claude/CLAUDE.md` 分层迁出（2026-10-18），内容逐字保留。
> 修改对应模块前先读本文件；CLAUDE.md 只保留必须遵守的不变量。

### Orchestrate 多 Agent 编排（设计沉淀，代码已移除）
> ⚠️ 现状（2026-08-03 确认）：`PlanManager.swift` + `OrchestrateCommand.swift` 从未被 git 跟踪，工作区开发验证后删除；`utility orchestrate` 子命令已不存在。以下为设计思路沉淀，核心已被 devflow 研发编排沿袭。
- 设计理念：loop 循环编排器——输入计划，启动多个子 Agent 进程（Coding Agent 持久化上下文 + Reviewer 干净上下文），循环直至计划完成
- 状态机：pending→oa_task→review→oa_response→done/blocked；OA（Orchestrator Agent）是最终决策者
- OA 通过 `--session-id <uuid>` 创建 + `--resume <uuid>` 恢复，跨 task 保持上下文
- Reviewer 用 `-p --no-session-persistence` 做干净一次性审查
- **Prompt 必须行动导向**（"直接修改源代码"），不是报告导向（"写入分析到文件"）——第二次测试 4 task 全部实际落码验证（2 新建 + 10 修改文件）
- 数据路径（设计）：`<项目>/.utility/plans/<name>.md`（plan）+ `<项目>/.utility/artifacts/<plan>/`（运行时产物）

### Claude Code CLI 关键标志（v2.1.193）
- `-p` 从 stdin 读 prompt（非位置参数），输出到 stdout
- `--session-id <uuid>` 创建命名会话；`--resume <uuid>` 恢复
- `--add-dir <dir>` 授予工具访问权限（无 `--dir`）
- `--no-session-persistence` 一次性用完不保存 session
- 原设计中 `--non-interactive` 不存在
