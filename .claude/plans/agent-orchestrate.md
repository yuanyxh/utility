```sh
claude --resume 9c406789-63e6-41c0-90ab-efb14eccf54a
```

# Agent 编排模式（orchestrate）

目标：实现多 Agent 协作编排能力，解决单 Agent 会话上下文膨胀导致的能力下降问题。

核心思想：**把文件系统当上下文用，而不是把上下文当文件系统用。**

---

## 问题背景

使用 Claude Code 等 Agent 时，随着会话持续：

- 上下文从 30k → 80k → 100k+ token
- 理解需求能力下降
- 编码质量退化
- 决策一致性变差

根本原因：**所有任务堆在同一上下文**。新开一个干净 Agent 进程就会好很多。orchestrate 就是让干净的一次性子 Agent（写代码）和干净的 Reviewer（审代码）帮忙分担，而**最终决策者是拥有完整上下文的 Orchestrator Agent（通过 --resume 持续恢复会话）**。

---

## 核心设计：四角色模型

```
                          ┌──────────────────────────────────────────────┐
                          │          Orchestrator (Swift 调度)            │
                          │  读 plan → 派 sub-agent → 派 reviewer        │
                          │  → 读 response → 更新 plan                    │
                          │  纯调度逻辑，无 LLM 上下文                     │
                          └──────┬─────────────┬────────────────────────┘
                                 │① spawn        │② spawn
                            ┌────▼────┐    ┌───▼──────────┐
                            │Sub-agent│    │  Reviewer     │
                            │(干净)   │    │  (干净)        │
                            │写代码   │    │  读产出        │
                            │一次性   │    │  提意见        │
                            └────────┘    └───┬──────────┘
                                              │
                 ┌────────────────────────────┘
                 │③ --resume <session-id> -p '有评审意见'
                 ▼
     ┌───────────────────────────────────────────────┐
     │       Orchestrator Agent (claude code)         │
     │  ═══ 真正干活的 ═══                             │
     │                                                │
     │  - 每次用 --resume <session-id> 恢复            │
     │  - session-id 存在 plan 文件中                   │
     │  - 第一次启动时无 session，完成后获取并写入 plan   │
     │  - Claude 自动压缩上下文，不怕膨胀                │
     │                                                │
     │  职责:                                          │
     │   ├── 写代码 / 重构                              │
     │   ├── 读 review → 决策接受/拒绝/部分采纳          │
     │   ├── 写 response                               │
     │   └── 将合意代码整合进项目                        │
     └────────────────────────────────────────────────┘

     ┌───────────────────────────────────────────────┐
     │       User TUI (claude code 单独终端)          │
     │  - 纯对话，不参与编排                           │
     │  - 可 monitor 进度                             │
     │  - 可查阅 plan / artifacts                     │
     └───────────────────────────────────────────────┘

                    ┌───────────────────────────────────────────┐
                    │              文件系统                       │
                    │                                           │
                    │  <目标项目>/.utility/plans/<name>.md        │
                    │    ├── session_id: orch-<plan>-<hash>      │
                    │    ├── tasks: [...]                        │
                    │                                           │
                    │  <目标项目>/.utility/artifacts/<plan>/      │
                    │    ├── <plan>.t1.0.output.md  ← sub-agent  │
                    │    ├── <plan>.t1.1.review.md  ← reviewer   │
                    │    └── <plan>.t1.2.response.md ← OA 回应   │
                    └───────────────────────────────────────────┘
```

### Orchestrate 与 -a 的关系

```
utility -a claude code                  仅启动 Agent TUI 会话（已有）

utility orchestrate --plan add-auth     Swift 调度 + 编排
                                         ├── 不启动 TUI，不阻塞终端
                                         └── Swift 前台串行调度
```

### 角色定义

