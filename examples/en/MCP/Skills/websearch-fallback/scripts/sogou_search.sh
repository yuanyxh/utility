#!/bin/bash
# sogou_search.sh — fetch Sogou search-result HTML
# Usage: sogou_search.sh <keywords...>            (multiple words joined by spaces)
# Output: HTML to stdout (contains result blocks for parse_sogou.py)
#
# Key points:
#   - Sogou's relevance for Chinese long queries is clearly better than Bing's
#     (Bing degrades "端到端原则" into a dictionary page for the single character "端")
#   - Chinese keywords are URL-encoded by python3
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

if [ $# -eq 0 ]; then
  echo "Usage: sogou_search.sh <keywords...>" >&2
  exit 1
fi

query="$*"
encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$query")"

curl -s -L --max-time 20 \
  -A "$UA" \
  -H "Accept: text/html" \
  "https://www.sogou.com/web?query=${encoded}"
