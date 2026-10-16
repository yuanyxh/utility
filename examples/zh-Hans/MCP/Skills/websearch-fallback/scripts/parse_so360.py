#!/usr/bin/env python3
"""从 360 搜索结果 HTML 提取结构化结果（标题/URL/日期/摘要）。

用法:
    python3 parse_so360.py <html文件>     # 解析文件
    cat <html> | python3 parse_so360.py - # 从 stdin 读取
输出:
    [n] 标题
        URL: <真实链接>
        日期: <YYYY年M月D日 或 ->
        摘要: <snippet>

依赖 360 标准结果块 <li class="res-list">，与 so360_search.sh 配合使用。

注意 URL 取值：a 标签的 href 是 360 的跳转链，站点真实地址在 **data-mdurl** 属性里，
直接取 href 会得到一串 so.com/link 的重定向地址。
"""

import html as htmlmod
import re
import sys


def _text(fragment: str) -> str:
    return htmlmod.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()


def parse_res_list(raw: str) -> list[dict]:
    """解析 <li class="res-list"> 结果块，返回 {title,url,date,snippet} 列表。"""
    results = []
    for block in re.findall(
        r'<li class="res-list[^"]*".*?(?=<li class="res-list|</ol>)', raw, re.S
    ):
        m = re.search(
            r'<h3[^>]*class="res-title[^"]*"[^>]*>\s*<a\s([^>]*)>(.*?)</a>', block, re.S
        )
        if not m:
            continue
        md = re.search(r'data-mdurl="([^"]+)"', m.group(1))
        href = re.search(r'href="([^"]+)"', m.group(1))
        url = htmlmod.unescape(md.group(1) if md else (href.group(1) if href else ""))
        if not url.startswith("http"):
            continue
        snippet = ""
        p = re.search(
            r'<span[^>]*class="res-list-summary"[^>]*>(.*?)</span>', block, re.S
        )
        if p:
            snippet = _text(p.group(1))
        d = re.search(r"\d{4}年\d{1,2}月\d{1,2}日", snippet)
        results.append(
            {
                "title": _text(m.group(2)),
                "url": url,
                "date": d.group(0) if d else "",
                "snippet": snippet,
            }
        )
    return results


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] == "-":
        raw = sys.stdin.read()
    else:
        with open(sys.argv[1], encoding="utf-8", errors="ignore") as f:
            raw = f.read()
    for i, r in enumerate(parse_res_list(raw), 1):
        print(f"[{i}] {r['title']}")
        print(f"    URL: {r['url']}")
        print(f"    日期: {r['date'] or '-'}")
        print(f"    摘要: {r['snippet']}")


if __name__ == "__main__":
    main()