| 角色 | 实现 | 上下文 | 启动方式 | 职责 | 决策权 |
|------|------|--------|---------|------|--------|
| **Orchestrator** | Swift (`utility orchestrate`) | 无 LLM 上下文 | 常驻进程 | 读 plan → 派 sub-agent → 派 reviewer → 读 response → 更新 plan | 仅调度 |
| **Orchestrator Agent (OA)** | `claude code` | **session 持久，自动压缩** | `--resume <session-id>` 恢复 | 写代码 + 读 review 做决策 + 整合代码 | **最终决策者** |
| **Sub-agent** | `claude code --non-interactive` | 干净，单次 task | Swift spawn，用完退出 | 读 task + 规范 → 产出代码/方案 | 参考输出 |
| **Reviewer** | `claude code --non-interactive` | 干净，单次审查 | Swift spawn，用完退出 | 读 sub-agent 产出 → 指出问题 | 仅提意见 |
| **User TUI** | `claude code` 单独终端 | 对话上下文 | 用户手动启动 | 纯聊天，monitor 进度 | 随时介入 |

### 通信流程

不依赖 signal 文件通知。Swift 直接通过 `--resume <session-id>` 启动/恢复 OA：

```
Step  Swift orchestrator       claude code 命令                     OA 上下文
───   ─────────────────        ──────────────────                   ──────────
 0    读 plan，找 task 1

 1    claude code -p 'task1 描述...' --resume <sid>
      ───── 启动 OA ──────────────────────────────────────────→    项目结构 + 需求

                                                         ← 退出   输出代码 + 写 output.md
      捕获 stdout，写 performance 记录

 2    claude code -p '审查产出...' --non-interactive
      → Reviewer 写 review.md → 退出

 3    claude code -p '有评审意见(附review摘要)...' --resume <sid>
      ───── 恢复 OA ──────────────────────────────────────────→    之前代码 + 之前决策
                                                                    + review 意见

                                                         ← 退出   写 response.md
      读 response，更新 plan

 4    循环：task 2 ...
```

### 协商收敛机制

1. Sub-agent（干净）按 task 描述产出代码 → `t<N>.0.output.md`
2. Reviewer（干净）审查产出 → `t<N>.1.review.md`
3. **Swift 恢复 OA（`--resume <session-id>`，带着 review 摘要）**
4. OA 拥有完整上下文（为什么这么写、项目结构、过往决策），读 review 后 **决定接受/拒绝/部分采纳** → `t<N>.2.response.md`
5. Swift 读 response → 更新 plan

第一次启动时无 session-id，直接 `claude code -p '...'`，OA 退出后 Swift 从 stdout 捕获 session-id 写入 plan：

```
plan.md 中记录:
  session_id: orch-add-auth-a1b2c3

后续:
  claude code -p 'task2 描述...' --resume orch-add-auth-a1b2c3
  OA 恢复后记得 task1 的一切
```

---

## 会话生命周期管理

### Session ID 的产生与存储

```
第一次编排（无 session-id）:
  claude code -p 'task1: ...' --non-interactive     ← 不传 --resume
  → Claude Code 自动创建新 session
  → stdout 中出现 session id（如 "Session: orch-xxx"）
  → Swift 从 stdout 正则提取 session-id
  → 写入 plan.md

后续编排:
  claude code -p 'taskN: ...' --resume orch-xxx     ← 传 --resume
  → OA 恢复之前的上下文继续工作

中断后恢复:
  utility orchestrate --dir /project --plan add-auth --resume
  → Swift 读 plan.md 拿到 session_id
  → 继续调度下一个 pending task
```

### 上下文管理

使用 Claude Code 内置的自动压缩机制，不手动干预。OA 在足够多的轮次后会自然压缩，Swift 不需要感知。

如果 OA 累计了极端多的上下文导致响应变慢（理论上 Claude 会自动处理），可以加一个兜底：

```swift
// 可选：每 N 个 task 判断是否需要轮换 session
if taskCount % 10 == 0 {
    let summary = readPlanSummary(planName)
    closeSession(oldSessionId)
    let newSessionId = createSessionId(planName)
    // 用摘要初始化新 session
    claude code -p '前情提要: \(summary)' --resume newSessionId
    // 更新 plan 中的 session_id
}
```

这作为优化选项先记录，按需实现。

---

## 启动命令设计

```bash
# 启动编排（仅调度，不启动 TUI）
utility orchestrate --dir /path/to/project --plan add-auth

# 恢复中断的编排
utility orchestrate --dir /path/to/project --plan add-auth

# 列出项目的计划
utility orchestrate --dir /path/to/project --list

# 不指定 --dir 则取 CWD（与 -a 一致）
```

### 命令解析逻辑

