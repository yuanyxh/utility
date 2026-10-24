# AGENTS.md — Utility Project

> 为 Agent/CLI 提供项目上下文、开发约定、内存数据参考。每次会话自动注入。

**必须基于事实而不是猜测**

---

## 项目概述

**utility** — macOS 菜单栏工具，Swift + AppKit + SPM，Python 子进程扩展。
- LSUIElement（无 Dock 图标）
- NSStatusItem 菜单栏入口
- NSPanel floating 面板：剪贴板管理、翻译、Stage 暂存
- Carbon EventHotKey 全局快捷键
- GRDB 本地 SQLite 存储
- Vision OCR 屏幕区域识别
- **MCP 记忆服务**：Mem0 + Qdrant 冷热双层记忆，通过 Python 子进程提供 MCP Tools
- **项目符号扫描**：Swift/JS-TS/Python AST + 正则提取 + FTS5 索引 + 文件监控（符号含起止行号）

---

## 参考方针

> 以下约定覆盖所有开发活动。

1. **提交时机**：用户明确功能正常后，再提交代码。不要自己 commit。
   - 只提交暂存区代码（`git commit` 不加 `-a`）
   - 提交前检查 `default-config.yaml`、`README.md`、`AGENTS.md` 是否需要同步更新
   - 如需更新，更新后等用户确认，不继续提交动作
2. **排查策略**：2-3 轮对话后仍无法解决问题，搜索网络相关资料。
3. **Bug 修复**：依赖现实调试信息，禁止靠猜测修改。先给出明确的调试方案——如何获取必要信息。
   - **禁止猜测代码用途**：看不懂某段代码为什么那样写时，先查 git log 看提交记录和 commit message
   - git 记录看不出来时，问用户，不要自己假设
4. **大改动审批**：代码改动过大时，先询问，确认后再修改。

---

## 设计原则

> 所有代码必须遵循。

### 最小暴露
- 类的内部实现用 `private` / `fileprivate`，仅对外暴露必要的 `public` / `internal` API
- 不在 `AppDelegate` 暴露内部属性供外部调用（如 `clipboardWatcher`）——自管生命周期
- 单一入口、单一出口

### 解耦
- 视图与逻辑分离：Service/Manager 不依赖 NSView/NSWindow/NSViewController
- `PasteHelper`、`SelectedTextService`、`Translator`、`OCRService` 全部无视图依赖
- 跨模块通信走 `EventBus` pub/sub，禁止直接持有对方引用
- 单向依赖使用枚举 key 事件，一个 key 可多个 handler

### 复用
- 相同逻辑只写一次，不重复造轮子
- `Constants.swift` 集中管理共享类型（如 `PasteboardImageTypes.all`）
- `PasteHelper.schedulePaste(to:)` 供剪贴板和翻译面板共用
- `SelectedTextService` 封装 AX + 剪贴板兜底两路径，所有调用方统一入口

### 可单独调用
- 核心逻辑不依赖 UI 上下文，可直接从 CLI 或无头模式调用
- 例如：`Translator.translate()` 可独立调用于脚本，`OCRService.recognize()` 可仅返回文本

### 架构意识
- 设计模式优先：pub/sub、单例、策略、门面
- 优先组合而非继承
- 避免到处散落的外部引用——代之以依赖注入或 EventBus 通信

---

## 核心架构

