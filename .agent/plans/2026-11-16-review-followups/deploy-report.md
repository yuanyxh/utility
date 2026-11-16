# 生产部署验证（2026-11-16 12:44）

用户部署 `/Applications/Utility.app` 1.2.19 后的只读复核。

## 证据

| 项 | 结果 | 级别 |
|---|---|---|
| 应用版本 | `CFBundleShortVersionString = 1.2.19` | L1 |
| 进程 | utility 27555 → token_proxy 27586、mcp.server 27587，12:44:57 启动 | L1 |
| 端口 | 9001 → 27587，8613 → 27586；两者 `/health` 均 ok | L2 |
| 库版本 | `memory_graph.sqlite` `user_version=4` | L2 |
| 自动备份 | `memory_graph.pre-v4-20261116124459.sqlite`（96M） | L1 |
| 边类型 | 6 类：fact 48857、derived_from 47268、episode 5823、relates 338、supersedes 95、disputes 9 | L2 |
| 启动日志 | 清理陈旧锁 → 冷层初始化 → consolidate 调度装载，无异常 | L2 |
| 部署包含修复 | `_backup_before_upgrade`、`_hot_retry_delay`、`_consume_future`、`_external_reason`、`unresolved_external` 均命中 | L1 |
| 热层写入 | `remember_batch` 3 条全部 hot 层成功 | L3（写入路径） |

## 工具数量口径

`tools/list` = 28 = 15 内置 + 13 用户技能。

- 内置：`build_tools()` 返回 15。
- 技能：`server_skills.scan_skills()` 扫描 `/Users/yuanyxh/Documents/selfdata/notes/MCP/Skills`，得到 `proj_init`、`proj_mem`、`skill_creator`、`token_analysis`、`devflow_start` 等 13 个。
- 结论：此前「旧 wheel 残留」判断错误，已在 `tool-review.md` 更正。

## 待办

- `VERSION` 1.2.19 未提交（用户打包自增），等授权。
- `scripts/memory_edges_v4.py` 不随 wheel 分发，属运维脚本，仅在 gateway 仓可用。
