#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Material scoring, relevance filtering and Markdown rendering."""

from __future__ import annotations

import hashlib
import re

from gen_articles import runtime
from gen_articles.i18n import t as tr


def dedupe(items: list[dict]) -> list[dict]:
    seen = set()
    out = []
    for item in sorted(items, key=lambda x: x.get("score", 0), reverse=True):
        key = hashlib.sha1(item["content"].encode("utf-8")).hexdigest()
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def _value_score(item: dict,
                 min_value: float = 0.25) -> tuple[float, list[str], str]:
    """按可复用性给素材打分；返回分数、理由、低价值原因。"""
    pack = runtime.pack()
    text = item.get("content", "")
    tags = {str(t).lower() for t in item.get("tags", [])}
    han = len(pack.unit_re.findall(text))
    strong = pack.material_pattern("strong_low", re.I | re.M).search(
        text
    ) or pack.material_pattern("ephemeral").search(text)
    weak = pack.material_pattern("weak_low").findall(text)
    if strong:
        return 0.0, [], f"low_value:{strong.group(0)}"
    if len(weak) >= 2 and han < 120:
        return 0.0, [], f"low_value:{'/'.join(weak[:2])}"
    tech = len(set(pack.material_pattern("tech").findall(text)))
    evidence = len(set(pack.material_pattern("evidence", re.I | re.M).findall(text)))
    reasoning = len(set(pack.material_pattern("reasoning").findall(text)))
    tag_hit = bool(tags & set(pack.words("high_tags")))
    score = min(
        1.0,
        0.12 * tech + 0.18 * evidence + 0.10 * reasoning
        + (0.15 if tag_hit else 0) + (0.10 if han >= 80 else 0),
    )
    if han < 30 and evidence == 0:
        score = min(score, 0.18)
    reasons = []
    if tech:
        reasons.append(tr("genarticles.material.reason.tech", count=tech))
    if evidence:
        reasons.append(tr("genarticles.material.reason.evidence", count=evidence))
    if reasoning:
        reasons.append(tr("genarticles.material.reason.reasoning", count=reasoning))
    if tag_hit:
        reasons.append(tr("genarticles.material.reason.high_tag"))
    if score < min_value and tech < 2:
        return score, reasons, "low_density"
    return score, reasons, ""


def _topic_terms(topic: str) -> set[str]:
    """去掉通用结构词后，按连接词切出主题的有效词。"""
    pack = runtime.pack()
    cleaned = topic
    for word in sorted(pack.words("generic_topic"), key=len, reverse=True):
        cleaned = cleaned.replace(word, " ")
    terms = set()
    token_re = re.compile(
        rf"[A-Za-z][A-Za-z0-9_.-]{{1,}}|{pack.unit_re.pattern}+"
    )
    stop = set(pack.words("en_stop"))
    for token in token_re.findall(cleaned):
        if token[0].isascii():
            if token.lower() not in stop:
                terms.add(token.lower())
            continue
        for segment in pack.pattern("topic_split").split(token):
            if len(segment) >= 2:
                terms.add(segment)
    return terms


def topic_relevance(topic: str, content: str) -> tuple[float, int]:
    """主题词覆盖率；返回 0~1 分数与命中的有效词数。"""
    terms = _topic_terms(topic)
    if not terms:
        return 0.0, 0
    text = content.lower()
    hits = {term for term in terms if term in text}
    coverage = len(hits) / len(terms)
    distinctive = sum(1 for term in hits if len(term) >= 3 or term.isascii())
    score = 0.7 * coverage + 0.3 * min(distinctive / 3, 1.0)
    return round(score, 3), len(hits)


def filter_items(items: list[dict], topic: str | None = None,
                  min_relevance: float = 0.35,
                  min_value: float = 0.25) -> tuple[list[dict], list[dict]]:
    kept, dropped = [], []
    for item in items:
        score, reasons, low = _value_score(item, min_value)
        relevance, hits = 0.0, 0
        if topic:
            relevance, hits = topic_relevance(topic, item["content"])
            item["relevance"] = relevance
        min_hits = 1 if len(_topic_terms(topic or "")) == 1 else 2
        weak_density = (
            low == "low_density" and relevance >= 0.45 and hits >= min_hits
        )
        if low and not weak_density:
            dropped.append({
                "kind": item.get("kind"),
                "id": item.get("id"),
                "path": item.get("path"),
                "reason": low,
            })
            continue
        if topic and (relevance < min_relevance or hits < min_hits):
            dropped.append({
                "kind": item.get("kind"),
                "id": item.get("id"),
                "path": item.get("path"),
                "reason": f"weak_relevance:{relevance}",
            })
            continue
        item["value"] = round(max(score, relevance * 0.5), 2)
        item["value_reasons"] = reasons
        kept.append(item)
    kept.sort(
        key=lambda x: (x.get("relevance", 0), x["value"], x.get("score", 0)),
        reverse=True,
    )
    return kept, dropped


def topic_queries(topic: str) -> list[str]:
    queries = [topic.strip()]
    stripped = runtime.pack().pattern("topic_suffix").sub("", topic).strip()
    terms = sorted(_topic_terms(topic), key=len, reverse=True)[:4]
    candidates = [" ".join(terms) if terms else "", stripped]
    first = runtime.pack().pattern("query_split").split(topic)[0].strip()
    candidates.append(first)
    for candidate in candidates:
        if candidate and candidate not in queries:
            queries.append(candidate)
    return [q for q in queries if q][:3]


def source_id(item: dict) -> str:
    if item["kind"] == "memory":
        return f"memory:{item.get('id', '')}"
    return f"note:{item.get('path', '')}:{item.get('line', 0)}"


MATERIAL_SOURCE_RE = re.compile(r"^## \d+\. (memory:\S+|note:[^\n]+)", re.M)


def project_tokens(markdown: str) -> tuple[str, ...]:
    """素材 tags 里的项目内部名称，供第三方视角检测使用。"""
    tags = set()
    for match in re.finditer(r"tags=([\w,\- ]+)", markdown):
        tags.update(t.strip() for t in match.group(1).split(","))
    return tuple(sorted(
        t for t in tags if re.fullmatch(r"[A-Za-z][\w.\-]*", t)
    ))


def render_markdown(material: dict) -> str:
    lines = [
        tr("genarticles.material.header", topic=material["topic"]),
        "",
        tr("genarticles.material.fetched", at=material["fetched_at"]),
        tr("genarticles.material.source", endpoint=material["endpoint"]),
        tr("genarticles.material.items", count=len(material["items"])),
        tr("genarticles.material.filtered",
           count=material.get("dropped_count", 0)),
        "",
    ]
    for i, item in enumerate(material["items"], 1):
        source = source_id(item)
        if item["kind"] == "memory":
            meta = f"score={item.get('score')} tags={','.join(item.get('tags', []))}"
        else:
            meta = f"score={item.get('score')}"
        if item.get("value") is not None:
            meta += f" value={item['value']}"
        lines.extend([f"## {i}. {source}", "", f"`{meta}`", "", item["content"], ""])
    return "\n".join(lines)
