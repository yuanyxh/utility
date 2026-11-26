# 生产部署验证（Utility 1.2.44，2026-11-26）

验证 1.2.44 新增的 `workspace.agentCli` 与工作区服务卡在生产环境的行为，结论为配置生效、状态与 tmux 事实一致。

## 环境

- `/Applications/Utility.app` 1.2.44，进程 pid 80229，22:48 启动
- 网关 9001（`gw-yuanyxhdeMacBook-Pro`），`agent-gateway.yaml` 无 mesh 段
- 生产 `~/.config/utility/config.yaml:345` 设 `workspace.agentCli: /opt/homebrew/bin/claude`
- 默认模板 `default-config.yaml:391` 仍为空字符串

## 结果

| 项 | 结果 |
|---|---|
| 安装版本与二进制 | 1.2.44，二进制含 `agentCli`、`start_command` 标记 |
| 卡片解析 | 10 张卡 `start_command` 全部为 `/opt/homebrew/bin/claude`、`startable=true` |
| 主会话启动命令 | tmux `utility-term-03ea0393` 的 pane 启动命令为 `/bin/zsh -lc /opt/homebrew/bin/claude` |
| 状态一致性 | 仅 utility 卡 `ready`，其余 9 张 `offline`；与 tmux 中唯一会话对应 |
| 心跳 | `heartbeat_at` 连续推进 14:50:06Z → 14:50:36Z，30 s 周期，TTL 120 s |
| 启动语义 | `service_start` ready 卡返回 `already_running` |
| 探测 | `service_probe` 返回 `ready`、`local=true` |
| 包内资源 | `utility_utility.bundle` 含 `default-config.yaml`、`en.json`/`zh-Hans.json`、`Gateway/agent_gateway-0.1.0-py3-none-any.whl`、`entries.json`、`env.json`、`prompts` |
| 安装 wheel | `~/.config/utility/mcp-venv/.../agent_gateway` 时间戳 22:48，随部署更新 |

## 现状

- `terminal-sessions.json` 只剩 utility 一条主会话记录（id `03ea0393`，2026-11-05 创建）
- 其余 9 个工作区无 tmux 会话，卡片 `offline` 如实反映；`startable=true` 表示可由 `service_start` 拉起

## 未覆盖

- 未对 offline 卡执行真实 `service_start`（会拉起 9 个 `claude` 进程）
- 未启用跨机 peers（token 空、仅回环）
