#!/usr/bin/env python3
"""扫描验证器日志中的过时外部路径，并建议缓存清理命令。

检测已不存在的 /tmp/ 与 /private/tmp/ 文件引用；这些是验证器
（golangci-lint 缓存、go build 缓存、npm 缓存等）指向的过时 worktree 的特征。

用法: python3 check_verifier_output.py ROOT LOG_FILE
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


TOKEN_RE = re.compile(
    r"(?P<path>(?:/|\.\./)(?:[^\s:'\"(),]+/)*[^\s:'\"(),]+\.[A-Za-z0-9_+-]+)"
)
TMP_RE = re.compile(r"(^|/)(private/)?tmp/")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", help="仓库根")
    parser.add_argument("log_file", help="要扫描的验证器日志")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    log_file = Path(args.log_file).resolve()
    if not root.is_dir():
        print(f"Repo root not found: {root}", file=sys.stderr)
        return 2
    if not log_file.is_file():
        print(f"Log file not found: {log_file}", file=sys.stderr)
        return 2

    text = log_file.read_text(encoding="utf-8", errors="replace")

    def normalize(token: str) -> Path:
        if token.startswith("/"):
            return Path(token)
        return (root / token).resolve()

    paths: list[Path] = []
    for match in TOKEN_RE.finditer(text):
        token = match.group("path").rstrip(".")
        if "/.git/" in token:
            continue
        path = normalize(token)
        if TMP_RE.search(path.as_posix()):
            paths.append(path)

    unique_paths = []
    seen = set()
    for path in paths:
        value = path.as_posix()
        if value in seen:
            continue
        seen.add(value)
        unique_paths.append(path)

    stale_paths = [path for path in unique_paths if not path.exists()]
    existing_paths = [path for path in unique_paths if path.exists()]
    lower = text.lower()

    actions: list[str] = []
    if stale_paths:
        if "golangci-lint" in lower or "errcheck" in lower:
            actions.append("golangci-lint cache clean")
        if re.search(r"\bgo (test|vet|build)\b", lower) or "go-build" in lower:
            actions.append("go clean -cache -testcache")
        if "npm" in lower or "node_modules" in lower:
            actions.append("npm cache verify")
        if not actions:
            actions.append(
                "rerun the verifier after removing stale temporary worktrees"
            )

    status = "WARN" if stale_paths else "PASS"

    print("=== VERIFIER OUTPUT SURFACE ===")
    print(f"verifier_output_status: {status}")
    print(f"log_file: {log_file}")
    print("stale_paths:")
    if stale_paths:
        for path in stale_paths[:20]:
            print(f"  {path}")
        if len(stale_paths) > 20:
            print(f"  ... {len(stale_paths) - 20} more")
    else:
        print("  (none)")
    print("existing_tmp_paths:")
    if existing_paths:
        for path in existing_paths[:10]:
            print(f"  {path}")
        if len(existing_paths) > 10:
            print(f"  ... {len(existing_paths) - 10} more")
    else:
        print("  (none)")
    print("recommended_actions:")
    if actions:
        for action in dict.fromkeys(actions):
            print(f"  {action}")
    else:
        print("  (none)")
    print("verifier_findings:")
    if stale_paths:
        print("  stale external verifier paths detected")
    else:
        print("  (none)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
