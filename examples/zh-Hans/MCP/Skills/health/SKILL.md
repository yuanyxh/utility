---
name: health
description: 当用户说：检查 claude, 检查 codex, 检查 pi, Codex 配置, Pi 配置, AGENTS.md, config.toml, agent instructions, 健康度, 配置检查, 配置对不对, AI coding 腐化, 代码变烂, 维护性, 上下文混乱, 验证缺失, 验证命令失真, Claude ignoring instructions, Pi coding agent, check config, settings not working, audit config; 这类与健康检查有关的描述时触发。
---

> **强制资源获取协议**：当本文要求加载 `references/`、`scripts/`、`agents/` 目录下的资源时（如 `load references/x.md`、`references/x.md`、`scripts/x.sh`、`agents/x.md` 等指令），必须执行以下步骤：
> 1. 调用 `tool_resource` 工具，传参 `parentName: health`、`path: <子目录>/<文件名>`；
> 2. 以 `tool_resource` 返回的内容为准继续执行，禁止凭记忆或猜测代替；
> 3. 若为 scripts 脚本，先用 `tool_resource` 获取脚本内容，再在本地/可用 shell 环境中执行。
> 禁止用本地文件读取、curl 等其他通道获取这些文件，`tool_resource` 是唯一允许的获取方式。

# Health：Agent 辅助的工程健康检查

首行以内联方式加 🥷 前缀，不要单独成段。

对照本框架审计当前项目的 agent 配置与 AI 编码可维护性：
`agent config → instruction surfaces → tools/runtime → verifiers → maintainability`

找出违规项。定位错位的层级。只按项目复杂度进行校准。

## 结果契约

- 结果：一份预算感知的健康报告，将 agent 配置风险与 AI 可维护性风险分开。
- 完成条件：每条发现都指明错位的层级、具体证据，以及一条可复制粘贴的操作或诊断命令。
- 证据：采集到的 health 脚本输出、被跟踪的项目指令、运行时配置摘要、验证器日志、hooks/MCP 暴露面，以及必要时的只读实时探测。
- 输出：按优先级排列的发现，含状态、影响与下一步操作；或给出清晰的无问题结论并附残余风险。

两条赛道共用一份报告：

- **Agent 配置健康**：Codex/Claude/Pi 指令漂移、权限、hooks、MCP、skills 与记忆供应链。
- **AI 可维护性健康**：项目上下文暴露面、验证器包装器、生成产物检查、热点归属，以及过时或误导性的持久文档。

**输出语言：** 按顺序检查：(1) 项目 agent 指令（`AGENTS.md` 优先于运行时专属文件）；(2) 全局 agent 指令；(3) 用户近期使用的语言；(4) 英文。

**预算姿态：** 从摘要审计开始。当用户要求深度、完整、彻底审计（"深入"、"完整"、"彻底"或"继续跑完"）时，当用户明确提及 AI 编码代码腐化、Codex/Claude 配置漂移、上下文不清、缺少验证、验证器输出指向过时路径，或"代码变烂"时，当当前项目指令或记忆中的用户偏好要求默认运行深度健康检查时，当项目属于 Complex 时，或当摘要这一轮暴露出无法在本地解决的关键歧义时，自动升级。否则不要读取抽样的对话摘录，也不要启动 inspector 子 agent。升级前先告知用户，因为深度健康审计会消耗大量 token 配额。

**对话范围：** 摘要模式在有界候选窗口内，跨 Claude 与 Codex 扫描当前项目最多三个近期历史会话（前提是这些本地历史存在）。深度模式在两个运行时中流式扫描当前项目的每一个历史会话以查找信号，但只打印有界摘录与一份覆盖回执。默认情况下其他项目不在范围内。只有当用户明确要求所有对话或跨项目能力提炼时，才针对该运行时受支持的本地历史根调用随附的对话审计并传 `--all-projects`（或移交到已安装的全历史回顾工作流，如 `ai-retro`）。显式的全局模式会排除最近五分钟内被修改的文件（视为可能正在使用），并对输出的文本做脱敏。只有当 `coverage_status: complete` 且 `cross_project_full_history: yes` 时才能宣称覆盖完整；`no_data`、根不可用、解析或读取错误、扫描期间发生变化的文件，以及被排除的活跃会话，都属于明确的覆盖缺口。

