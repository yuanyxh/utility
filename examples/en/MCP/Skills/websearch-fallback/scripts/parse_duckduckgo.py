#!/usr/bin/env python3
"""Extract structured results (title/URL/date/snippet) from DuckDuckGo search-result HTML.

Usage:
    python3 parse_duckduckgo.py <html-file>     # parse a file
    cat <html> | python3 parse_duckduckgo.py -  # read from stdin
Output:
    [n] title
        URL: <real link>
        Date: <date or ->
        Snippet: <snippet>

Relies on DuckDuckGo's standard result blocks; use together with duckduckgo_search.sh.
"""
import html as htmlmod
import re
import sys


def parse_duckduckgo_results(raw: str) -> list[dict]:
    """Parse DuckDuckGo search results, returning a list of {title,url,date,snippet}."""
    results = []

    # Result blocks of the DuckDuckGo HTML version
    for block in re.findall(r'<div class="result[^"]*".*?</div>\s*</div>', raw, re.S):
        # Extract link and title
        m = re.search(r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        if not m:
            continue

        url = m.group(1)
        title = htmlmod.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()

        # DuckDuckGo's URL may be a redirect; extract the real URL
        if "uddg=" in url:
            import urllib.parse
            parsed = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            url = parsed.get("uddg", [url])[0]

        # Extract snippet
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
        print(f"    Date: {r['date'] or '-'}")
        print(f"    Snippet: {r['snippet']}")


if __name__ == "__main__":
    main()
