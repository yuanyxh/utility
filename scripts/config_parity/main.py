"""Assert `config.py`'s YAML fallback table covers every env it reads.

The fallback only runs when Swift did not inject the env, so a missing entry is
silent: the env-driven path keeps working while the YAML path returns the default.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG_PY = ROOT / "Sources/MCPScripts/utility/core/config.py"
DEFAULT_YAML = ROOT / "Sources/Resources/default-config.yaml"

#: Env read by config.py with no config.yaml counterpart (reason required).
_EXEMPT = {
    "UTILITY_DATA_DIR": "config root itself, cannot come from the config file",
    "UTILITY_USER_ID": "system user name",
    "UTILITY_BIN": "app executable path",
}


def _is_env_get(node: ast.Call) -> bool:
    func = node.func
    if isinstance(func, ast.Name) and func.id == "get":
        return True
    return (
        isinstance(func, ast.Attribute)
        and func.attr == "get"
        and isinstance(func.value, ast.Attribute)
        and func.value.attr == "environ"
    )


def env_reads(tree: ast.Module) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not node.args or not _is_env_get(node):
            continue
        arg = node.args[0]
        if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
            if arg.value.isupper() and arg.value.replace("_", "").isalnum():
                names.add(arg.value)
    return names


def fallback_table(tree: ast.Module) -> dict[str, str]:
    for node in tree.body:
        target = node.target if isinstance(node, ast.AnnAssign) else None
        if not (isinstance(target, ast.Name) and target.id == "_YAML_FALLBACKS"):
            continue
        table: dict[str, str] = {}
        if not isinstance(node.value, ast.Dict):
            return table
        for key_node, value_node in zip(node.value.keys, node.value.values):
            pair = value_node.elts if isinstance(value_node, ast.Tuple) else []
            if isinstance(key_node, ast.Constant) and pair:
                table[key_node.value] = getattr(pair[0], "value", "")
        return table
    return {}


def yaml_keys() -> set[str]:
    import yaml

    data = yaml.safe_load(DEFAULT_YAML.read_text(encoding="utf-8"))
    keys: set[str] = set()

    def walk(node: object, prefix: str) -> None:
        if not isinstance(node, dict):
            return
        for key, child in node.items():
            path = f"{prefix}.{key}" if prefix else str(key)
            keys.add(path)
            walk(child, path)

    walk(data, "")
    return keys


def main() -> int:
    tree = ast.parse(CONFIG_PY.read_text(encoding="utf-8"))
    reads = env_reads(tree)
    table = fallback_table(tree)
    keys = yaml_keys()
    problems: list[str] = []

    for name in sorted(reads - set(table) - set(_EXEMPT)):
        problems.append(f"{name}: read by config.py but missing from _YAML_FALLBACKS")
    for name in sorted(set(table) - reads):
        problems.append(f"{name}: mapped in _YAML_FALLBACKS but never read")
    for name, path in sorted(table.items()):
        if path not in keys:
            problems.append(f"{name}: config.yaml has no key '{path}'")

    if problems:
        print("[config-parity] FAILED")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(
        f"[config-parity] OK: {len(reads)} env reads, {len(table)} YAML fallbacks, "
        f"{len(_EXEMPT)} exempt"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
