"""Reusable source parsers."""
from __future__ import annotations

import ast
import copy
import json
import os
import pathlib
import re
import sys
from dataclasses import dataclass, replace

try:
    #: Group 7's criterion comes from aiohttp's own response-decoding capability probe, rather than
    #: maintaining a separate table of "which encodings are decodable" (a rewritten table would
    #: inevitably drift from the real capability). If aiohttp changes its internal layout, this
    #: **goes red** instead of staying silent: anything undetectable is treated as "not decodable",
    #: favoring a loud error over letting it pass.
    from aiohttp.compression_utils import HAS_BROTLI, HAS_ZSTD
except ImportError:  # pragma: no cover
    HAS_BROTLI = HAS_ZSTD = False

def _read(path: str) -> str | None:
    try:
        return open(path, encoding="utf-8").read()
    except OSError:
        return None


def _extract_block(src: str, header: re.Pattern[str]) -> str | None:
    """Extract the body of the block matched by `header`, by brace balancing.

    Cannot reuse the non-greedy `struct … \\{ (.*?) \\n\\s*\\}`: the providers Payload has a nested
    CodingKeys, and non-greedy matching truncates there, dropping all the following fields.
    It works for both enums and structs like `EnvKeys` / `PythonScripts`, so it is extracted as a
    shared function.
    """
    m = header.search(src)
    if not m:
        return None
    depth = 1
    i = start = m.end()
    while i < len(src) and depth > 0:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return src[start : i - 1] if depth == 0 else None


def _extract_struct_body(src: str, struct_name: str) -> str | None:
    """Extract the body of `struct <name>: Encodable`, by brace balancing."""
    return _extract_block(
        src, re.compile(rf"struct\s+{re.escape(struct_name)}\s*:\s*Encodable\s*\{{")
    )


def _extract_enum_body(src: str, enum_name: str) -> str | None:
    """Extract the body of `enum <name> { … }`, by brace balancing (a trailing `: String` is also tolerated)."""
    return _extract_block(src, re.compile(rf"enum\s+{re.escape(enum_name)}\b[^{{]*\{{"))


def _module_string_constants(path: str) -> dict[str, str]:
    """Module-level `NAME = "literal"` constant table (the Python version of `parse_static_lets`)."""
    src = _read(path)
    if src is None:
        return {}
    out: dict[str, str] = {}
    for node in ast.parse(src).body:
        if (
            isinstance(node, ast.Assign)
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str)
        ):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    out[target.id] = node.value.value
    return out


def _set_literals_by_name(tree: ast.AST) -> dict[str, set[str] | None]:
    """The set table of `NAME = {…literals…}`; the same name assigned more than once is recorded as `None` (ambiguous).

    Ambiguity is **not silently passed**: when it cannot be resolved, `collect_upstream_accept_encoding`
    reports red, rather than treating it as "the guard doesn't have it" or "it has it"——both would
    make the criterion lie.
    """
    out: dict[str, set[str] | None] = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Set):
            continue
        values = {
            elt.value.lower()
            for elt in node.value.elts
            if isinstance(elt, ast.Constant) and isinstance(elt.value, str)
        }
        for target in node.targets:
            if isinstance(target, ast.Name):
                out[target.id] = None if target.id in out else values
    return out
