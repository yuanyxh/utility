# AGENTS.md — Utility Project

> 为 Hermes Agent 提供项目上下文、开发约定、内存数据参考。每次会话自动注入。

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
| `ProjectScanner` | 多语言符号提取器注册 → 批量 AST → 并发正则 → 批量 SQLite ↔ FTS5 索引 |
| `SwiftExtractor` / `JSTSExtractor` / `PythonExtractor` `VueExtractor` / `JavaExtractor` / `KotlinExtractor` | 各语言 SymbolExtractor 实现，正则提取函数/类/常量/注解 |
| `ManifestParser` | Package.swift / package.json / pyproject.toml 依赖解析 |
| `FileWatcher` | FSEvents 文件监控 + 3s 防抖增量更新 |
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
- 二进制：`.build/debug/utility` 或 `.build/arm64-apple-macosx/debug/utility`
- 验证改动进二进制：`strings .build/debug/utility | grep keyword`

### i18n
- JSON-dict 模式，`L10n + Bundle.module`
- `%@`（String）、`%ld`（Int）
- `refreshAllTitles()` 模式刷新运行时语言

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

### MCP 服务
- server.py / summarize.py / token_proxy.py 在 `Sources/MCPScripts/` 目录，脚本路径解析与 venv 定位统一由 `PythonScriptRunner` 提供（bundle → dev fallback）
- 常驻进程（server.py / token_proxy.py）生命周期统一由 `PythonDaemon` 守护（启动/崩溃重启/健康检查/停止），`MCPProcessManager` / `TokenProxyManager` 负责业务决策（State 语义、EventBus 广播、复用探测、通知）
- 一次性执行（ast_extractor.py batch/单文件）走 `PythonScriptRunner.runCaptureOutput`（边读边存避免 pipe buffer 阻塞 + 超时 kill）
- **冷启动端口复用**（2026-08-21）：`start()` 默认先探测 `:port/health`（`status==ok` 且 `service==mino-brain` 才命中），已有健康 server（如历史孤儿进程 reparent 到 launchd 仍监听端口）则复用不重复 spawn，避免新 spawn 绑定失败触发端口竞争；`forceRestart()` 传 `reuseIfHealthy: false` 强制真正重启——若复用旧进程，新配置（port/qdrantPath/apiKey）会静默不生效
- server.py 所有配置从环境变量读取（`PythonScriptRunner.baseEnvironment()` 提供公共 AI/路径配置，脚本专属变量经 `environment(overrides:)` 注入——如 MCP_PORT/QDRANT_PATH/FASTEMBED_CACHE_PATH），实时构建，不解析 sys.argv
- 端口仅通过 `MCP_PORT` 环境变量传递（config mcp.port → env）
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
- 新增语言支持：实现 `SymbolExtractor` 协议 + 在 `ProjectScanner.init()` 中注册
- **提取流水线（三项优化）**：
  1. **A — 批量 AST**：扫描前统一调用 `ast_extractor.py --batch`，单次 subprocess 处理所有 AST 文件（Python ast + @babel/parser），避免逐文件启动子进程
  2. **C — 并发提取**：`DispatchQueue.concurrentPerform` 并行执行正则提取，NSLock 保护结果收集
  3. **D — 批量写入**：`batchWriteFiles()` 单事务写入所有文件结果（DELETE old → INSERT symbols → UPDATE file → handle failed_files）
- 提取优先级：AST 脚本优先 → 正则提取器兜底 → 都失败则计数
- AST 连续 3 次失败后跳过（`failed_files` 表跨扫描计数），文件修改后自动重置
- `SwiftExtractor` / `JSTSExtractor` / `PythonExtractor` / `VueExtractor` / `JavaExtractor` / `KotlinExtractor` 用正则 + brace-depth tracking
- `.js` 文件始终启用 `@babel/parser` 的 `jsx` plugin 以支持 React Native/Expo
- `JavaExtractor` 提取 class/interface/enum/@interface + record + method + field，带关键字过滤和行内注解消耗
- `KotlinExtractor` 提取 fun/suspend fun + class/object/companion + val/var + typealias + fun interface/data object/annotation class，修饰符贪心通用匹配
- FTS5 + 同义词扩展：中文搜索先转同义词再 MATCH，降级到 LIKE
- MCP `project_search` 三状态响应：`exact`（自动选中）、`ambiguous`（同名多文件引导）、`no_match`（无结果）

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

## 版本

当前：**1.1.0**

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
- `Sources/MCPScripts/server.py` / `summarize.py`：移除 `StreamHandler()`，仅保留 `TimedRotatingFileHandler` 写文件日志
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
