#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""程序化语义与 Markdown 修复：Mermaid、引用、表格、列表、引用块、普遍断言。"""

from __future__ import annotations

import re
from pathlib import Path

from utility.articles.candidate_ops import (
    candidate_path,
    commit_candidate,
    load_meta,
    project_tokens_from_run,
    strict_lint,
    targets,
)
from utility.articles.textops import label_code_blocks, strip_preamble
from utility.articles.i18n import t as tr
from utility.articles import runtime
from utility.articles.llm import LLMClient, chat_with_retry
from utility.articles.stylometry import article_features
from utility.articles.markdown import format_report

URL = re.compile(r"https?://[^\s)>\]]+")


def build_format_prompt(
    article: str, issues: list[str], urls: list[str]
) -> tuple[str, str]:
    if urls:
        link_block = "\n".join(f"- {url}" for url in urls)
    else:
        link_block = tr("genarticles.format.no_links")
    issue_block = "\n".join(f"- {issue}" for issue in issues) or tr(
        "genarticles.prompt.none"
    )
    return (
        runtime.pack().prompt("gen_articles_format_system"),
        runtime.pack().prompt(
            "gen_articles_format_user",
            link_block=link_block,
            issue_block=issue_block,
            article=article,
        ),
    )


def format_repair(
    run_dir: Path, index: int | None = None, rounds: int = 2, max_tokens: int = 8192
) -> list[dict]:
    meta_path, meta = load_meta(run_dir)
    genre = meta.get("genre")
    material_path = run_dir / "material.md"
    material = (
        material_path.read_text(encoding="utf-8") if material_path.exists() else ""
    )
    tokens = project_tokens_from_run(run_dir)
    client = LLMClient()
    results = []
    for candidate in targets(meta, index):
        i = candidate["index"]
        path = Path(candidate["path"])
        original = path.read_text(encoding="utf-8")
        current = label_code_blocks(original)
        before = format_report(original, genre)
        before_lint = strict_lint(original, tokens)
        urls = sorted(set(URL.findall(material)) | set(URL.findall(original)))
        status = "ok"
        out = path
        for round_no in range(1, rounds + 1):
            fmt = format_report(current, genre)
            lint = strict_lint(current, tokens)
            issues = [i["message"] for i in fmt["warnings"]]
            issues += [i["message"] for i in lint["hard_issues"]]
            issues += [
                f"Unsupported universal claim: {claim}"
                for claim in lint["universal_claims"]
            ]
            if not issues:
                break
            status = "still_fail"
            system, user = build_format_prompt(current, issues, urls)
            fixed = strip_preamble(
                chat_with_retry(client, user, system, 0.3, max_tokens, True)
            )
            current = label_code_blocks(fixed)
            out = candidate_path(run_dir, i, f"fmt{round_no}")
            out.write_text(current, encoding="utf-8")
        if current != original and out == path:
            out = candidate_path(run_dir, i, "fmt0")
            out.write_text(current, encoding="utf-8")
        after_fmt = format_report(current, genre)
        after_lint = strict_lint(current, tokens)
        lint_improved = (
            before_lint["result"] != "PASS" and after_lint["result"] == "PASS"
        )
        markdown_improved = after_fmt["markdown_score"] > before["markdown_score"]
        warnings_improved = len(after_fmt["warnings"]) < len(before["warnings"])
        diagrams_kept = after_fmt["mermaid_count"] >= min(before["mermaid_count"], 3)
        improved = (
            out != path
            and after_lint["result"] == "PASS"
            and diagrams_kept
            and (markdown_improved or lint_improved or warnings_improved)
        )
        if improved:
            status = "repaired"
            commit_candidate(
                meta,
                meta_path,
                candidate,
                path=out,
                features=article_features(current),
                source_field="format_from",
                source_name=path.name,
            )
        results.append(
            {
                "index": i,
                "status": status,
                "before": {
                    "markdown": before["markdown_score"],
                    "warnings": before["warnings"],
                },
                "after": {
                    "markdown": after_fmt["markdown_score"],
                    "warnings": after_fmt["warnings"],
                    "lint": after_lint["result"],
                },
                "path": str(out),
            }
        )
    return results
