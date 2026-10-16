#!/usr/bin/env python3
"""Extract structured results (title/URL/date/snippet) from Sogou search-result HTML.

Usage:
    python3 parse_sogou.py <html-file>              # parse a file
    python3 parse_sogou.py --resolve <html-file>    # also rewrite /link?url= to the real site URL
    cat <html> | python3 parse_sogou.py -           # read from stdin
Output:
    [n] title
        URL: <real link>
        Date: <YYYY年M月D日 or ->
        Snippet: <snippet>

Relies on Sogou's standard result block <div class="vrwrap">; use together with sogou_search.sh.

About the jump links: a Sogou result's href is often /link?url=..., which does **not**
issue an HTTP redirect. It returns a 296-byte page that runs
window.location.replace("real-url") — following redirects just stays put. The page must
be fetched once more and that JS line read out, which is what --resolve does.
"""

import html as htmlmod
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"
)


def _text(fragment: str) -> str:
    return htmlmod.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()


def resolve_jump(url: str) -> str:
    """Rewrite a Sogou jump link to the real site URL; return it unchanged on failure."""
    if "/link?url=" not in url:
        return url
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=8) as resp:
            body = resp.read().decode("utf-8", "ignore")
    except Exception:
        return url
    m = re.search(r"location\.replace\(\s*[\"']([^\"']+)[\"']", body)
    return htmlmod.unescape(m.group(1)) if m else url


def parse_vrwrap(raw: str) -> list[dict]:
    """Parse <div class="vrwrap"> result blocks, returning a list of {title,url,date,snippet}."""
    results = []
    for block in re.findall(
        r'<div class="vrwrap".*?(?=<div class="vrwrap"|</body>)', raw, re.S
    ):
        m = re.search(
            r'<h3[^>]*class="vr-title[^"]*"[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
            block,
            re.S,
        )
        if not m:
            continue
        url = htmlmod.unescape(m.group(1))
        if url.startswith("/link"):
            url = "https://www.sogou.com" + url
        if not url.startswith("http"):
            continue
        snippet = ""
        p = re.search(r'<p[^>]*class="[^"]*space-txt[^"]*"[^>]*>(.*?)</p>', block, re.S)
        if p:
            snippet = _text(p.group(1))
        md = re.search(r"\d{4}年\d{1,2}月\d{1,2}日", snippet)
        results.append(
            {
                "title": _text(m.group(2)),
                "url": url,
                "date": md.group(0) if md else "",
                "snippet": snippet,
            }
        )
    return results


def main() -> None:
    do_resolve = "--resolve" in sys.argv[1:]
    args = [a for a in sys.argv[1:] if a != "--resolve"]
    if not args or args[0] == "-":
        raw = sys.stdin.read()
    else:
        with open(args[0], encoding="utf-8", errors="ignore") as f:
            raw = f.read()

    results = parse_vrwrap(raw)
    if do_resolve:
        with ThreadPoolExecutor(max_workers=5) as pool:
            for r, real in zip(
                results, pool.map(resolve_jump, [x["url"] for x in results])
            ):
                r["url"] = real

    for i, r in enumerate(results, 1):
        print(f"[{i}] {r['title']}")
        print(f"    URL: {r['url']}")
        print(f"    Date: {r['date'] or '-'}")
        print(f"    Snippet: {r['snippet']}")


if __name__ == "__main__":
    main()
