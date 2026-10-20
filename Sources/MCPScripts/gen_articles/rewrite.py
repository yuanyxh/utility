#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 4：按 lint 硬性问题定向重写候选，不新增未经证实的技术事实。"""

from __future__ import annotations

import shutil
from pathlib import Path

from gen_articles import runtime
from gen_articles.textops import (
    merge_short_sentences,
    split_long_paragraphs,
    strip_preamble,
)
from gen_articles.candidate_ops import (
    candidate_path,
    commit_candidate,
    load_meta,
    profile_for,
    profile_mean,
    project_tokens_from_run,
    strict_lint,
    targets,
)
from gen_articles.i18n import t as tr
from gen_articles.llm import LLMClient, chat_with_retry
from gen_articles.stylometry import article_features

# 只有纯表述问题才允许模型修；缺证据类问题无法靠改写补齐
REPAIRABLE_CODES = {
    "half_width_punct",
    "strong_ai_template",
    "soft_ai_template",
    "colloquial_density",
    "inline_calls",
    "inline_density",
    "title_project_name",
    "first_paragraph_project_name",
    "internal_identifiers",
    "opening_context",
}


def repairable_issues(issues: list[dict]) -> list[dict]:
    return [issue for issue in issues if issue.get("code") in REPAIRABLE_CODES]


def build_rewrite_prompt(
    article: str, issues: list[dict], warnings: list[dict]
) -> tuple[str, str]:
    none = tr("genarticles.prompt.none")
    issue_text = "\n".join(f"- {i['message']}" for i in issues) or none
    warning_text = "\n".join(f"- {w['message']}" for w in warnings) or none
    return (
        runtime.pack().prompt("gen_articles_rewrite_system", soul=runtime.soul_text()),
        runtime.pack().prompt(
            "gen_articles_rewrite_user",
            article=article,
            issue_text=issue_text,
            warning_text=warning_text,
        ),
    )


def merge_run(run_dir: Path, index: int | None = None) -> list[dict]:
    """确定性合并相邻短句：只把句号换成更长的连接，不改词语。"""
    meta_path, meta = load_meta(run_dir)
    profile = profile_for(meta.get("genre", ""))
    target = profile_mean(profile, "sent_p50", 55)
    tokens = project_tokens_from_run(run_dir)
    results = []
    for candidate in targets(meta, index):
        i = candidate["index"]
        path = Path(candidate["path"])
        article = path.read_text(encoding="utf-8")
        before = article_features(article)
        merged = merge_short_sentences(article, target)
        if merged == article:
            results.append({"index": i, "status": "ok", "p50": before["sent_p50"]})
            continue
        out = candidate_path(run_dir, i, "merge")
        out.write_text(merged, encoding="utf-8")
        after = article_features(merged)
        lint = strict_lint(merged, tokens)
        improved = after["sent_p50"] > before["sent_p50"] and lint["result"] == "PASS"
        results.append(
            {
                "index": i,
                "status": "merged" if improved else "unchanged",
                "p50_before": before["sent_p50"],
                "p50_after": after["sent_p50"],
                "target": target,
                "path": str(out),
            }
        )
        if improved:
            commit_candidate(
                meta,
                meta_path,
                candidate,
                path=out,
                features=after,
                source_field="merged_from",
                source_name=path.name,
            )
    return results


def split_run(run_dir: Path, index: int | None = None) -> list[dict]:
    """确定性拆长段：只改段落边界，不改句子与事实。"""
    meta_path, meta = load_meta(run_dir)
    tokens = project_tokens_from_run(run_dir)
    results = []
    for candidate in targets(meta, index):
        i = candidate["index"]
        path = Path(candidate["path"])
        article = path.read_text(encoding="utf-8")
        before = article_features(article)
        split = split_long_paragraphs(article)
        if split == article:
            results.append({"index": i, "status": "ok", "para": before["para_mean"]})
            continue
        out = candidate_path(run_dir, i, "split")
        out.write_text(split, encoding="utf-8")
        after = article_features(split)
        lint = strict_lint(split, tokens)
        improved = after["para_mean"] < before["para_mean"] and lint["result"] == "PASS"
        results.append(
            {
                "index": i,
                "status": "split" if improved else "unchanged",
                "para_before": before["para_mean"],
                "para_after": after["para_mean"],
                "path": str(out),
            }
        )
        if improved:
            commit_candidate(
                meta,
                meta_path,
                candidate,
                path=out,
                features=after,
                source_field="split_from",
                source_name=path.name,
            )
    return results


def build_pacing_prompt(
    article: str, target_p50: float, target_p90: float
) -> tuple[str, str]:
    return (
        runtime.pack().prompt("gen_articles_pacing_system", soul=runtime.soul_text()),
        runtime.pack().prompt(
            "gen_articles_pacing_user",
            target_p50=f"{target_p50:.0f}",
            target_p90=f"{target_p90:.0f}",
            article=article,
        ),
    )


