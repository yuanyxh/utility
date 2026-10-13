#!/usr/bin/env python3
"""Extract structured results (title/URL/date/snippet) from Google search-result HTML.

Usage:
    python3 parse_google.py <html-file>     # parse a file
    cat <html> | python3 parse_google.py -  # read from stdin
Output:
    [n] title
        URL: <real link>
        Date: <date or ->
        Snippet: <snippet>

Relies on Google's standard result blocks; use together with google_search.sh.
"""
import html as htmlmod
import re
import sys


def parse_google_results(raw: str) -> list[dict]:
    """Parse Google search results, returning a list of {title,url,date,snippet}."""
    results = []

    # Google result block patterns: div class="g" or similar structures
    # Try several patterns
    patterns = [
        r'<div class="g".*?</div>\s*</div>\s*</div>',  # standard result block
        r'<div data-hveid="[^"]*".*?</div>\s*</div>',  # alternate pattern
    ]

    blocks = []
    for pattern in patterns:
        blocks.extend(re.findall(pattern, raw, re.S))
        if blocks:
            break

    # If no standard block was found, try extracting all links
    if not blocks:
        # Extract all search-result links
        for m in re.finditer(r'<a[^>]*href="(/url\?q=[^"]+|https?://[^"]+)"[^>]*>(.*?)</a>', raw, re.S):
            url = m.group(1)
            title = htmlmod.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()

            # Clean the Google redirect URL
            if url.startswith("/url?q="):
                url = url[8:].split("&")[0]

            if url.startswith("http") and title and len(title) > 5:
                # Try to extract a snippet from nearby text
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

    # Deduplicate (by URL)
    seen = set()
    unique_results = []
    for r in results:
        if r["url"] not in seen:
            seen.add(r["url"])
            unique_results.append(r)

    return unique_results[:15]  # return at most 15


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
        print(f"    Date: {r['date'] or '-'}")
        print(f"    Snippet: {r['snippet']}")


if __name__ == "__main__":
    main()
