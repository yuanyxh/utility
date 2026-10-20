#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Language-aware text normalization and overlap primitives."""

from __future__ import annotations

import re

from gen_articles import runtime

INTERNAL_ID = re.compile(r"\b[0-9a-f]{7,40}\b|(?:[\w.-]+/)+[\w.-]+")


def norm(text: str) -> str:
    unit = runtime.pack().unit_re
    return "".join(ch for ch in text if ch.isalnum() or unit.fullmatch(ch))


def bigrams(text: str) -> set[str]:
    return {text[i:i + 2] for i in range(max(0, len(text) - 1))}


def overlap(left: str, right: str) -> float:
    a, b = norm(left), norm(right)
    ga, gb = bigrams(a), bigrams(b)
    if not ga or not gb:
        return 0.0
    return len(ga & gb) / len(ga)
