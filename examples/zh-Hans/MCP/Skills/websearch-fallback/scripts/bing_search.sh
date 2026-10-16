#!/bin/bash
# bing_search.sh — 用浏览器 UA 抓 Bing 中文搜索结果 HTML
# 用法: bing_search.sh <关键词...>            （多个词用空格拼接）
# 输出: HTML 到 stdout（含 <li class="b_algo"> 结果块，供 parse_bing.py 解析）
#
# 关键点（2026-09 实测）:
#   - 必须带浏览器 UA + Accept，否则 Bing 把请求降级成泛化导航页
#   - www.bing.com 会 302 到 cn.bing.com，-L 跟随
#   - 中文关键词由 python3 做 URL 编码（urllib.parse.quote）
set -euo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

if [ $# -eq 0 ]; then
  echo "用法: bing_search.sh <关键词...>" >&2
  exit 1
fi

query="$*"
encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$query")"

curl -s -L --max-time 20 \
  -A "$UA" \
  -H "Accept: text/html" \
  "https://www.bing.com/search?q=${encoded}&count=10"
