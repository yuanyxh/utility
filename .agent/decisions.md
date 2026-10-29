# 决策记录

## 2026-10-29 终端后端只保留 tmux

**背景**：screen 4.00.03 缺少 bracketed paste、真彩与鼠标 copy-mode，为其维护了日志 tap、
0700 目录、`-X` 竞态处理与附着看门狗等补丁。

**决策**：删除 `ScreenBackend` / `LocalBackend` / `TerminalNotificationTap`，只保留 `TmuxBackend`；
tmux 未安装时窗口内提示 + 一次系统通知，不降级。

**理由**：补丁数量已超过底座本身的价值；tmux 原生覆盖滚轮、多行粘贴、真彩与 OSC 转发。

**影响**：`terminal.backend` 配置项删除；`terminal-sessions.json` 的 `backend` 字段保留并固定写 `tmux`。

## 2026-10-29 抽象随实现数量收缩

**决策**：删除 `TerminalBackend` 协议、`TerminalBackendKind` 枚举与 `TerminalBackends` 工厂，
`TmuxBackend` 成为唯一具体类型；`TerminalSession` 不再持有 backend。

**理由**：单实现抽象没有注入点，测试也无法替换，属于负债。

## 2026-10-29 验证证据分级

**决策**：采用 TST-07 三级证据（存在性 / 行为 / 端到端），汇报必须标注级别。

**理由**：当天曾把 `swift build` 通过、`strings` 命中与日志关键字当作「验证通过」，
但 UI 行为从未实测，导致用户承担了全部测试成本。

## 2026-10-29 基座补齐

**决策**：为 utility 生成 `.agent/` 基座，`quality.test_level = basic`。

**理由**：此前只有 `.claude/`，没有 lessons/status/environment 可沉淀，验证能力也无处声明。
