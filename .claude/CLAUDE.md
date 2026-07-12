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
  - `SwiftExtractor` — 正则 + brace-depth，class/struct/enum/protocol/extension/func/var/let
  - `JSTSExtractor` — 正则，JS/TS/JSX/TSX 的 export function/class/const/interface/type
  - `PythonExtractor` — 正则，def/class/async def/UPPER_CASE 常量/装饰器
  - `VueExtractor` — 正则提取 `<script>` 块后委托 JSTSExtractor
  - `JavaExtractor` — 正则 + brace-depth，class/interface/enum/@interface/method/field + 注解追踪
  - `KotlinExtractor` — 正则 + brace-depth，fun/suspend fun/class/object/companion/val/var/typealias
- AST 脚本目录：`Sources/MCPScripts/ast_extractor.py`（Python 分发） + `ast-js/parse.mjs`（@babel/parser）
- `.js` 文件始终启用 `jsx` plugin 以支持 React Native/Expo
- Java/Kotlin 用 regex 提取（无 AST 脚本），共享 `RegexMatch` 辅助结构（`ExtractorProtocol.swift`）
- RegexMatch 原为 SwiftExtractor fileprivate，后提升至 ExtractorProtocol.swift internal 供所有提取器复用
- 注意：macOS NSRegularExpression 使用 ICU 语法，不支持嵌套字符类（如 `[\], ]` 非法）

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

### 拒绝猜测
- 看不懂某段代码为什么那样写时，先查 git log 看提交记录和 commit message
- git 记录看不出来时问用户，不要自己假设
- Bug 修复依赖现实调试信息，禁止靠猜测修改

## 未来规划
- 详见 `~/Documents/selfdata/notes/plan.md`（Utility & MCP 合并计划）
- MCP 移植、Agent 寄生模式、项目依赖图三条线
