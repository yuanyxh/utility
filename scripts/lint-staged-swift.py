#!/usr/bin/env python3
"""Lint only the staged lines of Swift files; legacy lines do not block commits."""

from __future__ import annotations

import re
import subprocess
import sys

GENERATED = {"Sources/Core/L10nKeys.swift"}
HUNK_RE = re.compile(r"\+(\d+)(?:,(\d+))?")
DIAG_RE = re.compile(r"(.+?):(\d+):(\d+): error: (.*)")


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True)


def changed_ranges() -> dict[str, list[tuple[int, int]]]:
    diff = run(["git", "diff", "--cached", "-U0", "--diff-filter=ACMR", "--", "*.swift"]).stdout
    ranges: dict[str, list[tuple[int, int]]] = {}
    current = ""
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current = line[6:]
            ranges.setdefault(current, [])
            continue
        if not line.startswith("@@") or not current:
            continue
        match = HUNK_RE.search(line)
        if not match:
            continue
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        if count > 0:
            ranges[current].append((start, start + count - 1))
    return ranges


def main() -> int:
    ranges = changed_ranges()
    files = [path for path in ranges if path not in GENERATED]
    if not files:
        print("==> swift-format: no changed Swift lines")
        return 0
    result = run(
        ["xcrun", "swift-format", "lint", "--strict", "--configuration", ".swift-format", *files]
    )
    violations = []
    for line in (result.stdout + result.stderr).splitlines():
        match = DIAG_RE.match(line)
        if not match:
            continue
        path, number = match.group(1), int(match.group(2))
        if any(low <= number <= high for low, high in ranges.get(path, [])):
            violations.append(line)
    if violations:
        print(f"==> swift-format: {len(violations)} violation(s) on changed lines")
        print("\n".join(violations))
        return 1
    print(f"==> swift-format: ok ({len(files)} changed Swift file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