```
utility orchestrate --dir /project --plan add-auth
  │
  ├─ 1. 确定项目路径（--dir / CWD，与 -a 一致）
  │
  ├─ 2. 解析 plan
  │     ├── --plan add-auth
  │     │     └── 读 /project/.utility/plans/add-auth.md
  │     │
  │     ├── --plan 指向一个 plan.md 文件
  │     │     └── 复制到 /project/.utility/plans/
  │     │
  │     └── 未传 --plan
  │           ├── 读 /project/.utility/plans/active 指向的 plan
  │           └── 或报错
  │
  ├─ 3. 重写适配 plan（如果是自由格式）
  │
  ├─ 4. 扫描/文件侦听（-a 逻辑）
  │
  ├─ 5. 执行编排循环
  │     while let task = plan.nextPending() {
  │       // task: pending → running
  │       // 1. 启动 OA：claude code -p 'task描述' --resume <sid>
  │       //    无 sid 则首次不传，退出后从 stdout 提取
  │       // 2. 启动 reviewer：claude code --non-interactive
  │       // 3. 启动 OA：claude code --resume <sid> -p '评审意见...'
  │       // 4. 读 response 更新 plan
  │     }
  │
  └─ 6. 打印摘要，退出
```

---

## Plan 重写适配

Plan 可能来自 Agent 输出（自由格式），不满足 orchestrate 的 task 结构要求。需要重写适配：

```
原始 plan（Agent 输出）：
  ┌──────────────────────────────┐
  │ 我的计划是：                    │
  │ 1. 先创建 User 实体            │
  │ 2. 然后实现 Repository          │
  │ 3. 最后写 Controller            │
  └──────────────────────────────┘

        │
        ▼ 重写适配

结构化 plan（orchestrate 可读）：
  ┌──────────────────────────────┐
  │ # Plan: add-auth              │
  │                               │
  │ ## Task: create-user-entity   │
  │ 描述: 创建 User 实体           │
  │ 状态: pending                  │
  │                               │
  │ ## Task: implement-repo       │
  │ 描述: 实现 UserRepository      │
  │ 状态: pending                  │
  │                               │
  │ ## Task: write-controller     │
  │ 描述: 编写 Controller          │
  │ 状态: pending                  │
  └──────────────────────────────┘
```

重写方式：调一次 `claude code --non-interactive` 做 plan 翻译，输出结构化 plan.md：

```swift
let rewritePrompt = """
将以下 plan 重写为结构化格式，每个 task 包含：task id、描述、状态 pending。
输出到 \(planPath)
---
\(rawPlanContent)
"""

runAgent(prompt: rewritePrompt, dir: projectDir, outputFile: planPath)
```

---

## 文件命名规则

```
<目标项目>/.utility/
├── plans/                  ← 所有编排计划
│   ├── add-auth.md
│   ├── refactor-wms.md
│   └── active → add-auth.md  ← symlink 当前活动计划
│
└── artifacts/              ← 运行时产物
    └── <plan-name>/
        ├── <plan>.t1.0.output.md     ← sub-agent 产出
        ├── <plan>.t1.1.review.md     ← reviewer 评论
        ├── <plan>.t1.2.response.md   ← **OA** 的回应（决策）
        ├── <plan>.t2.0.output.md
        ├── <plan>.t2.1.review.md
        └── ...
```

命名规则解析：

```
<plan>.t<N>.<step>.<type>.md
  │       │       │       └── 角色/内容类型: output / review / response / ask / answer
  │       │       └────────── 步骤序号: 0 起, 每步递增
  │       └────────────────── task 序号: t1 / t2 / t3 ...
  └────────────────────────── plan 名称
```

---

## Plan 文件 Schema

```markdown
# Plan: add-auth

## Task: create-user-entity
### 描述
创建 User 实体，包含 id/name/email/password_hash 字段

### 状态: pending | oa_task | review | oa_response | done | blocked

### 结果
- verdict: accepted | rejected | partial
- note: reviewer 建议加 created_at，已采纳
```

### 状态机

```
pending → oa_task → review → oa_response → done
                                       → blocked
```

- `pending`: 等待执行
- `oa_task`: Orchestrator Agent 正在执行 task（--resume）
- `review`: reviewer 正在审查
- `oa_response`: OA 恢复处理 review
- `done`: OA 已裁决，进入下一 task
- `blocked`: 出错或需人工介入

