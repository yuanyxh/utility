#!/usr/bin/env python3
"""Check the Swift-side i18n contract.

`Sources/Resources/<lang>.json` is the only source of truth for host UI copy; the typed
accessors in `Sources/Core/L10nKeys.swift` are generated from it. This script guards the seams
a generator alone cannot see:

  - every language has the same keys and the same typed placeholders as the baseline
  - the generated file is current (`gen-l10n.py --check`)
  - Swift never bypasses the generated accessors (`L10n.string/render/format` is private-by-convention)
  - every key is referenced by at least one accessor (warning only)

The Python side (agent-gateway) owns its own locale files, so nothing here reaches across repos.

Usage (from the project root): python3 scripts/check-l10n-contract.py
Exit 0 = all passed; 1 = a contract violation.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Sources", "Resources")
SWIFT_SOURCES = os.path.join(ROOT, "Sources")
GEN = os.path.join(ROOT, "scripts", "gen-l10n.py")
L10N_RUNTIME = os.path.join(SWIFT_SOURCES, "Core", "L10n.swift")
L10N_KEYS = os.path.join(SWIFT_SOURCES, "Core", "L10nKeys.swift")

BASELINE = "zh-Hans"
LANG_FILE_RE = re.compile(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]+)*\.json$")
KEY_RE = re.compile(r"^([a-z][a-z0-9]*)\.[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*$")
PLACEHOLDER_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)(?::(\.\d+f|d))?\}")
SWIFT_BYPASS_RE = re.compile(r"\bL10n\.(?:string|render|format)\s*\(")
SWIFT_ACRONYMS = {"rss": "RSS", "cli": "CLI"}
SWIFT_NAME_ACRONYMS = {"url": "URL"}


def load_languages() -> dict[str, dict[str, str]]:
    languages: dict[str, dict[str, str]] = {}
    for name in sorted(os.listdir(RESOURCES)):
        if not LANG_FILE_RE.match(name):
            continue
        with open(os.path.join(RESOURCES, name), encoding="utf-8") as f:
            languages[name[:-5]] = json.load(f)
    return languages


def placeholders(text: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for match in PLACEHOLDER_RE.finditer(text):
        spec = match.group(2)
        found[match.group(1)] = "int" if spec == "d" else "double" if spec else "string"
    return found


def swift_accessor(key: str) -> str:
    namespace, name = key.split(".", 1)
    ns = SWIFT_ACRONYMS.get(namespace) or "".join(
        p.capitalize() for p in namespace.split("_")
    )
    parts = name.split("_")
    camel = parts[0] + "".join(
        SWIFT_NAME_ACRONYMS.get(p, p.capitalize()) for p in parts[1:]
    )
    return f"L10n.{ns}.{camel}"


def iter_files(root: str, suffix: str):
    for directory, _, names in os.walk(root):
        for name in names:
            if name.endswith(suffix):
                yield os.path.join(directory, name)


def read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def main() -> int:
    violations: list[str] = []
    warnings: list[str] = []
    languages = load_languages()
    if BASELINE not in languages:
        print(f"[l10n] missing baseline {BASELINE}.json", file=sys.stderr)
        return 1
    baseline = languages[BASELINE]

    # Group 1: key parity + typed placeholders.
    for key in baseline:
        if not KEY_RE.match(key):
            violations.append(f"{BASELINE}: invalid key {key!r}")
    baseline_ph = {key: placeholders(value) for key, value in baseline.items()}
    for lang, data in languages.items():
        if set(data) != set(baseline):
            violations.append(
                f"{lang}: key set differs from baseline "
                f"(missing={sorted(set(baseline) - set(data))}, extra={sorted(set(data) - set(baseline))})"
            )
        for key, value in data.items():
            if placeholders(value) != baseline_ph.get(key):
                violations.append(
                    f"{lang}: {key}: placeholders {placeholders(value)} != {baseline_ph.get(key)}"
                )

    # Group 2: the generated file is current.
    result = subprocess.run(
        [sys.executable, GEN, "--check"], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        output = (result.stderr or result.stdout).strip()
        violations.append(f"generated files are stale: {output}")

    # Group 3: Swift must go through the generated accessors.
    for path in iter_files(SWIFT_SOURCES, ".swift"):
        if path in (L10N_RUNTIME, L10N_KEYS):
            continue
        for lineno, line in enumerate(read(path).splitlines(), 1):
            if SWIFT_BYPASS_RE.search(line):
                violations.append(
                    f"{os.path.relpath(path, ROOT)}:{lineno}: bypasses the generated accessors"
                )

    # Group 4: unreferenced keys (warning only — translation can land before the call site).
    swift_usage = "\n".join(
        read(path)
        for path in iter_files(SWIFT_SOURCES, ".swift")
        if path not in (L10N_RUNTIME, L10N_KEYS)
    )
    for key in sorted(baseline):
        if not re.search(re.escape(swift_accessor(key)) + r"\b", swift_usage):
            warnings.append(f"unreferenced key: {key} ({swift_accessor(key)})")

    for message in violations:
        print(f"[l10n] violation: {message}", file=sys.stderr)
    for message in warnings:
        print(f"[l10n] warning: {message}")
    if violations:
        print(f"[l10n] {len(violations)} violation(s)", file=sys.stderr)
        return 1
    print(
        f"[l10n] ok ({len(baseline)} keys, {len(languages)} languages, {len(warnings)} warning(s))"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
