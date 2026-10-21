#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""运行追溯：配置快照、阶段事件与最终结果。"""

from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from utility.articles.config import Config


def _hash(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()[:16]
    except OSError:
        return ""


class Trace:
    def __init__(self, output_dir: Path, config: Config, batch_id: str):
        self.output_dir = output_dir
        self.config = config
        self.batch_id = batch_id
        self.started = datetime.now(timezone.utc).isoformat()
        self.events_path = output_dir / "events.jsonl"
        self.manifest_path = output_dir / f"run_manifest_{batch_id}.json"

    def event(self, name: str, **fields) -> None:
        row = {
            "at": datetime.now(timezone.utc).isoformat(),
            "event": name,
            **fields,
        }
        self.events_path.parent.mkdir(parents=True, exist_ok=True)
        with self.events_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    def finish(self, status: str, exit_code: int, summary: dict | None) -> None:
        manifest = {
            "batch_id": self.batch_id,
            "started": self.started,
            "finished": datetime.now(timezone.utc).isoformat(),
            "status": status,
            "exit_code": exit_code,
            "code_version": os.environ.get("UTILITY_VERSION", ""),
            "config_digest": self.config.digest,
            "config": self.config.raw,
            "paths": {
                "root": str(self.config.root),
                "output": str(self.config.output_dir),
                "extracts": str(self.config.extracts_dir),
            },
            "assets": {
                "soul": _hash(self.config.soul),
                "anchors": _hash(self.config.anchors),
            },
            "results": []
            if summary is None
            else [
                {
                    "id": row["id"],
                    "status": row["status"],
                    "attempts": row.get("attempts", []),
                    "selected": row.get("selected", {}),
                    "review": row.get("review", ""),
                    "material_count": row.get("material_count", 0),
                    "material_filtered": row.get("material_filtered", 0),
                }
                for row in summary.get("results", [])
            ],
        }
        self.manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
