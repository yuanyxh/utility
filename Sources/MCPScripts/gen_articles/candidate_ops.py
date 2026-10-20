#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared candidate/meta plumbing for merge, split, pacing, rewrite and format stages."""

from __future__ import annotations

import json
from pathlib import Path

from gen_articles import runtime
from gen_articles.lint import lint_text
from gen_articles.material import project_tokens


def load_meta(run_dir: Path) -> tuple[Path, dict]:
    meta_path = run_dir / "meta.json"
    return meta_path, json.loads(meta_path.read_text(encoding="utf-8"))


def write_meta(meta_path: Path, meta: dict) -> None:
    meta_path.write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def targets(meta: dict, index: int | None = None) -> list[dict]:
    return [
        c for c in meta["candidates"] if index is None or c["index"] == index
    ]


def profile_for(genre: str) -> dict:
    path = runtime.profiles_dir() / f"{genre}.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def profile_mean(profile: dict, name: str, default: float = 0.0) -> float:
    return profile.get("features", {}).get(name, {}).get("mean", default)


def project_tokens_from_run(run_dir: Path) -> tuple[str, ...]:
    material = run_dir / "material.md"
    if not material.exists():
        return ()
    return project_tokens(material.read_text(encoding="utf-8"))


def strict_lint(text: str, tokens: tuple[str, ...]) -> dict:
    return lint_text(
        text, max_inline_code=2, strict_hardcore=True,
        third_party=True, project_tokens=tokens,
    )


def candidate_path(run_dir: Path, index: int, suffix: str) -> Path:
    return run_dir / "candidates" / f"candidate_{index}_{suffix}.md"


def commit_candidate(meta: dict, meta_path: Path, candidate: dict, *,
                     path: Path, features: dict,
                     source_field: str, source_name: str) -> None:
    candidate["path"] = str(path)
    candidate["title"] = features["title"]
    candidate["han"] = features["han"]
    candidate[source_field] = source_name
    write_meta(meta_path, meta)
