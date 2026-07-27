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
- 二进制路径：`.build/debug/utility` 或 `.build/arm64-apple-macosx/debug/utility`
- 验证改动进二进制：`strings .build/debug/utility | grep keyword`

## 核心架构

### PanelManager
- 面板零引用 PanelManager，仅通过 EventBus 发 requestShow/Close 事件
- PanelManager 唯一订阅 + 唯一调 showPanel/closePanel
- 栈结构 = 激活面板，后入栈顶
- dispatchKey：栈顶→底遍历，handleKeyEvent 对自己关心的键全 return true 阻断下层
- didResignKey：用 DispatchQueue.main.async 等通知链完再读 NSApp.keyWindow（不用 didResignActive）
- Stage 独立不入栈

### EventBus
- 线程安全 pub/sub，枚举 key 对应多 handler
- 跨模块通信走 EventBus，禁止直接持有对方引用

### Request 封装
- 请求封装类必须用 `RequestConfig` struct 收束所有控制参数（timeout/retryCount/headers/body/method/url）
- 不要拆成单独函数参数
- OpenAIClient/CustomClient 保持不动——新工具不为兼容已有代码而扭曲设计

### i18n
- JSON-dict 模式，`L10n + Bundle.module`
- `%@`（String）、`%ld`（Int）
- `refreshAllTitles()` 模式刷新运行时语言

### Stage 拖放
- `NSPasteboard(name: .drag)` 拖放结束后不清空，changeCount 不变
- 检测新拖拽：mouseDown 快照 changeCount → mouseUp 对比
- 仅检查 pasteboard 内容（hasContent）会因残留数据误判
- 图片类型统一定义在 `PasteboardImageTypes.all`

### 符号提取（Scanner）
- `ProjectScanner` 全量扫描 + `FileWatcher` 增量扫描，结果写入 `.utility/deps.sqlite`
- 多语言提取器通过 `SymbolExtractor` 协议注册，以扩展名为 key
- **提取优先级**：AST 脚本优先 → regex 提取器兜底 → 都失败则计数
- AST 连续 3 次失败后跳过（`failed_files` 表计数），文件修改后自动重置
- 支持的提取器：
  - `SwiftExtractor` — 正则 + brace-depth，class/struct/enum/protocol/extension/func/var/let/actor/macro/precedencegroup/operator。修饰符组贪心通用匹配（final/@objc/lazy 等任意修饰符）
  - `JSTSExtractor` — 正则，JS/TS/JSX/TSX 的 export function/class/const/interface/type
  - `PythonExtractor` — 正则，def/class/async def/UPPER_CASE 常量/装饰器。matchTripleQuote 行内任意位置检测，stripInlineComment 感知三引号
  - `VueExtractor` — 正则提取 `<script>` 块后委托 JSTSExtractor
  - `JavaExtractor` — 正则 + brace-depth，class/interface/enum/@interface/record + method + field + 注解追踪。方法名 `[a-z]` → `[a-zA-Z_]`（构造器/测试方法），所有正则前缀消耗 @Override 等行内注解
  - `KotlinExtractor` — 正则 + brace-depth，fun/suspend fun/class/object/companion/val/var/typealias + value/inline/annotation class + fun interface/data object。修饰符组贪心通用匹配（override suspend operator 等多修饰符），companionRegex 支持命名 companion
- AST 脚本 — `--batch` 模式：单次 subprocess 调用批量处理所有 AST 文件（`ast_extractor.py --batch`），通过 stdin 传入 JSON 数组，缩短总耗时
- AST 脚本目录：`Sources/MCPScripts/ast_extractor.py`（Python 分发） + `ast-js/parse.mjs`（@babel/parser）
- `.js` 文件始终启用 `jsx` plugin 以支持 React Native/Expo
- Java/Kotlin 用 regex 提取（无 AST 脚本），共享 `RegexMatch` 辅助结构（`ExtractorProtocol.swift`）
- RegexMatch 原为 SwiftExtractor fileprivate，后提升至 ExtractorProtocol.swift internal 供所有提取器复用
- 注意：macOS NSRegularExpression 使用 ICU 语法，不支持嵌套字符类（如 `[\], ]` 非法）

### MCP 进程管理（MCPProcessManager）
- 通过 Python 子进程运行 server.py，stderr 输出检测 readiness（"Application startup complete"）
- `waitForReady()`：捕获 stderr，等到就绪信号后再开始 HTTP 健康检查（/health endpoint）
- 无启动超时杀进程——`terminationHandler` 处理真实崩溃，`isStopping` 标志防止 stop() 误触重启
- 环境变量由 `buildEnv()` 从 ConfigManager 实时读取，不缓存
- Python venv 路径 `~/.config/utility/mcp-venv/bin/python3`

### Token Proxy（token_proxy.py）
- aiohttp 反向代理，拦截 Claude Code API 请求记录 token 用量
- 路由 `/open/{path}` → 上游 `UPSTREAM_URL/{path}` 原样转发
- SSE 流式解析：`model` 在早期 chunk，`usage` 在最后 chunk，`stop_reason` 在 `delta.stop_reason`
- LLM usage field resolver：自动发现不同 provider 的 usage 字段路径，缓存到 SQLite `usage_field_cache` 表
- TokenProxyManager.swift：进程守护（lifecycleQueue + terminationHandler + health check）
- 健康检查必须 `async/await` + `@MainActor`，不能用 `DispatchSemaphore`（阻塞主线程导致 URLSession 回调死锁）
- `response_valid`：只有 `error` stop_reason 是无效，`max_tokens`/`end_turn`/`stop_sequence` 正常
- 费用估算已移除（不准确），`estimated_cost_usd` 置 0
- 用户设置 `ANTHROPIC_BASE_URL=http://localhost:8613/open/v1` 使请求经代理转发

