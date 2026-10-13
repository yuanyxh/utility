#!/usr/bin/env python3
"""从 Google 搜索结果 HTML 提取结构化结果（标题/URL/日期/摘要）。

用法:
    python3 parse_google.py <html文件>     # 解析文件
    cat <html> | python3 parse_google.py - # 从 stdin 读取
输出:
    [n] 标题
        URL: <真实链接>
        日期: <日期或->
        摗要: <snippet>

依赖 Google 标准结果块，与 google_search.sh 配合使用。
"""
import html as htmlmod
import re
import sys


def parse_google_results(raw: str) -> list[dict]:
    """解析 Google 搜索结果，返回 {title,url,date,snippet} 列表。"""
    results = []

    # Google 结果块模式：div class="g" 或类似结构
    # 尝试多种模式匹配
    patterns = [
        r'<div class="g".*?</div>\s*</div>\s*</div>',  # 标准结果块
        r'<div data-hveid="[^"]*".*?</div>\s*</div>',  # 备用模式
    ]

    blocks = []
    for pattern in patterns:
        blocks.extend(re.findall(pattern, raw, re.S))
        if blocks:
            break

    # 如果没有找到标准块，尝试提取所有链接
    if not blocks:
        # 提取所有搜索结果链接
        for m in re.finditer(r'<a[^>]*href="(/url\?q=[^"]+|https?://[^"]+)"[^>]*>(.*?)</a>', raw, re.S):
            url = m.group(1)
            title = htmlmod.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()

            # 清理 Google 重定向 URL
            if url.startswith("/url?q="):
                url = url[8:].split("&")[0]

            if url.startswith("http") and title and len(title) > 5:
                # 尝试从附近文本提取摘要
                snippet = ""
                pos = m.end()
                snippet_match = re.search(r'<span[^>]*>(.*?)</span>', raw[pos:pos+500], re.S)
                if snippet_match:
                    snippet = htmlmod.unescape(re.sub(r"<[^>]+>", "", snippet_match.group(1))).strip()

                results.append({
                    "title": title,
                    "url": url,
                    "date": "",
                    "snippet": snippet[:200] if snippet else ""
                })
    else:
        for block in blocks[:10]:
            m = re.search(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
            if not m:
                continue
            url = m.group(1)
            title = htmlmod.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()

            if url.startswith("/url?q="):
                url = url[8:].split("&")[0]

            snippet = ""
            p = re.search(r'<span[^>]*class="[^"]*"[^>]*>(.*?)</span>', block, re.S)
            if p:
                snippet = htmlmod.unescape(re.sub(r"<[^>]+>", "", p.group(1))).strip()

            if url.startswith("http") and title:
                results.append({
                    "title": title,
                    "url": url,
                    "date": "",
                    "snippet": snippet[:200] if snippet else ""
                })

    # 去重（按 URL）
    seen = set()
    unique_results = []
    for r in results:
        if r["url"] not in seen:
            seen.add(r["url"])
            unique_results.append(r)

    return unique_results[:15]  # 最多返回 15 条


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] == "-":
        raw = sys.stdin.read()
    else:
        with open(sys.argv[1], encoding="utf-8", errors="ignore") as f:
            raw = f.read()

    results = parse_google_results(raw)
    for i, r in enumerate(results, 1):
        print(f"[{i}] {r['title']}")
        print(f"    URL: {r['url']}")
        print(f"    日期: {r['date'] or '-'}")
        print(f"    摘要: {r['snippet']}")


if __name__ == "__main__":
    main()
