# 零调用工具评估清单（T9）

数据窗口 2026-11-13 ~ 2026-11-19，来源 `notes/Review/2026-11-19/06-工具调用.md`。
实际注册核对时间 2026-11-19，方式：导入运行中的 wheel（`~/.config/utility/mcp-venv`）枚举 `build_tools()` 与 `scan_skills()`。
证据等级：用量为 L2（`api_usage.tool_names` 聚合），注册为 L1（运行包枚举）。本清单只评估，不改注册与契约。

## 评估表

| 工具 | 用途 | 替代工具 | 建议 |
|---|---|---|---|
| memory_expand | 已有 memory id 时沿神经元图快速跳转；纯内存遍历，不查 SQL、不嵌入、不调 LLM | memory_graph（走边取完整关系） | 保留观察 |
| memory_graph | 围绕单个 memory id 取版本链、episode 组、矛盾、来源链、突触与联想路径 | memory_expand（低开销跳转）、memory_get（单条正文） | 保留观察 |
| token_analysis | 分析当前会话上下文 token 构成（messages/记忆文件/MCP 工具/skills/工具输出），定位可压缩项 | 内置 `/context`；直接读会话 jsonl | 保留观察 |
| user_output_style | 用户输出风格偏好 skill，2026-11-03 建于 `~/.claude`，非 mino-brain 注册工具 | 无（当前未注册） | 下线候选 |
| notice | 快照中登记的通知类工具，当前注册清单无同名工具，源码与已装包均无定义 | 无（当前未注册） | 下线候选 |
| proj_mem | 用户说提交/总结/记录时，把会话洞察、架构决策与编码规范写入项目持久化文件 | remember/remember_batch（写共享记忆）；直接写 `.agent/` 文档 | 保留观察 |
| proj_init | 进入新项目时初始化上下文：读项目文档、判定技术栈、生成规则目录、查历史记忆 | project_notes、project_lookup；直接读 CLAUDE.md/AGENTS.md | 合并 |
| devflow_fetch | 通过云效 MCP 拉取需求，建单会话单需求模式 | 直接调 yunxiao 的 search_workitems / get_work_item | 保留观察 |
| devflow_start | 对指定需求执行完整研发闭环：建分支→调研→方案→开发→验证→云效状态流转 | 无单一替代；手工组合 git 与 yunxiao 写工具 | 保留观察 |
| skill_creator | 查/拉/建/适配 Skill，资源只经 tool_resource 获取 | 手工编辑 SKILL.md；tool_resource | 保留观察 |
| cleanup_cache | 扫描 macOS 常见缓存目录，把已卸载应用的残留移入废纸篓 | 手工 find + mv 到废纸篓 | 保留观察 |
| forget | 永久删除一条记忆 | remember 的 supersedes（退休旧条而非删除） | 保留观察 |
| set_memory_processed | 设置/重置记忆 processed 位，幂等；供治理管线跳过已沉淀/已作废条目 | 无 MCP 等价；裸 SQL 更新 processed 列 | 保留观察 |

## 与 06 报告的差异

- 06 报告基数 30 = 固定 schema 15 + 技能注册 13 + 快照残留 2（`user_output_style`、`notice`）。当前实际注册为 15 + 13 = 28。
- `user_output_style` 是用户级 skill 的历史产物（见 `notes/Extracts/方法论与经验/用户输出风格偏好与_user_output_style_skill.md`），不属 mino-brain；`notice` 在 gateway 源码、已装 wheel、`notes/MCP/Skills` 中均无定义。
- 按当前注册，真实零调用为 11 项；本表为对齐 06 报告保留 13 行，其中 2 项已标注未注册。两项建议下线候选，但本次不删注册。
- `graph-eval` 实例的 6 项零调用属独立实例，不纳入本清单。
- 建议不改注册清单：零调用不等于下线，06 报告的落点是评估懒加载，而非删工具。
