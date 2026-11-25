# 生产部署验证（Utility 1.2.42，2026-11-25）

## 环境

- `/Applications/Utility.app` 1.2.42，网关 9001（`gw-yuanyxhdeMacBook-Pro`），`agent-gateway.yaml` 无 mesh 段（默认：启用、bind 回环、token 空）

## 结果

| 项 | 结果 |
|---|---|
| `/mesh/health`、`/mesh/services` | 正常，10 个真实工作区卡全部 `ready` |
| 状态驱动 | 10 个工作区主会话均在 tmux 中存活，卡状态与之一致 |
| 注册默认值 | 无 `protocol` 配置的工作区仍注册（`startable=false`、`start_command=null`） |
| 心跳 | 30s 周期刷新，时间戳持续前进 |
| MCP 工具 | `service_list/probe/inbox/start/heartbeat/...` 均可用 |
| 状态校验 | `service_heartbeat(status="bogus")` → `invalid_message`，卡状态未被破坏 |
| 启动语义 | ready 卡 `service_start` → `already_running` |
| 探测 | 存在 → `ready`；不存在 → `unknown` |
| CLI 自动端口 | `runtime/mcp.json` 由应用写入，`utility workspace status/list` 直连 9001 成功 |
| 负 limit | `workspace inbox --limit=-1` 退出 0（不再崩溃） |

## 未覆盖

- 生产启用跨机 peers（当前无 peers，token 空、仅回环）
- GUI 内 `workspace enable` 热更新（未改生产 workspaces.json）
