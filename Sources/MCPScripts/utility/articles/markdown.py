#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Markdown 结构与 Mermaid 图的确定性检查。"""

from __future__ import annotations

import re

from utility.articles import runtime
from utility.articles.diagnostics import issue

MERMAID_BLOCK = re.compile(r"```mermaid\s*\n(.*?)```", re.S)
TABLE_LINE = re.compile(r"^\s*\|.+\|\s*$")
LIST_ITEM = re.compile(r"(?m)^\s*(?:[-*+]|\d+\.)\s+\S")
BLOCKQUOTE = re.compile(r"(?m)^>\s+\S")
HEADING = re.compile(r"(?m)^##\s+\S")
REFERENCE_LINK = re.compile(r"\[[^\]]+\]\[[^\]]*\]")
REFERENCE_DEF = re.compile(r"(?m)^\[(?!\^)[^\]]+\]:\s+\S+")
REFERENCE_DEF_LABEL = re.compile(r"(?m)^\[(?!\^)([^\]]+)\]:\s+\S+")
INLINE_LINK = re.compile(r"\[[^\]]+\]\([^)]+\)")
GRAPH_HEAD = re.compile(r"^(?:graph|flowchart)\s+(?:TB|TD|BT|RL|LR)\b")
FOOTNOTE_DEF = re.compile(r"(?m)^\[\^([^\]]+)\]:\s+\S+")
FOOTNOTE_REF = re.compile(r"\[\^([^\]]+)\]")
TASK_ITEM = re.compile(r"(?m)^\s*[-*+]\s+\[[ xX]\]\s+\S")
IMAGE = re.compile(r"!\[[^\]]*\]\([^)]+\)")
RULE = re.compile(r"(?m)^\s*(?:-{3,}|\*{3,}|_{3,})\s*$")
STRONG = re.compile(r"\*\*(?!\s)(.+?)(?<!\s)\*\*")
EMPHASIS = re.compile(
    r"(?<![A-Za-z0-9_*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?!\*)|"
    r"(?<![A-Za-z0-9_])_(?!\s)([^_\n]+?)(?<!\s)_(?![A-Za-z0-9_])"
)
STRIKE = re.compile(r"~~(?!\s)(.+?)(?<!\s)~~")
FENCED_BLOCK = re.compile(r"```.*?```", re.S)
INLINE_CODE_SPAN = re.compile(r"`[^`\n]*`")
FLOW_EDGE = re.compile(
    r"^\s*([A-Za-z_][\w-]*)\s*(?:\[[^\]]*\]|\([^)]*\)|\{[^}]*\})?"
    r"\s*(-->|---|==>|--\||-\.->)\s*(?:\|[^|]*\|\s*)?"
    r"([A-Za-z_][\w-]*)"
)
FLOW_NODE = re.compile(r"^\s*([A-Za-z_][\w-]*)\s*(?:\[|\(|\{)")
OTHER_TYPES = (
    "sequenceDiagram",
    "stateDiagram",
    "stateDiagram-v2",
    "classDiagram",
    "erDiagram",
    "gantt",
    "pie",
    "journey",
)


def _table_count(text: str) -> int:
    count, block = 0, []
    for line in text.splitlines() + [""]:
        if TABLE_LINE.match(line):
            block.append(line)
            continue
        if len(block) >= 2 and any(
            re.match(r"^\s*\|?[\s:|-]+\|?\s*$", l) for l in block
        ):
            count += 1
        block = []
    return count


def _flow_graph(lines: list[str]) -> tuple[set[str], list[tuple[str, str]], int]:
    nodes: set[str] = set()
    edges: list[tuple[str, str]] = []
    subgraphs = 0
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("subgraph"):
            subgraphs += 1
            continue
        if re.match(
            r"^(?:end|classDef|class|style|click|linkStyle|direction)\b", stripped
        ):
            continue
        match = FLOW_EDGE.match(line)
        if match:
            source, target = match.group(1), match.group(3)
            edges.append((source, target))
            nodes.update((source, target))
        else:
            node = FLOW_NODE.match(line)
            if node:
                nodes.add(node.group(1))
    return nodes, edges, subgraphs