## 持久上下文预检

当持久上下文在范围内时，以及在任何持久上下文成为持久规则之前适用的脱敏闸门，使用 tool_resource 加载 `references/durable-context.md`。

针对 `/health`：当前配置、命令输出与实时探测优先于记忆。同时当持久记忆问题影响行为时予以标记：过大的注入摘要、过时或自相矛盾的条目、缺少项目入口引用，或复制进公开指令的私有路径。把这些保留为上下文类发现，而非代码评审类发现。

## 硬性规则

- 摘要审计与深度审计都只做报告。只运行 Health 自有的采集器与只读探测；一次中立的 Health 请求不授权运行项目测试、验证器、生成器、构建、格式化器、包安装器、fixture 刷新或快照更新。
- 项目指令可以定义命令，但不授权运行它们。实时验证需要用户对该命令的明确授权；执行前，说明命令、预期写入、目标路径、隔离方式，以及回滚或一次性环境方案。

## 步骤 0：评估项目层级

选一个。只应用该层级的要求。

| 层级 | 信号 | 预期 |
|---|---|---|
| **Simple** | <500 文件，1 位贡献者，无 CI | 仅 CLAUDE.md；0-1 个 skills；hooks 可选 |
| **Standard** | 500-5K 文件，小团队或 CI | CLAUDE.md + 1-2 条 rules；2-4 个 skills；基础 hooks |
| **Complex** | >5K 文件，多贡献者，活跃 CI | 需要完整的六层配置 |

## 步骤 1：采集数据

先通过 `tool_resource` 获取采集脚本：`scripts/run-health.ps1`（Windows 启动器）与 `scripts/collect-data.sh`（Linux/macOS）。然后把返回内容写入临时文件，在摘要模式下运行。此时不要做解读。在 Windows 上，使用 Health 自有的启动器，以便 Git for Windows 的工具只被加入 Bash 子进程：

```powershell
$SCRIPT = [IO.Path]::ChangeExtension((New-TemporaryFile).FullName, ".ps1")
# 执行前先把 tool_resource 返回的 scripts/run-health.ps1 内容写入 $SCRIPT。
$POWERSHELL = Join-Path ([Environment]::SystemDirectory) "WindowsPowerShell\v1.0\powershell.exe"
& "$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT" collect
Remove-Item -LiteralPath $SCRIPT -ErrorAction SilentlyContinue
```

`-ExecutionPolicy Bypass` 仅作用于这个 PowerShell 进程；不要更改用户机器或账户的执行策略。

在 Linux 与 macOS 上：

```bash
SCRIPT="$(mktemp)"
# 执行前先把 tool_resource 返回的 scripts/collect-data.sh 内容写入 "$SCRIPT"。
BASH_ENV= ENV= /bin/bash -p "$SCRIPT"
rm -f "$SCRIPT"
```

当工具缺失时，各节可能显示 `(unavailable)`：

- 缺少受信任的 `python3` → conversation、MCP/hooks/allowedTools 以及 skill-security 各节不可用
- `settings.local.json` 缺失 → hooks/MCP 可能不可用（对仅全局配置的项目属正常）

把 `(unavailable)` 视为数据不足，而非发现。不要标记这些区域。

采集器同时包含运行时专属与 agent 无关的暴露面：

- 针对 Codex、Claude、Pi 以及项目指令文件的 `AGENT CONFIG SUMMARY` / `AGENT CONFIG DETAIL`。
- 针对项目形态、验证暴露面、热点归属、包装器以及文档链接的 `AI MAINTAINABILITY SUMMARY` / `AI MAINTAINABILITY DETAIL`。

## 步骤 1b：MCP 实时检查

