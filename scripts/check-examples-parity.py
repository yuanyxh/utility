#!/usr/bin/env python3
"""Assert that the bilingual example mirrors share identical logic.

`examples/en` and `examples/zh-Hans` ship the same skill scripts twice, with
only human-readable text translated. A fix applied to one side silently drifts
from the other, and nothing in the runtime would notice (examples are not
executed). This gate compares the *structure* instead of the bytes:

  - `.py`: AST after dropping docstrings and replacing string/bytes literals
  - `.sh`: non-comment lines after replacing quoted text

Markdown files are intentionally excluded: they are the translation itself.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EN_ROOT = ROOT / "examples" / "en"
ZH_ROOT = ROOT / "examples" / "zh-Hans"
SCRIPT_SUFFIXES = {".py", ".sh"}
SCRIPT_DEFS = (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
_QUOTED = re.compile(r'(["\'])(?:\\.|(?!\1).)*\1')


class _LiteralMask(ast.NodeTransformer):
    """Replace every string/bytes literal so translations do not count as drift."""

    def visit_Constant(self, node: ast.Constant) -> ast.AST:
        if isinstance(node.value, (str, bytes)):
            return ast.copy_location(ast.Constant(value="<text>"), node)
        return node


def canon_python(path: Path) -> str:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if not isinstance(node, SCRIPT_DEFS):
            continue
        body = node.body
        if (
            body
            and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)
        ):
            node.body = body[1:]
    return ast.dump(_LiteralMask().visit(tree), include_attributes=False)


def canon_shell(path: Path) -> list[str]:
    lines: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        lines.append(_QUOTED.sub('"<text>"', line))
    return lines


def canon(path: Path) -> str | list[str]:
    return canon_python(path) if path.suffix == ".py" else canon_shell(path)


def script_files(root: Path) -> set[Path]:
    if not root.is_dir():
        return set()
    return {
        path.relative_to(root)
        for path in root.rglob("*")
        if path.is_file() and path.suffix in SCRIPT_SUFFIXES
    }


def check() -> list[str]:
    en_files = script_files(EN_ROOT)
    zh_files = script_files(ZH_ROOT)
    problems: list[str] = []

    for rel in sorted(en_files - zh_files):
        problems.append(f"{rel} exists in examples/en but not in examples/zh-Hans")
    for rel in sorted(zh_files - en_files):
        problems.append(f"{rel} exists in examples/zh-Hans but not in examples/en")

    for rel in sorted(en_files & zh_files):
        try:
            if canon(EN_ROOT / rel) != canon(ZH_ROOT / rel):
                problems.append(f"{rel}: logic differs between the two languages")
        except SyntaxError as exc:
            problems.append(f"{rel}: cannot parse: {exc}")
    return problems


def main() -> int:
    problems = check()
    total = len(script_files(EN_ROOT))
    if problems:
        for problem in problems:
            print(f"  ✗ {problem}")
        print(f"\n[examples] ✗ {len(problems)} problem(s) across {total} scripts")
        return 1
    print(
        f"[examples] ✓ {total} scripts are logic-identical across en / zh-Hans"
        " (translations excluded)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
