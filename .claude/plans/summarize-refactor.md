# summarize.py 重构：检索驱动归并 + 逐组精炼（2026-08-05）

> 状态：设计已实施（2026-08-06），代码在 `Sources/MCPScripts/summarize.py`。
> 运行时管线与已知隐患见 `.claude/memory/summarize-memory-pipeline.md`；架构设计记忆见 MCP 记忆库（tag: summarize architecture）。

## Context

**问题**：summarize.py 每日把 3 天记忆总结成知识笔记，但脚本脆弱、产出低智。本会话排查确认 28 篇新增中 **15 篇与 Extracts 已有同主题笔记重复**、3 篇质量差（空壳/混编/流水账）。根因：

1. **phase1 靠 LLM 猜目录/标题，无检索依据** → 「优先复用已有笔记」只是软约束，`resolve_target_file` 匹配不上就静默新建。
2. `resolve_target_file` **限同目录匹配** + slug 子串脆弱（`ai_生态全景文章留存` vs `ai_生态全景_2026` 同目录也不命中）。
3. 聚合**无时间线演进**处理。
4. 致命节点失败**整体中断**（fetch/聚合/phase1/phase2 任一失败即停）。
5. 分批后只跨批合并一次，不递归。

**用户决策**：
- 存量 28 篇本次不动，只重构代码，下次运行新管线自然演化。
- 阶段 2 判断类调用 think enable + 精简 JSON + 大 max_tokens，JSON 解析失败**自动降级 disable_thinking 重试一次**。
- 知识库限制在 Extracts/（notes 根为用户手写，禁止污染）——本设计检索/写入全部限定 `EXTRACTS_DIR`。

**目标**：重构后新记忆总结通过「关键词检索 Extracts → 判断归并/新建 → think enable 精炼生成」落地，同一主题自动合并到已有笔记，不重复新建。

## 新管线流程（main 改造）

```
main():
  _acquire_single_instance → _generate_stats_report → [--stats-only 返回]
  → API key 校验 [致命]
  → _throttle_ai_run
  → memories = fetch_memories(today)          [致命：None 中断]
  → groups = _run_aggregate_v2(memories)      [致命：None 中断]
  → results, stats = _run_refine(groups, dir_tree)   [阶段2，单组失败不中断]
  → all_tags = _collect_tags(memories)
  → updated = _write_articles_v2(results, today_str, all_tags)
  → _run_phase3(groups, today_str)            [保留不动，仍吃 groups]
  → git_commit×2 → _mark_run_success → _print_report_v2(...)
```

## 阶段 1：批量聚合（改造 _run_aggregate → _run_aggregate_v2）

**输入**：fetch 条目（`memory` 键正文、`metadata.tags`、`created_at`/`updated_at`）。
**输出**：`[{"topic", "facts", "tags", "retain"}]`（facts 内按时间线组织）。

1. **时间戳进入聚合**：
   - 新增 `_memory_date(m)`：取 `created_at or updated_at` 前 10 位 `MM-DD`；缺键返回空串。
   - 改造 `_build_facts_text` → `_build_facts_text_v2`：每条加 `[MM-DD]` 前缀（`[日期未知]` 兜底），保留现有引号归一化 `_clean` 内联逻辑。
2. **分批 prompt 增强 3 条**（保留现有主题分组/合并去重/retain/禁止编造/facts 完整度约束）：
   - 时间线演进：同主题多条按时间组织进 facts，体现「先 A 后改 B」轨迹，新旧矛盾保留演变过程。
   - 关键节点标日期：根因判定/方案选型等标注 `（8/3 首次发现，8/5 确认根因）`。
   - facts 内按时间排序。
3. **递归合并**：
   - 抽 `_aggregate_round(facts_text, label)`（单轮 LLM 聚合，disable_thinking + max_tokens=16384，失败重试 1 次）。
   - `_run_aggregate_v2`：首轮分批 → `_merge_cross_batch_groups`（保留）→ `_filter_retain` → **递归**：把 groups 转 facts 再聚合，`len(groups) >= prev_len` 收敛即停，最大 `AGGREGATE_MAX_ROUNDS=3` 轮（不可能死循环：聚合只合并不拆散，组数单调不增）。递归轮失败 → 保留当前结果，warning 不中断。
   - retain 过滤抽 `_filter_retain(groups)`，每轮递归后执行。

## 阶段 2：逐组精炼（核心新逻辑 _run_refine，替换 _run_phase1/_run_phase2）

对每个主题组独立执行 5 步，单组失败不影响其他组：