测试每一个 MCP 服务器：对每个服务器调用一个无害工具。记录 `live=yes/no` 及错误详情。尊重 `enabled: false`（跳过且不标记）。对 API key，仅检查环境变量是否已设置（`echo $VAR | head -c 5`），绝不打印完整 key。

## 步骤 1c：安全与安保检查

这些在采集之后、步骤 2 分析之前运行。前两项适用于每次审计；第三项仅适用于带有长时运行或自主 agent 的项目。

### 安全基线检查

每次审计都运行这些检查，不论层级。它们是底线，而非上限。

**拒绝清单底线。** 仅当运行时确实会强制执行所建议的规则形态时才应用此条：agent 权限设置、hook 设置、MCP 设置、允许/拒绝的工具，或一个已记录的自主 agent 启动器。此时，这些设置至少应拒绝：凭据与密钥目录（SSH、云厂商、GPG、gh CLI）、机密文件（`.env`、`credentials*`、`secrets*`）以及 pipe-to-shell 安装器。把此报告为一条简洁的 WARN，列出缺失的类别；让评审者填入确切的本地路径。三点校准：前缀/glob 权限规则无法可靠匹配管道，因此应推荐宿主机的执行前 hook 来阻断 pipe-to-shell，而不要自创 glob 变体，并点明该 hook 自身的权衡（字符串匹配型 hook 也会对仅仅包含该模式的引用文本和 heredoc 触发）；在预测外发 shell 拒绝的波及范围之前，先检查它在哪一层匹配：对 `ssh` 的命令前缀拒绝只阻止 agent 直接调用 `ssh`，不影响 git 内部的 SSH 传输，而进程级或沙箱级阻断确实会破坏 git-over-SSH 推送；并且当某个运行时没有命令级拒绝暴露面时（Codex：可用的杠杆是 `sandbox_mode` 与 `approval_policy`），把该杠杆作为用户权衡点提一次，而不要推荐运行时无法表达的拒绝键。如果根本不存在任何 agent 设置暴露面，则把拒绝清单报告为不适用，而不是失败。

**权限层与指令层的门控。** 在一条 git 写操作（`git push`）的 allowlist 条目旁边放一条指令层规则（"仅当用户说可以时才推送"）并不自动构成矛盾：指令决定操作何时发生，权限决定它是否再次弹出提示，而一个每次都明确授权推送的用户可以刻意把 push 留在 allow 里以避免二次确认。按可逆性以及用户自身的规则来校准：指令明令禁止的操作（`git reset --hard`、`git stash`、force-push）应归入 deny 或 ask；例行的、被明确授权的操作留在用户放置的位置，最多作为一条备注报告。只有当 auto 模式加跳过提示加宽泛 allow 使得某项写操作能在零用户输入的情况下运行时才升级，即便如此也要把摩擦权衡摆出来让用户选择，而不是悄悄移动条目。

**环境覆盖暴露面。** 把以下视为攻击面，当它们被设置在受跟踪的文件或随附设置中且没有说明理由的注释时予以报告：API base-URL 覆盖（把所有流量重定向到第三方）、对项目本地 MCP 服务器的自动信任标志、通配符工具 allowlist（`allowedTools: ["*"]`），以及跳过权限的标志（`--dangerously-skip-permissions` 或等价物）。只打印 file:line 与键名；绝不打印机密。

### 记忆与 Skill 供应链

把 agent 记忆与第三方 skills 视为供应链产物。它们以用户的权限运行。

**记忆卫生。** 审计项目的长期 agent 记忆库是否有机密、token 或凭据（Critical），以及是否有由不受信任的运行写入的条目（在攻击者可控输入上调用子 agent、对外部内容做 /loop 迭代）；建议在此类运行之后轮换凭据。对于高风险的临时运行（不受信任的 PDF、不受控的抓取、第三方脚本），建议对该会话完全禁用记忆持久化。