def pacing_rewrite(
    run_dir: Path, index: int | None = None, max_tokens: int = 8192
) -> list[dict]:
    meta_path, meta = load_meta(run_dir)
    profile = profile_for(meta.get("genre", ""))
    target = profile_mean(profile, "sent_p50", 55)
    target90 = profile_mean(profile, "sent_p90", 140)
    para_target = profile_mean(profile, "para_mean", 40)
    client = LLMClient()
    tokens = project_tokens_from_run(run_dir)
    results = []
    for candidate in targets(meta, index):
        i = candidate["index"]
        path = Path(candidate["path"])
        article = path.read_text(encoding="utf-8")
        before = article_features(article)
        need_pace = (
            before["sent_p50"] < target * 0.9 or before["para_mean"] > para_target * 2
        )
        if not need_pace:
            results.append(
                {
                    "index": i,
                    "status": "ok",
                    "p50": before["sent_p50"],
                    "target": target,
                }
            )
            continue
        system, user = build_pacing_prompt(article, target, target90)
        fixed = strip_preamble(
            chat_with_retry(client, user, system, 0.3, max_tokens, True)
        )
        after = article_features(fixed)
        out = candidate_path(run_dir, i, "pace")
        out.write_text(fixed, encoding="utf-8")
        lint = strict_lint(fixed, tokens)
        improved = after["sent_p50"] > before["sent_p50"] and lint["result"] == "PASS"
        results.append(
            {
                "index": i,
                "status": "paced" if improved else "unchanged",
                "p50_before": before["sent_p50"],
                "p50_after": after["sent_p50"],
                "para_before": before["para_mean"],
                "para_after": after["para_mean"],
                "target": target,
                "path": str(out),
            }
        )
        if improved:
            commit_candidate(
                meta,
                meta_path,
                candidate,
                path=out,
                features=after,
                source_field="paced_from",
                source_name=path.name,
            )
    return results


def rewrite_run(
    run_dir: Path, index: int | None = None, rounds: int = 1, max_tokens: int = 8192
) -> list[dict]:
    meta_path, meta = load_meta(run_dir)
    client = LLMClient()
    tokens = project_tokens_from_run(run_dir)
    results = []
    for candidate in targets(meta, index):
        i = candidate["index"]
        path = Path(candidate["path"])
        original = path.read_text(encoding="utf-8")
        current, out = original, path
        before = strict_lint(original, tokens)
        opening_warning = [
            w for w in before["warnings"] if w.get("code") == "opening_context"
        ]
        if before["result"] == "PASS" and not opening_warning:
            results.append({"index": i, "status": "already_pass"})
            continue
        only_opening = before["result"] == "PASS"
        if only_opening:
            issues = opening_warning
        else:
            issues = before["hard_issues"]
        if before["result"] != "PASS" and not repairable_issues(issues):
            results.append(
                {
                    "index": i,
                    "status": "skip_unrepairable",
                    "before": issues,
                    "after": issues,
                    "path": str(path),
                }
            )
            continue
        backup = run_dir / "candidates" / "original" / f"candidate_{i}.md"
        backup.parent.mkdir(parents=True, exist_ok=True)
        if not backup.exists():
            shutil.copy2(path, backup)
        status = "still_fail"
        for round_no in range(1, rounds + 1):
            lint = strict_lint(current, tokens)
            if lint["result"] == "PASS" and lint["opening_background"]:
                status = "fixed"
                break
            if lint["result"] == "FAIL" and not repairable_issues(lint["hard_issues"]):
                break
            prompt_issues = lint["hard_issues"] or [
                w for w in lint["warnings"] if w.get("code") == "opening_context"
            ]
            if not prompt_issues:
                break
            system, user = build_rewrite_prompt(
                current, prompt_issues, lint["warnings"]
            )
            current = strip_preamble(
                chat_with_retry(client, user, system, 0.3, max_tokens, True)
            )
            out = run_dir / "candidates" / f"candidate_{i}_r{round_no}.md"
            out.write_text(current, encoding="utf-8")
        after = strict_lint(current, tokens)
        improved = out != path and (
            (after["result"] == "PASS" and after["opening_background"])
            or len(after["hard_issues"]) < len(before["hard_issues"])
        )
        if after["result"] == "PASS" and (
            not only_opening or after["opening_background"]
        ):
            status = "fixed"
        elif improved:
            status = "partial"
        results.append(
            {
                "index": i,
                "status": status,
                "before": issues,
                "after": after["hard_issues"],
                "path": str(out),
            }
        )
        if status in ("fixed", "partial"):
            commit_candidate(
                meta,
                meta_path,
                candidate,
                path=out,
                features=article_features(current),
                source_field="rewritten_from",
                source_name=str(backup.relative_to(run_dir)),
            )
    return results
