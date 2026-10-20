#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""进程级配置与资产缓存，供各阶段共享。"""

from __future__ import annotations

import json
from pathlib import Path

from gen_articles.config import Config
from gen_articles.language_pack import LanguagePack

_config: Config | None = None
_anchors: list[dict] | None = None


def configure(config: Config) -> None:
    global _config, _anchors
    _config = config
    _anchors = None


def config() -> Config:
    if _config is None:
        raise RuntimeError("gen_articles is not configured")
    return _config


def pack() -> LanguagePack:
    return config().pack


def anchors() -> list[dict]:
    global _anchors
    if _anchors is None:
        data = json.loads(config().anchors.read_text(encoding="utf-8"))
        if not isinstance(data, list):
            raise ValueError("anchors.json must be an array")
        _anchors = [row for row in data if row.get("genre") and row.get("title")]
    return _anchors


def soul_text() -> str:
    return config().soul.read_text(encoding="utf-8")


def profiles_dir() -> Path:
    return config().profiles


def output_dir() -> Path:
    return config().output_dir
