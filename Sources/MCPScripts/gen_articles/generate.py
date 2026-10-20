#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""候选生成：SOUL + 体裁画像 + 真实锚点 + 记忆素材 -> N 篇候选。"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime
from pathlib import Path

from gen_articles import runtime
from gen_articles.candidate_ops import profile_for, profile_mean
from gen_articles.llm import LLMClient, LLMError, chat_with_retry
from gen_articles.material import project_tokens, render_markdown, source_id
from gen_articles.plan import make_plan, render_plan
from gen_articles.router import classify_topic
from gen_articles.sources import collect_material
from gen_articles.stylometry import article_features
from gen_articles.textnorm import INTERNAL_ID, overlap
from gen_articles.textops import (
    label_code_blocks,
    merge_short_sentences,
    split_long_paragraphs,
    strip_empty_mermaid,
    strip_preamble,
)
from gen_articles.i18n import t as tr


class MaterialError(RuntimeError):
    def __init__(self, run_dir: Path, message: str, filtered: int = 0):
        super().__init__(message)
        self.run_dir = run_dir
        self.filtered = filtered


def _material_count(material: dict | None, markdown: str) -> int:
    if material is not None and "items" in material:
        return len(material["items"])
    numbered = re.findall(r"^##\s+\d+\.\s+", markdown, re.M)
    if numbered:
        return len(numbered)
    return 1 if markdown.strip() else 0


def _slug(text: str) -> str:
    return runtime.pack().pattern("slug_invalid").sub("-", text).strip("-")[:40]


def reference_excerpts(genre: str, topic: str, count: int = 2) -> list[dict]:
    items = [e for e in runtime.anchors() if e["genre"] == genre]
    items.sort(
        key=lambda e: hashlib.sha1(
            (topic + e.get("path", e["title"])).encode()
        ).hexdigest()
    )
    return [
        {"title": e["title"], "path": e.get("path", ""), "excerpt": e["excerpt"]}
        for e in items[:count]
        if e.get("excerpt")
    ]


def reference_openings(genre: str, topic: str, count: int = 2) -> list[dict]:
    items = [e for e in runtime.anchors() if e["genre"] == genre]
    items.sort(
        key=lambda e: hashlib.sha1(
            (topic + e.get("path", e["title"])).encode()
        ).hexdigest()
    )
    hook = runtime.pack().pattern("opening_hook")
    out = []
    for entry in items:
        opening = entry.get("opening", "")
        if opening and hook.search(opening):
            out.append({"title": entry["title"], "opening": opening})
        if len(out) >= count:
            break
    return out


def _topic_prefix_only(topic: str, title: str, prefix: int = 6, added: int = 6) -> bool:
    """标题只是主题前缀加少量后缀时，视为主题复述。"""
    common = 0
    for left, right in zip(topic, title):
        if left != right:
            break
        common += 1
    return common >= prefix and len(title) - common < added


def _title_needs_fix(topic: str, title: str, tokens: tuple[str, ...] = ()) -> bool:
    a, b = topic, title
    if not b or a == b or _topic_prefix_only(a, b):
        return True
    if INTERNAL_ID.search(title):
        return True
    if any(
        re.search(rf"(?<![0-9A-Za-z_]){re.escape(t)}(?![0-9A-Za-z_])", title, re.I)
        for t in tokens
    ):
        return True
    return overlap(a, b) > 0.8


def _anchor_leak_terms(title: str, anchors: str, allowed: str) -> list[str]:
    """标题里出现、锚点有、但 plan/material 没有的术语。"""
    pack = runtime.pack()
    leaks = set()
    for size in pack.raw["term_sizes"]:
        for i in range(len(title) - size + 1):
            term = title[i : i + size]
            if (
                all(pack.unit_re.fullmatch(ch) for ch in term)
                and term in anchors
                and term not in allowed
            ):
                leaks.add(term)
    for token in re.findall(r"[A-Za-z][A-Za-z0-9_-]{3,}", title):
        if token in anchors and token not in allowed:
            leaks.add(token)
    return sorted(leaks)


def _fallback_title(topic: str) -> str:
    pack = runtime.pack()
    text = pack.pattern("definition_guard").sub("", topic).strip()
    text = pack.pattern("title_split").split(text)[0].strip()
    return text[:32].rstrip(pack.raw["title_trim_chars"]) or pack.raw["fallback_title"]


def build_title_prompt(
    topic: str,
    article: str,
    angle: str | None,
    banned: tuple[str, ...] | list[str] = (),
) -> tuple[str, str]:
    ban = (
        tr(
            "genarticles.prompt.ban",
            terms=runtime.pack().raw["list_separator"].join(banned),
        )
        + "\n"
        if banned
        else ""
    )
    return (
        runtime.pack().prompt("gen_articles_title_system"),
        runtime.pack().prompt(
            "gen_articles_title_user", topic=topic, article=article[:1200], ban=ban
        ),
    )