| 组件 | 职责 |
|------|------|
| `AppDelegate` | 入口：注册 hotkey、初始化管理器 |
| `EventBus` | 线程安全 pub/sub（枚举 key 对应多 handler） |
| `ConfigManager` | YAML 配置加载/热重载 |
| `MenuBarManager` | NSStatusItem + NSMenu |
| `HotkeyManager` | Carbon RegisterEventHotKey |
| `PanelManager` | 栈结构面板生命周期：注册/弹出/关闭/焦点追踪 |
| `KeyDispatcher` | 责任链键盘事件派发：栈顶→栈底→系统 |
| `PanelProtocol` | 面板统一协议：panelID / showPanel / closePanel / handleKeyEvent |
| `SSEParser` | SSE 帧解析器：`data:` 行 → content delta 回调 |
| `ClipboardPanelController` | 剪贴板面板 + clipboardStorage + clipboardWatcher（自管生命周期） |
| `TranslationPanelController` | 翻译面板 + 选中文本获取 |
| `StageWindowController` | Stage 暂存窗口 + StageDropMonitor（自管注册） |
| `TaskScheduler` | Timer + cron + 系统唤醒检测（含内部任务注册） |
| `TaskExecutor` | 外部脚本执行（sh/js/py） |
| `TaskStateDB` | GRDB 任务状态持久化 |
| `MCPProcessManager` | Python server.py 服务编排：State 语义/EventBus 广播/端口复用探测/python 预检；进程生命周期委托 `PythonDaemon` |
| `PythonScriptRunner` | py 脚本统一入口：venv 路径 / 脚本定位（bundle→dev fallback）/ env 构造（baseEnvironment+overrides）/ shell 命令 / 一次性执行（runCaptureOutput） |
| `PythonDaemon` | 参数化常驻 Python 进程守护：启动/崩溃重启/健康检查/停止（`MCPProcessManager` 与 `TokenProxyManager` 共用） |
| `TokenProxyManager` | token_proxy.py 服务编排：State 语义/EventBus 广播/providers 路由；进程生命周期委托 `PythonDaemon` |
| `MCPMenuManager` | MCP 服务状态独立菜单栏管理（app 内部分离） |
| `ASTExtractorRunner` | AST 批量提取调度（`ast_extractor.py --batch` + 单文件兜底，经 `PythonScriptRunner.runCaptureOutput` 边读边存防 pipe 阻塞） |
| `ProjectScanner` | 多语言符号 + import 提取器注册 → 批量 AST → 并发正则 → 顺序解析依赖边 → 批量 SQLite ↔ FTS5 |
| `SwiftExtractor` / `JSTSExtractor` / `PythonExtractor` `VueExtractor` / `JavaExtractor` / `KotlinExtractor` | 各语言 SymbolExtractor 实现，正则提取函数/类/常量/注解 + `imports(...)` 兜底 |
| `ImportResolverRegistry` | 按扩展名把 raw import 解析为项目相对 `to_path`；未命中不造边 |
| `ManifestParser` | Package.swift / package.json / pyproject.toml 依赖解析 |
| `FileWatcher` | FSEvents 文件监控 + 3s 防抖增量更新（symbols/files/imports 同一事务） |
| `NotificationManager` | 本地通知 |
| `Translator` | OpenAI 兼容 API 翻译 |
| `OCRService` | Vision 帧捕获 + 文本识别 |
| `Database` | GRDB DatabaseQueue 单例 |
| `PasteHelper` | 粘贴到目标 app（osascript 子进程 + CGEventPost fallback） |
| `SelectedTextService` | AX Accessibility + 剪贴板兜底选中文本获取 |

---

## 关键技术约定

### Build
- Clean build: `rm -rf .build && swift build`
- 二进制：`.build/debug/utility`、release 为 `.build/release/utility`（SwiftPM 维护的符号链接）
- 实际产物目录随 SwiftPM 版本变化（旧 `.build/arm64-apple-macosx/{debug,release}`，新 `.build/out/Products/{Debug,Release}`）——**脚本中禁止硬编码，用 `swift build -c <config> --show-bin-path` 查询**
- 验证改动进二进制：`strings .build/debug/utility | grep keyword`
- ⚠️ `package-utility.sh` 曾硬编码 `.build/arm64-apple-macosx/release/utility_utility.bundle` 且包在 `if [ -d ]` 里，新版布局下该目录不存在 → 资源 bundle 被**静默漏拷**（app 18M→9.8M），启动即 `Fatal error: unable to find bundle named utility_utility`（`resource_bundle_accessor.swift`）。资源缺失一律硬失败，不做条件跳过
- 版本唯一来源是仓库根 `VERSION`：`package-utility.sh` 每次打包自增 patch 并写回，无文件时以 `INITIAL_VERSION=1.0.93` 起步
- macOS 26 起 `hdiutil create` 弃用，打包改用 `diskutil image create from --format UDZO --volumeName "$APP_NAME" "$APP" "$DMG"`（目标已存在时自动覆盖）
- ⚠️ **bash 3.2 会把紧跟 `$VAR` 的全角字符并入变量名**（`$VERSION（` → `VERSION<乱码>: unbound variable`，`set -u` 下直接退出）：变量后接中文/全角标点必须写 `${VAR}`

### Verification
每次改动按顺序跑，全绿才算完成：
```bash
swift build
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
python3 scripts/check-router-config-contract.py
python3 -m compileall -q Sources/MCPScripts
python3 -m unittest discover -s tests/python -t .
```
Python 测试依赖 `httpx`，用项目 venv：`~/.config/utility/mcp-venv/bin/python -m unittest discover -s tests/python -t .`

### scripts 目录
- `scripts/` 根只放可执行入口（`check-*.py`、`gen-l10n.py`、`package-utility.sh`、`run-tests.sh`），这些路径被文档与 `run-tests.sh` 引用，**不得移动**
- 校验器实现放子包：`scripts/router_contract/`（consts → parsers → proxy_checks/env_checks/content_checks → inputs → main）；新增校验脚本同样建包，根部入口只做 import + `main()`
- 子包内路径常量：`SCRIPTS_DIR = dirname(dirname(__file__))`、`ROOT = dirname(SCRIPTS_DIR)`
- ⚠️ venv 自举用 `os.execv` 重执行 `main.py` 时必须把 `scripts/` 加进 `PYTHONPATH`，否则子包导入失败