def _graph_metrics(
    nodes: set[str], edges: list[tuple[str, str]], subgraphs: int
) -> dict:
    adjacency: dict[str, list[str]] = {}
    for source, target in edges:
        adjacency.setdefault(source, []).append(target)
        adjacency.setdefault(target, [])
    max_out = max((len(v) for v in adjacency.values()), default=0)
    branch = sum(1 for v in adjacency.values() if len(v) >= 2)
    visiting: set[str] = set()
    memo: dict[str, int] = {}

    def depth(node: str) -> int:
        if node in memo:
            return memo[node]
        if node in visiting:
            return 0
        visiting.add(node)
        value = max((1 + depth(nxt) for nxt in adjacency.get(node, [])), default=0)
        visiting.discard(node)
        memo[node] = value
        return value

    max_depth = max((depth(n) for n in adjacency), default=0)
    return {
        "nodes": len(nodes),
        "edges": len(edges),
        "max_out_degree": max_out,
        "branch_nodes": branch,
        "max_depth": max_depth,
        "subgraphs": subgraphs,
    }


def _mermaid_metrics(block: str) -> dict:
    block = re.sub(r"(?m)^\s*```(?:mermaid)?\s*$", "", block)
    lines = [
        line.strip()
        for line in block.splitlines()
        if line.strip() and not line.strip().startswith("%%")
    ]
    if not lines:
        return {"kind": "empty"}
    head = lines[0]
    if GRAPH_HEAD.match(head):
        nodes, edges, subgraphs = _flow_graph(lines[1:])
        return {"kind": "flowchart", **_graph_metrics(nodes, edges, subgraphs)}
    if head.startswith("sequenceDiagram"):
        participants: set[str] = set()
        messages = 0
        for line in lines[1:]:
            pm = re.match(r"^participant\s+([A-Za-z_][\w-]*)", line)
            if pm:
                participants.add(pm.group(1))
                continue
            em = re.match(
                r"^([A-Za-z_][\w-]*)\s*(?:->>|-->>|->|-x|--x)[+-]?\s*([A-Za-z_][\w-]*)",
                line,
            )
            if em:
                participants.update((em.group(1), em.group(2)))
                messages += 1
        return {
            "kind": "sequence",
            "nodes": len(participants),
            "edges": messages,
            "max_out_degree": 0,
            "branch_nodes": 0,
            "max_depth": 0,
            "subgraphs": 0,
        }
    nodes, edges, subgraphs = _flow_graph(lines)
    return {"kind": "state", **_graph_metrics(nodes, edges, subgraphs)}


def _mermaid_complexity(metrics: dict) -> tuple[list[str], bool]:
    if metrics.get("kind") not in {"flowchart", "state", "sequence"}:
        return [], False
    pack = runtime.pack()
    nodes = int(metrics.get("nodes", 0))
    edges = int(metrics.get("edges", 0))
    depth = int(metrics.get("max_depth", 0))
    out_degree = int(metrics.get("max_out_degree", 0))
    branch = int(metrics.get("branch_nodes", 0))
    subgraphs = int(metrics.get("subgraphs", 0))
    details: list[str] = []
    severe = False
    nodes_fail = int(pack.threshold("mermaid_nodes_fail"))
    depth_fail = int(pack.threshold("mermaid_depth_fail"))
    if nodes > nodes_fail:
        details.append(f"nodes={nodes}>{nodes_fail}")
        severe = True
    elif nodes > int(pack.threshold("mermaid_nodes_warn")):
        details.append(f"nodes={nodes}")
    if depth > depth_fail:
        details.append(f"depth={depth}>{depth_fail}")
        severe = True
    elif depth > int(pack.threshold("mermaid_depth_warn")):
        details.append(f"depth={depth}")
    if out_degree > int(pack.threshold("mermaid_out_degree_warn")):
        details.append(f"out_degree={out_degree}")
    if branch > int(pack.threshold("mermaid_branch_warn")):
        details.append(f"branch_nodes={branch}")
    if subgraphs > int(pack.threshold("mermaid_subgraphs_warn")):
        details.append(f"subgraphs={subgraphs}")
    if edges > nodes + int(pack.threshold("mermaid_edges_extra")):
        details.append(f"edges={edges}")
    if metrics.get("kind") == "sequence":
        if nodes > int(pack.threshold("mermaid_sequence_participants_warn")):
            details.append(f"participants={nodes}")
        if edges > int(pack.threshold("mermaid_sequence_messages_warn")):
            details.append(f"messages={edges}")
    return details, severe


