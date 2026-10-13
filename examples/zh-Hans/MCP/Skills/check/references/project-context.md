# 项目评审上下文模板

用本模板在运行 Waza `/check` 之前压缩仓库上下文。上下文必须来自公开项目文件、diff、CI 配置或用户的明确指令。不要依赖私有的机器路径或未公开的项目指令。

## 什么属于 Waza `/check`

- diff 深度分类。
- 范围漂移检测。
- 硬性阻断，例如破坏性自动化、缺失的发布产物、生成产物漂移、版本错位、未知标识符、注入风险、凭据泄漏与依赖意外。
- 用于发布就绪的 Release Gate 2.0 矩阵。
- 针对破坏性操作、命令构造、路径边界、签名/appcast、沙箱/审批与鉴权提示的安全汇点评审。
- 安全与架构专家的路由。
- 自动修复策略。
- 收尾签署格式。
- 验证预期。

## 什么属于项目上下文

- 从公开文档、清单、Makefile、脚本或 CI 工作流中发现的验证命令。
- 受保护的文件与目录。
- 必须与源码改动保持同步的生成或打包产物。
- 打包的事实源：归档是从 `git ls-files`、显式白名单、生成的清单，还是源目录构建的。
- 交付面：生成产物是受跟踪、被忽略、外部发布资产、registry 上传、appcast、安装器元数据、校验和，还是站点/下载文案；它们如何被重新生成、检查、暂存或上传。
- 分发通道：preview、beta、nightly、stable、App Store 或 registry 通道，以及每个通道各属于哪些生成产物。
- CLI 命令面：入口点、子命令、flag、help/version 行为、退出码、stdout/stderr 契约、TTY 与非交互路径、配置/env 优先级，以及安装后运行时检查。
- 由 diff 引入的运行时依赖：尚未在 CI/文档中声明的 Python 包、CLI、网络服务、包管理器或平台工具。
- Skill、plugin、marketplace 或包安装面：安装器的默认 ref、marketplace 源路径、生成的镜像、包白名单、归档根、可执行位，以及安装后运行时的冒烟命令。
- 领域专属的安全规则。
- 必须存在的发布产物。
- 项目期望的 GitHub 发布表情或其他公开发布续接动作。
- 发布资产验证方法：下载、归档条目比对、校验和清单、包元数据回读、appcast 回读，或 registry 查询。
- 公开 issue 或 PR 的回复约定。
- 项目记录的已知 CI 或测试偶发失败，以及如何把它们与真实失败区分开。
- 项目记录的发布、发表、推送或关闭 issue 的前置条件。

## 什么不属于公开上下文

- 凭据路径、私钥文件名、密码、token 或密钥值。
- 仅维护者本机的机器路径。
- 不影响项目行为的一次性个人偏好。
- 被当作指引抄录、而未被提炼成稳定项目规则的一次性评审报告、评分卡或诊断快照。
- 来自另一个项目的原始记忆、聊天摘录、截图、私有支持细节、本地路径、项目专属命令、issue/PR 编号、发布 tag 或提交 hash。
- Waza `/check` 各节的完整副本。

## 建议的上下文形状

