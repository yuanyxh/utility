#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生产入口：读取 Gen_Articles/config.json，手动跑批并留下追溯。"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import signal
import sys
from datetime import datetime, timezone
from pathlib import Path

from gen_articles import config as config_mod
from gen_articles import runtime
from gen_articles.i18n import t as tr
from gen_articles.batch import run_batch
from gen_articles.router import classify_topic
from gen_articles.sources import collect_material
from gen_articles.topics import discover_topics, write_manifest
from gen_articles.trace import Trace

def _lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise RuntimeError("busy")
    return handle


def _selected_path(run_dir: Path, selected: dict) -> str:
    path = str(selected.get("path") or "")
    if path:
        return path
    try:
        meta = json.loads((run_dir / "meta.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    index = selected.get("index")
    candidate = next(
        (c for c in meta.get("candidates", []) if c.get("index") == index), None
    )
    return str(candidate.get("path", "")) if candidate else ""


def _scan_latest(output_dir: Path) -> dict | None:
    items = sorted(
        output_dir.rglob("batch_item.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not items:
        return None
    batch_dir = items[0].parent.parent
    latest: dict[str, tuple[float, dict]] = {}
    for path in batch_dir.glob("*/batch_item.json"):
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
            mtime = path.stat().st_mtime
        except (OSError, json.JSONDecodeError):
            continue
        item_id = item.get("id", "")
        if item_id not in latest or mtime > latest[item_id][0]:
            latest[item_id] = (mtime, item)
    rows = []
    for _, item in sorted(latest.values(), key=lambda pair: pair[0]):
        selected = item.get("selected") or {}
        rows.append({
            "id": item.get("id", ""),
            "status": item.get("status", ""),
            "title": selected.get("title", ""),
            "path": _selected_path(Path(item.get("run_dir", "")), selected),
            "run_dir": item.get("run_dir", ""),
            "review": item.get("review", ""),
        })
    return {
        "batch_id": batch_dir.name,
        "finished_at": datetime.fromtimestamp(
            items[0].stat().st_mtime, timezone.utc
        ).isoformat(),
        "status": "ok" if rows and all(r["status"] == "ok" for r in rows)
        else "review_required",
        "results": rows,
    }


def _write_latest(output_dir: Path, batch_id: str, summary: dict) -> None:
    rows = []
    for row in summary.get("results", []):
        selected = row.get("selected") or {}
        rows.append({
            "id": row.get("id", ""),
            "status": row.get("status", ""),
            "title": selected.get("title", ""),
            "path": selected.get("path", ""),
            "run_dir": row.get("run_dir", ""),
            "review": row.get("review", ""),
        })
    data = {
        "batch_id": batch_id,
        "finished_at": datetime.now(timezone.utc).isoformat(),
        "status": summary.get("status", ""),
        "results": rows,
    }
    path = output_dir / "latest.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")
    tmp.replace(path)
    lines = [tr("genarticles.latest.header", batch=batch_id),
             tr("genarticles.latest.status", status=data["status"]), ""]
    for row in rows:
        lines.append(tr(
            "genarticles.latest.item", id=row["id"], title=row["title"],
            path=row["path"] or "-", review=row["review"] or "-",
        ))
    (output_dir / "latest.md").write_text("\n".join(lines) + "\n",
                                          encoding="utf-8")


def _entry(topic: str) -> dict:
    digest = hashlib.sha1(topic.encode("utf-8")).hexdigest()[:8]
    return {
        "id": f"manual_{digest}",
        "topic": topic,
        "genre": classify_topic(topic)["genre"],
    }


def _timeout(seconds: int):
    if seconds <= 0:
        return
    def handler(signum, frame):
        raise TimeoutError(f"timeout after {seconds}s")
    signal.signal(signal.SIGALRM, handler)
    signal.alarm(seconds)


def run(args) -> int:
    root = Path(args.dir).expanduser()
    try:
        cfg = config_mod.load(root)
    except config_mod.ConfigError as exc:
        print(f"Config error: {exc}", file=sys.stderr)
        return 3
    runtime.configure(cfg)
    if args.latest:
        path = cfg.output_dir / "latest.json"
        if path.exists():
            print(path.read_text(encoding="utf-8").rstrip())
            return 0
        scanned = _scan_latest(cfg.output_dir)
        if scanned is None:
            print("No completed batch yet", file=sys.stderr)
            return 1
        print(json.dumps(scanned, ensure_ascii=False, indent=2))
        return 0
    errors = config_mod.validate(cfg)
    if args.validate_config or args.dry_run:
        print(json.dumps({
            "root": str(cfg.root),
            "output": str(cfg.output_dir),
            "extracts": str(cfg.extracts_dir),
            "soul": str(cfg.soul),
            "profiles": str(cfg.profiles),
            "anchors": str(cfg.anchors),
            "digest": cfg.digest,
            "errors": errors,
        }, ensure_ascii=False, indent=2))
        return 0 if not errors else 3
    if errors:
        print(tr("genarticles.preflight_failed", messages="\n- ".join(errors)), file=sys.stderr)
        return 3

    cfg.output_dir.mkdir(parents=True, exist_ok=True)
    batch_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    batch_root = cfg.output_dir / batch_id
    batch_root.mkdir(parents=True, exist_ok=True)
    trace = Trace(batch_root, cfg, batch_id)
    try:
        lock = _lock(cfg.output_dir / ".gen_articles.lock")
    except RuntimeError as exc:
        print(tr("genarticles.busy") if str(exc) == "busy" else str(exc), file=sys.stderr)
        return 4
    try:
        if args.preview_material:
            material = collect_material(args.preview_material, cfg)
            path = cfg.output_dir / "preview_material.json"
            path.write_text(json.dumps(material, ensure_ascii=False, indent=2),
                            encoding="utf-8")
            print(json.dumps({
                "items": len(material["items"]),
                "dropped": material["dropped_count"],
                "path": str(path),
            }, ensure_ascii=False, indent=2))
            return 0

        _timeout(int(cfg.pipeline.get("maxMinutes", 0)) * 60)
        if args.topic:
            entries = [_entry(args.topic)]
            manifest = batch_root / "topics.json"
            manifest.write_text(json.dumps(entries, ensure_ascii=False,
                                           indent=2), encoding="utf-8")
        elif args.manifest:
            manifest = Path(args.manifest).expanduser()
            if not manifest.is_absolute():
                manifest = cfg.root / manifest
        else:
            try:
                topics = discover_topics(
                    int(cfg.topics.get("count", 3)),
                    runs_root=cfg.output_dir,
                    seeds=cfg.topics.get("seedQueries") or None,
                )
            except ValueError as exc:
                trace.finish("review_required", 2, None)
                print(f"Topic discovery failed: {exc}", file=sys.stderr)
                return 2
            manifest = batch_root / "topics.json"
            write_manifest(topics, manifest)
        trace.event("batch_start", manifest=str(manifest))
        summary = run_batch(
            manifest,
            batch_root,
            int(cfg.pipeline.get("rounds", 2)),
            bool(cfg.pipeline.get("judge", False)),
            int(cfg.pipeline.get("maxTokens", 8192)),
            float(cfg.pipeline.get("temperature", 0.75)),
            int(cfg.pipeline.get("retries", 2)),
            int(cfg.pipeline.get("candidates", 1)),
            True,
            float(cfg.pipeline.get("maxMinutes", 0)) or None,
        )
        _write_latest(cfg.output_dir, batch_id, summary)
        code = 0 if summary["status"] == "ok" else 2
        trace.finish(summary["status"], code, summary)
        trace.event("batch_end", status=summary["status"],
                    queue=len(summary.get("review_queue", [])))
        print(json.dumps({
            "status": summary["status"],
            "summary": str(batch_root / "batch_summary.json"),
            "review": str(batch_root / "review_queue.json"),
            "manifest": str(trace.manifest_path),
        }, ensure_ascii=False, indent=2))
        return code
    except TimeoutError as exc:
        trace.finish("timeout", 1, None)
        print(tr("genarticles.timeout", message=str(exc)), file=sys.stderr)
        return 1
    finally:
        signal.alarm(0)
        lock.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Gen_Articles production entrypoint")
    parser.add_argument("--dir", required=True)
    parser.add_argument("--topic")
    parser.add_argument("--manifest")
    parser.add_argument("--preview-material")
    parser.add_argument("--latest", action="store_true")
    parser.add_argument("--validate-config", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
