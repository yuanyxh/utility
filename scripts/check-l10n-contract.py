#!/usr/bin/env python3
"""Check the i18n catalog contract shared by Swift and Python.

The JSON files under `Sources/Resources/` are the only source of truth; the typed Swift API and
the Python catalog are generated from them. This script guards the seams that a generator alone
cannot see:

  - every language has the same keys and the same typed placeholders as the baseline
  - both generated files are current (`gen-l10n.py --check`)
  - Swift never bypasses the generated accessors (`L10n.string/render/format` is private-by-convention)
  - Python never hardcodes a language tag outside the runtime/generated modules
  - `t("literal.key")` calls reference a key that exists
  - keys nobody references (warning only — translation can land before the call site)

Usage (from the project root): python3 scripts/check-l10n-contract.py
Exit 0 = all passed; 1 = a contract violation.
"""

from __future__ import annotations

import ast
import importlib.util
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Sources", "Resources")
SWIFT_SOURCES = os.path.join(ROOT, "Sources")
PY_SOURCES = os.path.join(ROOT, "Sources", "MCPScripts")
GEN = os.path.join(ROOT, "scripts", "gen-l10n.py")
L10N_RUNTIME = os.path.join(SWIFT_SOURCES, "Core", "L10n.swift")
L10N_KEYS = os.path.join(SWIFT_SOURCES, "Core", "L10nKeys.swift")
PY_RUNTIME = os.path.join(PY_SOURCES, "utility", "core", "l10n.py")
PY_CATALOG = os.path.join(PY_SOURCES, "utility", "core", "l10n_catalog.py")

BASELINE = "zh-Hans"
LANG_FILE_RE = re.compile(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]+)*\.json$")
KEY_RE = re.compile(r"^([a-z][a-z0-9]*)\.[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*$")
PLACEHOLDER_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)(?::(\.\d+f|d))?\}")
SWIFT_BYPASS_RE = re.compile(r"\bL10n\.(?:string|render|format)\s*\(")
SWIFT_ACRONYMS = {"rss": "RSS", "cli": "CLI"}
SWIFT_NAME_ACRONYMS = {"url": "URL"}


def load_generator():
    spec = importlib.util.spec_from_file_location("gen_l10n", GEN)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def python_language_constants(path: str) -> list[tuple[int, str]]:
    """Language tags written as a table key or as a fallback constant.

    Only these two shapes are checked: they are how the duplicated tables were written. A plain
    string such as `WIKI_LANGS = ("zh", "en")` is search behaviour, not UI copy, and is not flagged.
    """
    tree = ast.parse(read(path), filename=path)
    hits: list[tuple[int, str]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Dict):
            for key in node.keys:
                if isinstance(key, ast.Constant) and isinstance(key.value, str):
                    hits.append((key.lineno, key.value))
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            value = node.value
            if not (isinstance(value, ast.Constant) and isinstance(value.value, str)):
                continue
            for target in targets:
                if isinstance(target, ast.Name) and re.fullmatch(
                    r"(FALLBACK|BASELINE)_LANG", target.id
                ):
                    hits.append((value.lineno, value.value))
    return hits


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

    # Group 2: generated files are current.
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

    # Group 4: Python must not hardcode a language tag outside runtime/generated modules.
    tags = set(languages)
    for path in iter_files(PY_SOURCES, ".py"):
        if path in (PY_RUNTIME, PY_CATALOG):
            continue
        for lineno, value in python_language_constants(path):
            if value in tags:
                violations.append(
                    f"{os.path.relpath(path, ROOT)}:{lineno}: hardcoded language tag {value!r}"
                )

    # Group 5: Python literal keys exist. Parameter descriptions are fixed English and
    # are checked by check-router-config-contract.py, not against this catalog.
    for path in iter_files(PY_SOURCES, ".py"):
        if path == PY_CATALOG:
            continue
        tree = ast.parse(read(path), filename=path)
        for node in ast.walk(tree):
            if not (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name)
                and node.func.id == "t"
                and node.args
                and isinstance(node.args[0], ast.Constant)
                and isinstance(node.args[0].value, str)
            ):
                continue
            key = node.args[0].value
            if key not in baseline:
                violations.append(
                    f"{os.path.relpath(path, ROOT)}:{node.lineno}: t({key!r}) is not in the catalog"
                )

    # Group 6: unreferenced keys (warning only).
    swift_usage = "\n".join(
        read(path)
        for path in iter_files(SWIFT_SOURCES, ".swift")
        if path not in (L10N_RUNTIME, L10N_KEYS)
    )
    python_usage = "\n".join(
        read(path) for path in iter_files(PY_SOURCES, ".py") if path != PY_CATALOG
    )
    for key in sorted(baseline):
        namespace = key.split(".", 1)[0]
        if namespace in {"mcp", "proxy"}:
            if not re.search(re.escape(key).join(("[\"']", "[\"']")), python_usage):
                warnings.append(f"unreferenced Python key: {key}")
        elif not re.search(re.escape(swift_accessor(key)) + r"\b", swift_usage):
            warnings.append(f"unreferenced Swift key: {key} ({swift_accessor(key)})")

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
