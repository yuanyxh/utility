#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""素材来源：热层记忆 + 受限 Extracts 目录。"""

from __future__ import annotations

import urllib.error
from datetime import datetime, timezone

from utility.articles.config import Config
from utility.articles.material import dedupe, filter_items, topic_queries
from utility.articles.memory_client import recall_hot


def _hot_items(config: Config, query: str, limit: int) -> tuple[list[dict], str | None]:
    if not config.memory_endpoint:
        return [], "memoryEndpoint is not configured"
    try:
        return recall_hot(config.memory_endpoint, query, limit), None
    except (urllib.error.URLError, OSError, RuntimeError, KeyError) as exc:
        return [], f"{type(exc).__name__}: {exc}"


def _sections(text: str, limit: int = 4000) -> list[tuple[int, str]]:
    lines = text.splitlines()
    starts = [
        i
        for i, line in enumerate(lines)
        if line.startswith("## ") or line.startswith("### ")
    ]
    if not starts:
        return [(1, text)]
    out = []
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        body = "\n".join(lines[start:end]).strip()
        if len(body) >= 120:
            out.append((start + 1, body[:limit]))
    return out


def _extract_items(config: Config, limit: int) -> list[dict]:
    root = config.extracts_dir
    excluded = set(config.material.get("excludeDirs", []))
    section_limit = int(config.material.get("maxCharsPerItem", 4000))
    items = []
    for path in sorted(root.rglob("*.md")):
        if len(items) >= limit * 8:
            break
        try:
            rel = path.relative_to(root)
        except ValueError:
            continue
        if any(part in excluded for part in rel.parts):
            continue
        if path.is_symlink():
            try:
                path.resolve().relative_to(root.resolve())
            except ValueError:
                continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line, section in _sections(text, section_limit):
            items.append(
                {
                    "kind": "note",
                    "path": str(rel),
                    "line": line,
                    "content": section,
                    "score": 0.5,
                }
            )
    return items


def collect_material(topic: str, config: Config) -> dict:
    """深挖热层记忆与 Extracts，过滤后返回可渲染素材。"""
    limit = int(config.material.get("hotLimit", 20))
    extracts_limit = int(config.material.get("extractsLimit", 20))
    items, error = [], None
    for query in topic_queries(topic):
        found, query_error = _hot_items(config, query, limit)
        items.extend(found)
        error = error or query_error
    items.extend(_extract_items(config, extracts_limit))
    items, dropped = filter_items(
        dedupe(items),
        topic,
        float(config.material.get("minRelevance", 0.35)),
        float(config.material.get("minValue", 0.25)),
    )
    max_items = int(config.material.get("maxItems", limit + extracts_limit))
    items = items[:max_items]
    return {
        "topic": topic,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "endpoint": config.memory_endpoint,
        "error": error,
        "items": items,
        "dropped": dropped,
        "dropped_count": len(dropped),
    }