### 通用 helper `_llm_json(prompt, *, max_tokens, ...)`
think enable 调用 + 解析失败自动降级 disable_thinking 重试 1 次；全部失败返回 None。实现：`_llm_chat(..., disable_thinking=attempt > 0)`。

### A 关键词提炼 `_extract_keywords(group) -> list[str]`
`_llm_json` 输出 `{"keywords": [...]}`，要求 3-8 个名词性关键词（专有名词/项目名/技术栈/主题中心词），≥2 字符，避免「记忆/总结/问题」通配词。max_tokens=8192。失败返回 `[]`。

### B 本地检索 `search_extracts(keywords, limit=5) -> list[dict]`
**纯 Python 大小写不敏感子串匹配，零外部依赖**（不调 server/Qdrant——冷层向量 ≠ Extracts 全文，Qdrant local 有排他锁）：
- `EXTRACTS_DIR.rglob("*.md")`，跳过路径含 `.` 开头的部分。Extracts 内 `MCP/` 等是正常主题内容不排除。
- 全文读入 `errors="ignore"`，统计命中的关键词集合。
- 返回 `[{"rel_path"(相对Extracts), "snippet"(命中处前后~120字符), "matched", "score"}]`，按命中关键词数降序取前 limit。
- 单组关键词 ≤8 个 × 129 篇 md，全文子串匹配秒级完成。

### C 归并判断 `_decide_merge(group, hits) -> dict`
**无命中 → 跳过判断，直接新建**。有命中 → `_llm_json` think enable 输出 `{"action": "merge"|"new", "target"(相对Extracts路径), "reason"}`：
- 判定标准：高度相关（同技术栈/同项目/同一件事）→ merge；沾边/通用词 → new；多命中选最相关 1 个；内容冲突仍可 merge（reason 注明修订）。
- 校验：`action=merge` 时 target 必须存在、`.md` 结尾、parts 不含 SUMMARY_EXCLUDE_DIRS。
- 降级后仍失败 → **兜底 merge 到 hits[0]**（检索命中通常代表主题相关，比乱建好），写 `REFINE_JUDGE_JSON` 错误日志。

### D 最终生成（think enable）
- **新建** `_gen_new(group, dir_tree, existing_tops)`：一次输出 `{"dir", "title", "content"}`。dir 必须复用现有顶层或新建单层顶层（禁止嵌套），title 具体；正文保留关键节点日期，150-500 字，禁止编造。max_tokens=16384。长 content 在 JSON 值内已有先例（现聚合 facts）+ `_escape_inline_quotes` 兜底。
- **归并** `_gen_merge(group, target_file, existing_text)`：读目标文件前 2000 字符作上下文，输出 `{"title", "content"}`——只写「未被已有内容覆盖」的新增信息，保留日期，150-500 字。
- 两场景生成后统一 QC：`len(content) >= SUMMARY_MIN_CONTENT_LEN(150)`，不足 → `too_short` 记录并跳过该组。

### 主循环 `_run_refine(groups, dir_tree) -> (results, stats)`
逐组 A→B→C→D，任一环节失败 `write_error_log` + stats 计数 + continue。外层 try/except 兜底。返回 results（写入单元）+ stats（ok/kw_fail/judge_fail/gen_fail/too_short/hit_files）。

## 归并写入 `_write_articles_v2`

- **merge**：目标文件来自判断结果（可靠），直接用 `EXTRACTS_DIR / target`，调 `_merge_into_file(filepath, title, content, today_str, is_append=True)`。
- **new**：`resolve_target_file(EXTRACTS_DIR/dir, title)` **保留作兜底**——LLM 给的 dir+title 若撞上已有文件会自然归并，弥补检索召回边界。目录白名单/EXCLUDE 检查抽 `_dir_excluded`/`_sanitize_new_dir` 保留。
- 写入后沿用体积 QC + `write_to_cold_layer`（source_file=filepath, category=目录）。
- `_merge_into_file` 本身不改：同名 H1 保留旧内容+「补充于」子节（天然体现时间线演进），异名段末尾追加。

## 容错

| 节点 | 处理 | code |
|---|---|---|
| API key 缺失 / fetch None / 聚合整体 None | **中断** | CONFIG / FETCH_MEMORY / AGGREGATE_JSON |
| 聚合无有效主题（空组） | 正常返回，跳过 | — |
| 阶段 2 单组任一步失败 | `write_error_log` + continue，**不中断** | REFINE_KEYWORD / REFINE_JUDGE / REFINE_JUDGE_JSON / REFINE_GEN |
| 正文过短 | warning + 跳过该组 | — |
| 递归合并轮失败 | 保留当前结果继续 | — |
| 磁盘写入异常 | **新增 try/except**（现 `_merge_into_file` 无捕获，是已知缺口），记录错误日志 | WRITE |

