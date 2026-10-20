#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""体裁路由：按主题关键词选择体裁。"""

from __future__ import annotations

from gen_articles import runtime


def classify_topic(topic: str) -> dict:
    pack = runtime.pack()
    scores = {}
    matched = {}
    for genre, words in pack.router.items():
        hits = [w for w in words if w in topic]
        if hits:
            scores[genre] = len(hits)
            matched[genre] = hits
    if not scores:
        return {"genre": pack.raw["default_genre"], "confidence": 0.2,
                "candidates": [], "matched": {}}
    ordered = sorted(scores.items(), key=lambda x: x[1], reverse=True)
    top = ordered[0][0]
    confidence = min(1.0, ordered[0][1] / 3)
    candidates = [g for g, _ in ordered[:3]]
    return {"genre": top, "confidence": round(confidence, 2),
            "candidates": candidates, "matched": matched}
