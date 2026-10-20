#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""固定输入清单的批量运行；全部 status=ok 才算通过。"""

from __future__ import annotations

import json
import time
from pathlib import Path

from gen_articles import runtime
from gen_articles.i18n import t as tr
from gen_articles.material import MATERIAL_SOURCE_RE, render_markdown, source_id
from gen_articles.sources import collect_material
from gen_articles.run import run_pipeline


ENRICH_CODES = {"hardcore_density", "no_code", "bare_references"}


def _resolve_material(item: dict) -> Path | None:
    raw = item.get("material")
    if not raw or raw == "auto":
        return None
    path = Path(raw)
    return path if path.is_absolute() else runtime.config().root / path


def _checkpoint(out_root: Path, item_id: str) -> dict | None:
    paths = [out_root / item_id / "batch_item.json"]
    paths += sorted(out_root.glob(f"{item_id}_retry*/batch_item.json"))
    for path in paths:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if data.get("status") == "ok":
            return data
    return None


def _save_checkpoint(entry: dict) -> None:
    run_dir = Path(entry["run_dir"])
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "batch_item.json").write_text(
        json.dumps(entry, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def _review_codes(result: dict | None) -> set[str]:
    if not result:
        return set()
    state = Path(result["run_dir"]) / "review.json"
    try:
        data = json.loads(state.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return set()
    return set(data.get("codes") or [])


def _retry_material(item: dict, out_root: Path, run_dir: Path) -> Path | None:
    """证据不足时追加高价值记忆素材；没有新条目则返回原素材。"""
    fetched = collect_material(item["topic"], runtime.config())
    if not fetched.get("items"):
        return _resolve_material(item)
    parts, existing = [], ""
    first = out_root / item["id"] / "material.md"
    if first.exists():
        existing = first.read_text(encoding="utf-8")
        parts.append(existing)
    else:
        base = _resolve_material(item)
        if base and base.exists():
            existing = base.read_text(encoding="utf-8")
            parts.append(existing)
    known = set(MATERIAL_SOURCE_RE.findall(existing))
    fresh = []
    for row in fetched["items"]:
        source = source_id(row)
        if source not in known:
            fresh.append(row)
    if not fresh:
        return _resolve_material(item)
    fetched["items"] = fresh
    parts.append(
        tr("genarticles.batch.supplement") + "\n\n" + render_markdown(fetched)
    )
    path = run_dir / "retry_material.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n\n".join(parts), encoding="utf-8")
    return path


def run_batch(manifest: Path, out_root: Path, rounds: int,
              judge: bool, max_tokens: int, temperature: float,
              retries: int = 2, candidates: int = 1,
              resume: bool = True, max_minutes: float | None = None) -> dict:
    if retries < 1 or candidates < 1:
        raise ValueError("retries and candidates must be greater than 0")
    items = json.loads(manifest.read_text(encoding="utf-8"))
    if not items:
        raise ValueError("manifest is empty")
    if any(not item.get("id") or not item.get("topic") for item in items):
        raise ValueError("manifest entry missing id or topic")
    ids = [item.get("id") for item in items]
    if len(ids) != len(set(ids)):
        raise ValueError("manifest has duplicate ids")
    for item in items:
        material = _resolve_material(item)
        if material is not None and not material.exists():
            raise FileNotFoundError(f"material not found: {material}")
    started = time.monotonic()
    results = []
    for item in items:
        if resume:
            done = _checkpoint(out_root, item["id"])
            if done:
                results.append(done)
                continue
        if max_minutes is not None and (
            (time.monotonic() - started) / 60 >= max_minutes
        ):
            results.append({
                "id": item["id"],
                "status": "skipped_budget",
                "attempts": [],
                "run_dir": "",
                "selected": {},
                "review": "",
            })
            continue
        attempts = []
        result = None
        review_codes: set[str] = set()
        for attempt in range(1, retries + 1):
            run_dir = (
                out_root / item["id"] if attempt == 1
                else out_root / f"{item['id']}_retry{attempt}"
            )
            strategy = "initial"
            material = _resolve_material(item)
            if attempt > 1 and review_codes & ENRICH_CODES:
                enriched = _retry_material(item, out_root, run_dir)
                if enriched and enriched != material:
                    material = enriched
                    strategy = "enrich_material"
                else:
                    strategy = "regenerate"
            elif attempt > 1:
                strategy = "regenerate"
            result = run_pipeline(
                item["topic"], item.get("genre"), candidates,
                run_dir, rounds, judge,
                max_tokens, temperature, material_path=material,
            )
            review_codes = _review_codes(result)
            attempts.append({
                "attempt": attempt,
                "status": result["status"],
                "strategy": strategy,
                "run_dir": result["run_dir"],
            })
            entry = {
                "id": item["id"],
                "status": result["status"],
                "attempts": attempts,
                "run_dir": result["run_dir"],
                "selected": result["selected"],
                "review": result["review"],
                "material_filtered": result.get("material_filtered", 0),
                "material_count": result.get("material_count", 0),
            }
            _save_checkpoint(entry)
            if result["status"] == "ok":
                break
        results.append(entry)
    queue = [
        {"id": r["id"], "status": r["status"],
         "run_dir": r["run_dir"], "review": r["review"]}
        for r in results if r["status"] != "ok"
    ]
    summary = {
        "status": "ok" if all(r["status"] == "ok" for r in results)
        else "review_required",
        "results": results,
        "review_queue": queue,
    }
    out_root.mkdir(parents=True, exist_ok=True)
    (out_root / "batch_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (out_root / "review_queue.json").write_text(
        json.dumps(queue, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return summary
