#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""人工复核清单：只收录自动改写不能安全补齐的项。"""

from __future__ import annotations

import json
from pathlib import Path

from gen_articles.i18n import t as tr


REVIEW_ACTIONS = {
    "internal_identifiers": "genarticles.review.action.internal_identifiers",
    "hardcore_density": "genarticles.review.action.hardcore_density",
    "universal_claim": "genarticles.review.action.universal_claim",
    "example_promise": "genarticles.review.action.example_promise",
    "opening_context": "genarticles.review.action.opening_context",
    "placeholders": "genarticles.review.action.placeholders",
    "missing_mermaid": "genarticles.review.action.missing_mermaid",
    "mermaid_syntax": "genarticles.review.action.mermaid_syntax",
    "mermaid_too_complex": "genarticles.review.action.mermaid_too_complex",
    "footnote_missing_def": "genarticles.review.action.footnote_missing_def",
    "footnote_unused_def": "genarticles.review.action.footnote_unused_def",
    "emphasis_overuse": "genarticles.review.action.emphasis_overuse",
    "unclosed_emphasis": "genarticles.review.action.unclosed_emphasis",
    "flat_structure": "genarticles.review.action.flat_structure",
    "bare_references": "genarticles.review.action.bare_references",
    "code_language_missing": "genarticles.review.action.code_language_missing",
    "no_blockquotes": "genarticles.review.action.no_blockquotes",
}


def _review(report: dict) -> tuple[str, bool, list[str]]:
    lines = [tr("genarticles.review.header"), ""]
    found = False
    codes: list[str] = []
    for item in report["results"]:
        actions = []
        for issue in item["lint"]["hard_issues"]:
            codes.append(issue["code"])
            key = REVIEW_ACTIONS.get(issue.get("code", ""))
            action = tr(key) if key else tr("genarticles.review.action.hard_issue")
            actions.append(f"{action}: {issue['message']}")
        for issue in item["lint"]["warnings"]:
            codes.append(issue["code"])
            key = REVIEW_ACTIONS.get(issue.get("code", ""))
            if key:
                actions.append(f"{tr(key)}: {issue['message']}")
        for issue in item.get("markdown", {}).get("warnings", []):
            codes.append(issue["code"])
            key = REVIEW_ACTIONS.get(issue.get("code", ""))
            if key:
                actions.append(f"{tr(key)}: {issue['message']}")
        if actions:
            found = True
            lines.append(
                tr(
                    "genarticles.review.candidate",
                    index=item["index"],
                    title=item["title"],
                )
            )
            lines += [f"- {action}" for action in actions]
            lines.append("")
    if not found:
        lines.append(tr("genarticles.review.none"))
    return ("\n".join(lines).strip() + "\n", not found, sorted(set(codes)))


def write_review(run_dir: Path, report: dict) -> Path:
    text, clean, codes = _review(report)
    path = Path(run_dir) / "review.md"
    path.write_text(text, encoding="utf-8")
    (Path(run_dir) / "review.json").write_text(
        json.dumps({"clean": clean, "codes": codes}, ensure_ascii=False),
        encoding="utf-8",
    )
    return path
