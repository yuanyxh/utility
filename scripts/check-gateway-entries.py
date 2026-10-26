#!/usr/bin/env python3
"""Assert the host's `GatewayEntry` constants match the gateway's `entries.json` contract.

The host launches Python by module name, so a rename on the gateway side fails only at runtime
(`ModuleNotFoundError`, no MCP, no proxy) — nothing in the build notices. The gateway exports
`entries.json` from `--export-contracts`; this script compares it against
`Sources/Core/Constants.swift` (regex over the `enum GatewayEntry` block, no Swift parsing).

- host names a module the contract does not declare → violation (typo or renamed contract)
- both declare a name with different values → violation
- contract declares a name the host ignores → informational only (gateway may add entries)

Usage: python3 scripts/check-gateway-entries.py --entries <path/to/entries.json>
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONSTANTS = os.path.join(ROOT, "Sources", "Core", "Constants.swift")
DEFAULT_ENTRIES = os.path.join(ROOT, "Sources", "Gateway", "entries.json")

ENTRY_RE = re.compile(r'static let (\w+)\s*=\s*"([^"]+)"')


def swift_entries(path: str) -> dict[str, str]:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    block = re.search(r"enum GatewayEntry \{(.*?)\n\}", text, re.S)
    if not block:
        raise SystemExit(f"[entries] cannot find `enum GatewayEntry` in {path}")
    return dict(ENTRY_RE.findall(block.group(1)))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--entries",
        default=DEFAULT_ENTRIES,
        help=f"entries.json exported by agent-gateway (default: {DEFAULT_ENTRIES})",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.entries):
        print(f"[entries] error: not found {args.entries}", file=sys.stderr)
        return 1
    with open(args.entries, encoding="utf-8") as f:
        contract = json.load(f).get("entries", {})
    actual = swift_entries(CONSTANTS)

    violations: list[str] = []
    for name, module in sorted(actual.items()):
        if name not in contract:
            violations.append(f"GatewayEntry.{name} = {module!r} is not in the contract")
        elif contract[name] != module:
            violations.append(
                f"GatewayEntry.{name} = {module!r} != contract {contract[name]!r}"
            )
    unused = sorted(set(contract) - set(actual))

    for message in violations:
        print(f"[entries] violation: {message}", file=sys.stderr)
    if unused:
        print(f"[entries] note: contract also declares {unused} (host does not launch them)")
    if violations:
        print(f"[entries] {len(violations)} violation(s)", file=sys.stderr)
        return 1
    print(f"[entries] ok ({len(actual)} host entries match the contract)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
