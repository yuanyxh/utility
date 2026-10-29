# 项目状态

## 当前目标

终端模块已收敛为 tmux 单一后端（commit 61bf360），等待后续需求。

## 进行中

- 无

## 最近完成（2026-10-29）

- 删除 ScreenBackend / LocalBackend / screen 日志 tap，终端只走 tmux
- tmux 缺失时窗口内空状态提示 + 一次系统通知，禁止降级
- `TerminalSession` 与 backend 解耦，`TmuxBackend` 为唯一实现
- `terminal-sessions.json` 继续写 `backend` 字段，兼容旧版本解码
- 合入窗口失焦兜底、⌘←/→、滚轮加速、配置编辑器按可见行高亮

## 阻塞

- 无

## 基座生成记录（2026-10-29）

已生成：`profile.yaml`、`status.md`、`decisions.md`、`lessons.md`、`memory/README.md`、
`environment.md`、`research.md`、`domains/`、`knowledge/README.md`、`.agent/rules/`、`.claude/skills/`。

未生成：无。领域最低必问项已按现有仓库事实覆盖。

外部事实来源与查询时间：见 `research.md`（2026-10-29，本机命令输出）。
