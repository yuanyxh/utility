#!/bin/bash
# so360_search.sh — fetch 360 search-result HTML
# Usage: so360_search.sh <keywords...>            (multiple words joined by spaces)
# Output: HTML to stdout (contains result blocks for parse_so360.py)
#
# Key points:
#   - Like Sogou, 360 is stable for Chinese queries, and its result set barely
#     overlaps with Bing / DDG / Brave
#   - Chinese keywords are URL-encoded by python3
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

if [ $# -eq 0 ]; then
  echo "Usage: so360_search.sh <keywords...>" >&2
  exit 1
fi

query="$*"
encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$query")"

curl -s -L --max-time 20 \
  -A "$UA" \
  -H "Accept: text/html" \
  "https://www.so.com/s?q=${encoded}"