### i18n
- 唯一源 `Sources/Resources/<lang>.json`；`L10nKeys.swift` 由 `scripts/gen-l10n.py` 生成，禁止手改
- 占位符 `{name}` / `{name:d}` / `{name:.Nf}`，按名一次性替换
- Python 侧走同一目录生成的 `l10n_catalog.py` + `l10n.py`；`refreshAllTitles()` 模式刷新运行时语言
- 命名空间分工：`mcp` / `proxy` 仅 Python；`rss` 为共享（Swift CLI 帮助 + Python 日报），由 `SHARED_NAMESPACES` 控制，两侧都会生成访问器
- 语言无关的路径/默认值常量（季度目录名、知识卡片目录名、Clash 节点名）两语言取同值，避免切换语言后路径漂移

### 代码内文本语言
- 非用户可感知文本一律英文：注释、docstring、日志、内部错误消息、调试输出、测试名与断言消息
- 用户可感知文本按既有约定：UI 文案走 `Resources/<lang>.json`，提示词放 `prompts/<lang>/`，配置注释与 README 保持现有语言
- 新增内容不因周围历史中文注释而改用中文；历史中文注释不强制批量翻译，只在修改到的代码块内对齐

### 并发
- `Task?.cancel()` + `guard isCancelled` 模式
- 翻译用序列计数器（`translationSeq`）拒绝 stale 回调

### 面板管理
- 面板零引用 PanelManager，仅通过 EventBus 发 `PanelEvent.requestShow`/`requestClose` 事件
- PanelManager 唯一订阅 + 唯一调 `showPanel`/`closePanel`
- 栈结构 = 激活面板序，后入栈顶；同 ID 去重
- `dispatchKey`：栈顶→底遍历可见面板，`handleKeyEvent` 返回 true 阻断下层
- 失焦关闭：`didResignKeyNotification` → `DispatchQueue.main.async` 延迟到通知链完成再读 `NSApp.keyWindow`（防中间状态）
- 栈空 → `NSApplication.shared.hide(nil)`
- Stage 独立不入栈

### 知识面板
- 卡片池 = `~/.config/utility/knowledge.sqlite`，schema 所有者是 Python（`knowledge_pool.py`）；Swift 侧（`KnowledgeStore`）**只做裸 SQL 读写、绝不建表**，且每个方法都容忍「表不存在」
- 补货 = `knowledge_refill.py` 子进程，由 `KnowledgeService` 自建 Timer 驱动（面板只读池子，秒开）
  - ⚠️ **不能走 TaskScheduler**：`handleMissed()` 以「今天 00:00 后的第一个 cron 点」为基准，任何 sub-daily 的 cron 都静默退化成每天一次（`*/30 * * * *` 实测一天只跑一次且无报错）
  - ⚠️ **`runCaptureOutput` 默认不传 environment**，子进程继承 launchd 启动的 GUI 进程环境（无 `AI_API_KEY` / `UTILITY_DATA_DIR`）→ 脚本「成功」但一张卡都出不来。必须显式传 `PythonScriptRunner.environment(overrides: [:])`
- ⚠️ **Markdown 不能直接塞 `AttributedString(markdown:)`**：它只给 `presentationIntent` 语义属性、**不带任何字体**，结果是标题与正文一样大、加粗不变粗、列表没有项目符号，而且**不报错**。`KnowledgeMarkdownView` 逐 run 翻译 intent
  - 新 SDK 的 `intent.components` 元素是 `IntentType` 包装，枚举在它的 `.kind` 上（直接当 `Kind` 用会编译失败）
- ⚠️ **跨进程 WAL**：Python 子进程与 Swift 面板同时打开同一个文件，两侧都要 WAL + busy timeout（只设一侧会回落 delete 模式互相阻塞）；「读 + UPDATE」放同一事务，失败必须 `debugLog`
- 卡片生成的失败源**几乎全是上游 LLM 超时/断连**，不是内容判据：`knowledge_card` 曾带 thinking 生成 8k，单次 60~180s；现关思考 + `max_tokens=4096`
- `knowledge_engine._llm_json` 把「调用没返回内容」与「返回了但解析不出」分成两条日志 —— 混在一起会让上游超时看起来像提示词问题
- ⚠️ **主题必须带 `scope` / `exclude`**：只给主题名时「下一个自然概念」会无限外溢（实测 TCP/IP 协议栈从 SDN 滑到 AI 驱动、服务网格、eBPF、容器网络）。两者同时喂 `knowledge_expand` / `knowledge_gate` / `knowledge_card`；`seed_from_config()` 对已存在主题也同步 scope
- **选题闸门是独立的一次 LLM 判断**（`knowledge_gate`，零温度 256 token），不让 expand 自评。拒绝的概念落 `rejected` 且不计 `fail_streak`；上游不可用（含 `gate_unavailable`）同样不计
- **赞与踩都只标记并停留当前卡**，不调用 `advance()`；换卡只由定时自动弹出与补货后的 `reloadCurrent()` 触发。面板没有「已知」按钮。踩过的标题经 `disliked_titles()` 作为 `{disliked}` 负反馈喂给 expand（不要选相邻话题）与 gate（第 5 条判据）
- **自检的证据必须给全文,不能截断**（自检步骤后因长输入必断连已移除，重建时必须遵守）：实测把 10469 字截到 6000 字,模型立刻把后半段的真实内容逐条判成「卡片自行添加」,同一张卡从 `ok` 翻成 `not ok` —— 截断在这里是批量制造假阳性
- **系统休眠不执行**：`willSleep` 置 `suspended` 并停掉两个 timer；已在跑的补货子进程由 `runCaptureOutput` 的 `shouldCancel` 闭包中止（否则它被冻结后一直挂着,唤醒时立刻撞上 wall-clock 超时）。`didWake` 清标志 + `rearm()` + 立刻补一轮
- 菜单栏「任务」里有一条知识补货（显示未读卡数量 / 上次结果 / 运行中打勾），但它**不注册进 TaskScheduler** —— 只借子菜单做入口，起进程仍走 `KnowledgeService` 的闸门（交给 `TaskExecutor` 会多出一个不受防重保护的补货进程）
- **补货判据是「未读卡」而非池总量**：`unseenCount(kind:)` 只数 `shown_count = 0` 的池中卡。旧卡复习由 `showReviewedCards` 控制，默认关闭；按池总量判断会让补货永远「充足」
- **自动关闭只属于定时弹出的卡**：`showAuto()` 置 `autoCloseEligible`，手动打开清掉；窗口成为 key 时停表，失焦（含 app 失活）后从 0 重新计时

