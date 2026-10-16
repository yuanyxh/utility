#!/usr/bin/env python3
"""校验 skill 结构。用法: validate_skill.py <skill.md 或 skill 目录>"""

import os
import re
import sys

NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")
AFFIL_DIRS = ("references", "scripts", "agents")


def parse_frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        return None
    fm = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            fm[k.strip()] = v.strip()
    return fm


def validate(path):
    if os.path.isdir(path):
        md = os.path.join(path, "SKILL.md")
        if not os.path.isfile(md):
            return [f"目录 skill 缺少 SKILL.md: {path}"]
    else:
        md = path

    with open(md, encoding="utf-8") as fh:
        fm = parse_frontmatter(fh.read())
    if fm is None:
        return [f"缺少 frontmatter(--- ... ---): {md}"]

    errs = []
    name = fm.get("name", "")
    if not NAME_RE.match(name):
        errs.append(f"name 必须是 snake_case（小写字母开头）: {name!r}")
    if len(fm.get("description", "")) < 20:
        errs.append("description 过短，需写清触发场景")

    if os.path.isdir(path):
        for entry in os.listdir(path):
            full = os.path.join(path, entry)
            if (
                os.path.isdir(full)
                and entry not in AFFIL_DIRS
                and not entry.startswith(".")
            ):
                errs.append(f"附属目录应放 {AFFIL_DIRS} 之一，发现: {entry}")
    return errs


def main():
    if len(sys.argv) != 2:
        print("用法: validate_skill.py <skill.md 或 skill 目录>")
        return 2
    errs = validate(sys.argv[1])
    if errs:
        for e in errs:
            print("✗", e)
        return 1
    print("✓ 校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
