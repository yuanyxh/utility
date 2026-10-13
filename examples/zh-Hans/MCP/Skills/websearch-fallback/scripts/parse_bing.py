#!/usr/bin/env python3
"""从 Bing 搜索结果 HTML 提取结构化结果（标题/URL/日期/摘要）。

用法:
    python3 parse_bing.py <html文件>     # 解析文件
    cat <html> | python3 parse_bing.py - # 从 stdin 读取
输出:
    [n] 标题
        URL: <真实链接>
        日期: <YYYY年M月D日 或 ->
        摘要: <snippet>

依赖 Bing 标准结果块 <li class="b_algo">，与 bing_search.sh 配合使用。
"""
import html as htmlmod
import re
import sys


def parse_b_algo(raw: str) -> list[dict]:
    """解析 <li class="b_algo"> 结果块，返回 {title,url,date,snippet} 列表。"""
    results = []
    for block in re.findall(r'<li class="b_algo".*?</li>', raw, re.S):
        m = re.search(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        if not m:
            continue
        url = m.group(1)
        title = htmlmod.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()
        p = re.search(r"<p[^>]*>(.*?)</p>", block, re.S)
        snippet = ""
        if p:
            snippet = htmlmod.unescape(re.sub(r"<[^>]+>", "", p.group(1))).strip()
        md = re.search(r"\d{4}年\d{1,2}月\d{1,2}日", snippet)
        date = md.group(0) if md else ""
        if url.startswith("http"):
            results.append(
                {"title": title, "url": url, "date": date, "snippet": snippet}
            )
    return results


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] == "-":
        raw = sys.stdin.read()
    else:
        with open(sys.argv[1], encoding="utf-8", errors="ignore") as f:
            raw = f.read()
    for i, r in enumerate(parse_b_algo(raw), 1):
        print(f"[{i}] {r['title']}")
        print(f"    URL: {r['url']}")
        print(f"    日期: {r['date'] or '-'}")
        print(f"    摘要: {r['snippet']}")


if __name__ == "__main__":
    main()
