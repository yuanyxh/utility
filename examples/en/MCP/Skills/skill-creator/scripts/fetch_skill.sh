#!/bin/bash
# Fetch a candidate skill into a temp directory and print the landing path.
# Usage: fetch_skill.sh <github-url | raw-.md-url> [subpath-within-repo]
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: fetch_skill.sh <url> [subdir]" >&2
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
        echo "Unsupported source: $src (only direct .md links or github repos are supported)" >&2
        exit 1
        ;;
esac

if [ -n "$sub" ]; then dest="$dest/$sub"; fi
[ -e "$dest" ] || { echo "Subpath does not exist: $sub" >&2; exit 1; }
echo "$dest"