def rewrite_title(
    client: LLMClient,
    topic: str,
    article: str,
    angle: str | None,
    tokens: tuple[str, ...] = (),
    banned: tuple[str, ...] | list[str] = (),
) -> str | None:
    system, user = build_title_prompt(topic, article, angle, banned)
    try:
        raw = client.chat(
            user, system=system, temperature=0.5, max_tokens=64, disable_thinking=True
        )
    except LLMError:
        return None
    title = (
        raw.strip()
        .splitlines()[0]
        .strip()
        .strip(runtime.pack().raw["title_quote_chars"])
        .lstrip("#")
        .strip()
    )
    if not title or _title_needs_fix(topic, title, tokens):
        return None
    if any(term in title for term in banned):
        return None
    return title


def build_prompts(
    topic: str,
    genre: str,
    material_md: str,
    angle: str | None = None,
    opening_mode: str | None = None,
    plan_md: str | None = None,
    general_topic: str | None = None,
) -> tuple[str, str]:
    profile = profile_for(genre)
    sent_p50 = profile_mean(profile, "sent_p50", 0)
    sent_p90 = profile_mean(profile, "sent_p90", 0)
    anchors = reference_excerpts(genre, topic)
    anchor_text = "\n\n".join(
        tr("genarticles.prompt.anchor", index=i + 1, title=a["title"])
        + "\n"
        + a["excerpt"]
        for i, a in enumerate(anchors)
    )
    openings = reference_openings(genre, topic)
    opening_text = "\n\n".join(
        tr("genarticles.prompt.opening", index=i + 1, title=a["title"])
        + "\n"
        + a["opening"]
        for i, a in enumerate(openings)
    )
    plan_block = tr("genarticles.prompt.plan_block", plan=plan_md) if plan_md else ""
    system = runtime.pack().prompt(
        "gen_articles_article_system",
        soul=runtime.soul_text(),
        genre=genre,
        sent_p50=sent_p50,
        sent_p90=sent_p90,
        sent_min=max(40, int(sent_p50 * 0.85)),
        anchor_text=anchor_text,
        opening_text=opening_text,
        plan_block=plan_block,
    )
    user = runtime.pack().prompt(
        "gen_articles_article_user",
        general_topic=general_topic or topic,
        topic=topic,
        genre=genre,
        angle=angle or runtime.pack().raw["default_angle"],
        opening_mode=opening_mode or runtime.pack().words("opening_modes")[0],
        material_md=material_md,
        sent_p50=sent_p50,
        sent_p90=sent_p90,
    )
    return system, user


def _recover_candidates(run_dir: Path, meta: dict) -> None:
    """中断的运行没有 meta.json 或只写了一半，从已落盘的候选文件补齐。"""
    known = {c["index"] for c in meta["candidates"]}
    for path in sorted((run_dir / "candidates").glob("candidate_*.md")):
        try:
            i = int(path.stem.rsplit("_", 1)[1])
        except (IndexError, ValueError):
            continue
        if i in known:
            continue
        article = path.read_text(encoding="utf-8")
        features = article_features(article)
        meta["candidates"].append(
            {
                "index": i,
                "path": str(path),
                "title": features["title"],
                "han": features["han"],
                "angle": runtime.pack().words("angles")[
                    (i - 1) % len(runtime.pack().words("angles"))
                ],
            }
        )
    meta["candidates"].sort(key=lambda c: c["index"])


