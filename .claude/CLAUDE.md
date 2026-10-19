# Utility 项目

**必须基于事实而不是猜测**

## 项目概述
macOS 菜单栏工具，Swift + AppKit + SPM。
- LSUIElement（无 Dock 图标）
- NSStatusItem 菜单栏入口
- NSPanel floating 面板：剪贴板管理、翻译、Stage 暂存
- Carbon EventHotKey 全局快捷键
- GRDB 本地 SQLite 存储
- Vision OCR 屏幕区域识别

## Git 流程
- 用户测试通过后才 commit
- 只提交暂存区（`git commit` 不加 `-a`）
- 提交前检查 `default-config.yaml`、`README.md`、`AGENTS.md` 是否需要同步更新
- 如需更新，改后等用户确认，不继续提交动作

## Build
- Clean build: `rm -rf .build && swift build`
- 二进制路径：`.build/debug/utility`、release 为 `.build/release/utility`（SwiftPM 维护的符号链接）
- 实际产物目录随 SwiftPM 版本变化（旧 `.build/arm64-apple-macosx/{debug,release}`，新 `.build/out/Products/{Debug,Release}`）——**脚本中禁止硬编码，用 `swift build -c <config> --show-bin-path` 查询**
- 验证改动进二进制：`strings .build/debug/utility | grep keyword`
- ⚠️ `package-utility.sh` 曾硬编码 `.build/arm64-apple-macosx/release/utility_utility.bundle` 且包在 `if [ -d ]` 里，新版布局下该目录不存在 → 资源 bundle 被**静默漏拷**（app 18M→9.8M），启动即 `Fatal error: unable to find bundle named utility_utility`（`resource_bundle_accessor.swift`）。资源缺失一律硬失败，不做条件跳过

## 核心架构

**修改某个模块前，先读对应的架构文档**（逐字保留实现细节、踩坑过程与验证数据）：

| 模块 | 文档 |
|---|---|
| 面板 / EventBus / 热键 / Stage / OCR / 内存诊断 | `.claude/docs/architecture/panel-ui.md` |
| 符号提取 Scanner | `.claude/docs/architecture/scanner.md` |
| PythonScriptRunner / PythonDaemon / 日志 | `.claude/docs/architecture/python-runtime.md` |
| Token Proxy | `.claude/docs/architecture/token-proxy.md` |
| llm_client / 提示词 / MCP 描述文案 | `.claude/docs/architecture/llm-and-prompts.md` |
| 知识面板 | `.claude/docs/architecture/knowledge-panel.md` |
| MCP 服务 server.py | `.claude/docs/architecture/mcp-server.md` |
| Orchestrate 设计沉淀 / Claude CLI 标志 | `.claude/docs/architecture/design-notes.md` |

以下只列**每次改动都必须遵守的不变量**；原因与历史案例在文档里。

### 面板与 UI
- 面板零引用 PanelManager，只经 EventBus 发 requestShow/Close；PanelManager 是唯一 show/close 入口，栈顶优先，Stage 不入栈
- `didResignKey` 用 `DispatchQueue.main.async` 等通知链完再读 `NSApp.keyWindow`，不用 didResignActive
- 跨模块通信走 EventBus，禁止直接持有对方引用
- `HotkeyManager.keyCodeMap` 必须完整覆盖 26 个字母 + 常用符号；`parse` 的 keyCode 用 Optional，**不能用 0 表示未匹配**（`a` 的 ANSI 键码就是 0）
- 热键只在启动时 `registerAllHotkeys()` 注册，配置重载不重注册 —— 改热键要重启 app
- Stage 拖放检测用 mouseDown/mouseUp 的 changeCount 快照对比，不能只看 hasContent（`.drag` 残留会误判）
- 请求封装类必须用 `RequestConfig` struct 收束全部控制参数，不拆成单独函数参数
- i18n 唯一数据源是 `Sources/Resources/<lang>.json`；Swift 访问器由 `scripts/gen-l10n.py` 生成到 `L10nKeys.swift`（禁止手改），Python 生成 `l10n_catalog.py`；占位符只用 `{name}` / `{name:d}` / `{name:.Nf}`（禁止 `%@`/`%ld`/`String(format:)`）；改 JSON 后必须重新生成，打包前跑 `gen-l10n.py --check` 与 `check-l10n-contract.py`；运行时切语言用 `refreshAllTitles()` 模式

### 符号提取（Scanner）
- 全量扫描写入必须是**单事务原子替换**（`replaceScanResults()`）；`clearAll()` 已删除，**禁止重新引入**
- 模块根标记 `has_package_manifest` 的判定必须在 includes 过滤**之前**，遍历结束后统一回填
- 向量检索的符号缓存键必须是业务字段 `sha1(file_path|name|kind|signature|doc_comment)`，**不能用 `symbols.id`**（两条写入路径都先删后插，id 每次都变）
- 提取优先级 AST 脚本 → regex 兜底 → 失败计数；AST 连续 3 次失败跳过，`failed_files` 跨扫描保留

