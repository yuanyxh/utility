# 面板与 UI（PanelManager / EventBus / 热键 / Stage / OCR）

> 从 `.claude/CLAUDE.md` 分层迁出（2026-10-18），内容逐字保留。
> 修改对应模块前先读本文件；CLAUDE.md 只保留必须遵守的不变量。

### PanelManager
- 面板零引用 PanelManager，仅通过 EventBus 发 requestShow/Close 事件
- PanelManager 唯一订阅 + 唯一调 showPanel/closePanel
- 栈结构 = 激活面板，后入栈顶
- dispatchKey：栈顶→底遍历，handleKeyEvent 对自己关心的键全 return true 阻断下层
- didResignKey：用 DispatchQueue.main.async 等通知链完再读 NSApp.keyWindow（不用 didResignActive）
- **向焦点控件定向粘贴必须走响应链**：`finishPaste` 直接 `sendAction(paste:, to: firstResponder)` 会给不响应 `paste:` 的视图（终端/WebView）抛 unrecognized selector，进程 SIGABRT（2026-11-12 翻译回车粘贴闪退）；用 `tryToPerform` 沿链查找，兜底 `sendAction(to: nil)`
- Stage 独立不入栈
- **自动弹出也必须走 requestShow**（context 带 `auto`），不能直接 `orderFront`：直接显示的面板不在栈里，`dispatchKey` 分发不到，ESC 失效，`hasVisiblePanel` 也会漏判（2026-10-29 知识面板 showAuto 修复）
- **常驻窗口必须注册 `AppWindowRegistry`**（终端 / 配置 / Stage）：`hideIfEmpty` 用 `hasVisibleWindow` 决定是否 `NSApp.hide`，漏注册会让常驻窗口在最后一个面板关闭时被连带隐藏（2026-10-29 Stage 修复）

### 应用形态与主窗口
- 默认 regular（Dock 图标 + 主菜单）；`app.hideDockIcon: true` 时终端窗口关闭后切 `.accessory`（移除 Dock 图标与应用菜单栏），窗口打开或最小化时切回 regular，保证菜单栏与 Cmd+Tab 可用
- `AppActivation` 是激活策略唯一入口：`mainWindowActive` 由 `TerminalManager.showWindow` 置 true、热键隐藏与 `windowShouldClose` 置 false；改策略一律走 `AppActivation.apply()`
- 主菜单由 `AppMainMenu.install()` 构建，语言切换时 `rebuild()`；`Cmd+,` 与菜单栏「设置…」都打开 `SettingsWindowController.shared`
- 启动按 `app.showTerminalOnLaunch && terminal.enabled` 展示终端窗口；点 Dock 图标走 `applicationShouldHandleReopen` 恢复终端或前置已有窗口
- regular 下 `TerminalWindowController` 不再在失焦后自动恢复窗口，否则 `Cmd+H` 会被 1 s 后弹回；终端窗口 styleMask 含 `.miniaturizable`
- 设置窗口是常驻窗口，必须注册 `AppWindowRegistry`，否则最后一个面板关闭时会被 `hideIfEmpty` 连带隐藏
- 设置保存走 `ConfigManager.apply(_:)`：重编码整份 YAML、写 `config.yaml.bak`、超过 1 MB 或会丢未知顶层键时拒绝写入；YAML 注释会丢失

### EventBus
- 线程安全 pub/sub，枚举 key 对应多 handler
- 跨模块通信走 EventBus，禁止直接持有对方引用

### Request 封装
- 请求封装类必须用 `RequestConfig` struct 收束所有控制参数（timeout/retryCount/headers/body/method/url）
- 不要拆成单独函数参数
- OpenAIClient/CustomClient 保持不动——新工具不为兼容已有代码而扭曲设计

### i18n
- 唯一源 `Sources/Resources/<lang>.json`；`L10nKeys.swift` 由 `scripts/gen-l10n.py` 生成，禁止手改
- 占位符 `{name}` / `{name:d}` / `{name:.Nf}`，按名一次性替换（替换值不会被二次扫描）
- 语言解析、逐 key 回退、渲染都在 `L10n.swift`；`refreshAllTitles()` 模式刷新运行时语言

### Stage 拖放
- `NSPasteboard(name: .drag)` 拖放结束后不清空，changeCount 不变
- 检测新拖拽：mouseDown 快照 changeCount → mouseUp 对比
- 仅检查 pasteboard 内容（hasContent）会因残留数据误判
- 图片类型统一定义在 `PasteboardImageTypes.all`

### 全局热键（HotkeyManager）
- `keyCodeMap` 必须**完整覆盖 26 个字母 + 常用符号**：表里缺哪个键，配了它的热键就 `parse` 失败，弹「热键解析失败」通知 —— 且**只影响用户自己配的那个键**，看起来像配置写错了
  - 实测踩坑（2026-10-16）：知识面板默认热键 `option+k` 部署后立刻报解析失败，根因是表里只列了 c/d/f/v/s/a/x/z/w/q/e/r/y/t **14 个字母**，没有 `k`。现补齐 60 条并与 `kVK_ANSI_*` 逐项核对
- `parse` 的 keyCode 用 `Optional`，**不能用 0 表示「未匹配」**：`a` 的 ANSI 键码就是 0，旧的 `guard keyCode != 0` 让 `cmd+a`/`option+a` 一律解析失败
- 热键只在 `AppDelegate.registerAllHotkeys()`（启动时调一次）注册，**配置重载不重注册** —— 改热键要重启 app
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
- utility 进程空闲时 physical footprint ~17MB baseline（`overview.md` 有最新数据）

### NSTableView
- `selectionHighlightStyle = .none` + manual frame + cell 子类 layout
- 避免 NSTableView 缓存 rowView 导致无限内存

### 粘贴
- osascript 子进程（避免 NSAppleScript 运行时内存泄漏）
- 浏览器 120ms / 原生 50ms 延迟
- CGEventPost fallback 双路保障
- `didActivateApplicationNotification` 激活检测

### i18n 补充
- 本仓 JSON 只保留 Swift 用到的键；`mcp` / `proxy` 已随 RSS 上移全部迁到 gateway
- 语言无关的路径/默认值常量（季度目录名、知识卡片目录名、Clash 节点名）两语言取同值，避免切换语言后路径漂移