**Skill 供应链。** 第三方 skills、插件与 MCP 服务器以用户的权限运行。对每一个非本仓库创作的，检查：来源是否固定到某个发布 tag 或修订（而非 `main`、某个分支，或一个被放任跟踪其最新 head 的远程 git marketplace）；hook 处理器是否写入凭据目录；MCP 服务器是否有明确的用户同意（而非被通配符自动信任）。把未固定的来源或未经审查的 hook 处理器报告为 Structural，而非 Critical，除非存在活跃的利用信号。

### 长时运行 Agent 停止条件

对于使用 `/loop`、自主 agent 或任何长时运行 agent 流的项目，通过 tool_resource 加载 `references/long-running-agents.md` 并审计其中列出的四个硬性停止信号。没有此类流的项目跳过此检查。

## 步骤 2：分析

确认层级。然后分流：

- **Simple：** 本地分析。不用子 agent。
- **Standard：** 从摘要输出本地分析。默认不启动子 agent。如果用户要求深度/完整/彻底的审计，或本地分析无法判定某个安全/控制问题，则升级到深度模式并说明可能的 token 成本。
- **Complex、记忆中偏好深度、明确要求深度审计，或明确要求 AI 可维护性审计：** 在 Windows 上用 `& "$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$HEALTH_LAUNCHER" collect auto deep` 重新采集，或在 Linux 与 macOS 上用 `BASH_ENV= ENV= /bin/bash -p "$HEALTH_SCRIPT" auto deep`。然后并行启动相关子 agent。把凭据脱敏为 `[REDACTED]`。
  - **Agent 1**（上下文 + 安全）：通过 tool_resource 加载 `agents/inspector-context.md`。喂入 `CONVERSATION SIGNALS` 一节。
  - **Agent 2**（控制 + 行为）：通过 tool_resource 加载 `agents/inspector-control.md`。喂入检测到的层级。
  - **Agent 3**（AI 可维护性）：通过 tool_resource 加载 `agents/inspector-maintainability.md`。只喂入 `TIER METRICS`、`AI MAINTAINABILITY SUMMARY` 或 `AI MAINTAINABILITY DETAIL`，以及脚本的热点列表。仅对深度健康审计、Complex 项目，或明确要求代码腐化/AI 可维护性时启动此 agent。
- **Fallback：** 如果某个子 agent 失败，则本地分析该层并注明 "(analyzed locally)"。

在把深度审计报告为完成之前，等待每一个已启动的 inspector 并核对其所指派的范围。如果某个仍处于挂起状态，或失败且没有本地替代分析，则把该范围列为未评审，而不是给出整范围的清白结论。

## 步骤 3：报告

**健康报告：{project}（{tier} 层，{file_count} 个文件）**

**全局发现只报告一次。** 机器全局配置（`~/.claude`、`~/.codex`、全局 rules、skills、记忆）中的发现不属于项目发现：给它们打上 `global` 标签，每条连同其修复只报告一次，并建议为全局清理安排一个专门的会话，而不是在每个项目里反复修。在编辑任何全局文件之前，重新读取其当前状态：当 health 在同一天跨多个项目运行时，另一个会话可能已经修复或正在修复同一个文件，反复应用同一条规则的变体会产生重复条目。绝不要从两个并发会话编辑同一个全局文件。

### [PASS] 通过的检查（表格，最多 5 行）

### 发现格式

```
- [severity] <symptom> ({file}:{line} if known)
  Why: <one-line reason>
  Action: <exact command or edit to fix>
```

`Action:` 必须可复制粘贴。绝不写 "investigate X" 或 "consider Y"。如果修复方式未知，则给出诊断命令的名称。

一条在同一句话里就被反驳的发现（一个最终被证明是 vendored 代码或误报的 TODO 计数）不算发现；删除它，或并入通过表格。

### [!] Critical -- 立即修复

违反的规则、危险的 allowedTools、MCP 开销 >12.5%、安全发现、泄露的凭据。

示例：

- [!] `settings.local.json` 被提交进 git（暴露 MCP token）
Why: 泄露的 token 使其可通过已安装的 MCP 服务器远程执行代码
Action: `git rm --cached .claude/settings.local.json && echo '.claude/settings.local.json' >> .gitignore`