---

## Swift 调度循环

```swift
// Sources/CLI/OrchestrateCommand.swift

struct OrchestrateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchestrate",
        abstract: "多 Agent 编排模式（-a 的超集）"
    )

    @Option(name: .shortAndLong,
            help: "项目目录路径（默认：当前目录）")
    var dir: String?

    @Option(name: .long, help: "计划名称或路径")
    var plan: String?

    @Flag(name: .long, help: "恢复指定计划")
    var resume: Bool = false

    @Flag(name: .long, help: "列出项目的所有计划")
    var list: Bool = false

    func run() throws {
        let projectDir = dir.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.currentDirectoryPath

        if list { try listPlans(in: projectDir); return }

        // Plan 解析与重写
        let planner = try PlanManager.setup(
            projectDir: projectDir, planName: plan, resume: resume
        )
        if planner.needsRewrite { try planner.rewritePlan() }

        // 执行 -a 的基础逻辑（扫描/侦听）
        try AgentRunner.prepareDatabase(projectPath: projectDir)
        let _ = try ProjectScanner.shared.scan(projectPath: projectDir)
        let watcher = FileWatcher(projectPath: projectDir)
        watcher.start()
        defer { watcher.stop() }

        // 编排循环（前台，串行）
        orchestrateLoop(planner: planner)
        planner.printSummary()
    }

    private func orchestrateLoop(planner: PlanManager) {
        while let task = planner.nextPending() {
            task.status = .oa_task; try? planner.save()

            // 1️⃣ 启动 Orchestrator Agent 做 task
            //    首次无 session-id → 不传 --resume
            //    后续 → --resume <session-id>
            let outputFile = artifactPath(plan: planner.planName,
                                          task: task.id, step: 0, type: "output")
            let agentArgs = buildAgentArgs(
                prompt: buildTaskPrompt(task),
                session: planner.sessionId  // nil on first run
            )

            let agentOut = runCLI(args: agentArgs, dir: planner.projectDir)

            // 首次：从 stdout 提取 session-id
            if planner.sessionId == nil,
               let sid = extractSessionId(from: agentOut) {
                planner.sessionId = sid
                try? planner.save()
            }

            // 2️⃣ 启动 Reviewer（干净，一次性）
            task.status = .review; try? planner.save()
            let reviewFile = artifactPath(plan: planner.planName,
                                          task: task.id, step: 1, type: "review")
            try? spawnCleanAgent(
                prompt: buildReviewPrompt(task: task, outputFile: outputFile),
                dir: planner.projectDir,
                outputFile: reviewFile
            )

            // 3️⃣ 恢复 Orchestrator Agent 处理 review
            //    使用同一个 session-id，OA 记得之前写的代码和上下文
            let responseFile = artifactPath(plan: planner.planName,
                                            task: task.id, step: 2, type: "response")
            let reviewSummary = readReviewSummary(reviewFile)
            try? spawnResumedAgent(
                prompt: "有评审意见：\(reviewSummary)\n阅读后决定接受/拒绝，写 response 到 \(responseFile)",
                session: planner.sessionId!,
                dir: planner.projectDir,
                outputFile: responseFile
            )

            // 4️⃣ 读 verdict，更新 plan
            let verdict = (try? parseVerdict(from: responseFile)) ?? "unknown"
            task.resolve(verdict); try? planner.save()
        }
        print("✅ 编排完成")
    }
}
```

### 子 Agent 启动函数

