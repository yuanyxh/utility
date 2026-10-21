#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从高价值记忆素材中发现通用技术选题，生成可复现 manifest。"""

from __future__ import annotations

import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from utility.articles import runtime
from utility.articles.llm import LLMClient, LLMError
from utility.articles.router import classify_topic
from utility.articles.material import source_id
from utility.articles.sources import collect_material as collect_sources
from utility.articles.i18n import t as tr
from utility.articles.textnorm import INTERNAL_ID, overlap


def _excerpt(text: str, limit: int = 600) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


def collect_material(
    limit_per_query: int = 6, seeds: list[str] | None = None
) -> list[dict]:
    items, seen = [], set()
    for query in seeds or runtime.pack().words("seeds"):
        result = collect_sources(query, runtime.config())
        for item in result["items"]:
            key = hashlib.sha1(item["content"].encode("utf-8")).hexdigest()
            if key in seen:
                continue
            seen.add(key)
            items.append({**item, "source_id": source_id(item)})
    source_days = float(runtime.config().material.get("sourceCooldownDays", 14))
    used = set()
    for row in _load_history():
        if _within_cooldown(row, source_days):
            used.update(row.get("sources") or [])
    items.sort(key=lambda x: (x["source_id"] in used, -x.get("value", 0)))
    return items


def _history_path() -> Path:
    name = runtime.config().topics.get("historyFile", "topic_history.json")
    path = Path(name).expanduser()
    return path if path.is_absolute() else runtime.config().root / path


def _load_history() -> list[dict]:
    path = _history_path()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    rows = data.get("topics") if isinstance(data, dict) else None
    return [row for row in (rows or []) if isinstance(row, dict) and row.get("topic")]


def _within_cooldown(row: dict, days: float) -> bool:
    if days <= 0:
        return True
    try:
        seen = datetime.fromisoformat(str(row.get("lastSeen", "")))
    except (TypeError, ValueError):
        return True
    return (datetime.now(timezone.utc) - seen).days < days


def load_existing_topics(runs_root: Path | None = None) -> list[str]:
    """History survives `runs/` cleanup; expired entries become eligible again."""
    root = runs_root or runtime.output_dir()
    cooldown = float(runtime.config().topics.get("cooldownDays", 30))
    history = sorted(
        _load_history(), key=lambda row: row.get("lastSeen", ""), reverse=True
    )
    topics = [str(row["topic"]) for row in history if _within_cooldown(row, cooldown)]
    for path in root.rglob("meta.json"):
        try:
            age_days = (
                datetime.now(timezone.utc)
                - datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
            ).days
            if cooldown > 0 and age_days >= cooldown:
                continue
            topic = json.loads(path.read_text(encoding="utf-8")).get("topic")
        except (OSError, json.JSONDecodeError, ValueError):
            continue
        if topic:
            topics.append(topic)
    seen = set()
    return [t for t in topics if not (t in seen or seen.add(t))]


def _revisit_allowed(
    topic: str, sources: list[str], source_hashes: dict[str, str], history: list[dict]
) -> bool:
    cooldown = float(runtime.config().topics.get("cooldownDays", 30))
    for row in history:
        if overlap(topic, str(row.get("topic", ""))) <= 0.6:
            continue
        if not _within_cooldown(row, cooldown):
            return True
        old_sources = set(row.get("sources") or [])
        if not old_sources or not set(sources).issubset(old_sources):
            return True
        old_hashes = row.get("sourceHashes") or {}
        for source, digest in source_hashes.items():
            if old_hashes.get(source) and old_hashes[source] != digest:
                return True
        return False
    return False


def record_topics(topics: list[dict]) -> None:
    """Persist auto-discovered topics outside `runs/` so cleanup cannot reset dedupe."""
    path = _history_path()
    data = {"version": 1, "topics": _load_history()}
    index = {str(row["topic"]).strip(): row for row in data["topics"]}
    now = datetime.now(timezone.utc).isoformat()
    for item in topics:
        topic = str(item.get("topic", "")).strip()
        if not topic:
            continue
        row = index.get(topic)
        if row is None:
            row = {
                "topic": topic,
                "genre": item.get("genre", ""),
                "count": 0,
                "firstSeen": now,
            }
            data["topics"].append(row)
            index[topic] = row
        row["count"] = int(row.get("count", 0)) + 1
        row["lastSeen"] = now
        row["sources"] = sorted(
            set(row.get("sources") or []) | set(item.get("sources") or [])
        )
        row["sourceHashes"] = {
            **(row.get("sourceHashes") or {}),
            **(item.get("sourceHashes") or {}),
        }
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    os.replace(tmp, path)


def build_topic_prompt(
    items: list[dict], exclude: list[str], limit: int
) -> tuple[str, str]:
    material = []
    for i, item in enumerate(items, 1):
        material.append(
            f"[{i}] source={item['source_id']} value={item.get('value')}\n"
            f"{_excerpt(item['content'])}"
        )
    pack = runtime.pack()
    exclude_text = "\n".join(f"- {t}" for t in exclude[-20:]) or tr(
        "genarticles.topics.none"
    )
    return (
        pack.prompt("gen_articles_topics_system"),
        pack.prompt(
            "gen_articles_topics_user",
            material="\n\n".join(material),
            exclude_text=exclude_text,
            genres=pack.raw["list_separator"].join(pack.words("genres")),
            limit=limit,
        ),
    )


