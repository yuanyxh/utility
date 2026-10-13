#!/bin/bash
# duckduckgo_search.sh — fetch DuckDuckGo search-result HTML
# Usage: duckduckgo_search.sh <keywords...>            (multiple words joined by spaces)
# Output: HTML to stdout (contains result blocks, parsed by parse_duckduckgo.py)
#
# Key points:
#   - DuckDuckGo needs no special UA, but keep it for consistency
#   - Chinese keywords are URL-encoded by python3
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

if [ $# -eq 0 ]; then
  echo "Usage: duckduckgo_search.sh <keywords...>" >&2
  exit 1
fi

query="$*"
encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$query")"

curl -s -L --max-time 20 \
  -A "$UA" \
  -H "Accept-Language: zh-CN,zh;q=0.9" \
  -H "Accept: text/html" \
  "https://html.duckduckgo.com/html/?q=${encoded}"
