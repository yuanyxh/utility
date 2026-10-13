#!/usr/bin/env python3
"""从 DuckDuckGo 搜索结果 HTML 提取结构化结果（标题/URL/日期/摘要）。

用法:
    python3 parse_duckduckgo.py <html文件>     # 解析文件
    cat <html> | python3 parse_duckduckgo.py - # 从 stdin 读取
输出:
    [n] 标题
        URL: <真实链接>
        日期: <日期或->
        摗要: <snippet>

依赖 DuckDuckGo 标准结果块，与 duckduckgo_search.sh 配合使用。
"""
import html as htmlmod
import re
import sys


def parse_duckduckgo_results(raw: str) -> list[dict]:
    """解析 DuckDuckGo 搜索结果，返回 {title,url,date,snippet} 列表。"""
    results = []

    # DuckDuckGo HTML 版本的结果块
    for block in re.findall(r'<div class="result[^"]*".*?</div>\s*</div>', raw, re.S):
        # 提取链接和标题
        m = re.search(r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        if not m:
            continue

        url = m.group(1)
        title = htmlmod.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()

        # DuckDuckGo 的 URL 可能是重定向，提取真实 URL
        if "uddg=" in url:
            import urllib.parse
            parsed = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            url = parsed.get("uddg", [url])[0]

        # 提取摘要
        snippet = ""
        snippet_match = re.search(r'<a class="result__snippet"[^>]*>(.*?)</a>', block, re.S)
        if snippet_match:
            snippet = htmlmod.unescape(re.sub(r"<[^>]+>", "", snippet_match.group(1))).strip()

        if url.startswith("http") and title:
            results.append({
                "title": title,
                "url": url,
                "date": "",
                "snippet": snippet[:200] if snippet else ""
            })

    return results[:15]


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] == "-":
        raw = sys.stdin.read()
    else:
        with open(sys.argv[1], encoding="utf-8", errors="ignore") as f:
            raw = f.read()

    results = parse_duckduckgo_results(raw)
    for i, r in enumerate(results, 1):
        print(f"[{i}] {r['title']}")
        print(f"    URL: {r['url']}")
        print(f"    日期: {r['date'] or '-'}")
        print(f"    摘要: {r['snippet']}")


if __name__ == "__main__":
    main()
