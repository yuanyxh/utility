---
date: 2026-08-06
tags: [summarize, memory-pipeline, aggregate, refine, architecture]
---

# summarize.py 记忆沉淀流水线

## 背景
每日 17:00 定时（summaryHour:17）将热层 mem0 记忆沉淀为 notes 仓库 `Extracts/*.md` 总结文章，同时写入 Qdrant 冷层 `knowledge_base`。主流程（2026-08-06 重构后）：`main()` → `_acquire_single_instance` → `_generate_stats_report` → `_throttle_ai_run` → fetch → `_run_aggregate_v2` → `_run_refine` → `_write_articles_v2` → `_run_phase3` → git_commit×2。

## 关键机制
- **数据源**：`fetch_memories()` 拉 `/api/memories/recent?since=<today-3d>&limit=200`（SUMMARY_MEMORY_DAYS=3, LIMIT=200）
- **content 键**：REST API 返回的记忆正文在 `memory` 键（非 `content`），`_build_facts_text_v2` 用 `m.get('memory') or m.get('content')`——曾误读 content 键导致正文全空、LLM 编造（2026-08-04 修复，commit 1628e7f）
- **tag 过滤（excludeTags）**：2026-09-04 新增，从 `config.yaml` 的 `mcp.excludeTags` 读取排除 tag 列表，含这些 tag 的记忆不进入总结。环境变量 `SUMMARY_EXCLUDE_TAGS`（逗号分隔）由 Swift 侧 `AppDelegate` 传入。函数 `_filter_by_tags()` 在 `_filter_processed()` 之后调用。
- **阶段1 聚合（`_run_aggregate_v2`）**：分批聚合 + 递归合并（≤3 轮收敛，组数单调不增）；facts 带 `[MM-DD]` 日期前缀、组内按时间排序、关键节点标日期；retain 过滤抽 `_filter_retain`
- **阶段2 逐组精炼（`_run_refine`）**：每组独立走「关键词提炼 → 检索 Extracts → 归并/新建判断 → think enable 生成」，单组失败不中断（写 `流水线错误日志.jsonl`）。`search_extracts` 纯 Python 大小写不敏感子串匹配，零外部依赖；`_decide_merge` 无命中直接新建、有命中调 LLM 判断，判断失败兜底 merge hits[0]
- **merge 写入契约**：`_gen_merge` 返回 `{title, content}` 不含 target，`_run_refine` 的 merge 分支**必须补 `item["target"] = decision["target"]`** 供 `_write_articles_v2` 定位写入——曾漏补导致 33 个归并全部 KeyError（2026-08-06 修复）
- **防重复触发**：单实例文件锁（`~/.config/utility/summarize.lock`）+ 距上次完整总结 <6h 跳过（`~/.config/utility/summarize_last_run`）。内部任务注册规则见 `rules/internal-task-registration.md`
- **冷层沉淀**：`write_to_cold_layer()` 在 `_write_articles_v2` 内逐篇调用，SHA-256(source_file|content) 去重存 `cold_sync.sqlite`

## ⚠️ 潜在隐患（未修，2026-08-06）
`_decide_merge` 的 subpath 校验在 macOS 临时目录下抛「is not in the subpath」——`/var` 是 `/private/var` 符号链接，`t.resolve()` 与未 resolve 的 `EXTRACTS_DIR` 不一致。生产路径（notes 仓库不在 `/var` 下）不触发，属健壮性缺口。

## 关联
- 2026-08-03 16 项缺陷全修：`d1ddc27f`（按 H1 段合并去重、事实约束 prompt、冷层哈希去重等）
- 2026-08-06 重构：阶段1 v2（时间线+递归）+ 阶段2 检索驱动归并（替换 `_run_phase1`/`_run_phase2`）+ merge target 修复
- 沉淀时机错过机制：定时 17:00 被 throttle 跳过 + 记忆晚于触发写入时，需等 throttle 解除（上次完整总结 +6h）或次日定时
- 测试注意：系统 python3 无 httpx，须用 `~/.config/utility/mcp-venv/bin/python3` 运行/测试
