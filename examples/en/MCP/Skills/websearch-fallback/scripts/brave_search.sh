#!/bin/bash
# brave_search.sh — fetch Brave search-result HTML
# Usage: brave_search.sh <keywords...>            (multiple words joined by spaces)
# Output: HTML to stdout (contains result blocks, parsed by parse_brave.py)
#
# Key points:
#   - Brave Search is privacy-focused and needs no special UA
#   - Chinese keywords are URL-encoded by python3
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

if [ $# -eq 0 ]; then
  echo "Usage: brave_search.sh <keywords...>" >&2
  exit 1
fi

query="$*"
encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$query")"

curl -s -L --max-time 20 \
  -A "$UA" \
  -H "Accept: text/html" \
  "https://search.brave.com/search?q=${encoded}"
