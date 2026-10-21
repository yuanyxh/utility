#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""三层评价：lint 硬规则、stylometric 距离、与真实锚点的 pairwise。"""

from __future__ import annotations

import json
from pathlib import Path

from utility.llm.client import parse_json

from utility.articles import runtime
from utility.articles.candidate_ops import (
    profile_for,
    profile_mean,
    project_tokens_from_run,
    strict_lint,
)
from utility.articles.generate import reference_excerpts
from utility.articles.llm import LLMClient
from utility.articles.review import write_review
from utility.articles.stylometry import article_features, distance
from utility.articles.markdown import format_report


def _opening_score(lint: dict) -> float:
    if lint.get("opening_definition"):
        return 0.0
    if lint.get("opening_scope"):
        return 0.3
    score = (
        0.5
        + 0.25 * bool(lint.get("opening_causal"))
        + 0.25 * bool(lint.get("opening_concrete"))
    )
    if not lint.get("opening_background"):
        score -= 0.25
    return round(max(0.0, score), 3)


def judge_pair(
    candidate: str, reference: str, client: LLMClient, candidate_is_a: bool
) -> dict:
    a, b = (candidate, reference) if candidate_is_a else (reference, candidate)
    text = runtime.pack().prompt("gen_articles_judge", a=a[:3000], b=b[:3000])
    raw = client.chat(text, temperature=0, max_tokens=1024, disable_thinking=True)
    data = parse_json(raw) or {}
    winner = str(data.get("winner", "tie")).upper()
    candidate_won = (winner == "A" and candidate_is_a) or (
        winner == "B" and not candidate_is_a
    )
    score = 1.0 if candidate_won else (0.5 if winner == "TIE" else 0.0)
    return {
        "winner": winner,
        "candidate_score": score,
        "reason": data.get("reason", ""),
        "raw": raw[:500],
    }


def evaluate_run(run_dir: Path, judge: bool = True) -> dict:
    meta = json.loads((run_dir / "meta.json").read_text(encoding="utf-8"))
    profile = profile_for(meta["genre"])
    refs = reference_excerpts(meta["genre"], meta["topic"], count=2)
    client = LLMClient() if judge and refs else None
    tokens = project_tokens_from_run(run_dir)
    results = []
    for candidate in meta["candidates"]:
        path = Path(candidate["path"])
        text = path.read_text(encoding="utf-8")
        lint = strict_lint(text, tokens)
        features = article_features(text)
        style = distance(features, profile)
        target_p50 = profile_mean(profile, "sent_p50", 0)
        pacing = (
            round(min(1.0, features["sent_p50"] / target_p50), 3) if target_p50 else 0.5
        )
        judgments = []
        if client:
            for ref in refs:
                # 正反两个位置各判一次，抵消位置偏好
                for candidate_is_a in (True, False):
                    try:
                        judgment = judge_pair(
                            text, ref["excerpt"], client, candidate_is_a
                        )
                        judgment["candidate_is_a"] = candidate_is_a
                        judgments.append(judgment)
                    except Exception as exc:  # noqa: BLE001
                        judgments.append(
                            {
                                "winner": "ERROR",
                                "candidate_score": None,
                                "candidate_is_a": candidate_is_a,
                                "reason": f"{type(exc).__name__}: {exc}",
                            }
                        )
        valid = [
            j["candidate_score"] for j in judgments if j["candidate_score"] is not None
        ]
        results.append(
            {
                "index": candidate["index"],
                "path": str(path),
                "title": candidate["title"],
                "lint": {
                    "result": lint["result"],
                    "hard_issues": lint["hard_issues"],
                    "warnings": lint["warnings"],
                    "scores": lint["scores"],
                    "colloquial_per_1k": lint["colloquial_per_1k"],
                    "technical_per_1k": lint["technical_per_1k"],
                },
                "style": {
                    "distance": style["distance"],
                    "outliers": style["outliers"],
                },
                "opening": {
                    "score": _opening_score(lint),
                    "definition": lint.get("opening_definition"),
                    "scope": lint.get("opening_scope"),
                    "causal": lint.get("opening_causal"),
                    "concrete": lint.get("opening_concrete"),
                    "background": lint.get("opening_background"),
                },
                "pacing": {
                    "score": pacing,
                    "sent_p50": features["sent_p50"],
                    "target": target_p50,
                },
                "generality": {
                    "score": lint["generality_score"],
                    "project_title": lint["project_title"],
                    "project_first": lint["project_first"],
                    "project_token_count": lint["project_token_count"],
                    "transferable": lint["transferable"],
                },
                "markdown": format_report(text, meta.get("genre")),
                "pairwise": {
                    "win_rate": round(sum(valid) / len(valid), 3) if valid else None,
                    "judgments": judgments,
                },
            }
        )
    report = {
        "run_id": meta["run_id"],
        "topic": meta["topic"],
        "genre": meta["genre"],
        "results": results,
    }
    (run_dir / "evaluation.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    write_review(run_dir, report)
    return report