### Python 运行时
- **新增跨语言 env 必须同时加两个注入点**：`baseEnvironment()` 与 `taskEnvironmentOverrides()`（`.sh` 任务），漏一个会「服务里生效、定时任务静默回退默认」
- 端口解析必须缓存；显式配置 `port > 0` 始终优先、不走缓存
- `terminationHandler` 的身份判断 `process !== p` 必须放在 `isStopping` 之前；崩溃判据包含非零退出码
- 健康检查必须 `async/await` + `@MainActor`，禁止 `DispatchSemaphore`（阻塞主线程导致回调死锁）
- 崩溃重启前先探测端口，健康则认领而不是再 spawn
- 契约脚本第 3 组断言的是**实际注入点**，不是「源码里出现过这个名字」

### Token Proxy
- 转发上游**不得透传客户端 `Accept-Encoding`**：`skip_headers` 排除 + `headers["Accept-Encoding"]` 显式声明，两处都要
- 规则注入必须注入**每一条**真实用户消息，不能只注入最后一条（注入点移动会让 prompt cache 前缀每次断）
- 含 tool_result 的消息必须插到**最后一个 tool_result 之后**，禁止 `insert(0)`
- 响应注记会被模型复述，请求侧必须剥离 assistant 消息里的注记行
- 协议判据优先取入口路径，路径不表明协议时才回退请求体启发式
- `finish_reason → stop_reason` 映射是单一常量 `FINISH_REASON_MAP`，转换层兜底、记录层保留原样
- 转发入口 `/v1/*` 与 `/open/*` 共用同一 handler，路径在 `_upstream_path` 归一

### LLM 调用与提示词
- Python 侧唯一 LLM 出口是 `llm_client.py`；配置唯一来源 `config.py`，该模块不读 env、不持默认值
- `LLMTarget.ready` 与 `configured` 别混；**api_key 为空是合法的**（表示透传客户端 key）
- 提示词在 `Sources/MCPScripts/prompts/<lang>/<feature>.md`；目录优先级：用户覆盖（语言无关）→ 内置（当前语言 → `zh-Hans` 基线）
- 渲染**禁用** `str.format` / 逐 key 替换，必须按名字**一次性**替换
- 语言唯一判据 `L10n.resolvedLanguage()` / `UTILITY_LANG`
- 工具描述与参数描述固定英文，不进语言目录；参数描述只做 `inputSchema.description`，未登记的键抛 `MissingParamText`
- `param.memory_content` 与 `TOOL_DESCRIPTIONS["remember"]` 必须同为三要素口径

### MCP 服务（server.py）
- 冷层集合维度不一致：`logger.error` + **禁用冷层**，不拒绝启动
- 同义词 / 工具默认值 = 内置默认 + 用户增量；对应 env 不进 `config.py`，由契约脚本单独交叉断言
- schema 的 `default` 与 handler 兜底必须同源（`arg_default()`）
- 整数参数一律经 `_int_arg`（显式传 `null` 会让切片变成不截断）
- MCP 层文案统一英文，重复文案必须走常量
- `websearch_engine` 内置在 `server.py`（`web_search.py`），旧 `websearch-fallback` skill 已移除；页面内容必须转 Markdown 并限长，禁止把 HTML 直接返回给模型

### 知识面板
- 补货**不能走 TaskScheduler**（sub-daily cron 会静默退化成每天一次），用 `KnowledgeService` 自建 Timer
- 补货判据必须是**新鲜卡**（Python `fresh_count` / Swift `freshCount`），两侧同源 `knowledge.maxShownPerCard`；按池总量判断会让补货在 while 入口空转
- `runCaptureOutput` 必须显式传 `environment:`，否则 GUI 进程没有 `AI_API_KEY`
- 知识库 schema 唯一所有者是 `knowledge_pool.py`，Swift 只做裸 SQL、绝不建表；两侧都要 WAL + busy timeout
- Markdown 必须逐 run 把 intent 翻成字体/段落样式；表格或解析失败降级纯文本
- 自检证据必须给全文，**禁止截断**（截断会批量制造假阳性）
- 卡片失败源几乎全是上游 LLM 超时：`disable_thinking=True`

## 设计原则

### 最小暴露
- 类的内部实现用 private/fileprivate，仅对外暴露必要的 public/internal API
- 不在 AppDelegate 暴露内部属性供外部调用——自管生命周期

### 解耦
- 视图与逻辑分离：Service/Manager 不依赖 NSView/NSWindow/NSViewController
- PasteHelper、SelectedTextService、Translator、OCRService 全部无视图依赖

### 单⼀调用
- 核心逻辑不依赖 UI 上下文，可直接从 CLI 或无头模式调用

### 拒绝猜测
- 看不懂某段代码为什么那样写时，先查 git log 看提交记录和 commit message
- git 记录看不出来时问用户，不要自己假设
- Bug 修复依赖现实调试信息，禁止靠猜测修改

## 未来规划
- Orchestrate 已实现 + 真实测试验证通过（2026-07-15），但代码已移除（2026-08-03 确认），设计沉淀见 `.claude/docs/architecture/design-notes.md` 与 `.claude/plans/agent-orchestrate.md`
- devflow 研发编排（云效需求拉取 → 子会话 → 状态流转 → 汇报）为当前落地方向
- MCP 移植、Agent 寄生模式已完成；项目依赖图持续维护