def generate(
    topic: str,
    genre: str | None,
    candidates: int,
    out: Path | None,
    temperature: float,
    max_tokens: int,
    index: int | None = None,
    disable_thinking: bool = True,
    use_plan: bool = True,
    material_path: Path | None = None,
) -> dict:
    genre = genre or classify_topic(topic)["genre"]
    run_id = (
        out.name
        if out
        else (f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{_slug(topic)}")
    )
    run_dir = out or (runtime.output_dir() / run_id)
    (run_dir / "candidates").mkdir(parents=True, exist_ok=True)
    client = LLMClient()
    meta_path = run_dir / "meta.json"
    material = None
    if material_path:
        material_md = material_path.read_text(encoding="utf-8")
        (run_dir / "material.md").write_text(material_md, encoding="utf-8")
        material = {"error": None}
    if meta_path.exists():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        meta.setdefault("run_dir", str(run_dir))
    else:
        if material is None:
            material = collect_material(topic, runtime.config())
            material_md = render_markdown(material)
            (run_dir / "material.md").write_text(material_md, encoding="utf-8")
        meta = {
            "run_id": run_dir.name,
            "run_dir": str(run_dir),
            "topic": topic,
            "genre": genre,
            "model": client.model,
            "candidates": [],
            "material_error": material.get("error"),
            "material_filtered": material.get("dropped_count", 0),
        }
    _recover_candidates(run_dir, meta)
    material_md = (run_dir / "material.md").read_text(encoding="utf-8")
    material_count = _material_count(material, material_md)
    meta["material_count"] = material_count
    if material and "dropped" in material:
        rows = []
        for item in material.get("items", []):
            rows.append(
                {
                    "decision": "kept",
                    "kind": item.get("kind"),
                    "source": source_id(item),
                    "value": item.get("value"),
                    "relevance": item.get("relevance"),
                }
            )
        for item in material.get("dropped", []):
            rows.append({"decision": "dropped", **item})
        (run_dir / "material_decisions.jsonl").write_text(
            "\n".join(json.dumps(row, ensure_ascii=False) for row in rows) + "\n",
            encoding="utf-8",
        )
    min_items = (
        int(runtime.config().material.get("minItems", 2))
        if material and "items" in material
        else 1
    )
    if material_count < min_items and not meta["candidates"]:
        meta["material_error"] = "insufficient material"
        meta_path.write_text(
            json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        review = (
            tr("genarticles.review.header")
            + "\n\n"
            + tr(
                "genarticles.review.candidate",
                index=1,
                title=tr("genarticles.review.not_generated"),
            )
            + "\n- "
            + tr(
                "genarticles.material_insufficient", count=material_count, min=min_items
            )
            + "\n"
        )
        (run_dir / "review.md").write_text(review, encoding="utf-8")
        raise MaterialError(
            run_dir, "insufficient material", meta.get("material_filtered", 0)
        )
    internal_tokens = project_tokens(material_md)
    plan_path = run_dir / "plan.json"
    plan = None
    if plan_path.exists():
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
    elif use_plan:
        try:
            plan = make_plan(topic, meta["genre"], material_md)
            plan_path.write_text(
                json.dumps(plan, ensure_ascii=False, indent=2), encoding="utf-8"
            )
        except Exception as exc:  # noqa: BLE001
            meta["plan_error"] = f"{type(exc).__name__}: {exc}"
    plan_md = render_plan(plan) if plan else None
    general_topic = (plan or {}).get("general_problem") or topic
    profile = profile_for(meta["genre"])
    target_p50 = profile_mean(profile, "sent_p50", 55)
    indices = (
        [index]
        if index
        else [
            i
            for i in range(1, candidates + 1)
            if i not in {c["index"] for c in meta["candidates"]}
        ]
    )
    for i in indices:
        pack = runtime.pack()
        angles = pack.words("angles")
        modes = pack.words("opening_modes")
        angle = angles[(i - 1) % len(angles)]
        opening_mode = modes[(i - 1) % len(modes)]
        system, user = build_prompts(
            topic,
            meta["genre"],
            material_md,
            angle=angle,
            opening_mode=opening_mode,
            plan_md=plan_md,
            general_topic=general_topic,
        )
        (run_dir / f"system_prompt_{i}.txt").write_text(system, encoding="utf-8")
        (run_dir / f"user_prompt_{i}.txt").write_text(user, encoding="utf-8")
        text = chat_with_retry(
            client, user, system, temperature, max_tokens, disable_thinking
        )
        article = strip_empty_mermaid(strip_preamble(text))
        article = label_code_blocks(article)
        article = merge_short_sentences(article, target_p50)
        article = split_long_paragraphs(article)
        features = article_features(article)
        title_fixed = False
        anchors = reference_excerpts(meta["genre"], topic) + reference_openings(
            meta["genre"], topic
        )
        anchor_text = "\n".join(
            a.get("excerpt") or a.get("opening", "") for a in anchors
        )
        allowed_text = material_md + topic
        leaks = _anchor_leak_terms(
            features["title"], anchor_text + "\n" + angle, allowed_text
        )
        if _title_needs_fix(general_topic, features["title"], internal_tokens) or leaks:
            new_title = rewrite_title(
                client,
                general_topic,
                article,
                angle,
                internal_tokens,
                banned=leaks,
            )
            if not new_title:
                new_title = _fallback_title(general_topic)
            if leaks and any(term in new_title for term in leaks):
                new_title = _fallback_title(topic)
            if new_title:
                article = re.sub(
                    r"^#\s+.+$", f"# {new_title}", article, count=1, flags=re.M
                )
                features = article_features(article)
                title_fixed = True
        path = run_dir / "candidates" / f"candidate_{i}.md"
        path.write_text(article, encoding="utf-8")
        meta["candidates"] = [c for c in meta["candidates"] if c["index"] != i]
        meta["candidates"].append(
            {
                "index": i,
                "path": str(path),
                "title": features["title"],
                "han": features["han"],
                "angle": angle,
                "title_fixed": title_fixed,
            }
        )
        meta["candidates"].sort(key=lambda c: c["index"])
        # 每篇落盘后立即写 meta，超时中断也能续跑
        meta_path.write_text(
            json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"candidate {i}: {features['title']} ({features['han']} chars)")
    meta_path.write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return meta
