# 零调用 MCP 工具评估

审查 06 报出 8 个七天零调用工具。本期核实源码与运行中服务的工具清单不一致，结论按源码口径给出。

- 源码 `build_tools()` 15 个工具；运行中 `tools/list` 28 个工具。
- `proj_init`、`proj_mem`、`skill_creator`、`token_analysis` 在 `src/agent_gateway/` 中检索为 0 次命中，只存在于 `tests/eval` 历史数据集。
- 运行中多出的 4 个来自已安装的旧 wheel，重启 MCP 后消失，无需下线动作。

## 结论

| 工具 | 结论 | 依据 |
|---|---|---|
| `catch_up` | 保留 | 时间语义（刚做/上次/遗留）无等价替代，`recall` 面向主题 |
| `forget` | 保留 | 记忆删除的唯一入口，低频但不可替代 |
| `memory_expand` | 观察到 2026-12-09 | 上期约定观察满 30 天，未到期不决策 |
| `set_memory_processed` | 保留 | 治理位操作，供归档与摘要流程调用 |
| `proj_init` | 不处理 | 源码已移除，重启即下线 |
| `proj_mem` | 不处理 | 源码已移除，重启即下线 |
| `skill_creator` | 不处理 | 源码已移除，重启即下线 |
| `token_analysis` | 不处理 | 源码已移除，重启即下线 |

## 后续

- 2026-12-09 复盘 `memory_expand`：仍为 0 调用则下线，改动 `server_tools.py` 与 `server_tool_schema.py` 两处。
- 重启 MCP 后复查 `tools/list` 应为 15 个；多出的工具说明安装副本未更新。
