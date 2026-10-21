#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""完整管线：生成候选 → lint 定向重写 → 三层评价 → MMR 重排。"""

from __future__ import annotations

import json
from pathlib import Path

from utility.articles.evaluate import evaluate_run
from utility.articles.format_repair import format_repair
from utility.articles.generate import MaterialError, generate
from utility.articles.rerank import rerank
from utility.articles.rewrite import (
    merge_run,
    pacing_rewrite,
    rewrite_run,
    split_run,
)


def run_pipeline(
    topic: str,
    genre: str | None,
    candidates: int,
    out: Path | None,
    rounds: int,
    judge: bool,
    max_tokens: int,
    temperature: float,
    disable_thinking: bool = True,
    use_plan: bool = True,
    material_path: Path | None = None,
) -> dict:
    try:
        meta = generate(
            topic,
            genre,
            candidates,
            out,
            temperature,
            max_tokens,
            disable_thinking=disable_thinking,
            use_plan=use_plan,
            material_path=material_path,
        )
    except MaterialError as exc:
        run_dir = Path(exc.run_dir)
        return {
            "run_dir": str(run_dir),
            "status": "review_required",
            "review": str(run_dir / "review.md"),
            "material_filtered": exc.filtered,
            "material_count": 0,
            "rewrite": [],
            "format": [],
            "pacing": [],
            "merge": [],
            "split": [],
            "selected": {},
            "ranking": [],
            "rejected": [],
            "evaluation": [],
        }
    run_dir = Path(meta["run_dir"])
    rewritten = rewrite_run(run_dir, rounds=rounds, max_tokens=max_tokens)
    formatted = (
        format_repair(run_dir, rounds=rounds, max_tokens=max_tokens)
        if rounds > 0
        else []
    )
    paced = pacing_rewrite(run_dir, max_tokens=max_tokens) if rounds > 0 else []
    merged = merge_run(run_dir) if rounds > 0 else []
    split = split_run(run_dir) if rounds > 0 else []
    report = evaluate_run(run_dir, judge=judge)
    selection = rerank(run_dir)
    review_path = run_dir / "review.md"
    review_state = run_dir / "review.json"
    clean = False
    if review_state.exists():
        try:
            clean = bool(json.loads(review_state.read_text())["clean"])
        except (OSError, ValueError, KeyError, TypeError):
            clean = False
    selected_ok = bool(selection["selected"] and selection["selected"].get("lint_ok"))
    status = "ok" if selected_ok and clean else "review_required"
    return {
        "run_dir": str(run_dir),
        "status": status,
        "review": str(review_path),
        "material_filtered": meta.get("material_filtered", 0),
        "material_count": meta.get("material_count", 0),
        "rewrite": rewritten,
        "format": formatted,
        "pacing": paced,
        "merge": merged,
        "split": split,
        "selected": selection["selected"],
        "ranking": selection["ranking"],
        "rejected": selection["rejected"],
        "evaluation": [
            {
                "index": item["index"],
                "title": item["title"],
                "lint": item["lint"]["result"],
                "distance": item["style"]["distance"],
                "pairwise": item["pairwise"]["win_rate"],
            }
            for item in report["results"]
        ],
    }
