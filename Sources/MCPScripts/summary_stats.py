"""summarize 终端报告模块。

从 summarize.py 拆分（2026-08-30，重构阶段3）：记忆总结流水线的终端报告打印。
自包含（无外部依赖）。代码原样搬移不改逻辑。
"""

from __future__ import annotations

COLD_READY = True


def _print_report_v2(
    today_str: str,
    memory_count: int,
    updated_files: dict[str, str],
    rules_updates: str = "",
    refine_stats: dict | None = None,
    agg_rounds: int = 0,
    skipped_processed: int = 0,
    skipped_quality: int = 0,
):
    print(f"📝 记忆总结报告 ({today_str})")
    print(f"   本次处理事实: {memory_count} 条")
    if skipped_processed or skipped_quality:
        print(
            f"   输入过滤: 已处理跳过 {skipped_processed}，"
            f"低质丢弃 {skipped_quality}"
        )
    if refine_stats:
        print(
            f"   阶段2 精炼: {refine_stats['ok']} 成功"
            f"（新建 {refine_stats['new']} / 归并 {refine_stats['merge']}），"
            f"关键词失败 {refine_stats['kw_fail']}，生成失败 {refine_stats['gen_fail']}，"
            f"过短 {refine_stats['too_short']}，"
            f"占位低质 {refine_stats.get('too_low_quality', 0)}，"
            f"重复跳过 {refine_stats.get('dup_skip', 0)}，"
            f"检索命中 {len(refine_stats['hit_files'])}"
        )
    if agg_rounds:
        print(f"   聚合收敛轮数: {agg_rounds}")
    print(f"   写入文件: {len(updated_files)} 个")
    for path, action in updated_files.items():
        print(f"     {'📄' if action == '新建' else '📎'} {path} ({action})")
    if rules_updates:
        print(f"   📐 规范提炼: {rules_updates}")
    print(f"   冷层同步: {'✓' if COLD_READY else '⚠️ 未启用'}")
