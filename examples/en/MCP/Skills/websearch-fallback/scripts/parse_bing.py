#!/usr/bin/env python3
"""Extract structured results (title/URL/date/snippet) from Bing search-result HTML.

Usage:
    python3 parse_bing.py <html-file>     # parse a file
    cat <html> | python3 parse_bing.py -  # read from stdin
Output:
    [n] title
        URL: <real link>
        Date: <YYYY年M月D日 or ->
        Snippet: <snippet>

Relies on Bing's standard result block <li class="b_algo">; use together with bing_search.sh.
"""
import html as htmlmod
import re
import sys


def parse_b_algo(raw: str) -> list[dict]:
    """Parse <li class="b_algo"> result blocks, returning a list of {title,url,date,snippet}."""
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
        print(f"    Date: {r['date'] or '-'}")
        print(f"    Snippet: {r['snippet']}")


if __name__ == "__main__":
    main()
