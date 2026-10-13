#!/bin/bash
# 拉取候选 skill 到临时目录，打印落地路径。
# 用法: fetch_skill.sh <github-url | raw-.md-url> [仓库内子路径]
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "用法: fetch_skill.sh <url> [subdir]" >&2
    exit 2
fi
src="$1"
sub="${2:-}"
dest="$(mktemp -d)/skill-src"

case "$src" in
    *.md)
        mkdir -p "$dest"
        curl -fsSL "$src" -o "$dest/SKILL.md"
        ;;
    *github.com*)
        git clone --depth 1 "$src" "$dest"
        ;;
    *)
        echo "不支持的来源: $src（仅支持 .md 直链或 github 仓库）" >&2
        exit 1
        ;;
esac

if [ -n "$sub" ]; then dest="$dest/$sub"; fi
[ -e "$dest" ] || { echo "子路径不存在: $sub" >&2; exit 1; }
echo "$dest"
