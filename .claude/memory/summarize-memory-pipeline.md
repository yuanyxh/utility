---
date: 2026-08-04
tags: [summarize, memory-pipeline, aggregate, architecture]
---

# summarize.py 记忆沉淀流水线

## 背景
每日 17:00 定时（summaryHour:17）将热层 mem0 记忆沉淀为 notes 仓库 `Extracts/*.md` 总结文章，同时写入 Qdrant 冷层 `knowledge_base`。主流程：`main()` → `_acquire_single_instance` → `_generate_stats_report` → `_throttle_ai_run` → fetch → `_run_aggregate` → `_run_phase1` → `_run_phase2` → `_write_articles` → git_commit。

## 关键机制
- **数据源**：`fetch_memories()` 拉 `/api/memories/recent?since=<today-3d>&limit=200`（SUMMARY_MEMORY_DAYS=3, LIMIT=200）
- **content 键**：REST API 返回的记忆正文在 `memory` 键（非 `content`），`_build_facts_text` 用 `m.get('memory') or m.get('content')`——曾误读 content 键导致正文全空、LLM 编造（2026-08-04 修复，commit 1628e7f）
- **阶段1记忆聚合**：`_run_aggregate()` 在 fetch 后、生成前对记忆分类、组内合并去重、丢弃临时信息（AGGREGATE_BATCH_THRESHOLD=120，LLM 聚合 temperature=0.2）
- **防重复触发**：单实例文件锁（`~/.config/utility/summarize.lock`）+ 距上次完整总结 <6h 跳过（`~/.config/utility/summarize_last_run`）。内部任务注册规则见 `rules/internal-task-registration.md`
- **冷层沉淀**：`write_to_cold_layer()` 在 `_write_articles` 内逐篇调用，SHA-256(source_file|content) 去重存 `cold_sync.sqlite`

## ⚠️ 已知缺口（2026-08-04 诊断，方案待确认未实施）
时间线缺口是 101 份 Extracts 审计大量「修复未沉淀」失真（GBK→GB18030、OAuth→BDUSS 等新旧状态混淆）的机制根因——三处缺时间线：
1. `_build_facts_text` 只输出 `[tags] memory`，不含 `created_at`
2. `_run_aggregate` 聚合 prompt 无按时间排序/新旧状态并存要求
3. `_run_phase1` 生成 prompt 无日期标注要求

改进方向（待用户确认）：每条记忆加日期前缀、聚合组内按时间排序保留「旧→新」演变、关键事实标日期。

## 关联
- 2026-08-03 16 项缺陷全修：`d1ddc27f`（按 H1 段合并去重、事实约束 prompt、冷层哈希去重等）
- 沉淀时机错过机制：定时 17:00 被 throttle 跳过 + 记忆晚于触发写入时，需等 throttle 解除（上次完整总结 +6h）或次日定时
- 测试注意：系统 python3 无 httpx，须用 `~/.config/utility/mcp-venv/bin/python3` 运行/测试
