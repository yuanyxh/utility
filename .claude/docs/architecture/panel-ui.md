# 面板与 UI（PanelManager / EventBus / 热键 / Stage / OCR）

> 从 `.claude/CLAUDE.md` 分层迁出（2026-10-18），内容逐字保留。
> 修改对应模块前先读本文件；CLAUDE.md 只保留必须遵守的不变量。

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
- utility 进程空闲时 physical footprint ~17MB baseline（AGENTS.md 有最新数据）
