#!/usr/bin/env python3
"""Backfill memory lifecycle metadata (status/revision) into the hot layer.

Report-only by default; pass --apply to write. Idempotent: entries that already have
a status are untouched.

Two modes:
  HTTP   (default when the MCP server is running): read via /api/memories/recent and
         write via /api/memories/status. Needed because Qdrant local mode takes an
         exclusive lock, so a second process cannot open the same storage folder.
  direct (--direct, server stopped): open mem0/Qdrant and update metadata in place.

HTTP mode cannot set revision (endpoint scope); readers default a missing revision to 1,
so lifecycle behavior is unaffected.

Usage:
  python3 scripts/memory-status-migrate.py                    # HTTP report
  python3 scripts/memory-status-migrate.py --apply            # HTTP write
  QDRANT_PATH=/path python3 scripts/memory-status-migrate.py --direct --apply
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Sources", "MCPScripts"))

RECENT_PATH = "/api/memories/recent?since=2000-01-01T00:00:00&limit={limit}"
STATUS_PATH = "/api/memories/status"


def _get_json(url: str, timeout: int = 120):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read())


def _post_json(url: str, payload: dict):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.loads(resp.read())


def _healthy(base: str) -> bool:
    try:
        return _get_json(base + "/health", timeout=3).get("status") == "ok"
    except Exception:
        return False


def run_http(base: str, limit: int, batch: int, apply: bool) -> int:
    rows = _get_json(base + RECENT_PATH.format(limit=limit), timeout=180).get(
        "results", []
    )
    missing = [r for r in rows if not (r.get("metadata") or {}).get("status")]
    print(f"mode=http scanned={len(rows)} missing_status={len(missing)}")
    if not apply:
        print("report-only; rerun with --apply to write")
        return 0
    updated, failed = 0, 0
    for start in range(0, len(missing), batch):
        chunk = [r["id"] for r in missing[start : start + batch]]
        result = _post_json(
            base + STATUS_PATH, {"memory_ids": chunk, "status": "active"}
        )
        updated += int(result.get("updated", 0))
        failed += int(result.get("failed", 0))
        print(
            f"  {start + len(chunk)}/{len(missing)} updated={updated} failed={failed}"
        )
    print(f"updated={updated} failed={failed}")
    return 0 if failed == 0 else 1


def run_direct(qdrant_path: str, user_id: str, limit: int, apply: bool) -> int:
    if not qdrant_path:
        print("QDRANT_PATH (or --qdrant-path) is required for --direct")
        return 2
    os.environ["QDRANT_PATH"] = qdrant_path

    from mem0 import Memory

    from utility.core.memory_lifecycle import (
        REVISION_FIELD,
        STATUS_ACTIVE,
        STATUS_FIELD,
        SUPERSEDED_BY_FIELD,
    )
    from utility.services.mcp.server_memory import MEM0_CONFIG

    # mem0 builds an OpenAI client even though this script never calls the LLM;
    # a placeholder avoids failing on machines without AI_API_KEY injected.
    if not MEM0_CONFIG["llm"]["config"].get("api_key"):
        MEM0_CONFIG["llm"]["config"]["api_key"] = "unused"

    memory = Memory.from_config(MEM0_CONFIG)
    raw = memory.get_all(filters={"user_id": user_id}, top_k=limit)
    rows = raw if isinstance(raw, list) else raw.get("results", [])

    missing, updated, failed = 0, 0, 0
    for row in rows:
        meta = dict(row.get("metadata") or {})
        if meta.get(STATUS_FIELD):
            continue
        missing += 1
        if not apply:
            continue
        meta[STATUS_FIELD] = STATUS_ACTIVE
        meta[REVISION_FIELD] = int(meta.get(REVISION_FIELD, 1) or 1)
        meta.setdefault(SUPERSEDED_BY_FIELD, "")
        try:
            memory.update(row["id"], metadata=meta)
            updated += 1
        except Exception as e:
            failed += 1
            print(f"failed {row['id']}: {e}")

    print(f"mode=direct scanned={len(rows)} missing_status={missing}")
    if apply:
        print(f"updated={updated} failed={failed}")
    else:
        print("report-only; rerun with --apply to write")
    return 0 if failed == 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="write changes")
    parser.add_argument("--direct", action="store_true", help="open Qdrant directly")
    parser.add_argument("--server-url", default="http://127.0.0.1:9001")
    parser.add_argument("--qdrant-path", default=os.environ.get("QDRANT_PATH", ""))
    parser.add_argument("--user-id", default=os.environ.get("UTILITY_USER_ID", ""))
    parser.add_argument("--limit", type=int, default=10000)
    parser.add_argument("--batch", type=int, default=200)
    args = parser.parse_args()

    base = args.server_url.rstrip("/")
    if not args.direct and _healthy(base):
        return run_http(base, args.limit, args.batch, args.apply)
    if not args.direct:
        print(f"MCP server not reachable at {base}; falling back to direct mode")
    return run_direct(args.qdrant_path, args.user_id, args.limit, args.apply)


if __name__ == "__main__":
    raise SystemExit(main())