```markdown
## Project Commands

- Format: `<command>`
- Fast check: `<command>`
- Full verification: `<command>`

## CLI Command Surface

- Entrypoints: `<command or bin>`.
- Command contract: help/version, subcommands, flags, exit codes, stdout/stderr, JSON/schema output.
- Runtime shape: TTY vs non-interactive behavior, env/config precedence, completion/manpage or shell integration.
- Install/run proof: built package, temp prefix, PATH shim, shebang/executable bit, or package-manager path checked with `<command>`.
- Mutating commands: dry-run/confirmation, operation log, rollback/retry behavior, signal/partial-failure handling.

## Skill Or Plugin Install Surface

- User install path: `<package manager / release archive / marketplace entry / plugin id / installer script>`.
- Source path and generated mirror: `<source dir>` -> `<installed dir>`.
- Package/archive inclusion: new scripts, references, templates, rules, manifests, and executable bits checked with `<command>`.
- Isolated install smoke: fresh temp home/config/cache plus `<install command>` and `<list or invoke command>`.
- Noise filtering: cache files, local logs, screenshots, and temp outputs excluded or intentionally shipped.

## Project Hard Stops

- Do not modify `<protected path>` unless explicitly requested.
- If `<artifact>` is generated from `<source>`, verify it was regenerated.
- If `<artifact>` is ignored by git but required for release, verify the regeneration and force-stage, upload, or registry publish path named by the project.
- If `<package script>` builds from tracked files or an allowlist, verify newly introduced helpers, references, templates, and scripts are included in `<archive>`.
- If an installer fetches remote content, verify the default ref is pinned to a release tag or checksum-protected; floating `main` must be an explicit override.
- If a helper introduces a non-stdlib package or external CLI, verify CI installs it or the helper fails with a clear setup path.
- If `<artifact>` is listed in release notes, verify it exists before sign-off.

## Project-Specific Risks

- `<risk>`: `<how to inspect it>`

## Public Replies

See `public-reply.md` for the full reply template (language match, `@user` + thanks, factual paragraphs, ship-state line, closure criteria). It is the single source; do not restate the rules here.

## Release Follow-through

- Version fields to check: `<manifest>`, `<app config>`, `<lockfile>`.
- Generated artifacts to check: `<artifact>` from `<source>`.
- Distribution lane: `<preview/beta/nightly/stable/etc.>` and which public surfaces it is allowed to touch.
- Dry-run command before publishing: `<command>`.
- Remote asset proof: `<download/readback command>` that checks content, manifest, digest, appcast, or registry state.
- GitHub release reactions to add after asset verification: `<+1/laugh/heart/hooray/rocket/eyes or none>`.
- Public state to re-read after publishing or closing: `<registry/release/issue URL or command>`.
```

保持这份上下文简短。它应指引评审，而非替代评审方法。

## Release Gate 2.0 矩阵

在声称某个改动可以发布之前填入此表。只有当项目显然没有这样的面时才用「n/a」。

| 面 | 证据 |
|---|---|
| 评审基线 | 已评审的基线分支、最新 tag 与提交范围 |
| 工作区状态 | 脏、已暂存与未跟踪文件均已考虑 |
| 远端状态 | 已核对 `origin/main` 或发布分支的同步 |
| 版本字段 | 清单、app 配置、changelog、appcast 与 lockfile 的版本已对齐 |
| 分发通道 | 已指名 preview、beta、nightly、stable、registry 或 app-store 通道，且无关通道未被触碰 |
| 运行时依赖 | 新引入的 Python 包、CLI、包管理器与网络工具已声明且在 CI 中可用 |
| 生成产物 | 被跟踪的归档、被忽略的 dist 输出、打包/压缩文件、appcast、安装器元数据、校验和与站点/下载文案，已重新生成或已被证明不需要 |
| 包/归档内容 | 已检查构建出的包，确认必需文件、新引入的辅助/reference，以及缺失的附加文件 |
| 安装后运行时 | 当 diff 改动可安装面时，已在干净环境中实际执行包、skill、plugin、CLI 或 marketplace 安装 |
| 发布资产 | 已下载或回读 GitHub release、appcast、下载归档、校验和或安装器资产，并在页面文本或文件大小之外完成验证 |
| Registry/appcast | 发布后重读了 npm/crates/Homebrew/appcast/App Store 或等价状态 |
| CI 状态 | 最新的必需检查已通过，或已指名阻塞项 |
| Issue/PR 状态 | 在评论、关闭、合并或声称已发布之前重读了目标 issue 或 PR |

## 安全汇点评审

任何触及下列汇点之一的 diff，都需要对校验与回滚做显式思考：

- 删除、移动或覆盖用户文件、缓存、历史、偏好或生成产物。
- 用用户输入构造 shell、AppleScript、SQL、URL 或文件系统路径。
- 改动 cwd 处理、symlink 解析、路径穿越守卫、沙箱权限、审批检查或鉴权提示。
- 改动签名、公证、appcast、更新、许可、支付或发布资产生成。

先评审能到达该汇点的最小入口点，再评审其下游调用。如果校验缺失或回滚不明，把它当作硬性阻断。
