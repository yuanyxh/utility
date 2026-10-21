#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pure text transforms shared by generation, rewrite and format repair."""

from __future__ import annotations

import json
import re

from utility.articles import runtime


def merge_short_sentences(
    text: str, target_p50: float = 55, max_chars: int = 110
) -> str:
    """把相邻短句用分号连接，只改标点，不改词语与事实。"""
    pack = runtime.pack()
    unit = pack.unit_re
    skip = ("```", "#", "|", ">", "-", "*", "![", "[")

    def merge_block(block: str) -> str:
        if block.lstrip().startswith(skip):
            return block
        parts = [p for p in re.split(pack.sentence_end_lookbehind, block) if p.strip()]
        changed = True
        while changed:
            changed = False
            i = 0
            while i + 1 < len(parts):
                a, b = parts[i].rstrip(), parts[i + 1].lstrip()
                la = len(unit.findall(a))
                lb = len(unit.findall(b))
                if (
                    a.endswith(pack.raw["sentence_terminal"])
                    and la < target_p50 * 0.8
                    and lb < target_p50 * 0.8
                    and la + lb <= max_chars
                ):
                    parts[i : i + 2] = [a[:-1] + pack.sentence_join + b]
                    changed = True
                    continue
                i += 1
        return "".join(parts)

    return "\n\n".join(merge_block(b) for b in re.split(pack.paragraph_split, text))


def strip_empty_mermaid(text: str) -> str:
    """删除空 Mermaid 代码块，避免留下无法渲染的围栏。"""
    return re.sub(r"```mermaid[ \t]*\n?[ \t]*```\n?", "", text)


def _infer_code_language(body: str) -> str:
    """按内容推断围栏语言；无法判断时回退 text。"""
    text = body.strip()
    if not text:
        return "text"
    if text[0] in "[{":
        try:
            json.loads(text)
            return "json"
        except json.JSONDecodeError:
            pass
    lines = [
        line
        for line in text.splitlines()
        if line.strip() and not line.strip().startswith(("#", "//"))
    ]
    head = "\n".join(lines[:3])
    if re.match(
        r"^\s*(?:SELECT|INSERT|UPDATE|DELETE|CREATE|PRAGMA|"
        r"WITH|BEGIN|COMMIT|ALTER|DROP)\b",
        head,
        re.I,
    ):
        return "sql"
    if re.match(
        r"^\s*(?:\$|sqlite3|curl|git|brew|npm|pnpm|python3?|"
        r"swift|cd|ls|cat|echo|sudo|mkdir|chmod)\b",
        head,
    ):
        return "bash"
    if re.search(
        r"\b(?:func|guard|struct|enum)\b|"
        r"^\s*import\s+(?:SwiftUI|Foundation|AppKit|UIKit|Combine|GRDB)\b",
        head,
        re.M,
    ):
        return "swift"
    if re.match(
        r"^\s*(?:def |class |import |from .+ import |"
        r"for .+ in |while |if __name__|print\()",
        head,
    ):
        return "python"
    if re.search(r"\b(?:const|let|function|=>|console\.log)\b", head):
        return "javascript"
    return "text"


def label_code_blocks(text: str) -> str:
    """给无信息串的围栏补语言，闭合围栏不改。"""
    lines = text.split("\n")
    inside = False
    start = 0
    for i, line in enumerate(lines):
        if not line.strip().startswith("```"):
            continue
        if not inside:
            start = i
            inside = True
            continue
        if line.strip() == "```" and lines[start].strip() == "```":
            body = "\n".join(lines[start + 1 : i])
            lang = _infer_code_language(body)
            lines[start] = lines[start].replace("```", f"```{lang}", 1)
        inside = False
    return "\n".join(lines)


def split_long_paragraphs(
    text: str, max_chars: int = 120, chunk_chars: int = 90
) -> str:
    """把超长自然段按句子边界拆开，不改动代码块、标题、表格与列表。"""
    pack = runtime.pack()
    unit = pack.unit_re
    skip = ("```", "#", "|", ">", "-", "*", "![", "[")

    def split_block(block: str) -> str:
        stripped = block.lstrip()
        if stripped.startswith(skip) or len(unit.findall(block)) <= max_chars:
            return block
        sentences = re.split(pack.sentence_end_lookbehind, block)
        chunks, current = [], ""
        for sentence in sentences:
            if not sentence:
                continue
            if current and len(unit.findall(current + sentence)) > chunk_chars:
                chunks.append(current.strip())
                current = sentence
            else:
                current += sentence
        if current.strip():
            chunks.append(current.strip())
        return "\n\n".join(chunks)

    return "\n\n".join(split_block(b) for b in re.split(pack.paragraph_split, text))


def strip_preamble(text: str) -> str:
    text = text.strip()
    m = re.search(r"^#\s+.+$", text, re.M)
    if m:
        text = text[m.start() :]
    return text.strip() + "\n"