```swift
/// 启动 Orchestrator Agent（使用 --resume 恢复上下文）
/// OA 的 stdout/stderr 由调用方 runCLI() 捕获，用于提取 session-id
func buildAgentArgs(prompt: String, session: String?) -> [String] {
    var args = ["claude", "code", "-p", prompt, "--dir", projectDir]
    if let sid = session {
        args.append(contentsOf: ["--resume", sid])
    }
    return args
}

/// 启动非交互的干净 agent（sub-agent 或 reviewer）
func spawnCleanAgent(prompt: String, dir: String, outputFile: String) throws -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["claude", "code", "-p", prompt,
                       "--non-interactive", "--dir", dir]
    proc.currentDirectoryURL = URL(fileURLWithPath: dir)

    let outURL = URL(fileURLWithPath: outputFile)
    let outHandle = try FileHandle(forWritingTo: outURL)
    proc.standardOutput = outHandle
    proc.standardError = outHandle
    var env = ProcessInfo.processInfo.environment
    env["UTILITY_PROJECT_DIR"] = dir
    proc.environment = env

    try proc.run()
    proc.waitUntilExit()
    try outHandle.close()
    return proc.terminationStatus
}

/// 启动恢复会话的 Orchestrator Agent（带 --resume，有交互）
func runCLI(args: [String], dir: String) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = args
    proc.currentDirectoryURL = URL(fileURLWithPath: dir)

    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe

    try? proc.run()
    proc.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

/// 从 stdout 提取 session-id（claude code 输出格式）
func extractSessionId(from output: String) -> String? {
    // 匹配 "Session: orch-xxx" 或类似格式
    let pattern = /Session: (\S+)/
    return output.firstMatch(of: pattern).map { String($0.1) }
}
```

---

## 关键设计要点总结

| 特性 | 设计 |
|------|------|
| **orchestrate vs -a** | 超集：-a 基础逻辑（扫描/侦听）保留，编排循环额外叠加 |
| **不启动 TUI** | orchestrate 是纯后台调度，不 attach 终端 |
| **User TUI 单独** | 用户另开终端 `claude code --dir /project` 纯聊天，跟调度无关 |
| **决策者** | Orchestrator Agent（`--resume <session-id>` 恢复，长上下文） |
| **Orchestrator Agent 通信** | Swift 直接 `claude code -p '...' --resume <sid>` 启动/恢复 |
| **session-id 存储** | plan.md 中记录，首次从 stdout 提取，后续取用 |
| **Sub-agent** | 干净一次性，`--non-interactive`，产出参考代码 |
| **Reviewer** | 干净一次性，`--non-interactive`，产出审查意见 |
| **Plan 管理** | 目标项目 `.utility/plans/` |
| **Artifacts** | 目标项目 `.utility/artifacts/<plan>/`，命名 `<plan>.t<N>.<step>.<type>.md` |
| **Plan 来源** | 可来自 LLM 输出的自由格式，需重写适配 |
| **上下文管理** | Claude 自动压缩，不手工干预 |

---

## 讨论记录

### 2026-07-12 设计讨论

**问题提出**：单 Agent 会话上下文膨胀导致能力下降。

**核心论点**：
- Clean agent（sub-agent / reviewer）用于一次性任务：写代码、审代码
- **长上下文 agent（Orchestrator Agent）** 是真正干活的，做最终决策
- Swift orchestrator 后台循环调度

**设计演进**：

| 版本 | 决策者 | 长上下文 | 与 -a 关系 | 交互方式 |
|------|--------|---------|-----------|---------|
| v1 | LLM orchestrator | 无 | 独立 | signal 文件 |
| v2 | 类似 Workflow | 无 | 独立 | 文件 |
| v3 | Sub-agent（干净） | 无 | 替代 -a | 文件 |
| v4 | **主 Agent TUI** | TUI | -a 超集 | signal 文件 |
| **v5（最终）** | **Orchestrator Agent（--resume）** | **session 持久** | **基础叠加** | **直接 claude code 命令** |

**关键决策**：
1. `orchestrate` 保留 -a 基础逻辑（扫描/侦听），**不启动 TUI**
2. **User TUI 单独开终端**，跟编排无关，纯对话
3. **Orchestrator Agent 用 `--resume` 恢复**，session-id 存在 plan 中
4. 首次无 session-id，运行后从 stdout 提取；后续带 session-id 恢复上下文
5. Claude 自动压缩上下文，不需要手工干预
6. Sub-agent（干净）产出代码供参考，Reviewer（干净）审查提意见
7. OA 是最终决策者，恢复上下文后处理 review 并写 response

**关联资源**：
- `Sources/CLI/AgentRunner.swift` — -a 模式实现
- `Sources/CLI/UtilityCLI.swift` — CLI 入口
- `Sources/CLI/FileWatcher.swift` — 文件侦听

**待讨论**：
1. Sub-agent / reviewer / OA 的 timeout 机制
2. Plan 重写失败时的 fallback
3. OA 累计上下文过多时的自动轮换策略（暂不实现，Claude 自动压缩兜底）
