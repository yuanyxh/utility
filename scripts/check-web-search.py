#!/usr/bin/env python3
"""Checks for Sources/MCPScripts/web_search.py.

Default is offline: parser fixtures, Markdown conversion, truncation, relevance,
rate limiting, and the engine circuit breaker. `--live` additionally hits the real
engines and is intentionally slow (per-engine rate limits).
"""

from __future__ import annotations

import argparse
import os
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Sources", "MCPScripts"))

import web_search as w

FAILS: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ✓ {name}")
    else:
        FAILS.append(f"{name}: {detail}")
        print(f"  ✗ {name} {detail}")


def selftest() -> None:
    print("[web_search] offline checks")

    html = (
        "<html><head><title>Demo</title><style>.x{color:red}</style>"
        "<script>alert(1)</script></head><body><nav>skip me</nav>"
        "<article><h1>Hello</h1><p>World <a href='/x'>link</a></p>"
        "<ul><li>A</li><li>B</li></ul><pre><code>print(1)</code></pre>"
        "<table><tr><th>K</th><th>V</th></tr><tr><td>a</td><td>1</td></tr></table>"
        "</article><footer>foot</footer></body></html>"
    )
    md = w.html_to_markdown(html, base_url="https://example.com/base")
    check("markdown: heading", "# Hello" in md, md[:80])
    check("markdown: link resolved", "https://example.com/x" in md, md[:120])
    check("markdown: list", "- A" in md and "- B" in md)
    check("markdown: code fence", "```" in md and "print(1)" in md)
    check("markdown: table", "| K | V |" in md and "| --- | --- |" in md)
    check(
        "markdown: boilerplate removed",
        all(x not in md for x in ("alert", "color", "skip me", "foot")),
        md[:120],
    )

    long_md = w.html_to_markdown("<p>" + "x" * 3000 + "</p>", max_chars=200)
    check(
        "truncate: capped",
        len(long_md) <= 260 and "truncated" in long_md,
        f"len={len(long_md)}",
    )

    malformed = w.html_to_markdown("<p>unclosed<div><script>x")
    check("malformed: no exception", isinstance(malformed, str))

    check(
        "relevance: positive",
        w._matches({"title": "端到端原则", "snippet": "网络设计"}, "端到端原则"),
    )
    check(
        "relevance: negative",
        not w._matches({"title": "端", "snippet": "端字的解释"}, "端到端原则"),
    )
    check(
        "relevance: long gibberish",
        not w._matches(
            {"title": "SQL query tutorial", "snippet": "query"},
            "zzzz-no-such-query-12345",
        ),
    )
    check(
        "challenge: detector",
        w._looks_like_challenge("<title>Verify you are human</title>"),
    )
    check(
        "challenge: normal page",
        not w._looks_like_challenge("<title>Python asyncio</title><p>guide</p>"),
    )

    w.reset_engine_health()
    started = time.monotonic()
    w._respect_rate("selftest", 0.2)
    w._respect_rate("selftest", 0.2)
    waited = time.monotonic() - started
    check("rate: second call waits", waited >= 0.15, f"waited={waited:.2f}s")

    w.reset_engine_health()
    w._record_failure("fake")
    check("breaker: one failure still ok", w._engine_ok("fake"))
    w._record_failure("fake")
    check("breaker: two failures open", not w._engine_ok("fake"))
    w._record_success("fake")
    check("breaker: success closes", w._engine_ok("fake"))
    w.reset_engine_health()

    fixtures = {
        "bing": (
            '<li class="b_algo"><h2><a href="https://x.test/1">T1</a></h2>'
            "<p>S1</p></li>"
        ),
        "duckduckgo": (
            '<div class="result results_links">'
            '<a class="result__a" href="https://x.test/2">T2</a>'
            '<a class="result__snippet">S2</a></div></div>'
        ),
        "brave": (
            '<div class="snippet svelte">'
            '<a class="result-header" href="https://x.test/3">T3</a>'
            '<p class="snippet-description">S3</p></div></div>'
        ),
        "sogou": (
            '<div class="vrwrap"><h3 class="vr-title">'
            '<a href="https://x.test/4">T4</a></h3>'
            '<p class="space-txt">S4</p></div>'
        ),
        "so360": (
            '<li class="res-list"><h3 class="res-title">'
            '<a data-mdurl="https://x.test/5" href="/link">T5</a></h3>'
            '<span class="res-list-summary">S5</span></li></ol>'
        ),
        "baidu": (
            '<div class="result c-container"><h3>'
            '<a href="http://www.baidu.com/link?url=abc">T6</a></h3>'
            '<div class="c-abstract">S6</div></div></body>'
        ),
        "marginalia": (
            '<section class="card search-result"><h2>'
            '<a class="title" href="https://x.test/7">T7</a></h2>'
            '<p class="description">S7</p></section>'
        ),
    }
    for engine, raw in fixtures.items():
        parsed = w._PARSERS[engine](raw)
        check(
            f"parser: {engine}",
            len(parsed) == 1 and parsed[0]["title"].startswith("T"),
            str(parsed)[:120],
        )

    # System proxy (macOS _scproxy + env) must reach the urllib opener.
    old_proxy = os.environ.get("HTTPS_PROXY")
    try:
        os.environ["HTTPS_PROXY"] = "http://127.0.0.1:7897"
        w.reset_http_state()
        status = w.proxy_status()
        check(
            "proxy: system/env read",
            status.get("https") == "http://127.0.0.1:7897",
            str(status),
        )
        opener = w._opener("page")
        handlers = [
            h for h in opener.handlers if isinstance(h, urllib.request.ProxyHandler)
        ]
        check(
            "proxy: opener uses proxy",
            bool(handlers) and handlers[0].proxies.get("https") == "http://127.0.0.1:7897",
            str(handlers[0].proxies if handlers else None),
        )
        original_map = w._proxy_map
        w._proxy_map = lambda: {"https": "http://user:pass@127.0.0.1:7897"}
        check(
            "proxy: credentials masked",
            "user:pass" not in str(w.proxy_status()),
            str(w.proxy_status()),
        )
        w._proxy_map = original_map
    finally:
        if old_proxy is None:
            os.environ.pop("HTTPS_PROXY", None)
        else:
            os.environ["HTTPS_PROXY"] = old_proxy
        w.reset_http_state()

    # websearch() must degrade to diagnostics instead of raising when pages fail.
    original_report, original_fetch = w.search_report, w.fetch_markdown
    try:
        w.search_report = lambda *a, **k: (
            [
                {
                    "title": "T",
                    "url": "https://x.test/1",
                    "snippet": "S",
                    "engine": "fake",
                }
            ],
            {"engines": {"fake": {"status": "ok"}}},
        )
        w.fetch_markdown = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("403"))
        payload = w.websearch("q", limit=1, fetch_top=1)
        check(
            "fallback: page error reported",
            payload["pages"] == []
            and payload.get("page_errors", [{}])[0].get("error")
            and "all page fetches failed" in payload.get("page_error", ""),
            str(payload)[:160],
        )
    finally:
        w.search_report, w.fetch_markdown = original_report, original_fetch

    try:
        w.search_report = lambda *a, **k: (
            [],
            {
                "engines": {
                    "bing": {"status": "failed", "error": "TimeoutError: timed out"},
                    "sogou": {"status": "failed", "error": "Blocked: challenge page"},
                },
                "all_failed": True,
                "no_engines_available": False,
            },
        )
        payload = w.websearch("q", fetch_top=0)
        check(
            "failure: all engines message",
            "all search engines failed" in payload.get("error", "")
            and "bing" in payload.get("error", ""),
            str(payload)[:200],
        )
        check(
            "failure: engine report included",
            "bing" in payload.get("engine_report", {}),
            str(payload.get("engine_report")),
        )

        w.search_report = lambda *a, **k: (
            [],
            {"engines": {}, "all_failed": False, "no_engines_available": True},
        )
        payload = w.websearch("q", fetch_top=0)
        check(
            "failure: no engine available",
            "no search engine available" in payload.get("error", ""),
            str(payload)[:160],
        )
    finally:
        w.search_report = original_report