def _valid_topic(
    topic: str,
    exclude: list[str],
    accepted: list[str],
    sources: list[str] | None = None,
    source_hashes: dict[str, str] | None = None,
) -> bool:
    if not 6 <= len(topic) <= 50:
        return False
    pack = runtime.pack()
    if len(pack.unit_re.findall(topic)) < pack.raw["topic_min_units"]:
        return False
    blocked = runtime.config().topics.get("blockedTerms") or []
    if INTERNAL_ID.search(topic) or any(
        term and term.casefold() in topic.casefold() for term in blocked
    ):
        return False
    history = _load_history()
    for old in exclude:
        if overlap(topic, old) <= 0.6:
            continue
        if not _revisit_allowed(topic, sources or [], source_hashes or {}, history):
            return False
    return not any(overlap(topic, old) > 0.75 for old in accepted)


def _parse_topics(
    text: str, items: list[dict], exclude: list[str], limit: int
) -> list[dict]:
    decoder = json.JSONDecoder()
    payload = None
    for match in re.finditer(r"\[", text):
        try:
            data, _ = decoder.raw_decode(text[match.start() :])
        except json.JSONDecodeError:
            continue
        if isinstance(data, list):
            payload = data
            break
    if payload is None:
        return []
    out = []
    for row in payload:
        if not isinstance(row, dict):
            continue
        topic = str(row.get("topic", "")).strip()
        genre = str(row.get("genre", "")).strip()
        sources = []
        source_hashes = {}
        for raw in row.get("sources") or []:
            try:
                idx = int(raw) - 1
            except (TypeError, ValueError):
                continue
            if 0 <= idx < len(items):
                source_id = items[idx]["source_id"]
                sources.append(source_id)
                source_hashes[source_id] = hashlib.sha1(
                    items[idx]["content"].encode("utf-8")
                ).hexdigest()
        if genre not in runtime.pack().words("genres") or not _valid_topic(
            topic, exclude, [x["topic"] for x in out], sources, source_hashes
        ):
            continue
        out.append(
            {
                "topic": topic,
                "genre": genre,
                "reason": str(row.get("reason", "")).strip(),
                "sources": sources,
                "sourceHashes": source_hashes,
            }
        )
        if len(out) >= limit:
            break
    return out


def _fallback_topics(items: list[dict], exclude: list[str], limit: int) -> list[dict]:
    out = []
    for item in items:
        text = item["content"]
        heading = re.search(r"^#{1,3}\s+(.+)$", text, re.M)
        pack = runtime.pack()
        topic = (
            heading.group(1)
            if heading
            else re.split(f"{pack.sentence_end}|\\n", text)[0]
        )
        topic = re.sub(r"^[-*>#\s]+", "", topic).strip()
        topic = re.sub(r"\s+", " ", topic)[:40].rstrip(pack.raw["topic_trim_chars"])
        source_id = item["source_id"]
        source_hashes = {
            source_id: hashlib.sha1(item["content"].encode("utf-8")).hexdigest()
        }
        if not _valid_topic(
            topic,
            exclude,
            [x["topic"] for x in out],
            [source_id],
            source_hashes,
        ):
            continue
        out.append(
            {
                "topic": topic,
                "genre": classify_topic(topic)["genre"],
                "reason": tr("genarticles.topics.fallback_reason"),
                "sources": [source_id],
                "sourceHashes": source_hashes,
            }
        )
        if len(out) >= limit:
            break
    return out


def discover_topics(
    limit: int = 3,
    client: LLMClient | None = None,
    items: list[dict] | None = None,
    runs_root: Path | None = None,
    max_tokens: int = 1600,
    seeds: list[str] | None = None,
) -> list[dict]:
    pool = items if items is not None else collect_material(seeds=seeds)
    if not pool:
        raise ValueError("no high-value material available")
    exclude = load_existing_topics(runs_root)
    llm = client or LLMClient()
    system, user = build_topic_prompt(pool, exclude, limit)
    try:
        raw = llm.chat(
            user,
            system=system,
            temperature=0.4,
            max_tokens=max_tokens,
            disable_thinking=True,
        )
    except LLMError:
        raw = ""
    topics = _parse_topics(raw, pool, exclude, limit)
    if len(topics) < limit:
        topics += _fallback_topics(
            pool, exclude + [t["topic"] for t in topics], limit - len(topics)
        )
    if not topics:
        raise ValueError(f"no new topics available ({len(exclude)} already used)")
    return topics[:limit]


def write_manifest(topics: list[dict], path: Path) -> list[dict]:
    entries = []
    for topic in topics:
        digest = hashlib.sha1(topic["topic"].encode("utf-8")).hexdigest()[:8]
        entries.append(
            {
                "id": f"auto_{digest}",
                "topic": topic["topic"],
                "genre": topic["genre"],
                "sources": topic.get("sources", []),
            }
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
    record_topics(topics)
    return entries
