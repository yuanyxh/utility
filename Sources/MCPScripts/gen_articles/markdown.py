#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Markdown 结构与 Mermaid 图的确定性检查。"""

from __future__ import annotations

import re

from gen_articles import runtime
from gen_articles.diagnostics import issue

MERMAID_BLOCK = re.compile(r"```mermaid\s*\n(.*?)```", re.S)
TABLE_LINE = re.compile(r"^\s*\|.+\|\s*$")
LIST_ITEM = re.compile(r"(?m)^\s*(?:[-*+]|\d+\.)\s+\S")
BLOCKQUOTE = re.compile(r"(?m)^>\s+\S")
HEADING = re.compile(r"(?m)^##\s+\S")
REFERENCE_LINK = re.compile(r"\[[^\]]+\]\[[^\]]*\]")
REFERENCE_DEF = re.compile(r"(?m)^\[[^\]]+\]:\s+\S+")
REFERENCE_DEF_LABEL = re.compile(r"(?m)^\[([^\]]+)\]:\s+\S+")
INLINE_LINK = re.compile(r"\[[^\]]+\]\([^)]+\)")
GRAPH_HEAD = re.compile(r"^(?:graph|flowchart)\s+(?:TB|TD|BT|RL|LR)\b")
OTHER_TYPES = (
    "sequenceDiagram", "stateDiagram", "stateDiagram-v2",
    "classDiagram", "erDiagram", "gantt", "pie", "journey",
)


def _table_count(text: str) -> int:
    count, block = 0, []
    for line in text.splitlines() + [""]:
        if TABLE_LINE.match(line):
            block.append(line)
            continue
        if len(block) >= 2 and any(re.match(r"^\s*\|?[\s:|-]+\|?\s*$", l)
                                   for l in block):
            count += 1
        block = []
    return count


def validate_mermaid(block: str) -> list[str]:
    block = re.sub(r"(?m)^\s*```(?:mermaid)?\s*$", "", block)
    lines = [
        line.strip() for line in block.splitlines()
        if line.strip() and not line.strip().startswith("%%")
    ]
    if not lines:
        return ["empty diagram"]
    head = lines[0]
    if GRAPH_HEAD.match(head):
        kind = "flowchart"
    elif head.startswith(OTHER_TYPES):
        kind = "sequence" if head.startswith("sequenceDiagram") else "other"
    else:
        return [f"Unknown diagram type: {head[:24]}"]
    issues = []
    if kind == "flowchart":
        subgraphs = len(re.findall(r"(?m)^\s*subgraph\b", block))
        ends = len(re.findall(r"(?m)^\s*end\s*$", block))
        if subgraphs != ends:
            issues.append("subgraph not closed")
        if not re.search(r"-->|---|==>", block):
            issues.append("no edges")
    elif kind == "sequence":
        if not re.search(r"->>|-->>|->", block):
            issues.append("no message arrows")
    elif not re.search(r"-->|--\||\|", block):
        issues.append("no relation edges")
    if block.count('"') % 2:
        issues.append("unclosed quotes")
    return issues


def _code_stats(text: str) -> tuple[int, int]:
    total = with_lang = 0
    inside = False
    for line in text.splitlines():
        if not line.startswith("```"):
            continue
        if inside:
            inside = False
            continue
        total += 1
        if line[3:].strip():
            with_lang += 1
        inside = True
    return total, with_lang


def _bare_references(text: str) -> list[str]:
    prose = re.sub(r"```.*?```", "", text, flags=re.S)
    prose = re.sub(r"(?m)^\[[^\]]+\]:\s+\S+.*$", "", prose)
    prose = re.sub(r"(?m)^>.*$", "", prose)
    pack = runtime.pack()
    labels = set(REFERENCE_DEF_LABEL.findall(text))
    found = []
    for sentence in re.split(pack.sentence_end_lookbehind, prose):
        sentence = sentence.strip()
        if not sentence or not pack.markdown_pattern("reference_sources", re.I).search(sentence):
            continue
        if REFERENCE_LINK.search(sentence) or INLINE_LINK.search(sentence):
            continue
        if any(f"[{label}]" in sentence for label in labels):
            continue
        found.append(sentence[:120])
    return found


def format_report(text: str, genre: str | None = None) -> dict:
    blocks = MERMAID_BLOCK.findall(text)
    issues = [issue for block in blocks for issue in validate_mermaid(block)]
    tables = _table_count(text)
    lists = len(LIST_ITEM.findall(text))
    quotes = len(BLOCKQUOTE.findall(text))
    headings = len(HEADING.findall(text))
    body = re.sub(r"(?m)^\[[^\]]+\]:\s+\S+.*$", "", text)
    ref_labels = set(REFERENCE_DEF_LABEL.findall(text))
    shortcut_body = REFERENCE_LINK.sub("", body)
    shortcut_links = sum(
        1 for label in ref_labels if f"[{label}]" in shortcut_body
    )
    reference_links = len(REFERENCE_LINK.findall(body)) + shortcut_links
    reference_defs = len(REFERENCE_DEF.findall(text))
    inline_links = len(INLINE_LINK.findall(text))
    bare_references = _bare_references(text)
    code_total, code_with_lang = _code_stats(text)
    if reference_defs >= 1 and (reference_links >= 1 or inline_links >= 1):
        reference_score = 1.0
    elif inline_links >= 1:
        reference_score = 0.5
    else:
        reference_score = 0.0
    pack = runtime.pack()
    expected = genre in pack.markdown_words("diagram_genres")
    if not blocks:
        diagram_score = 0.0 if expected else 0.3
    elif issues:
        diagram_score = 0.4
    elif len(blocks) > 3:
        diagram_score = 0.7
    else:
        diagram_score = 1.0
    structure = (
        0.12 * min(1.0, headings / 5)
        + 0.12 * min(1.0, tables / 2)
        + 0.12 * min(1.0, lists / 3)
        + 0.12 * min(1.0, quotes / 1)
    )
    markdown_score = round(
        min(1.0, 0.4 * diagram_score + structure + 0.12 * reference_score),
        3,
    )
    warnings = []
    if expected and not blocks:
        warnings.append(issue("missing_mermaid"))
    if blocks and issues:
        warnings.append(issue("mermaid_syntax", detail=issues[:3]))
    if len(blocks) > 3:
        warnings.append(issue("too_many_mermaid", count=len(blocks)))
    if not tables and not lists and not quotes:
        warnings.append(issue("flat_structure"))
    if bare_references:
        warnings.append(issue("bare_references", sample=bare_references[:2]))
    if code_total > code_with_lang:
        warnings.append(issue("code_language_missing", count=code_total - code_with_lang))
    if not quotes and pack.markdown_pattern("blockquote_cue").search(text):
        warnings.append(issue("no_blockquotes"))
    return {
        "mermaid_count": len(blocks),
        "mermaid_issues": issues,
        "tables": tables,
        "lists": lists,
        "blockquotes": quotes,
        "headings": headings,
        "reference_links": reference_links,
        "reference_defs": reference_defs,
        "inline_links": inline_links,
        "reference_score": round(reference_score, 3),
        "code_blocks": code_total,
        "code_with_lang": code_with_lang,
        "bare_references": bare_references,
        "diagram_score": round(diagram_score, 3),
        "markdown_score": markdown_score,
        "warnings": warnings,
    }