### 全局热键
- `HotkeyManager.keyCodeMap` 必须完整（26 字母 + 常用符号），与 `kVK_ANSI_*` 一致：缺哪个键，配了它的热键就静默 `parse` 失败并弹「热键解析失败」——**只影响用户自己配的那个键**，看起来像配置写错了（`option+k` 就这么栽过：表里只有 14 个字母）
- `parse` 的 keyCode 必须用 `Optional`：`a` 的 ANSI 键码是 0，拿 0 当「未匹配」会让 `cmd+a` 解析失败
- 热键只在启动时注册一次，配置重载不重注册，改热键要重启 app

### NSTableView
- `selectionHighlightStyle = .none` + manual frame + cell 子类 layout
- 避免 NSTableView 缓存 rowView 导致无限内存

### 粘贴
- osascript 子进程（避免 NSAppleScript 运行时内存泄漏）
- 浏览器 120ms / 原生 50ms 延迟
- CGEventPost fallback 双路保障
- `didActivateApplicationNotification` 激活检测

### Stage Drop
- `NSPasteboard(name: .drag)` cc 检测新拖拽
- `mouseDown` 快照 changeCount → `mouseUp` 对比
- `PasteboardImageTypes.all` 集中定义图片类型

### Config YAML
- 所有字段 `decodeIfPresent`（避免缺少 key 导致 crash）
- YAML key 必须与 struct property 名完全相同
  - ⚠️ **Yams 的 `YAMLDecoder` 不做键名转换**（源码核实：无 `keyDecodingStrategy`，`_KeyedDecodingContainer` 直接用 `key.stringValue` 查表）。写成 snake_case 的 key **不会报错，只会静默回退到默认值**——历史上 `max_retries`/`retry_delay_ms`/`timeout_ms`/`default_tier` 四个键因此从未生效（默认值恰好相同所以没暴露）。新增配置项后要确认它真的进了二进制：`strings .build/debug/utility | grep <propertyName>`
  - `modelProxy.clientAccel` / `clientText` 段例外：解码走 `ConfigTypes.decodeAny`（用 `Decoder.container(keyedBy: AnyKey.self)` 另开任意键名容器），每个键**同时登记 camelCase 与 snake_case 两种拼写**（修复上述历史失效且不破坏既有配置）
    - ⚠️ 不要用 `K(stringValue:)` 去试探键名：合成 CodingKeys 的 `init?(stringValue:)` 只认 case 名，传 snake_case 恒返回 nil，回退分支会变成死代码（实测过）

### RSS 内置日报

- 采集唯一实现是 `RSSManager.fetchAll()`（CLI `utility rss --fetch`）；`rss_daily.py` 只裸 SQL 读 `rss_item` 并回写 `is_read`，不重复实现抓取
- 日报由内部任务 `rss-daily` 驱动（`AppDelegate.updateRSSDailyTask()`），`cron` 为空时注册 `manual` 模式；启用时直接 register，禁止先 unregister
- `rss_filter` / `rss_digest` / `rss_summary` 三次 LLM 调用必须传 `extra_body={"thinking": {"type": "disabled"}}`：该 provider 不关闭思考时会耗尽 `max_tokens` 且单次调用可达数分钟
- LLM 只返回 JSON；标题格式、来源方括号、归档路径全部由 `rss_render.py` 确定性拼装
- 单篇抓取/总结失败降级为「已过滤条目」，不中断整次日报；LLM 未配置时退出码 1，不写空日报