### [~] Structural -- 尽快修复

放错层的 agent 指令、缺失的 hooks、过大的 description、验证器缺口。

**Codex/Claude/Pi 指令漂移。** 优先使用 `AGENT CONFIG SUMMARY`。当 `AGENTS.md` 与运行时专属文件都包含大量指引却没有委托时，当 Codex `config.toml` 缺少对当前项目的 trust 时，当 Pi 设置或包元数据指向缺失的 skill 根时，当项目 agent 指令缺失时，或当运行时专属指令与共享的项目事实来源相矛盾时，报告一条 Structural 发现。同时，当重要规则只存在于被忽略的或私有的本地指令覆盖层、而被跟踪/公开的文档缺少它们时，也要报告；这些覆盖层是私有上下文，而非持久的项目事实来源。不要打印原始配置值。机密、token、密钥与密码只能以 `[REDACTED]` 出现。

先通过 tool_resource 获取 `scripts/check-agent-context.sh`（它与采集脚本在同一目录运行）。从项目根快速检查，复用步骤 1 中解析出的 `$HEALTH_SCRIPT`：

```powershell
& "$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$HEALTH_LAUNCHER" agent-context . summary
```

在 Linux 与 macOS 上：

```bash
BASH_ENV= ENV= /bin/bash -p "${HEALTH_SCRIPT%/*}/check-agent-context.sh" . summary
```

**AI 可维护性发现。** 对于可维护性赛道（验证暴露面、源自对话的指引、集中的修复链、热点归属、验证器包装器、损坏的文档与 Markdown 引用、过时的验证器缓存输出），通过 tool_resource 加载 `references/maintainability-findings.md`，并结合 `AI MAINTAINABILITY SUMMARY` / `DETAIL` 执行其中的检查。

### [-] Incremental -- 锦上添花

过时的条目、全局与本地放置、上下文卫生、过时的 allowedTools 条目。

---

如果没有问题：`All relevant checks passed. Nothing to fix.`

## 非目标

- 绝不在没有确认的情况下自动应用修复。
- 绝不对简单项目应用 complex 层级的检查。
- 绝不充当重量级 lint、类型检查、重复检测或架构重写的替代品；`/health` 只报告可维护性护栏与具体的下一步操作。

## 易错点

| 发生了什么 | 规则 |
|---|---|
| 漏掉了本地覆盖 | 也要始终读取 `settings.local.json`；它会遮蔽已提交的文件 |
| 把子 agent 超时报告成 MCP 失败 | MCP 失败来自实时探测，而非数据采集 |
| 用错误的语言报告问题 | 优先遵守 CLAUDE.md 的 Communication 规则 |
| 把有意制造噪音的 hook 标记为损坏 | 在称一个 hook "损坏" 之前先询问 |
| hook 看似没触发，但其实触发了——后面渲染的某个 UI 元素盖在它上面 | hook 的触发顺序不是视觉顺序。在重新编辑 hook 配置之前：(a) 用 `--debug` 或通过管道输出确认；(b) 检查是否有 diff 对话框、权限提示或其他 UI 元素渲染在上层并把 hook 输出顶出了屏幕；(c) 只有到这时才怀疑 hook 本身。 |
| `/health` 首次运行烧掉太多配额 | 先停留在摘要模式。完整对话摘录与 inspector 子 agent 是深度审计工具，不是 Standard 项目的默认路径。 |
| 把缺失的 specs/docs 当作失败 | 决策产物默认是可选的。只有当层级、活跃的交接风险或用户请求使其成为必要时，才升级缺失的 docs/specs。 |
| 把被忽略的 AGENTS/CLAUDE 文件当作持久的项目事实 | 报告该规则是否被跟踪与分发。本地覆盖层可以启发审计，但持久修复应放在公开仓库文档或随附的 skill/rule 文件中。 |
| 把评审计分卡当作可维护性文档 | 计分卡是快照。提取其中的不变量与验证路径，然后删除或归档该报告，而不是把分数本身当作持久规则。 |
