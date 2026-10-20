#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""候选重排：lint 过滤 + 加权分数 + MMR 多样性。"""

from __future__ import annotations

import json
import re
from pathlib import Path

from gen_articles import runtime
from gen_articles.i18n import t as tr


def _grams(text: str, n: int = 3) -> set[str]:
    prose = re.sub(r"```.*?```", "", text, flags=re.S)
    unit = runtime.pack().unit_re
    prose = "".join(ch for ch in prose if ch.isalnum() or unit.fullmatch(ch))
    return {prose[i : i + n] for i in range(max(0, len(prose) - n + 1))}


def _similarity(a: str, b: str) -> float:
    ga, gb = _grams(a), _grams(b)
    if not ga or not gb:
        return 0.0
    return len(ga & gb) / len(ga | gb)


def rerank(run_dir: Path) -> dict:
    report = json.loads((run_dir / "evaluation.json").read_text(encoding="utf-8"))
    texts = {
        item["index"]: Path(item["path"]).read_text(encoding="utf-8")
        for item in report["results"]
    }
    rows = []
    for item in report["results"]:
        lint_ok = item["lint"]["result"] == "PASS"
        lint_score = item["lint"]["scores"]["overall"] / 100
        style_score = max(0.0, min(1.0, 1 - item["style"]["distance"] / 3))
        pairwise = item["pairwise"]["win_rate"]
        pairwise_score = pairwise if pairwise is not None else 0.5
        opening = item.get("opening", {}).get("score", 0.5)
        pacing = item.get("pacing", {}).get("score", 0.5)
        generality = item.get("generality", {}).get("score", 0.5)
        markdown = item.get("markdown", {}).get("markdown_score", 0.5)
        total = (
            0.20 * lint_score
            + 0.15 * style_score
            + 0.20 * pairwise_score
            + 0.10 * opening
            + 0.10 * pacing
            + 0.15 * generality
            + 0.10 * markdown
        )
        rows.append(
            {
                "index": item["index"],
                "title": item["title"],
                "path": item["path"],
                "lint_ok": lint_ok,
                "lint_score": round(lint_score, 3),
                "style_score": round(style_score, 3),
                "opening": opening,
                "pacing": pacing,
                "generality": generality,
                "markdown": markdown,
                "pairwise": pairwise,
                "total": round(total, 3),
                "hard_issues": item["lint"].get("hard_issues", []),
            }
        )
    eligible = [r for r in rows if r["lint_ok"]] or rows
    rejected = [r for r in rows if not r["lint_ok"]]
    selected = []
    remaining = sorted(eligible, key=lambda r: r["total"], reverse=True)
    while remaining:
        best = None
        for row in remaining:
            penalty = max(
                (_similarity(texts[row["index"]], texts[s["index"]]) for s in selected),
                default=0.0,
            )
            row["diversity_penalty"] = round(penalty, 3)
            adjusted = row["total"] - 0.15 * penalty
            if best is None or adjusted > best[0]:
                best = (adjusted, row)
        _, chosen = best
        chosen["adjusted"] = round(best[0], 3)
        selected.append(chosen)
        remaining.remove(chosen)
    result = {
        "run_id": report["run_id"],
        "topic": report["topic"],
        "genre": report["genre"],
        "all_lint_failed": not any(r["lint_ok"] for r in rows),
        "selected": selected[0] if selected else None,
        "ranking": selected,
        "rejected": rejected,
    }
    (run_dir / "selection.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    lines = [
        tr("genarticles.report.header", topic=report["topic"]),
        "",
        tr("genarticles.report.table"),
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in selected:
        lines.append(
            f"| {row['index']} | {row['title']} | {'PASS' if row['lint_ok'] else 'FAIL'} "
            f"| {row['style_score']} | {row['opening']} | {row['pacing']} "
            f"| {row['generality']} | {row['markdown']} | {row['pairwise']} "
            f"| {row['total']} | {row['adjusted']} |"
        )
    if result["selected"]:
        lines += [
            "",
            tr(
                "genarticles.report.selected",
                index=result["selected"]["index"],
                title=result["selected"]["title"],
            ),
        ]
    if rejected:
        lines += [
            "",
            tr("genarticles.report.rejected"),
            tr("genarticles.report.reject_table"),
            "|---|---|---|",
        ]
        for row in rejected:
            reason = "; ".join(i["message"] for i in row["hard_issues"][:2]) or tr(
                "genarticles.report.lint_failed"
            )
            lines.append(f"| {row['index']} | {row['title']} | {reason} |")
    (run_dir / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return result
