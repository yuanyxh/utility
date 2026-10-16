#!/bin/bash
# bing_search.sh — fetch Bing Chinese search-result HTML using a browser UA
# Usage: bing_search.sh <keywords...>            (multiple words joined by spaces)
# Output: HTML to stdout (contains <li class="b_algo"> result blocks, parsed by parse_bing.py)
#
# Key points (measured 2026-09):
#   - Must send a browser UA + Accept, or Bing downgrades the request to a generic navigation page
#   - www.bing.com 302-redirects to cn.bing.com; -L follows
#   - Chinese keywords are URL-encoded by python3 (urllib.parse.quote)
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

if [ $# -eq 0 ]; then
  echo "Usage: bing_search.sh <keywords...>" >&2
  exit 1
fi

query="$*"
encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$query")"

curl -s -L --max-time 20 \
  -A "$UA" \
  -H "Accept: text/html" \
  "https://www.bing.com/search?q=${encoded}&count=10"