报告 `_print_report_v2` 追加：聚合轮数、阶段2 成功/失败明细、检索命中数、新建/归并/文件数。

## 保留不动 vs 改造 vs 新增 vs 删除

- **保留不动**：`write_error_log`、`_acquire_single_instance`、`_throttle_ai_run`、`_mark_run_success`、`_cold_already_synced`、`write_to_cold_layer`、`git_commit`、`_llm_chat`、`_parse_json_any`、`_escape_inline_quotes`、`_normalize_slug`、`fetch_memories`、`_list_extract_summaries`、`scan_notes_structure`、`_merge_into_file`、`_strip_leading_h1`、`_collect_tags`、`_run_phase3`（含 rules 系列）、`_generate_stats_report`（含 stats 系列）、全部现有常量。
- **改造**：`_build_facts_text`→v2（加日期前缀）、`_run_aggregate`→`_run_aggregate_v2`（时间线+递归）、`_merge_cross_batch_groups`（prompt 微调）、`_write_articles`→`_write_articles_v2`、`_print_report`→v2、`main`。
- **新增**：`_memory_date`、`_build_facts_text_v2`、`_aggregate_round`、`_run_aggregate_v2`、`_groups_to_facts`、`_filter_retain`、`_llm_json`、`_extract_keywords`、`search_extracts`、`_make_snippet`、`_decide_merge`、`_gen_new`、`_gen_merge`、`_run_refine`、`_new_stats`、`_dir_excluded`、`_sanitize_new_dir`、`_existing_extract_tops`。
- **删除**（被阶段 2 取代）：`_run_phase1`、`_run_phase2`（防御逻辑已迁移进 `_run_refine`/`_sanitize_new_dir`）。

## 新常量

```python
AGGREGATE_MAX_ROUNDS = 3          # 阶段1 递归最大轮数
SUMMARY_KEYWORD_MAX_TOKENS = 8192
SUMMARY_JUDGE_MAX_TOKENS = 8192
SUMMARY_GEN_MAX_TOKENS = 16384
SUMMARY_SEARCH_LIMIT = 5
SEARCH_MIN_TOKEN_LEN = 2
SUMMARY_KEYWORD_COUNT = 8
SUMMARY_MERGE_CONTEXT_CHARS = 2000
```

## 验证

运行环境：必须用 `~/.config/utility/mcp-venv/bin/python3 summarize.py`（系统 python3 无 httpx）。

1. **端到端**：完整跑一次，`流水线错误日志.jsonl` 无新增致命项，Extracts 有新文件；报告显示阶段 2 统计。
2. **同主题合并**：日志中某主题命中已有笔记 → 最终写入为「追加」非「新建」。
3. **新建主题**：全新主题（检索无命中）生成新文件，dir 复用现有顶层。
4. **时间线演进**：正文含 `（8/x` 日期标注；`_merge_into_file` 产生「补充于」子节而非覆盖。
5. **单组失败不中断**：monkeypatch `_llm_chat` 使第 2 组返回 None，确认第 1/3 组正常产出，错误日志有 `REFINE_*`。
6. **递归收敛**：造含重复主题的输入，观察「聚合收敛：第 X 轮」日志，≤3 轮内停止。
7. **函数级**：`search_extracts(["ImportEngine"])` 命中 tms-front 导入引擎篇；`_memory_date` 对 ISO 串/缺键正确（**先验证 fetch_memories 返回条目确含 created_at**，否则 `_memory_date` 恒空，需改用服务端排序或降级方案）。

## 风险

- **think enable 成本/耗时**：每篇 2-3 次 LLM 调用，每日 10-20 篇 → 30-60 次，总耗时 +1-3 分钟。用 `SUMMARY_MERGE_CONTEXT_CHARS=2000`、判断 prompt 只给 facts 前 300 字控输入。
- **think 吃 max_tokens**：大 max_tokens + 降级 disable_thinking 兜底（用户已确认）。
- **检索误判**：判断失败兜底 merge hits[0]；`_merge_into_file` 误合也只是多一段「补充于」，可追溯可删。
- **回归**：phase3 吃 groups 的 `topic/facts` 键（结构不变仅 facts 带日期，兼容）；new 路径保留 `resolve_target_file` 兜底防撞。

## 实施后

检查 `default-config.yaml`、`README.md`、`AGENTS.md` 是否需要同步（Git 流程规定）；更新 `.claude/memory/summarize-memory-pipeline.md` 的设计决策。