### MCP 服务
- server.py / summarize.py / token_proxy.py 的入口 shim 在 `Sources/MCPScripts/` 根目录，实现在 `utility/services/{mcp,summarize,proxy}/`；脚本路径解析与 venv 定位统一由 `PythonScriptRunner` 提供（bundle → dev fallback）
- server.py 只保留入口 / HTTP endpoints / 项目与网页工具；记忆子系统在 `server_memory.py`，工具 schema 在 `server_tool_schema.py`，归档在 `server_archive.py`，技能扫描在 `server_skills.py`，共享常量/状态/工具在 `server_constants.py` / `server_state.py` / `server_utils.py`。`hot_memory` / `qdrant` 一律经 `server_state` 存取，禁止再引入模块级全局
- `token_proxy.handle_proxy` 只做编排：`_prepare_request` → `_apply_rewrites` → `_forward`，共享字段放在 `_ProxyState`
- 常驻进程（server.py / token_proxy.py）生命周期统一由 `PythonDaemon` 守护（启动/崩溃重启/健康检查/停止），`MCPProcessManager` / `TokenProxyManager` 负责业务决策（State 语义、EventBus 广播、复用探测、通知）
- 一次性执行（ast_extractor.py batch/单文件）走 `PythonScriptRunner.runCaptureOutput`（边读边存避免 pipe buffer 阻塞 + 超时 kill）
- **冷启动端口复用**（2026-08-21）：`start()` 默认先探测 `:port/health`（`status==ok` 且 `service==mino-brain` 才命中），已有健康 server（如历史孤儿进程 reparent 到 launchd 仍监听端口）则复用不重复 spawn，避免新 spawn 绑定失败触发端口竞争；`forceRestart()` 传 `reuseIfHealthy: false` 强制真正重启——若复用旧进程，新配置（port/qdrantPath/apiKey）会静默不生效
  - ⚠️ **只传 `reuseIfHealthy: false` 不够**（2026-09-21 修复）：**复用路径不设置 `process`**（保持 nil），`stopSync()` 的 `guard let proc = process` 因此直接 return，孤儿照常占着端口，新 spawn 仍旧绑定失败（uvicorn 报 `Errno 48` → exit 3），服务静默挂掉且不会自愈。现 `forceRestart()` 在 `process == nil`（即复用场景）时调 `terminatePortOccupant()` 按端口清理监听者。清理用 `/usr/sbin/lsof -ti:<port> -sTCP:LISTEN` —— **`-sTCP:LISTEN` 绝不能省**，不带时 `lsof -ti:<port>` 会连「连接该端口的客户端」一并返回（实测 8613 上返回正在走代理的 Clash Verge），照此 kill 即误杀。清理**只放在 `forceRestart()`，不进 `stopSync()`**——后者被 `stop()` 共用（app 退出 / 配置 disabled 两条路径），放进去会带来跨实例误杀
