#!/usr/bin/env python3
"""Assert the host GraphProtocol matches the gateway graph contract.

The gateway writes graph.sqlite; the host only filters watcher events with the
same extension map. A drift here means the watcher sends files the gateway will
not parse, or misses files it should.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTOCOL = os.path.join(ROOT, "Sources", "Scanner", "Graph", "GraphProtocol.swift")
DEFAULT_CONTRACT = os.path.join(ROOT, "Sources", "Gateway", "graph.json")

ENGINE_RE = re.compile(r'static let engineVersion = "([^"]+)"')
SCHEMA_RE = re.compile(r'static let schemaVersion = "([^"]+)"')
BLOCK_RE = re.compile(r"languagesByExtension: \[String: String\] = \[(.*?)\n    \]", re.S)
ENTRY_RE = re.compile(r'"([^"]+)":\s*"([^"]+)"')


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", default=DEFAULT_CONTRACT)
    args = parser.parse_args()

    if not os.path.isfile(args.contract):
        print(f"[graph] error: not found {args.contract}", file=sys.stderr)
        return 1
    with open(args.contract, encoding="utf-8") as handle:
        contract = json.load(handle)
    with open(PROTOCOL, encoding="utf-8") as handle:
        source = handle.read()

    problems: list[str] = []
    engine = ENGINE_RE.search(source)
    schema = SCHEMA_RE.search(source)
    if not engine or engine.group(1) != contract.get("engine_version"):
        problems.append(
            f"engineVersion {engine.group(1) if engine else 'missing'!r} "
            f"!= {contract.get('engine_version')!r}"
        )
    if not schema or schema.group(1) != contract.get("schema_version"):
        problems.append(
            f"schemaVersion {schema.group(1) if schema else 'missing'!r} "
            f"!= {contract.get('schema_version')!r}"
        )

    block = BLOCK_RE.search(source)
    host_map = dict(ENTRY_RE.findall(block.group(1))) if block else {}
    expected = {
        key.lstrip("."): value for key, value in contract.get("extensions", {}).items()
    }
    if host_map != expected:
        missing = sorted(set(expected) - set(host_map))
        extra = sorted(set(host_map) - set(expected))
        if missing:
            problems.append(f"host missing extensions: {missing}")
        if extra:
            problems.append(f"host has unknown extensions: {extra}")
        for key in sorted(set(host_map) & set(expected)):
            if host_map[key] != expected[key]:
                problems.append(
                    f"extension {key!r}: host {host_map[key]!r} != {expected[key]!r}"
                )

    for message in problems:
        print(f"[graph] violation: {message}", file=sys.stderr)
    if problems:
        return 1
    print(f"[graph] ok ({len(host_map)} extensions match the contract)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