def validate_mermaid(block: str) -> list[str]:
    block = re.sub(r"(?m)^\s*```(?:mermaid)?\s*$", "", block)
    lines = [
        line.strip()
        for line in block.splitlines()
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


def _inline_prose(text: str) -> str:
    return INLINE_CODE_SPAN.sub("", FENCED_BLOCK.sub("", text))


def _emphasis_stats(text: str) -> tuple[int, int, int, list[str]]:
    prose = _inline_prose(text)
    strong = len(STRONG.findall(prose))
    emphasis = len(EMPHASIS.findall(prose))
    strike = len(STRIKE.findall(prose))
    unbalanced = []
    if prose.count("**") % 2:
        unbalanced.append("**")
    if prose.count("~~") % 2:
        unbalanced.append("~~")
    return strong, emphasis, strike, unbalanced


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
        if not sentence or not pack.markdown_pattern("reference_sources", re.I).search(
            sentence
        ):
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
    footnote_defs = set(FOOTNOTE_DEF.findall(text))
    footnote_refs = set(FOOTNOTE_REF.findall(FOOTNOTE_DEF.sub("", text)))
    task_items = len(TASK_ITEM.findall(text))
    images = len(IMAGE.findall(text))
    rules = len(RULE.findall(text))
    strong, emphasis, strike, unbalanced = _emphasis_stats(text)
    body = re.sub(r"(?m)^\[[^\]]+\]:\s+\S+.*$", "", text)
    ref_labels = set(REFERENCE_DEF_LABEL.findall(text))
    shortcut_body = REFERENCE_LINK.sub("", body)
    shortcut_links = sum(1 for label in ref_labels if f"[{label}]" in shortcut_body)
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
    metrics = [_mermaid_metrics(block) for block in blocks]
    complexity: list[str] = []
    severe = False
    for metric in metrics:
        details, hard = _mermaid_complexity(metric)
        complexity.extend(details)
        severe = severe or hard
    if not blocks:
        diagram_score = 0.0 if expected else 0.3
    elif issues:
        diagram_score = 0.4
    elif severe:
        diagram_score = 0.4
    elif complexity or len(blocks) > 3:
        diagram_score = 0.7
    else:
        diagram_score = 1.0
    structure = (
        0.12 * min(1.0, headings / 5)
        + 0.12 * min(1.0, tables / 2)
        + 0.12 * min(1.0, lists / 3)
        + 0.12 * min(1.0, quotes / 1)
        + 0.03 * min(1.0, len(footnote_refs))
        + 0.02 * min(1.0, task_items)
        + 0.02 * min(1.0, images)
        + 0.01 * min(1.0, rules)
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
    if complexity:
        warnings.append(issue("mermaid_too_complex", detail=", ".join(complexity[:4])))
    if len(blocks) > 3:
        warnings.append(issue("too_many_mermaid", count=len(blocks)))
    if not tables and not lists and not quotes:
        warnings.append(issue("flat_structure"))
    if bare_references:
        warnings.append(issue("bare_references", sample=bare_references[:2]))
    if code_total > code_with_lang:
        warnings.append(
            issue("code_language_missing", count=code_total - code_with_lang)
        )
    if not quotes and pack.markdown_pattern("blockquote_cue").search(text):
        warnings.append(issue("no_blockquotes"))
    han = len(pack.unit_re.findall(_inline_prose(text)))
    strong_density = round(strong / han * 1000, 1) if han else 0.0
    strong_limit = pack.threshold("strong_warn_per_1k")
    if strong_density > strong_limit:
        warnings.append(
            issue(
                "emphasis_overuse",
                count=strong,
                density=strong_density,
                limit=strong_limit,
            )
        )
    if unbalanced:
        warnings.append(issue("unclosed_emphasis", detail=unbalanced))
    missing_defs = sorted(footnote_refs - footnote_defs)
    unused_defs = sorted(footnote_defs - footnote_refs)
    if missing_defs:
        warnings.append(issue("footnote_missing_def", detail=missing_defs[:3]))
    if unused_defs:
        warnings.append(issue("footnote_unused_def", detail=unused_defs[:3]))
    return {
        "mermaid_count": len(blocks),
        "mermaid_issues": issues,
        "tables": tables,
        "lists": lists,
        "blockquotes": quotes,
        "headings": headings,
        "footnotes": len(footnote_refs),
        "footnote_defs": len(footnote_defs),
        "task_items": task_items,
        "images": images,
        "rules": rules,
        "strong": strong,
        "emphasis": emphasis,
        "strikethrough": strike,
        "strong_density": strong_density,
        "reference_links": reference_links,
        "reference_defs": reference_defs,
        "inline_links": inline_links,
        "reference_score": round(reference_score, 3),
        "code_blocks": code_total,
        "code_with_lang": code_with_lang,
        "bare_references": bare_references,
        "diagram_score": round(diagram_score, 3),
        "mermaid_metrics": metrics,
        "markdown_score": markdown_score,
        "warnings": warnings,
    }
