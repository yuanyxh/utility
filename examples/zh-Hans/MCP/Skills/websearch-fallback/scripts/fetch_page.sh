#!/bin/bash
# fetch_page.sh — 用浏览器 UA 抓任意 URL 的页面 HTML（正文深挖兜底）
# 用法: fetch_page.sh <URL>         输出: HTML 到 stdout
#
# 用途：WebFetch 抓正文失败（目标站 403/CAPTCHA/需登录/重定向/超时）时，
#       用它替代。同款浏览器 UA（与 bing_search.sh 一致），-L 跟随重定向。
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

if [ $# -ne 1 ]; then
  echo "用法: fetch_page.sh <URL>" >&2
  exit 1
fi

curl -s -L --max-time 25 -A "$UA" "$1"