### 共享 Python 日志模块（log_utils.py）
- `setup_logging(name)` 输出到 `~/.cache/utility/[name].log`
- 禁止 StreamHandler（pipe buffer 死锁），TimedRotatingFileHandler midnight 轮转 30 天
- server.py 和 summarize.py 已替换为使用此模块

### server.py（MCP Python 服务）
- mem0 热层（`Memory.from_config`）使用 Qdrant 本地存储 + fastembed 嵌入
- Qdrant 冷层独立集合 `knowledge_base`
- 热层初始化含 PostHog 遥测 SSL 握手，双重禁用：模块级 `posthog.disabled = True` + 环境变量 `MEM0_TELEMETRY=False`（后者更关键——mem0 的 `AnonymousTelemetry` 创建独立 PostHog 实例，不受 `posthog.disabled` 影响）
- 热层惰性初始化：不在模块加载阶段执行，由 `_ensure_hot_memory()` 在首次工具调用时触发
- `FASTEMBED_CACHE_PATH`（注意不是 `FASTEMBED_CACHE_DIR`）是 fastembed 读取的环境变量名，两处设置此变量：server.py 模块级 + Swift MCPProcessManager.buildEnv()
- `MEM0_CONFIG["embedder"]["config"]` 不支持 `cache_dir` 参数（`BaseEmbedderConfig` 不接受），依靠 `FASTEMBED_CACHE_PATH` 环境变量让 mem0 内部 fastembed 找到已有缓存
- `pyproject.toml` 未知，依赖见 `requirements.txt`

### OCR overlay
- 无文案提示
- 暗灰 0.5pt 边框
- 选区内半透明高亮 + 尺寸标注
- LSUIElement 下用 CGEventTap 拦截 ESC（passRetained + perform:afterDelay:）
- CGDisplayCreateImage 放后台线程
- 遮罩用 .nonactivatingPanel 不抢前台焦点

### 内存诊断
- `ps -p PID -o rss` → `leaks PID` → `vmmap --summary PID | grep "Physical footprint"`
- 多快照对比找增长趋势，heap 定位具体类
- utility 进程空闲时 physical footprint ~17MB baseline（AGENTS.md 有最新数据）

## 设计原则

### 最小暴露
- 类的内部实现用 private/fileprivate，仅对外暴露必要的 public/internal API
- 不在 AppDelegate 暴露内部属性供外部调用——自管生命周期

### 解耦
- 视图与逻辑分离：Service/Manager 不依赖 NSView/NSWindow/NSViewController
- PasteHelper、SelectedTextService、Translator、OCRService 全部无视图依赖

### 单⼀调用
- 核心逻辑不依赖 UI 上下文，可直接从 CLI 或无头模式调用

### Orchestrate 多 Agent 编排
- `PlanManager`（`Sources/CLI/PlanManager.swift`）— Plan 文件管理、状态机（pending→oa_task→review→oa_response→done/blocked）、session-id 持久化
- `OrchestrateCommand`（`Sources/CLI/OrchestrateCommand.swift`）— `utility orchestrate -d <project> --plan <name>` 子命令
- 数据路径：`<项目>/.utility/plans/<name>.md`（plan）+ `<项目>/.utility/artifacts/<plan>/`（运行时产物）
- Artifact 命名：`<plan>.<task-id>.<step>.<type>.md`（type: output/review/response）
- Active plan 通过 `.utility/plans/active` symlink 指向
- OA（Orchestrator Agent）通过 `--session-id <uuid>` 创建 + `--resume <uuid>` 恢复，跨 task 保持上下文
- Reviewer 用 `-p --no-session-persistence` 做干净一次性审查
- Prompt 必须是行动导向（"直接修改源代码"），不是报告导向（"写入分析到文件"）
- CLI 关键标志：`-d`（目录，注意根命令用 `--dir` customLong）、`--dry-run`（验证调度不启 agent）、`--list`（列出 plan）

### Claude Code CLI 关键标志（v2.1.193）
- `-p` 从 stdin 读 prompt（非位置参数），输出到 stdout
- `--session-id <uuid>` 创建命名会话；`--resume <uuid>` 恢复
- `--add-dir <dir>` 授予工具访问权限（无 `--dir`）
- `--no-session-persistence` 一次性用完不保存 session
- 原设计中 `--non-interactive` 不存在

### 拒绝猜测
- 看不懂某段代码为什么那样写时，先查 git log 看提交记录和 commit message
- git 记录看不出来时问用户，不要自己假设
- Bug 修复依赖现实调试信息，禁止靠猜测修改

## 未来规划
- 详见 `.claude/plans/agent-orchestrate.md`（Orchestrate 设计文档）
- Orchestrate 已实现 + 真实测试验证通过（2026-07-15）：4 task 全部实际修改源代码（2 新建 + 10 修改文件），action 导向 prompt 方案确认有效。Prompt 必须"直接修改源代码"而非"将分析写入文件"
- MCP 移植、Agent 寄生模式已完成；项目依赖图持续维护
