# 2026-11-25 审查修复计划

依据 2026-11-25 审查核查结论，执行 A/B/C 全部与 D 的子集。冷层历史 importance 不回填，决策落到本期 review 目录。

## 范围与任务

### A 运维（无代码）

- A1 将 `~/.config/agent-gateway/knowledge.sqlite`（0 字节）移入废纸篓。
- A2 备份 `~/.config/utility/config.yaml` 后移除 5 个死键：`general.aiTimeout`、`workspace.ignoredDirectories`、`workspace.imagePreviewMaxSizeMB`、`workspace.maxFileSizeMB`。
- A3 对 `agent-gateway` 调用一次 `project_lookup` 触发增量索引，验证 `graph.sqlite` 的 `git_head` 回到 `784af20`。

### B 代码修复（agent-gateway）

- B1 `services/memory/lifecycle.py:48-53` 的 `_days_since` 改用 `forgetting.as_utc`，消除 aware/naive 8 小时偏移。
- B2 `services/summarize/storage.py:61-71` 的 `_inherited_importance` 捕获异常时记 WARN，并区分「无源」与「异常」。
- B3 `services/retrieval/pipeline.py` 的 `trace_payload` 增加 `related` 摘要（`:742` 附近）。
- B4 `llm/client.py:200-205` 的 `thinking` 按 provider 能力发送，非 Anthropic 不写 `thinking`。

### C 观测

- C1 MCP RSS 采样已存在（`server.py:707-735` `rss_sampler`），确认默认 600 s 生效，不重复实现。
- C2 `collect_metrics.py:2152-2183` 的 `retrieval.p95_ms` 按工具拆阈值：外部搜索单独阈值，本地 pipeline 维持 3000 ms。
- C3 `collect_metrics.py:417-505` 网关统计增加 402 计数，并在错误面板按上游列出。

### D 数据治理

- D1 `Sources/Core/Database.swift` 新增 v5 迁移给 `rss_item` 加 `created_at`；`Sources/RSS/RSSItem.swift` 增加字段；`collect_metrics.py:846-899` 优先用 `created_at` 统计窗口新增。
- D2 `services/mcp/server_memory.py:506` 的预览列表对超长内容补省略号，改用 `fact` 兜底。
- D3 按 `agent-vibe/protocols/zh/upgrade-seeds.md` 把 utility 与 agent-gateway 从 1.5.0 升到 1.6.0。
- D4 在 `notes/Review/2026-11-25/` 记录「冷层历史 importance 不回填」决策。

## 验证

- agent-gateway：`python -m py_compile` 涉及文件 + 相关 `unittest`。
- utility：`swift build`。
- collect_metrics：`python -m py_compile`，并用真实库试跑 `collect_rss`、`collect_gateway`。
- A3：查询 `graph.sqlite` 的 `meta.git_head`。

## 风险与回滚

- 配置移除前先备份到 `config.yaml.bak-20261125`，可原样恢复。
- 代码改动均单点函数级，`git diff` 可逐条回退。
- RSS 新增列向后兼容：旧行 `created_at` 为空，统计时回退 `pub_date`。
