# AI 可维护性结构性发现

由 `health` 步骤 3 为 AI 可维护性赛道加载。摘要模式读取 `AI MAINTAINABILITY SUMMARY`；深度审计、Complex 项目与明确的代码腐化请求读取 `DETAIL`。agent 配置赛道（指令漂移）留在 `SKILL.md` 中。下面的 `$HEALTH_SCRIPT` 与 `$HEALTH_LAUNCHER` 变量就是步骤 1 已解析出的那两个。

**AI 可维护性缺口。** 摘要模式使用 `AI MAINTAINABILITY SUMMARY`，深度模式使用 `AI MAINTAINABILITY DETAIL`。当项目没有可执行的验证命令、非平凡仓库没有 agent 指令暴露面，或存在损坏的文档引用时，报告 `FAIL`。当指令存在但缺少项目地图、验证指引、边界/非目标语言时，当 TODO/HACK 标记集中时，当大型源码热点缺少归属/边界与验证指引时，当持久文档包含原始的一次性评审报告、计分卡、带日期的行引用或诊断转储而非稳定的不变量时，或当某运行时支持路径作用域指令加载（Claude Code 带 `paths` front-matter 的 `.claude/rules/*.md`、嵌套目录的 `CLAUDE.md`）但一个总是加载的大型指令文件却夹带了只在某些路径下适用的领域或语言专属规则，导致每个无关会话都要付出其完整上下文成本时，报告 `WARN`。最后一种情况的动作是添加 `paths` front-matter（或把该块移到嵌套的 `CLAUDE.md` / 某个 skill），而不是删除该规则。把缺失的 `docs/`、`specs/`、`.specify/`、`HANDOFF.md`、`CHANGELOG`、issue 模板与 PR 模板视为信息性，除非项目复杂度使其成为交接所必需。对过时报告的动作是把稳定的规则提取进公开指令、rules、references 或验证器脚本，然后删除或归档那份临时报告。

**源自对话的指引。** 当一次 health 审计读取了近期的 agent 对话时，不要建议把该对话或某个计分卡复制进文档。改为建议做一次候选矩阵梳理：

| 字段 | 问题 |
|---|---|
| 重复失败 | 这在多次修复、发布、agent 或用户报告之间复发了吗？ |
| 持久不变量 | 这条教训能否被表述为一条稳定的规则，而非带日期的偶然事件摘要？ |
| 目标层 | 它应存在于项目指令、某个 Waza skill、某条全局规则，还是私有记忆中？ |
| 验证器 | 是否有确定性的命令、脚本、产物检查或运行时冒烟测试可以强制执行它？ |
| 脱敏风险 | 这条教训是否需要本地路径、issue 编号、客户细节、机器状态、机密或未发布的版本事实？ |

分层规则：项目专属的命令、应用名、产物名与发布仪式留在项目中；可复用的工作流（如取消发布的评审闸门或原生冻结证据阶梯）属于 Waza skills；普适的诚实与验证规则属于全局 CLAUDE/AGENTS；私有的用户偏好与单机事实留在记忆中。如果这条教训无法通过脱敏风险一栏，就把它排除在公开指引之外。

按加载暴露面作用域，而不只是按层。一条留在项目中的规则，除非绑定到它适用之处，否则仍会在每个会话上付出上下文成本：语言与框架规则具文件类型的 `paths` 作用域，项目领域规则绑定到其源码目录（`paths` front-matter 或嵌套目录的 `CLAUDE.md`），只有真正横切的约束才在总是加载的根中无条件加载。一条只在其条路径下才重要的规则不属于总是加载的文件。

**集中的修复链。** 运行 `git -c core.fsmonitor=false log --oneline --since='2 weeks ago' | grep -i fix` 并按区域分组（`:` 或 `(` 之前的前缀）。当同一区域在短窗口内有 3+ 个修复提交时，它预示着一个缺失的结构性不变量：每个修复都是对一条从未被写下的规则的猜测。报告一条 Structural `WARN`，附上区域名、修复计数，并建议向 `AGENTS.md` / `CLAUDE.md` / 项目 rules 添加一条显式规则，以捕捉那些修复正趋近的不变量。同一文件被改动 4+ 次的集中修复链，是比分散在不同文件上的修复更强的信号。

