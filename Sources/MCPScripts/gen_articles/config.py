#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Gen_Articles config: fixed `<dir>/config.json`; language controls artifacts, not article body."""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from gen_articles.language_pack import LanguagePack, PackError

CONFIG_NAME = "config.json"
DEFAULTS = {
    "version": 1,
    "language": "zh-Hans",
    "outputDir": "runs",
    "extractsDir": "",
    "memoryEndpoint": "",
    "pack": "packs/zh-Hans",
    "topics": {
        "count": 3,
        "seedQueries": [],
        "blockedTerms": [],
        "historyFile": "topic_history.json",
        "cooldownDays": 30,
    },
    "pipeline": {
        "candidates": 1,
        "retries": 2,
        "rounds": 2,
        "maxMinutes": 120,
        "judge": False,
        "maxTokens": 8192,
        "temperature": 0.75,
    },
    "material": {
        "hotLimit": 20,
        "extractsLimit": 20,
        "minItems": 2,
        "maxItems": 20,
        "maxCharsPerItem": 4000,
        "maxTotalChars": 32000,
        "minRelevance": 0.35,
        "minValue": 0.25,
        "sourceCooldownDays": 14,
        "excludeDirs": ["runs", "output", "drafts", ".git"],
    },
}


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class Config:
    root: Path
    raw: dict
    output_dir: Path
    extracts_dir: Path
    soul: Path
    profiles: Path
    anchors: Path
    pack: LanguagePack
    memory_endpoint: str
    digest: str
    warnings: list[str] = field(default_factory=list)

    @property
    def pipeline(self) -> dict:
        return self.raw["pipeline"]

    @property
    def material(self) -> dict:
        return self.raw["material"]

    @property
    def topics(self) -> dict:
        return self.raw["topics"]


def _merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def _resolve(root: Path, value: str, fallback: str = "") -> Path:
    text = (value or fallback).strip()
    if not text:
        raise ConfigError("empty path")
    path = Path(os.path.expandvars(text)).expanduser()
    return path if path.is_absolute() else (root / path)


def load(root: Path) -> Config:
    root = root.expanduser().resolve()
    config_path = root / CONFIG_NAME
    if not config_path.exists():
        raise ConfigError(f"missing config: {config_path}")
    try:
        override = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot parse config: {exc}") from exc
    if not isinstance(override, dict):
        raise ConfigError("config must be a JSON object")
    raw = _merge(DEFAULTS, override)
    if raw.get("version") != 1:
        raise ConfigError(f"unsupported config version: {raw.get('version')}")

    extracts = raw.get("extractsDir") or ""
    notes_dir = os.environ.get("NOTES_DIR", "")
    if not raw.get("extractsDir") and notes_dir:
        extracts = str(Path(notes_dir) / "Extracts")
    if not extracts:
        raise ConfigError("extractsDir is required (or set NOTES_DIR)")
    endpoint = raw.get("memoryEndpoint") or os.environ.get("MEMORY_SERVER_URL", "")
    try:
        pack = LanguagePack(_resolve(root, raw.get("pack", "packs/zh-Hans")))
    except PackError as exc:
        raise ConfigError(str(exc)) from exc
    if "language" not in override and "pack" in override:
        raw["language"] = pack.id
    if raw.get("language") != pack.id:
        raise ConfigError(
            f"language {raw.get('language')!r} does not match pack {pack.id!r}"
        )
    digest = hashlib.sha256(
        json.dumps(raw, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ).hexdigest()[:16]
    config = Config(
        root=root,
        raw=raw,
        output_dir=_resolve(root, raw.get("outputDir", "runs")),
        extracts_dir=_resolve(root, extracts),
        soul=pack.asset("soul"),
        profiles=pack.asset("profiles"),
        anchors=pack.asset("anchors"),
        pack=pack,
        memory_endpoint=endpoint.rstrip("/"),
        digest=digest,
    )
    return config


def validate(config: Config) -> list[str]:
    errors = []
    if not config.root.is_dir():
        errors.append(f"directory not found: {config.root}")
    for name, path in (
        ("SOUL", config.soul),
        ("profiles", config.profiles),
        ("anchors", config.anchors),
        ("prompts", config.pack.asset("prompts")),
    ):
        if not path.exists():
            errors.append(f"{name} not found: {path}")
    if not config.extracts_dir.is_dir():
        errors.append(f"Extracts not found: {config.extracts_dir}")
    if config.pipeline.get("candidates", 1) < 1:
        errors.append("pipeline.candidates must be > 0")
    if config.pipeline.get("retries", 1) < 1:
        errors.append("pipeline.retries must be > 0")
    if config.material.get("minItems", 2) < 1:
        errors.append("material.minItems must be > 0")
    if config.material.get("minRelevance", 0) < 0:
        errors.append("material.minRelevance must be >= 0")
    for key in ("maxItems", "maxCharsPerItem", "maxTotalChars"):
        try:
            value = int(config.material.get(key, 0))
        except (TypeError, ValueError):
            value = 0
        if value < 1:
            errors.append(f"material.{key} must be > 0")
    return errors
