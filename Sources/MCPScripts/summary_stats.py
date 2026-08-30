"""summarize 统计报表模块。

从 summarize.py 拆分（2026-08-30，重构阶段3）：MCP 工具调用统计报表
的生成与打印。自包含（仅依赖标准库 + 自身常量）。代码原样搬移不改逻辑。
"""

from __future__ import annotations

import sqlite3
from datetime import date, datetime, timedelta
from pathlib import Path

from config import data_dir, notes_dir
from log_utils import setup_logging

# ---------------------------------------------------------------------------
# 配置（与拆分前 summarize.py 一致）
# ---------------------------------------------------------------------------

COLD_READY = True
UTILITY_DATA_DIR = Path(data_dir())
NOTES_DIR = Path(notes_dir())
STATS_DB = UTILITY_DATA_DIR / "tool_usage.sqlite"
MCP_DIR = NOTES_DIR / "MCP"
STATS_OUTPUT = MCP_DIR / "工具调用统计.md"
STATS_DAYS = 15  # 报表显示最近天数
STATS_RETENTION_DAYS = 90  # 数据保留天数

logger = setup_logging("summarize")


def _get_stats_db_readonly() -> sqlite3.Connection | None:
    """只读连接，用于报表生成。"""
    if not STATS_DB.exists():
        return None
    try:
        conn = sqlite3.connect(str(STATS_DB))
        conn.execute("PRAGMA busy_timeout=5000")
        conn.row_factory = sqlite3.Row
        return conn
    except Exception:
        return None


def _cleanup_old_stats() -> None:
    """清理超过 STATS_RETENTION_DAYS 的旧数据。"""
    try:
        conn = sqlite3.connect(str(STATS_DB))
        conn.execute("PRAGMA busy_timeout=5000")
        cutoff = (date.today() - timedelta(days=STATS_RETENTION_DAYS)).isoformat()
        conn.execute("DELETE FROM tool_calls WHERE called_at < ?", (cutoff,))
        conn.commit()
        conn.close()
    except Exception:
        pass


def _generate_stats_report() -> None:
    """生成 MCP 工具调用统计报表。"""
    try:
        _cleanup_old_stats()
        conn = _get_stats_db_readonly()
        if conn is None:
            content = "# MCP 工具调用统计\n\n暂无数据。"
            MCP_DIR.mkdir(parents=True, exist_ok=True)
            STATS_OUTPUT.write_text(content, encoding="utf-8")
            return

        cutoff = (date.today() - timedelta(days=STATS_DAYS)).isoformat()
        rows = conn.execute(
            """SELECT date(called_at) as day, tool_name,
                      COUNT(*) as calls,
                      SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) as errors,
                      ROUND(AVG(duration_ms), 1) as avg_duration
               FROM tool_calls
               WHERE called_at >= ?
               GROUP BY day, tool_name
               ORDER BY day DESC, calls DESC""",
            (cutoff,),
        ).fetchall()
        conn.close()

        if not rows:
            content = "# MCP 工具调用统计\n\n最近 15 天无调用记录。"
            MCP_DIR.mkdir(parents=True, exist_ok=True)
            STATS_OUTPUT.write_text(content, encoding="utf-8")
            return

        # 组装数据: {day: [(tool_name, calls, errors, avg_duration), ...]}
        days: dict[str, list] = {}
        total_calls = 0
        total_errors = 0
        for r in rows:
            day = r["day"]
            if day not in days:
                days[day] = []
            days[day].append(
                (r["tool_name"], r["calls"], r["errors"], r["avg_duration"])
            )
            total_calls += r["calls"]
            total_errors += r["errors"]

        success_rate = (
            round((total_calls - total_errors) / total_calls * 100, 1)
            if total_calls > 0
            else 100.0
        )
        day_count = len(days)
        daily_avg = round(total_calls / day_count, 1) if day_count > 0 else 0

        now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
        lines = [
            "# MCP 工具调用统计\n",
            f"> 更新于 {now_str}\n",
            "## 📊 总览\n",
            "| 指标 | 数值 |",
            "|------|------|",
            f"| 过去 {STATS_DAYS} 天总调用 | {total_calls} 次 |",
            f"| 日均 | {daily_avg} 次 |",
            f"| 成功率 | {success_rate}% |",
            "",
        ]

        sorted_days = sorted(days.keys(), reverse=True)
        for day in sorted_days:
            tool_stats = days[day]
            day_total = sum(t[1] for t in tool_stats)
            day_errors = sum(t[2] for t in tool_stats)
            max_calls = max(t[1] for t in tool_stats)
            bar_width = 20

            lines.append(f"## {day}（共 {day_total} 次）\n")
            lines.append("| 工具 | 调用 | 错误 | 平均耗时 |")
            lines.append("|:-----|:----|:----|:--------|")
            for tool_name, calls, errors, avg_dur in tool_stats:
                bar_len = max(1, round(calls / max_calls * bar_width))
                bar = "█" * bar_len
                dur_str = f"{avg_dur}ms" if avg_dur else "-"
                lines.append(f"| {tool_name} | {bar} {calls} | {errors} | {dur_str} |")
            lines.append("")

        content = "\n".join(lines)
        MCP_DIR.mkdir(parents=True, exist_ok=True)
        STATS_OUTPUT.write_text(content, encoding="utf-8")
        logger.info(
            f"工具调用统计已写入: {STATS_OUTPUT} "
            f"({day_count} 天, {total_calls} 次调用)"
        )
    except Exception as e:
        logger.warning(f"工具调用统计生成失败: {e}")


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
