#!/usr/bin/env python3
"""Generate the typed Swift API and the Python catalog from Resources/<lang>.json.

The JSON files are the only source of truth. This script validates them and writes:

- Sources/Core/L10nKeys.swift        (Swift accessors, all namespaces except Python-only ones)
- Sources/MCPScripts/utility/core/l10n_catalog.py (Python catalog, Python-only + shared)

Run with --check to verify the checked-in files are current (CI / packaging).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(ROOT, "Sources", "Resources")
SWIFT_OUT = os.path.join(ROOT, "Sources", "Core", "L10nKeys.swift")
PY_OUT = os.path.join(
    ROOT, "Sources", "MCPScripts", "utility", "core", "l10n_catalog.py"
)

BASELINE_LANG = "zh-Hans"
LANG_FILE_RE = re.compile(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]+)*\.json$")
KEY_RE = re.compile(r"^([a-z][a-z0-9]*)\.[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*$")
PLACEHOLDER_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)(?::(\.\d+f|d))?\}")

#: Namespaces emitted to Python only. Swift must not generate accessors for them.
PYTHON_NAMESPACES = {"mcp", "proxy"}
#: Namespaces emitted to both runtimes (RSS copy is produced by Python, CLI help by Swift).
SHARED_NAMESPACES = {"rss"}
#: Namespaces whose values are raw templates: rendered later by PromptManager, never here.
RAW_NAMESPACES = {"prompt"}

SWIFT_ACRONYMS = {"rss": "RSS", "cli": "CLI"}
#: Name segments that keep their all-caps spelling after the first (URL → invalidURL).
SWIFT_NAME_ACRONYMS = {"url": "URL"}
SWIFT_RESERVED = {
    "associatedtype",
    "class",
    "deinit",
    "enum",
    "extension",
    "fileprivate",
    "func",
    "import",
    "init",
    "inout",
    "internal",
    "let",
    "open",
    "operator",
    "private",
    "precedencegroup",
    "protocol",
    "public",
    "rethrows",
    "static",
    "struct",
    "subscript",
    "typealias",
    "var",
    "break",
    "case",
    "catch",
    "continue",
    "default",
    "defer",
    "do",
    "else",
    "fallthrough",
    "for",
    "guard",
    "if",
    "in",
    "repeat",
    "return",
    "throw",
    "switch",
    "where",
    "while",
    "as",
    "any",
    "false",
    "is",
    "nil",
    "self",
    "super",
    "throws",
    "true",
    "try",
    "some",
}


class GenError(Exception):
    pass


def fail(message: str) -> None:
    raise GenError(message)


def load_languages() -> dict[str, dict[str, str]]:
    try:
        names = sorted(os.listdir(RESOURCES))
    except OSError as e:
        fail(f"cannot list {RESOURCES}: {e}")
    files = [n for n in names if LANG_FILE_RE.match(n)]
    if not files:
        fail(f"no language files found in {RESOURCES}")
    languages: dict[str, dict[str, str]] = {}
    for name in files:
        path = os.path.join(RESOURCES, name)
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError) as e:
            fail(f"{name}: cannot read JSON: {e}")
        if not isinstance(data, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in data.items()
        ):
            fail(f"{name}: expected a flat object of string values")
        languages[name[:-5]] = data
    if BASELINE_LANG not in languages:
        fail(f"baseline language {BASELINE_LANG!r} is missing")
    return languages


def placeholders(text: str, key: str) -> dict[str, str]:
    """Placeholder name -> kind (string/int/double), in first-appearance order."""
    found: dict[str, str] = {}
    for match in PLACEHOLDER_RE.finditer(text):
        name, spec = match.group(1), match.group(2)
        kind = "int" if spec == "d" else "double" if spec else "string"
        if name in found and found[name] != kind:
            fail(f"{key}: placeholder {name!r} has conflicting types")
        found[name] = kind
    return found


def validate(
    languages: dict[str, dict[str, str]],
) -> tuple[list[str], dict[str, dict[str, str]]]:
    baseline = languages[BASELINE_LANG]
    for key in baseline:
        if not KEY_RE.match(key):
            fail(f"{BASELINE_LANG}: invalid key {key!r} (expected ns.snake_case)")
    baseline_ph = {key: placeholders(value, key) for key, value in baseline.items()}
    for lang, data in languages.items():
        if set(data) != set(baseline):
            missing = sorted(set(baseline) - set(data))
            extra = sorted(set(data) - set(baseline))
            fail(
                f"{lang}: key set differs from baseline (missing={missing}, extra={extra})"
            )
        for key, value in data.items():
            ph = placeholders(value, key)
            if ph != baseline_ph[key]:
                fail(
                    f"{lang}: {key}: placeholders {ph} differ from baseline {baseline_ph[key]}"
                )
    return sorted(baseline), baseline_ph


def swift_name(snake: str) -> str:
    parts = snake.split("_")
    name = parts[0] + "".join(
        SWIFT_NAME_ACRONYMS.get(p, p.capitalize()) for p in parts[1:]
    )
    return f"`{name}`" if name in SWIFT_RESERVED else name


def namespace_name(ns: str) -> str:
    if ns in SWIFT_ACRONYMS:
        return SWIFT_ACRONYMS[ns]
    return "".join(p.capitalize() for p in ns.split("_"))


def fingerprint(languages: dict[str, dict[str, str]]) -> str:
    digest = hashlib.sha256()
    for lang in sorted(languages):
        digest.update(lang.encode())
        digest.update(b"\0")
        digest.update(
            json.dumps(languages[lang], sort_keys=True, ensure_ascii=False).encode()
        )
        digest.update(b"\0")
    return digest.hexdigest()


def swift_kind(kind: str) -> tuple[str, str]:
    """Placeholder kind -> (Swift type, Arg case)."""
    return {
        "string": ("String", "string"),
        "int": ("Int", "int"),
        "double": ("Double", "double"),
    }[kind]


def render_swift(
    languages: dict[str, dict[str, str]], keys: list[str], ph: dict[str, dict[str, str]]
) -> str:
    groups: dict[str, list[str]] = {}
    for key in keys:
        ns = key.split(".", 1)[0]
        if ns in PYTHON_NAMESPACES and ns not in SHARED_NAMESPACES:
            continue
        groups.setdefault(ns, []).append(key)

    lines = [
        "// Generated by scripts/gen-l10n.py — do not edit.",
        f"// Input fingerprint: {fingerprint(languages)}",
        "",
        "extension L10n {",
        "    static let availableLanguages: [String] = ["
        + ", ".join(json.dumps(lang) for lang in sorted(languages))
        + "]",
        "}",
    ]
    for ns in sorted(groups):
        lines.append("")
        lines.append("extension L10n {")
        lines.append(f"    enum {namespace_name(ns)} {{")
        for key in groups[ns]:
            name = swift_name(key.split(".", 1)[1])
            params = ph[key]
            if not params or ns in RAW_NAMESPACES:
                lines.append(
                    f"        static var {name}: String {{ L10n.string({json.dumps(key)}) }}"
                )
                continue
            signature = []
            args = []
            for param, kind in params.items():
                swift_type, arg_case = swift_kind(kind)
                signature.append(f"{swift_name(param)}: {swift_type}")
                args.append(f"{json.dumps(param)}: .{arg_case}({swift_name(param)})")
            lines.append(
                f"        static func {name}("
                + ", ".join(signature)
                + f") -> String {{ L10n.render({json.dumps(key)}, ["
                + ", ".join(args)
                + "]) }"
            )
        lines.append("    }")
        lines.append("}")
    return "\n".join(lines) + "\n"


def render_python(languages: dict[str, dict[str, str]], keys: list[str]) -> str:
    rows = [
        key
        for key in keys
        if key.split(".", 1)[0] in PYTHON_NAMESPACES | SHARED_NAMESPACES
    ]
    lines = [
        '"""Generated by scripts/gen-l10n.py — do not edit."""',
        "",
        f'FINGERPRINT = "{fingerprint(languages)}"',
        "AVAILABLE_LANGUAGES: list[str] = ["
        + ", ".join(json.dumps(lang) for lang in sorted(languages))
        + "]",
        "",
        "CATALOG: dict[str, dict[str, str]] = {",
    ]
    for key in rows:
        entries = ", ".join(
            f"{json.dumps(lang)}: {json.dumps(languages[lang][key], ensure_ascii=False)}"
            for lang in sorted(languages)
        )
        lines.append(f"    {json.dumps(key)}: {{{entries}}},")
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_or_check(path: str, content: str, check: bool) -> bool:
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            current = f.read()
    else:
        current = None
    if check:
        if current != content:
            print(f"[gen-l10n] stale: {os.path.relpath(path, ROOT)}", file=sys.stderr)
            return False
        return True
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"[gen-l10n] wrote {os.path.relpath(path, ROOT)}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check", action="store_true", help="verify generated files are current"
    )
    args = parser.parse_args()
    try:
        languages = load_languages()
        keys, ph = validate(languages)
        swift = render_swift(languages, keys, ph)
        py = render_python(languages, keys)
    except GenError as e:
        print(f"[gen-l10n] error: {e}", file=sys.stderr)
        return 1
    ok = write_or_check(SWIFT_OUT, swift, args.check)
    ok = write_or_check(PY_OUT, py, args.check) and ok
    if args.check and ok:
        print(f"[gen-l10n] up to date ({len(keys)} keys, {len(languages)} languages)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
