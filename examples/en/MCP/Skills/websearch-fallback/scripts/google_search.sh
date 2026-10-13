#!/bin/bash
# google_search.sh — fetch Google search-result HTML using a browser UA
# Usage: google_search.sh <keywords...>            (multiple words joined by spaces)
# Output: HTML to stdout (contains result blocks, parsed by parse_google.py)
#
# Key points:
#   - Must send a browser UA + Accept-Language, or Google may return a CAPTCHA
#   - Chinese keywords are URL-encoded by python3 (urllib.parse.quote)
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

if [ $# -eq 0 ]; then
  echo "Usage: google_search.sh <keywords...>" >&2
  exit 1
fi

query="$*"
encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$query")"

curl -s -L --max-time 20 \
  -A "$UA" \
  -H "Accept-Language: zh-CN,zh;q=0.9,en;q=0.8" \
  -H "Accept: text/html,application/xhtml+xml" \
  "https://www.google.com/search?q=${encoded}&hl=zh-CN&num=10"
