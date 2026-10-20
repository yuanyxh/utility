#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文体计量：抽取文章特征并计算与既有画像的距离。"""

from __future__ import annotations

import re
import statistics

from gen_articles import runtime

CODE_BLOCK = re.compile(r"```.*?```", re.S)
COMMAND = re.compile(
    r"(?m)^\s*(?:\$|(?:npm|npx|pnpm|yarn|git|curl|docker|kubectl|python3?|sqlite3|node|go|swift|vim|cat|grep|lsof|ss|netstat|top|ps|kill)\b)[^\n]*"
)
def _pct(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * q)))
    return float(ordered[idx])


def _count_patterns(text: str, patterns: tuple[str, ...]) -> int:
    return sum(len(re.findall(p, text)) for p in patterns)


def _prose(text: str) -> str:
    return CODE_BLOCK.sub("", text)


def article_features(text: str) -> dict:
    pack = runtime.pack()
    unit = pack.unit_re
    prose = _prose(text)
    han = len(unit.findall(prose))
    sentences = [
        s.strip() for s in re.split(pack.sentence_end_lookbehind, prose)
        if len(unit.findall(s)) > 0
    ]
    sent_lengths = [len(unit.findall(s)) for s in sentences] or [0]
    paragraphs = []
    for block in re.split(pack.paragraph_split, prose):
        s = block.strip()
        if not s or s.startswith(("#", "|", ">", "- ", "* ", "[")):
            continue
        paragraphs.append(len(unit.findall(s)))
    if not paragraphs:
        paragraphs = [0]

    code_blocks = CODE_BLOCK.findall(text)
    code_lines = sum(max(0, len(b.splitlines()) - 2) for b in code_blocks)
    prose_lines = sum(1 for line in prose.splitlines() if line.strip())
    code_ratio = code_lines / max(1, code_lines + prose_lines)

    headings = re.findall(r"^(#{1,3})\s+(.+)$", text, re.M)
    title = next((line[2:].strip() for line in text.splitlines() if line.startswith("# ")), "")
    inline = re.findall(r"`([^`\n]+)`", prose)
    colloquial = _count_patterns(prose, pack.words("colloquial"))
    connective = sum(prose.count(w) for w in pack.words("connectives"))
    pronoun = sum(prose.count(w) for w in pack.words("pronouns"))
    tech = sum(prose.count(w) for w in pack.words("tech"))

    return {
        "han": han,
        "sent_mean": round(statistics.mean(sent_lengths), 2),
        "sent_p50": round(_pct(sent_lengths, 0.5), 2),
        "sent_p90": round(_pct(sent_lengths, 0.9), 2),
        "sent_std": round(statistics.pstdev(sent_lengths), 2),
        "pronoun_per_1k": round(pronoun / han * 1000, 2) if han else 0.0,
        "connective_per_1k": round(connective / han * 1000, 2) if han else 0.0,
        "colloquial_per_1k": round(colloquial / han * 1000, 2) if han else 0.0,
        "code_ratio": round(code_ratio, 3),
        "inline_code_per_1k": round(len(inline) / han * 1000, 2) if han else 0.0,
        "para_mean": round(statistics.mean(paragraphs), 2),
        "para_p90": round(_pct(paragraphs, 0.9), 2),
        "heading_count": len(headings),
        "half_punct_per_1k": round(len(pack.pattern("half_punct").findall(prose)) / han * 1000, 2) if han else 0.0,
        "title_len": len(unit.findall(title)),
        "has_commands": bool(COMMAND.search("\n".join(code_blocks))),
        "has_logs": bool(re.search(r"```(?:text|log)\n.*(?:ERROR|WARN|FATAL|SQLSTATE)", text, re.S)),
        "has_spec_quote": bool(re.search(r"^>\s+\S", text, re.M)),
        "title": title,
        "tech_per_1k": round(tech / han * 1000, 2) if han else 0.0,
    }


def distance(features: dict, profile: dict) -> dict:
    outliers = []
    for name, stat in profile.get("features", {}).items():
        value = float(features.get(name, 0.0))
        std = max(float(stat["std"]), 1e-6)
        z = round((value - float(stat["mean"])) / std, 2)
        outliers.append({"feature": name, "value": value, "z": z})
    ordered = sorted(outliers, key=lambda x: abs(x["z"]), reverse=True)
    return {
        "distance": round(statistics.mean(abs(x["z"]) for x in ordered), 3),
        "outliers": ordered[:2],
    }
