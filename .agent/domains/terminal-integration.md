# 领域：终端集成

## summary

在 GUI 应用中嵌入终端视图，并把会话托管给外部复用器，处理输入编码、鼠标报告、通知与滚动语义。

## applies_when

项目内嵌终端视图（如 SwiftTerm）或托管 tmux/screen 会话。

## core_concerns

1. **终端能力由后端决定**：bracketed paste、真彩、鼠标 copy-mode、OSC 透传要逐项确认，不假设。
2. **输入编码**：`ESC[?1007l` 关闭 alternate scroll；mouse reporting 默认保留给 TUI。
3. **滚动预算**：SwiftTerm 每个 classic notch 只发 1 个 mouse report，需要显式放大。
4. **通知通道**：只认程序显式 OSC（9/777），不按输出静默推断任务结束。
5. **会话生命周期**：App 退出等于 detach；恢复按 id 重新 attach，会话名带命名空间前缀。
6. **进程与权限**：GUI 进程 PATH 受限；由 App 拉起的服务可能继承受限的网络身份。

## questions

- 会话命名空间与 socket 如何隔离？
- 客户端异常退出时是结束会话还是重新 attach？
- 通知抑制判据是什么（聚焦、已读、去重）？

## research

- tmux 3.8：`mouse on` 进 copy-mode、`terminal-features xterm-256color:RGB` 真彩、`allow-passthrough on`，OSC 777 会转发给客户端（实测）。
- SwiftTerm 限制：`scrollWheel` 非 open，不能跨模块覆写，只能本地 monitor 重放。

## generates

后端能力核对表、输入编码规则、通知抑制规则、会话恢复流程。

## verify

- 普通 shell 与全屏 TUI 两条路径分别验证滚动与鼠标。
- 通知在聚焦、离开、去重三种场景各有断言。

## pitfalls

- 在老旧复用器（screen 4.00）上堆 OSC 日志抓取与看门狗补丁。
- 关掉 `allowMouseReporting` 后 TUI 无法点击。
- 用 `String(format:)` 或菜单快捷键处理无主菜单应用的 ⌘C/⌘←。
- 删除 screen/local 后忘记移除对应的持久化字段与文档。
