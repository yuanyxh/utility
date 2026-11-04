# 多终端（TmuxBackend + SwiftTerm）

> 从 `AGENTS.md` 分层迁出（2026-11-03），内容逐字保留。
> 修改终端模块前先读本文件。

- **只保留 tmux 后端**（`-L utility` 私有 socket、`-f /dev/null`），`TmuxBackend` 是唯一实现；screen/local 已删除，**禁止再加降级**
- tmux 未安装时：`resolvedBackend()` 只返回 nil（无副作用），由 `createSession` / `showWindow` 显示窗口内空状态文案 + 一次系统通知（`didReportMissingTmux` 去重）；空状态文案由 `showEmptyState(message:)` 传入，`reload()` 会重置为默认文案，所以提示必须在 `reload` 之后设
- `terminal-sessions.json` 的 `backend` 字段**必须继续写**（`TmuxBackend.storageName`）：旧版结构把它当必填，缺键会让旧版整数组解码失败、静默丢会话恢复；新版解码用 `decodeIfPresent ?? "tmux"`
- 会话用 `new-session -d` 建好，窗口只做 `attach-session -d -t`；App 退出等于 detach，重开按 `terminal-sessions.json` 恢复
- 恢复会话先 `window.layoutIfNeeded()` 并把视图预置为目标尺寸再 attach，避免首帧按默认尺寸渲染后再缩放
- 通知只认程序显式发出的 OSC（Claude Code 在 `TERM_PROGRAM=ghostty` 下发 OSC 777），**不要按输出静默推断任务结束**：长时间 Bash 误报，TUI 流式输出刷屏
- ⚠️ **tmux 3.8 会把 pane 内的 `TERM_PROGRAM` 改写成 `tmux`**（`TERM_PROGRAM_VERSION=3.8`），即使 server 环境是 ghostty；Claude 不认识 `tmux` 就不发 OSC 777，通知整条链路静默失效。`new-session` 必须用 `env TERM_PROGRAM=ghostty <shell>` 启动，已有会话不会自动修复，需重建或手动 export
- 不做未读计数与侧栏角标：OSC 原样转发（同 Ghostty）。只在两种情况下抑制——通知到达时用户正在看该会话，或最后一段输出是在聚焦状态下到达的（`lastSeenOutputAt >= lastOutputAt`，即离开前已看过，覆盖 Claude Code 延迟 60s 发出的通知）。输出时间戳只用于这个判据，不代表任务结束
- **必须保留 SwiftTerm 默认的 mouse reporting**：Claude 全屏 TUI 的滚轮滚动依赖终端转发鼠标事件（官方 issue #75143）；关掉后滚轮会被编码成 ↑/↓（`alternateScrollMode`），被 TUI 当成输入历史。拖选冲突用 `TerminalDropView.mouseDown` 临时挂起 `allowMouseReporting`（mouseUp 恢复，滚轮事件带自愈）解决——按下即本地选择，滚轮仍转发
- 会话创建时喂 `ESC[?1007l` 关掉 alternate scroll：程序没开 mouse reporting 时滚轮不再变 ↑/↓（不会污染输入历史）；代价是 alternate screen 本身没有本地历史，滚轮保持无效
- 非精确滚轮每 notch SwiftTerm 只发 **1 个** mouse report（`WheelReportBudget.requestedReports`），全屏 TUI 滚得极慢；`TerminalDropView` 的本地 scrollWheel 监听（`scrollWheel` 非 `open`，无法覆写）对非精确事件重复转发 `reportsPerNotch = 3` 次（预算 burst 6 / 100 reports/s）
- 默认 regular 应用有主菜单（`app.hideDockIcon: true` 时为 accessory，无主菜单），⌘←/⌘→ 由 `EditingShortcutRouter` 直接路由到 `moveToBeginningOfLine:` / `moveToEndOfLine:`（⇧ 用 `…AndModifySelection:`）；**方向键判断必须放在 `charactersIgnoringModifiers` 之前**（输入法下可能为 nil）；`TerminalDropView` 覆写这两个方法转给 SwiftTerm 的 `doCommand(by:)` 发 Home/End，路由前先 `responds(to:)` 否则 `sendAction` 直接抛异常
- **窗口「自己隐藏」的日志证据是热键**：实测 debug.log 里每次 `resigned key visible=false` 都紧跟 `window hidden by hotkey`，没有任何系统隐藏路径。默认热键按用户偏好保持 `option+space`——该组合与输入法/不间断空格冲突，输入时可能被 Carbon 全局热键截获导致窗口收起；排查先 grep `hidden by hotkey`，不要臆测系统行为
- **点击顶部菜单栏不是窗口隐藏**：accessory 模式（`app.hideDockIcon: true`）没有主菜单，激活时菜单栏仍显示上一个 app（访达等）的菜单，点击菜单栏任意区域/图标会激活对应 app；日志表现为 `active=false` + `frontmost=<该 app>`，窗口本身 `visible=true`，只是被该 app 的窗口盖住。`terminal.alwaysOnTop`（默认 false）控制窗口是否用 `.floating` 层级避免被盖住；改它需要重启
- 终端窗口失活后的兜底只在 accessory 模式生效：`wantsVisible` 意图标志（`showWindow` 置 true，热键隐藏/用户关闭置 false），`windowDidResignKey` 0.4s、`didResignActive` 0.3s/1.0s 各检查一次，命中 `wantsVisible && (!isVisible || NSApp.isHidden)` 就 `unhideWithoutActivation` + `orderFront`（不抢焦点）；regular 下直接返回，否则 `Cmd+H` 会被自动弹回；`isMiniaturized` 的窗口一律跳过，否则 `Cmd+M` 会被 0.4s 后拉回
- 面板显示时若一个会话都没有，`showWindow` 直接 `createSession()`，避免空面板无输入对象；侧栏 `allowsEmptySelection = false`，点空白不会丢选中样式
- 同一会话 3 秒内最多弹一条系统通知（`lastNotification`）：prompt 可能把同一事件发两遍，终端会看到两个横幅
- **tmux 3.8 会把 OSC 777 转发给客户端**（实测），通知直接走 SwiftTerm 的 `observeOscEvents`，不要再用 `pipe-pane`（否则一次事件弹两条）；`set -g mouse on` 让普通 shell 滚轮进 copy-mode，`terminal-features xterm-256color:RGB` 开真彩，`allow-passthrough on` 留给支持 DCS 透传的程序