**热点归属缺口。** 在深度模式下，读取 `HOTSPOT OWNERSHIP SURFACE`。如果某个最大源码文件超过热点阈值，而 `AGENTS.md` / `CLAUDE.md` / 共享指令文件没有指明谁拥有该热点、哪条边界应保持稳定、哪条验证命令覆盖它，则报告一条 Structural `WARN`。不要仅凭体积就把有记录的大文件当作代码腐化；有些模块是有意做大。

**缺失稳定的验证器包装器。** 如果仓库通过 CI、脚本或清单暴露了多条验证命令，但 `Makefile` 没有 `check`、`test` 或 `verify` 目标，则报告一条 Structural `WARN`。这是 AI 可维护性缺口，因为 agent 需要一个稳定的默认入口，而不是因为项目坏了。

从项目根快速检查，复用步骤 1 中解析出的 `$HEALTH_SCRIPT`：

```powershell
& "$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$HEALTH_LAUNCHER" maintainability . summary
```

在 Linux 与 macOS 上：

```bash
BASH_ENV= ENV= /bin/bash -p "${HEALTH_SCRIPT%/*}/check-maintainability.sh" . summary
```

深度审计：

```powershell
& "$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$HEALTH_LAUNCHER" maintainability . deep
```

在 Linux 与 macOS 上：

```bash
BASH_ENV= ENV= /bin/bash -p "${HEALTH_SCRIPT%/*}/check-maintainability.sh" . deep
```

保持动作具体且非侵入：添加或修复最小可用的指令暴露面、添加一条可执行的验证命令、记录热点归属与测试、仅在边界已清晰时才拆分，或修复损坏的引用。不要仅凭脚本输出就提出大范围重写。

**损坏的文档引用。** 扫描 `AGENTS.md`、`CLAUDE.md`、`.claude/rules/*.md` 以及每个 `.claude/skills/*/SKILL.md`，查找形如 `@<path>`、`~/.claude/rules/<name>.md`、`~/.claude/skills/<name>/`、`docs/<name>.md` 或 `references/<name>.md` 的引用。对每个匹配项，检查目标是否存在于磁盘上。报告每一个"被引用但缺失"的指针，附上源文件与行号。

常见的罪魁祸首：
- 某条项目级规则引用了某个从未创建的全局规则文件（例如 `~/.claude/rules/swift.md`）。
- 某个 `CLAUDE.md` 使用了 `@AGENTS.md` 占位符，但实际的 `AGENTS.md` 缺失或为空。
- 某个 skill 正文引用了 `references/<name>.md`，但只存在 `references/<name>-v2.md`。
- 某个规则文件引用了已被删除的 skill 路径。

从项目根快速检查，复用步骤 1 中解析出的 `$HEALTH_SCRIPT`：

```powershell
& "$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$HEALTH_LAUNCHER" doc-refs .
```

在 Linux 与 macOS 上：

```bash
BASH_ENV= ENV= /bin/bash -p "${HEALTH_SCRIPT%/*}/check-doc-refs.sh" .
```

该检查器从项目根解析 `@...` 与 `docs/...`，展开 `~`，从每个 `.claude/skills/<name>/SKILL.md` 目录解析 `references/...`，检查一行上的每个引用，跳过围栏代码示例，并在任何目标缺失时以非零码退出。

把缺失的引用报告为 Structural 发现，而非 Critical，除非该缺失文件被指名为硬依赖（例如项目发布 skill 的 `release.md`）。

**损坏的 Markdown 引用。** 在深度模式下，`check-maintainability.sh` 还会扫描仓库的 Markdown 链接。当它们指向缺失的本地文件时，报告为 Structural 发现，尤其是 agent 在后续工作中可能遵循的设计、安全、发布或交接文档。

**过时的验证器缓存输出。** 如果验证输出指向已被删除的临时 worktree，或不存在的 `/tmp` / `/private/tmp` 文件，用以下命令解析被捕获的日志：

```powershell
& "$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$HEALTH_LAUNCHER" verifier-output . <log-file>
```

在 Linux 与 macOS 上：

```bash
BASH_ENV= ENV= /bin/bash -p "${HEALTH_SCRIPT%/*}/check-verifier-output.sh" . <log-file>
```

仅对用户提供的、或本次审计期间生成的现有命令输出使用此脚本。不要为了喂给这个检查器而运行项目测试。已知的动作包括 `golangci-lint cache clean`、`go clean -cache -testcache` 与 `npm cache verify`；未知工具给出一条诊断性重跑动作。