def live() -> None:
    print("\n[web_search] live checks")
    queries = ["Python asyncio", "端到端原则", "Rust ownership", "OpenAI"]
    for round_index in (1, 2):
        print(f" round {round_index}")
        for query in queries:
            started = time.monotonic()
            results = w.search(query, min_results=3)
            elapsed = time.monotonic() - started
            engines = sorted({r["engine"] for r in results})
            print(
                f"  {query!r}: {len(results)} results, {elapsed:.1f}s, "
                f"engines={engines}"
            )
            check(f"live: {query!r} has results", bool(results))
            time.sleep(1.0)

    try:
        page = w.fetch_markdown("https://httpbin.org/html", max_chars=2000)
        page_ok = "Moby-Dick" in page["markdown"] and "<html" not in page["markdown"]
        page_detail = page["markdown"][:120]
    except Exception as exc:
        page_ok = False
        page_detail = f"{type(exc).__name__}: {exc}"
    check("live: page markdown", page_ok, page_detail)

    payload = w.websearch("Python asyncio", limit=3, fetch_top=1, max_chars=1500)
    check("live: websearch results", bool(payload["results"]), str(payload)[:160])
    check(
        "live: websearch page or error",
        bool(payload["pages"]) or bool(payload.get("page_errors")),
        str(payload.get("page_errors", []))[:160],
    )

    junk = w.search("zzzz-no-such-query-12345", min_results=1)
    check("live: gibberish query filtered", junk == [], f"{len(junk)} results")

    print(f"  engine status: {w.engine_status()}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="also hit real engines")
    args = parser.parse_args()
    selftest()
    if args.live:
        live()
    print()
    if FAILS:
        print(f"[web_search] ✗ {len(FAILS)} failure(s)")
        for item in FAILS:
            print("  -", item)
        return 1
    print("[web_search] ✓ all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