- **崩溃判据必须覆盖非零退出码**（2026-09-21 修复）：原先只看 `reason == .uncaughtSignal`，而 Python 未捕获异常、端口绑定失败、外部 kill 都退化为 `.exit`（非零退出码被忽略）→ 被当作正常退出静默置 `.stopped`，永不重试也不通知，「崩溃自动重启」实际只对 SIGKILL/SIGSEGV 生效。现改为 `reason == .uncaughtSignal || terminationStatus != 0`（主动停止仍由 `isStopping` 提前 return，不会误触发重启）
- server.py 所有配置从环境变量读取（`PythonScriptRunner.baseEnvironment()` 提供公共 AI/路径配置，脚本专属变量经 `environment(overrides:)` 注入——如 MCP_PORT/QDRANT_PATH/FASTEMBED_CACHE_PATH），实时构建，不解析 sys.argv；`QDRANT_PATH` 必须由 Swift 注入，Python 侧不再提供个人路径默认值
- 端口仅通过 `MCP_PORT` 环境变量传递（config mcp.port → env）
- 工具参数默认值经 `MCP_TOOL_DEFAULTS` 注入（config `mcp.toolDefaults` → env → `tool_defaults.load_defaults()` 合并内置表，**同名覆盖**）。默认值与工具 schema 的 `default` 同源（都取自 `arg_default()`），改了需重启 MCP 服务才生效——脚本专属 env 不走 `config.py`，两侧 env 名由契约脚本交叉断言
- skill 全文去重（`proxy_skill_dedup.py`，`modelProxy.skillDedupEnabled` → `MODEL_PROXY_SKILL_DEDUP`）：代理转发前把**逐字节相同**的 tool_result 文本第二份起换成 i18n 短提示、保留第一次——本项目 MCP skill 不是 Claude Code 原生 skill，吃不到官方那套去重。插入点在 `record_request_body` 之后、协议转换之前（记录层必须留原样，否则 `tool_output_log` 的度量标尺被自己毁掉）
- 响应注记（`proxy_response_note.py`，`modelProxy.responseAnnotationEnabled` → `MODEL_PROXY_RESPONSE_NOTE`）：代理在响应末尾追加一行 `{model} | 上下文 34.3 万 | 已执行: Bash 过滤/Skill 短提示`（模型名取自 message_start.message.model，清单由请求侧 output_filter/skill_dedup 统计生成；上下文取自上游 usage = input + cache_read + cache_creation，超 `modelProxy.contextWarnTokens`（默认 300000，`0` = 不提示）追加「建议新开会话」）。**注记会被模型复述**：它注入在 assistant 的 text block 内部、因而进历史，模型会自己生成出同样一行（铁证：`output_preview` 取自只收上游字节的 `collected_body`，里面却含注记行）→ 请求侧由 `strip_notes_from_messages()` 剥掉 assistant 里的注记行（挂 `modelProxy.responseAnnotationEnabled`，位置在 output filter 之后、协议转换之前；只动 assistant，判据由 `NOTE_APPLIED`/`NOTE_EMPTY` 派生）。`_injected` 硬闸仍保留，但只防「代理自己注两次」。**只加在最终文本回复上**——判据是最后一个 content block 的类型（`text` 才加），不取 stop_reason（那时 block 已 stop，来不及补 delta）；SSE 注入用「延迟 `content_block_stop`」：先缓存 stop，等下一个事件确认它是否最后一个，是则在前面补一个 delta（复用 index，不新建 block）。**无改写时也加**（显示 `{model} | 无改写`）——模型名才是这行的主信息，新会话头几轮不触发任何改写
- shell 工具输出瘦身（`proxy_output_filter.py`，`modelProxy.outputFilter` → `MODEL_PROXY_OUTPUT_FILTER`）：超长砍头尾（带自证标记）+ JSON 无损 minify，只对 shell 类工具生效（Read/Edit 是模型点名要的文件内容，截断等于损坏）。识别用**结构判据**（input 含 `command`）而非硬编码工具名——跨客户端名字各不相同（Gemini=`run_shell_command`、Cursor=`run_terminal_cmd`、Codex=`local_shell`），名单外的名字靠结构命中时记 `shell_tool_unlisted` 以便发现。插入点与 skill 去重同处、排其后
- summarize.py 作为内部任务注册到 TaskScheduler，以 `.sh(cmd)` 方式执行，所有 env 通过内联命令传入
- summarize.py 防重复触发：单实例文件锁 + 距上次完整总结 < 6h 跳过；mcp-summary 注册时
  enabled 直接 register（不先 unregister，避免清 last_fire 后 handleMissed 每天重复补触发）
- MEMORY_SERVER_URL 从配置 mcp.port 动态计算，确保总结流水线连对端口
- summarize.py 输入侧质量门（方案 E v5，细节见 notes 分类文章/工具使用/总结流水线审计与质量门方案.md §五）：规则层零 LLM 过滤低质记忆（截断占位/半词/过短等）+ LLM 3 票复核（3 全 drop 才 drop + fail-open），丢弃不标记 processed 保留下轮重评估
- summarize.py 输出侧主题归属过滤（2026-08-18，根治「正文偶然命中导致错位归并」）：`_file_topic_feature`（文件主题特征=相对路径+所有 H1 标题+首段）+ `_hit_topic_relevant`（组关键词 ≥1 命中主题特征才算相关，正文命中不算）→ `_decide_merge` 前过滤 hits，无主题相关候选判定新建；fallback_merge 用过滤后 hits；检索加权 `title_matched`（路径+首段命中优先）+ `_gen_new` 复用目录优先 + `_sanitize_new_dir` 共享主题词回退
- summarize.py 输出侧 merge 去重三层防线（2026-08-07 修复，真实跑 11 处重复段根因）：
  1. **上下文**：`SUMMARY_MERGE_LOOKBACK_CHARS=8000` + `_relevant_segments`（按 facts 与段体 difflib ratio 排序取 top 段，兜底文件头）——防大文件前 2K 截断看不到文件尾既有段，LLM 无从判断重复
  2. **机械兜底**：`_max_segment_similarity` 多级标题 `#{1,6}` 切段 + **覆盖率指标**（SequenceMatcher matched/len(new_content)），`SUMMARY_DUP_SIM_THRESHOLD=0.7` 超值判无增量跳过（0.8 ratio→0.7 覆盖率，实测 ScanTextUtil 重复 0.767）
  3. **LLM 语义判定**：`_gen_merge` prompt 第 8 条 no_increment——改写式重复（措辞不同但信息已被既有段覆盖）拦截
  - 契约：`_gen_merge` 正常返回 `{title,content,supersedes}` **不带 action**，仅 no_increment 带 `{"action":"no_increment","reason":...}`——防 `results.append({..., **item})` 中 action 覆盖局部变量污染 fallback_merge
  - 纯 ratio 阈值不可分：真重复（0.55-0.75）与正常段（README 模板 0.7-1.0）区间重叠 → 覆盖率 + LLM 语义双判定

