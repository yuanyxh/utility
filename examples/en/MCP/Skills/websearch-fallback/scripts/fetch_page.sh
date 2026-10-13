#!/bin/bash
# fetch_page.sh — fetch the page HTML of any URL using a browser UA (fallback for digging into the full text)
# Usage: fetch_page.sh <URL>         Output: HTML to stdout
#
# Purpose: use this when WebFetch fails to fetch the full text
#          (target site 403/CAPTCHA/login required/redirect/timeout).
#          Same browser UA (identical to bing_search.sh); -L follows redirects.
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

if [ $# -ne 1 ]; then
  echo "Usage: fetch_page.sh <URL>" >&2
  exit 1
fi

curl -s -L --max-time 25 -A "$UA" -H "Accept-Language: zh-CN,zh;q=0.9" "$1"
