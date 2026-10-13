#!/usr/bin/env python3
"""Validate a skill's structure. Usage: validate_skill.py <skill.md or skill directory>"""
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
            return [f"Directory skill is missing SKILL.md: {path}"]
    else:
        md = path

    with open(md, encoding="utf-8") as fh:
        fm = parse_frontmatter(fh.read())
    if fm is None:
        return [f"Missing frontmatter (--- ... ---): {md}"]

    errs = []
    name = fm.get("name", "")
    if not NAME_RE.match(name):
        errs.append(f"name must be snake_case (starting with a lowercase letter): {name!r}")
    if len(fm.get("description", "")) < 20:
        errs.append("description is too short; it must clearly state the trigger scenario")

    if os.path.isdir(path):
        for entry in os.listdir(path):
            full = os.path.join(path, entry)
            if os.path.isdir(full) and entry not in AFFIL_DIRS and not entry.startswith("."):
                errs.append(f"Affiliated directories must be one of {AFFIL_DIRS}, found: {entry}")
    return errs


def main():
    if len(sys.argv) != 2:
        print("Usage: validate_skill.py <skill.md or skill directory>")
        return 2
    errs = validate(sys.argv[1])
    if errs:
        for e in errs:
            print("✗", e)
        return 1
    print("✓ Validation passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
