#!/usr/bin/env python3
"""Extract structured results (title/URL/date/snippet) from 360 search-result HTML.

Usage:
    python3 parse_so360.py <html-file>     # parse a file
    cat <html> | python3 parse_so360.py -  # read from stdin
Output:
    [n] title
        URL: <real link>
        Date: <YYYY年M月D日 or ->
        Snippet: <snippet>

Relies on 360's standard result block <li class="res-list">; use together with so360_search.sh.

About the URL: the anchor's href is 360's own jump link; the real site address lives in
the **data-mdurl** attribute. Reading href directly yields a so.com/link redirect URL.
"""

import html as htmlmod
import re
import sys


def _text(fragment: str) -> str:
    return htmlmod.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()


def parse_res_list(raw: str) -> list[dict]:
    """Parse <li class="res-list"> result blocks, returning a list of {title,url,date,snippet}."""
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
        print(f"    Date: {r['date'] or '-'}")
        print(f"    Snippet: {r['snippet']}")


if __name__ == "__main__":
    main()