### 项目扫描
- 新增语言支持：实现 `SymbolExtractor` 协议（含 `imports(from:filePath:)`）+ 一个 `LanguageImportResolver`，在 `ProjectScanner.init()` 与 `ImportResolverRegistry` 注册；AST 语种再加 parser 分支
- **`imports` 表是文件级依赖边**：`from_path / raw_target / to_path / is_external / kind / line / confidence / resolver`。提取器只产出 raw，`ResolutionContextBuilder` + `ImportResolverRegistry` 统一解析；解析不到时 `to_path=NULL`，绝不猜路径
- **AST 成功按结果 key 是否存在判断**，不能用 `symbols.isEmpty`：只有 import、没有符号的文件（如 `__init__.py`）不能被误判为 AST 失败
- 全量 `replaceScanResults` 与增量 `replaceFileExtraction` 都把 symbols/files/imports/failed_files 放在同一事务；删除子树时出边删除、入边保留 raw 并置 `resolver='stale'`
- **新增语言只改两处**：提取器（`imports`）+ 解析器（`LanguageImportResolver`）；DB、FileWatcher、MCP 查询不用动
- MCP `project_dependencies` 只做 1 跳：`outgoing` / `incoming` / `both`，缺 `imports` 表返回 `degraded` 而不是报错
- **提取流水线（三项优化）**：
  1. **A — 批量 AST**：扫描前统一调用 `ast_extractor.py --batch`，单次 subprocess 处理所有 AST 文件（Python ast + @babel/parser），避免逐文件启动子进程
  2. **C — 并发提取**：`DispatchQueue.concurrentPerform` 并行执行正则提取，NSLock 保护结果收集
  3. **D — 单事务原子替换**：`replaceScanResults()` 一次 `dbQueue.write` 内完成「清空全部表 → 写目录/文件/符号/包 → 重建 FTS」（2026-09-21 由 `clearAll()` + `batchWriteFiles()` 合并而来）
- **写入必须原子，清空与写入不能分开提交**：分开时遍历 + 提取期间（大项目数十秒）库对 MCP 读者是空的，检索一律返回「什么都没有」，模型会据此重复实现已有功能；中途被打断还会留下空库。**`clearAll()` 已删除，勿重新引入**——单独暴露可外部调用的清库方法会诱导后来者在扫描开头清库
- **模块根标记 `has_package_manifest` 的判定要在 includes 过滤之前**（清单文件不匹配任何 include 模式，放后面永远标不上），且**统一在遍历结束后回填**，不依赖枚举顺序；不要拿目录名比对清单文件名（恒为 false）
- 提取优先级：AST 脚本优先 → 正则提取器兜底 → 都失败则计数
- AST 连续 3 次失败后跳过（`failed_files` 表跨扫描计数），文件修改后自动重置
- `SwiftExtractor` / `JSTSExtractor` / `PythonExtractor` / `VueExtractor` / `JavaExtractor` / `KotlinExtractor` 用正则 + brace-depth tracking
- `.js` 文件始终启用 `@babel/parser` 的 `jsx` plugin 以支持 React Native/Expo
- `JavaExtractor` 提取 class/interface/enum/@interface + record + method + field，带关键字过滤和行内注解消耗
- `KotlinExtractor` 提取 fun/suspend fun + class/object/companion + val/var + typealias + fun interface/data object/annotation class，修饰符贪心通用匹配
- FTS5 + 同义词扩展：中文搜索先转同义词再 MATCH，降级到 LIKE
- MCP `project_search` 三状态响应：`exact`（自动选中）、`ambiguous`（同名多文件引导）、`no_match`（无结果）
- **符号向量缓存必须用稳定业务键，不能用 `symbols.id`**（2026-09-11 根治）：`symbols.id` 是
  GRDB AUTOINCREMENT，而 `ProjectScanner.scan()` 经 `replaceScanResults()` 先整体
  `DELETE FROM symbols` 再重插、`FileWatcher` 增量路径先 `DELETE FROM symbols WHERE
  file_path = ?` 再 `insertSymbols` —— **两条写入路径都会让同一符号拿到新 id**。
  边表 `symbol_embeddings` 曾以 id 为键，每次全量重扫即全部失效（实测 67438 行、
  有效 0 行、占 132MB），下一次向量检索被迫重算全部符号（实测 349s）。
  现键 = `sha1(file_path|name|kind|signature|doc_comment)`，即 **embedding 输入字段本身**：
  符号没变则重扫不重算，字段变了则键变、自然重算（键即输入，不存在脏读）。
  改这条务必守住：**键必须覆盖 embedding 的全部输入字段**，否则会返回陈旧向量
- 边表随查询做孤儿清理（`_prune_symbol_embeddings`），行数恒等于存活符号数；符号查询被
  `_MAX_VECTOR_ROWS` 截断时**必须跳过清理**，否则会误删没读到的那些行
