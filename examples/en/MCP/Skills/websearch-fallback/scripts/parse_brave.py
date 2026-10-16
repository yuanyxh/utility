#!/usr/bin/env python3
"""Extract structured results (title/URL/date/snippet) from Brave search-result HTML.

Usage:
    python3 parse_brave.py <html-file>     # parse a file
    cat <html> | python3 parse_brave.py -  # read from stdin
Output:
    [n] title
        URL: <real link>
        Date: <date or ->
        Snippet: <snippet>

Relies on Brave's standard result blocks; use together with brave_search.sh.
"""

import html as htmlmod
import re
import sys


def parse_brave_results(raw: str) -> list[dict]:
    """Parse Brave search results, returning a list of {title,url,date,snippet}."""
    results = []

    # Brave result block pattern
    for block in re.findall(r'<div class="snippet[^"]*".*?</div>\s*</div>', raw, re.S):
        # Extract link and title
        m = re.search(
            r'<a[^>]*class="result-header"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
            block,
            re.S,
        )
        if not m:
            m = re.search(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        if not m:
            continue

        url = m.group(1)
        title = htmlmod.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()

        # Extract snippet
        snippet = ""
        snippet_match = re.search(
            r'<p class="snippet-description[^"]*"[^>]*>(.*?)</p>', block, re.S
        )
        if snippet_match:
            snippet = htmlmod.unescape(
                re.sub(r"<[^>]+>", "", snippet_match.group(1))
            ).strip()

        # Extract date
        date = ""
        date_match = re.search(r'<time[^>]*datetime="([^"]*)"', block, re.S)
        if date_match:
            date = date_match.group(1)[:10]  # YYYY-MM-DD

        if url.startswith("http") and title:
            results.append(
                {
                    "title": title,
                    "url": url,
                    "date": date,
                    "snippet": snippet[:200] if snippet else "",
                }
            )

    return results[:15]


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] == "-":
        raw = sys.stdin.read()
    else:
        with open(sys.argv[1], encoding="utf-8", errors="ignore") as f:
            raw = f.read()

    results = parse_brave_results(raw)
    for i, r in enumerate(results, 1):
        print(f"[{i}] {r['title']}")
        print(f"    URL: {r['url']}")
        print(f"    Date: {r['date'] or '-'}")
        print(f"    Snippet: {r['snippet']}")


if __name__ == "__main__":
    main()
