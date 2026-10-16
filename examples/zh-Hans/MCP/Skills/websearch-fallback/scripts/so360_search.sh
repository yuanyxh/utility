#!/bin/bash
# so360_search.sh — 抓 360 搜索结果 HTML
# 用法: so360_search.sh <关键词...>              （多个词用空格拼接）
# 输出: HTML 到 stdout（含搜索结果块，供 parse_so360.py 解析）
#
# 关键点:
#   - 360 与搜狗一样对中文查询稳定，且结果集与 Bing/DDG/Brave 基本不重叠
#   - 中文关键词由 python3 做 URL 编码
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

if [ $# -eq 0 ]; then
  echo "用法: so360_search.sh <关键词...>" >&2
  exit 1
fi

query="$*"
encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$query")"

curl -s -L --max-time 20 \
  -A "$UA" \
  -H "Accept: text/html" \
  "https://www.so.com/s?q=${encoded}"