- **内存向量缓存必须带 DB 变更指纹**（`_symbols_signature` = `(COUNT(*), MAX(id))`）：
  只按 db_path 缓存会让进程在 DB 被重扫后继续返回**已删符号的陈旧路径**、且新符号搜不到，
  直到进程重启。判据**不能用 DB 文件的 mtime/size** —— 库跑 WAL 模式，提交只写 `-wal`
  文件、主库文件纹丝不动（实测确认），mtime 判据会永远认为「没变」

### 检索性能约定（2026-09-11）
- **notes 关键词搜索禁止 subprocess**：`search_cold_layer` 曾对 notes 目录「每个文件 × 每个
  token」各起一个 `grep` 子进程 —— notes 有 454 个 .md，实测 2.4s(N=1) / 4.5s(N=2) /
  7.5s(N=4)，**随 token 数线性放大**，是 `recall` 的最大单项开销。改为 Python 原生
  `str.lower()` + `in` 一次读文件匹配全部 token；snippet 由 `_notes_snippet` 复刻
  `grep -inF -m 3` 的输出格式（`行号:行内容`）。等价性已对拍验证（文件集合 100% 一致，
  仅保留源行尾部空格的差异）
- **`_ensure_note_cache` 不做目录 mtime 快速跳过**：曾用「项目**根目录** mtime ≤ 缓存中
  .md 的**最大** mtime」判断，两者语义不同（根目录 mtime 只在直接子项增删时变化）——
  改深层已有文件会被漏判为「未变」而**返回陈旧结果**（正确性缺陷），根目录有增删则触发
  全量重扫。现始终 walk + 逐文件 diff（实测 453 个 .md 仅 7ms），只对真正变更的文件做
  embedding，且待嵌入文本合批推理（`_embed_in_batches`）；单文件的「删旧行 + 插新行」
  在同一事务内提交以保证原子性
- **查询嵌入走 `server_embed.embed_query` 共享 LRU**（容量 `EMBED_QUERY_CACHE_SIZE`，默认
  64，`0` 关闭缓存）：同一轮 agent 常对同一 query 并行调用多个检索工具，此前各自独立嵌入
  （单条约 45ms）。返回的 ndarray **就是缓存对象本身，调用方只读**
- mem0 内部使用它自己的 embedder，不经过 `embed_query`，那一路无法共享
- `recall` / `_contradiction_check_hot` 不再传 `rerank=True`：`MEM0_CONFIG` 未配置
  RerankerFactory 所需的 `reranker` 段，mem0 内部条件 `if rerank and self.reranker` 恒假，
  该参数是空操作，留着只会误导后来的读者

### 文件删除
- 重要文件：`osascript Finder delete` 移废纸篓
- 临时/自建文件：`rm`
- 删除后记录到 `~/.hermes/edit_history/[YYYY-MM-DD].md`

---

## 内存基线

| 指标 | 值 |
|------|-----|
| RSS（空闲） | ~76 MB |
| Physical footprint（空闲） | ~22.5 MB |
| Physical footprint（回收后） | ~18.9 MB |
| Heap nodes | ~44,770 / ~6.8 MB |
| 粘贴后稳定 | ~30.4 MB（不再增长） |
| 粘贴方案 | NSTask + osascript，零 NSAppleScript 内存分配 |

---

## 相关技能

- `macos-menu-bar-app` — 完整 macOS 菜单栏应用开发指南
- `macos-swift-appkit` — AppKit 模式与陷阱（NSTableView、pasteboard、CGEventTap 等）
- `macos-native-dev` — Swift + AppKit 基础开发模式

---

## MCP 进程 pipe buffer 阻塞事故（2026-07-25）

**现象**：MCP server.py 运行 4 天后 "失联"，端口 LISTEN 但 HTTP 请求全部超时。
**根因**：`_setup_logging()` 添加了 `StreamHandler(sys.stderr)`，但父进程（`PythonDaemon`，重构前为 MCPProcessManager 内联逻辑）在启动检测通过后停止读取 stderr pipe。几天后 pipe buffer 积满 64KB，任何 `logging.info()` 触发 `write()` 阻塞，uvicorn 主线程卡死，无法响应新连接。

**修复**：
- `Sources/MCPScripts/utility/services/mcp/server.py` / `utility/services/summarize/summarize.py`：移除 `StreamHandler()`，仅保留 `TimedRotatingFileHandler` 写文件日志
- `Sources/MCP/PythonDaemon.swift`：就绪信号检测通过后继续读取 pipe 并丢弃数据（双重保险）

**症状识别**：
- 进程旧（数天）、pipe stderr 有大量积压（`lsof -p PID` 看 SIZE/OFF 列）
- `sample PID` 显示主线程卡在 `write (libsystem_kernel.dylib)`
- 同一问题的 summarize.py 定时任务会永远不退出的挂起

**排查命令**：
```bash
lsof -p PID -a -d 2        # 看 stderr pipe 的积压字节数
sample PID 3 -file /dev/stdout | head -40  # 看调用栈
lsof -i :9001 -P           # 检查 MCP 端口
```
