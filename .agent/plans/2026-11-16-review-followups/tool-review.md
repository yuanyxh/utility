# 零调用 MCP 工具评估

审查 06 报出 8 个七天零调用工具。本期核实源码与运行中服务的工具清单不一致，结论按源码口径给出。

- 源码 `build_tools()` 15 个内置工具；运行中 `tools/list` 28 个 = 15 内置 + 13 用户技能。
- 13 个技能由 `server_skills.scan_skills()` 扫描 `~/Documents/selfdata/notes/MCP/Skills` 生成，名字来自各 SKILL.md frontmatter，与内置工具无源码交集。
- `proj_init`、`proj_mem`、`skill_creator`、`token_analysis` 在 `src/agent_gateway/` 检索为 0 命中，它们出现在 `tools/list` 中是因为技能目录里有同名技能，不是旧 wheel 残留（2026-11-16 部署后复核确认）。

## 结论

| 工具 | 结论 | 依据 |
|---|---|---|
| `catch_up` | 保留 | 时间语义（刚做/上次/遗留）无等价替代，`recall` 面向主题 |
| `forget` | 保留 | 记忆删除的唯一入口，低频但不可替代 |
| `memory_expand` | 观察到 2026-12-09 | 上期约定观察满 30 天，未到期不决策 |
| `set_memory_processed` | 保留 | 治理位操作，供归档与摘要流程调用 |
| `proj_init` | 技能 | 内置已移除；现存同名技能，属用户资产不评估下线 |
| `proj_mem` | 技能 | 同上 |
| `skill_creator` | 技能 | 同上 |
| `token_analysis` | 技能 | 同上 |

## 后续

- 2026-12-09 复盘 `memory_expand`：仍为 0 调用则下线，改动 `server_tools.py` 与 `server_tool_schema.py` 两处。
- 重启 MCP 后内置工具应为 15 个；超出部分先核对是否技能注册（`scan_skills()`），再判断安装副本是否更新。
