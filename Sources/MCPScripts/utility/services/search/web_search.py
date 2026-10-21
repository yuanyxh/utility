"""Multi-engine web search, page fetching, and HTML-to-Markdown conversion.

Three callers share this module: the knowledge pipeline (`search` / `wiki` / `fetch`),
the MCP `websearch` tool (`websearch` / `fetch_markdown`), and the check script.
Requests are rate-limited per engine; repeated failures put an engine into a cooldown.
"""

from __future__ import annotations

import gzip
import html as htmlmod
import http.cookiejar
import json
import math
import random
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser

UA_POOL = (
    (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    ),
    (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        "(KHTML, like Gecko) Version/18.1 Safari/605.1.15"
    ),
    (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    ),
)
#: Wikipedia asks for an identifiable client; a browser UA gets anonymous limits.
WIKI_UA = "utility-knowledge-panel/1.0 (personal use)"
TIMEOUT = 20

WIKI_LANGS = ("zh", "en")
WIKI_MIN_CHARS = 600

_ENDPOINTS = {
    "bing": "https://www.bing.com/search?q={q}&count=10",
    "duckduckgo": "https://html.duckduckgo.com/html/?q={q}",
    "brave": "https://search.brave.com/search?q={q}",
    "sogou": "https://www.sogou.com/web?query={q}",
    "so360": "https://www.so.com/s?q={q}",
    "baidu": "https://www.baidu.com/s?wd={q}&rn=10",
    "marginalia": "https://old-search.marginalia.nu/search?query={q}",
}
_HOME = {
    "bing": "https://www.bing.com/",
    "duckduckgo": "https://html.duckduckgo.com/html/",
    "brave": "https://search.brave.com/",
    "sogou": "https://www.sogou.com/",
    "so360": "https://www.so.com/",
    "baidu": "https://www.baidu.com/",
    "marginalia": "https://old-search.marginalia.nu/",
}
#: Only Baidu needs a homepage visit to receive the cookies that keep results stable.
_WARMUP = ("baidu",)
#: Seconds between two requests to the same engine. Longer for engines that ban quickly.
_MIN_INTERVAL = {
    "bing": 1.2,
    "sogou": 2.0,
    "so360": 1.5,
    "baidu": 2.0,
    "marginalia": 1.5,
    "brave": 2.5,
    "duckduckgo": 2.5,
    "page": 0.0,
}
#: Chinese queries hit the CN engines first; English queries avoid their noise.
CJK_ORDER = ("sogou", "so360", "baidu", "bing", "marginalia", "brave", "duckduckgo")
LATIN_ORDER = ("bing", "marginalia", "brave", "duckduckgo", "sogou", "so360", "baidu")
DEFAULT_ENGINES = (
    "bing",
    "sogou",
    "so360",
    "baidu",
    "marginalia",
    "brave",
    "duckduckgo",
)
#: Stop cascading once this many candidates exist; IDF ranking needs a corpus.
_CANDIDATE_TARGET = 15
#: Drop candidates whose weighted token coverage is below this floor.
_MIN_SCORE = 0.25
ENGINE_COOLDOWN = 600.0
MAX_TOTAL_CHARS = 16000
SEARCH_BUDGET = 25.0
PAGE_BUDGET = 25.0
SEARCH_TIMEOUT = 12
PAGE_TIMEOUT = 15

_CJK_RE = re.compile(r"[\u3400-\u9fff]")
_CHALLENGE_MARKERS = (
    "verify you are human",
    "unusual traffic",
    "are you a robot",
    "enable javascript",
    "security check",
    "captcha",
    "访问验证",
    "请输入验证码",
    "滑动验证",
)


class Blocked(Exception):
    """The engine answered with a challenge page instead of results."""


# ── shared state ────────────────────────────────────────────────────────────

_meta_lock = threading.Lock()
_openers: dict[str, urllib.request.OpenerDirector] = {}
_uas: dict[str, str] = {}
_warmed: set[str] = set()


def _session_key(engine: str) -> str:
    return engine if engine in _ENDPOINTS else "page"


def _proxy_map() -> dict:
    """System proxy settings (macOS `_scproxy` + env), re-read when an opener is built."""
    try:
        return {k: v for k, v in urllib.request.getproxies().items() if v}
    except Exception:
        return {}


def proxy_status() -> dict:
    """Proxy map with credentials stripped, for diagnostics."""
    out = {}
    for key, value in _proxy_map().items():
        try:
            parsed = urllib.parse.urlsplit(
                value if "://" in value else "http://" + value
            )
            host = parsed.hostname or ""
            out[key] = f"{parsed.scheme}://{host}" + (
                f":{parsed.port}" if parsed.port else ""
            )
        except Exception:
            out[key] = "configured"
    return out


def _build_opener() -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(
        urllib.request.ProxyHandler(_proxy_map()),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    )


def reset_http_state() -> None:
    """Clear cached openers/UAs/warm-up flags (tests and proxy changes)."""
    with _meta_lock:
        _openers.clear()
        _uas.clear()
        _warmed.clear()


def _opener(engine: str) -> urllib.request.OpenerDirector:
    key = _session_key(engine)
    with _meta_lock:
        opener = _openers.get(key)
        if opener is None:
            opener = _build_opener()
            _openers[key] = opener
        return opener


def _ua(engine: str) -> str:
    key = _session_key(engine)
    with _meta_lock:
        ua = _uas.get(key)
        if ua is None:
            ua = random.choice(UA_POOL)
            _uas[key] = ua
        return ua


def _headers(engine: str) -> dict:
    home = _HOME.get(engine, "")
    headers = {
        "User-Agent": _ua(engine),
        "Accept": (
            "text/html,application/xhtml+xml,application/xml;q=0.9,"
            "image/avif,image/webp,*/*;q=0.8"
        ),
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Accept-Encoding": "gzip, deflate",
        "Connection": "keep-alive",
        "Upgrade-Insecure-Requests": "1",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "same-origin" if home else "none",
        "Sec-Fetch-User": "?1",
        "DNT": "1",
    }
    if home:
        headers["Referer"] = home
    return headers


_rate_lock = threading.Lock()
_rate_next: dict[str, float] = {}


def _respect_rate(key: str, interval: float) -> None:
    """Reserve a request slot for `key`; concurrent callers queue without holding the lock."""
    if interval <= 0:
        return
    with _rate_lock:
        now = time.monotonic()
        wait = max(0.0, _rate_next.get(key, 0.0) - now)
        _rate_next[key] = now + wait + interval + random.uniform(0, 0.25)
    if wait > 0:
        time.sleep(wait)


_health_lock = threading.Lock()
_health: dict[str, dict] = {}


def _engine_ok(engine: str) -> bool:
    with _health_lock:
        return time.monotonic() >= _health.get(engine, {}).get("until", 0.0)


def _record_failure(engine: str) -> None:
    with _health_lock:
        state = _health.setdefault(engine, {"failures": 0, "until": 0.0})
        state["failures"] += 1
        if state["failures"] >= 2:
            state["until"] = time.monotonic() + ENGINE_COOLDOWN
            state["failures"] = 0


def _record_success(engine: str) -> None:
    with _health_lock:
        _health[engine] = {"failures": 0, "until": 0.0}


def reset_engine_health() -> None:
    """Clear cooldowns (tests and manual recovery)."""
    with _health_lock:
        _health.clear()


def engine_status() -> dict:
    now = time.monotonic()
    with _health_lock:
        return {
            name: {
                "failures": state["failures"],
                "cooldown_s": max(0, int(state["until"] - now)),
            }
            for name, state in sorted(_health.items())
        }


# ── HTTP ────────────────────────────────────────────────────────────────────


def _looks_like_challenge(raw: str) -> bool:
    head = (raw or "")[:8000].lower()
    return any(marker in head for marker in _CHALLENGE_MARKERS)


def _request(url: str, engine: str, timeout: int = TIMEOUT):
    req = urllib.request.Request(url, headers=_headers(engine))
    with _opener(engine).open(req, timeout=timeout) as resp:
        raw = resp.read()
        encoding = (resp.headers.get("Content-Encoding") or "").lower()
        if "gzip" in encoding:
            try:
                raw = gzip.decompress(raw)
            except OSError:
                pass
        elif "deflate" in encoding:
            try:
                raw = zlib.decompress(raw)
            except zlib.error:
                pass
        charset = resp.headers.get_content_charset() or "utf-8"
        text = raw.decode(charset, errors="ignore")
        status = getattr(resp, "status", 200)
        if status == 202 or _looks_like_challenge(text):
            raise Blocked(f"challenge page (status {status})")
        return resp.geturl(), text, status


def _retry_delay(exc: urllib.error.HTTPError, attempt: int) -> float:
    header = exc.headers.get("Retry-After") if exc.headers else None
    if header:
        try:
            return min(float(header), 10.0)
        except ValueError:
            pass
    return 2.0 * (attempt + 1)


def _get(url: str, engine: str, timeout: int = TIMEOUT, retries: int = 2):
    last: Exception | None = None
    for attempt in range(retries + 1):
        _respect_rate(engine, _MIN_INTERVAL.get(engine, 1.5))
        try:
            return _request(url, engine, timeout=timeout)
        except Blocked as exc:
            last = exc
            if attempt < retries:
                time.sleep(2.0 * (attempt + 1))
                continue
            raise
        except urllib.error.HTTPError as exc:
            last = exc
            if (
                exc.code in (403, 408, 425, 429, 500, 502, 503, 504)
                and attempt < retries
            ):
                time.sleep(_retry_delay(exc, attempt))
                continue
            raise
        except Exception as exc:
            last = exc
            if attempt < retries:
                time.sleep(1.0 * (attempt + 1))
                continue
            raise
    raise last or RuntimeError("request failed")


def _warm(engine: str) -> None:
    if engine not in _WARMUP:
        return
    with _meta_lock:
        if engine in _warmed:
            return
    try:
        _respect_rate(engine, _MIN_INTERVAL.get(engine, 1.5))
        _request(_HOME[engine], engine, timeout=10)
        time.sleep(0.4)
        with _meta_lock:
            _warmed.add(engine)
    except Exception:
        pass


def fetch(url: str, engine: str = "bing", timeout: int = TIMEOUT) -> str:
    """Fetch raw HTML with a browser-like request (kept for the knowledge pipeline)."""
    host = urllib.parse.urlparse(url).netloc.lower()
    _respect_rate("host:" + host, 0.6)
    _, text, _ = _request(url, engine, timeout=timeout)
    return text


# ── result parsers ──────────────────────────────────────────────────────────


def _text(fragment: str) -> str:
    # Comments carry structured payloads; script/style bodies are not page text.
    fragment = re.sub(r"<!--.*?-->", "", fragment, flags=re.DOTALL)
    fragment = re.sub(
        r"<(script|style)\b.*?</\1>", "", fragment, flags=re.DOTALL | re.I
    )
    return htmlmod.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()


def _unredirect(url: str) -> str:
    if url.startswith("/url?q="):
        return url[8:].split("&")[0]
    if "uddg=" in url:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        return q.get("uddg", [url])[0]
    return url


#: Baidu ad slots link through baidu.php / e.baidu.com; `mu` then points at an
#: internal placeholder host instead of the advertiser's real page.
_AD_URL_MARKERS = (
    "baidu.php",
    "e.baidu.com",
    "nourl.ubs.baidu.com",
    "recommend_list.baidu.com",
)


def _is_ad_url(url: str) -> bool:
    if not url:
        return True
    low = url.lower()
    return any(marker in low for marker in _AD_URL_MARKERS)


#: A search engine's own result/aggregation page carries no page content.
_ENGINE_PAGES = (
    ("www.sogou.com", "/sogou"),
    ("www.sogou.com", "/web"),
    ("www.baidu.com", "/s"),
    ("www.so.com", "/s"),
    ("www.bing.com", "/search"),
    ("cn.bing.com", "/search"),
    ("html.duckduckgo.com", "/html/"),
    ("search.brave.com", "/search"),
    ("old-search.marginalia.nu", "/search"),
)


def _is_engine_page(url: str) -> bool:
    parts = urllib.parse.urlparse(url.lower())
    return any(
        parts.netloc == host and parts.path.startswith(path)
        for host, path in _ENGINE_PAGES
    )


def _dedup(results: list, limit: int | None = None) -> list:
    seen, out = set(), []
    for r in results:
        if r["url"] not in seen and r["title"]:
            seen.add(r["url"])
            out.append(r)
    return out if limit is None else out[:limit]


def _parse_bing(raw: str) -> list:
    out = []
    for block in re.findall(r'<li class="b_algo".*?</li>', raw, re.DOTALL):
        m = re.search(
            r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.DOTALL
        )
        if not m or not m.group(1).startswith("http"):
            continue
        snippet = ""
        p = re.search(r"<p[^>]*>(.*?)</p>", block, re.DOTALL)
        if p:
            snippet = _text(p.group(1))
        md = re.search(r"\d{4}年\d{1,2}月\d{1,2}日", snippet)
        out.append(
            {
                "title": _text(m.group(2)),
                "url": m.group(1),
                "date": md.group(0) if md else "",
                "snippet": snippet[:200],
            }
        )
    return out


def _parse_duckduckgo(raw: str) -> list:
    out = []
    for block in re.findall(
        r'<div class="result[^"]*".*?</div>\s*</div>', raw, re.DOTALL
    ):
        m = re.search(
            r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
            block,
            re.DOTALL,
        )
        if not m:
            continue
        url = _unredirect(m.group(1))
        if not url.startswith("http"):
            continue
        snippet = ""
        hit = re.search(r'<a class="result__snippet"[^>]*>(.*?)</a>', block, re.DOTALL)
        if hit:
            snippet = _text(hit.group(1))
        out.append(
            {
                "title": _text(m.group(2)),
                "url": url,
                "date": "",
                "snippet": snippet[:200],
            }
        )
    return out


def _parse_brave(raw: str) -> list:
    out = []
    for block in re.findall(
        r'<div class="snippet[^"]*".*?</div>\s*</div>', raw, re.DOTALL
    ):
        m = re.search(
            r'<a[^>]*class="result-header"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
            block,
            re.DOTALL,
        ) or re.search(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.DOTALL)
        if not m or not m.group(1).startswith("http"):
            continue
        snippet = ""
        hit = re.search(
            r'<p class="snippet-description[^"]*"[^>]*>(.*?)</p>', block, re.DOTALL
        )
        if hit:
            snippet = _text(hit.group(1))
        date = ""
        dm = re.search(r'<time[^>]*datetime="([^"]*)"', block, re.DOTALL)
        if dm:
            date = dm.group(1)[:10]
        out.append(
            {
                "title": _text(m.group(2)),
                "url": m.group(1),
                "date": date,
                "snippet": snippet[:200],
            }
        )
    return out


def _parse_sogou(raw: str) -> list:
    out = []
    for block in re.findall(
        r'<div class="vrwrap".*?(?=<div class="vrwrap"|</body>|\Z)', raw, re.DOTALL
    ):
        m = re.search(
            r'<h3[^>]*class="vr-title[^"]*"[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
            block,
            re.DOTALL,
        )
        if not m:
            continue
        url = htmlmod.unescape(m.group(1))
        if url.startswith("/link"):
            url = "https://www.sogou.com" + url
        if not url.startswith("http"):
            continue
        snippet = ""
        p = re.search(
            r'<(?:p|div)[^>]*class="[^"]*space-txt[^"]*"[^>]*>(.*?)</(?:p|div)>',
            block,
            re.DOTALL,
        )
        if p:
            snippet = _text(p.group(1))
        out.append(
            {
                "title": _text(m.group(2)),
                "url": url,
                "date": "",
                "snippet": snippet[:200],
            }
        )
    return out


def _parse_so360(raw: str) -> list:
    out = []
    for block in re.findall(
        r'<li class="res-list[^"]*".*?(?=<li class="res-list|</ol>)', raw, re.DOTALL
    ):
        m = re.search(
            r'<h3[^>]*class="res-title[^"]*"[^>]*>\s*<a\s([^>]*)>(.*?)</a>',
            block,
            re.DOTALL,
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
            r'<span[^>]*class="res-list-summary"[^>]*>(.*?)</span>', block, re.DOTALL
        )
        if p:
            snippet = _text(p.group(1))
        d = re.search(r"\d{4}年\d{1,2}月\d{1,2}日", snippet)
        out.append(
            {
                "title": _text(m.group(2)),
                "url": url,
                "date": d.group(0) if d else "",
                "snippet": snippet[:200],
            }
        )
    return out


_BAIDU_SDATA_RE = re.compile(r"<!--s-data:(.*?)-->", re.DOTALL)


def _baidu_summary(block: str) -> str:
    """New Baidu cards keep the snippet in an s-data comment, not c-abstract."""
    raw = _BAIDU_SDATA_RE.search(block)
    if raw:
        try:
            payload = json.loads(htmlmod.unescape(raw.group(1)))
            lines = payload.get("summaryData", {}).get("generalLines", [])
            parts = [
                item.get("text", "")
                for line in lines
                for item in line.get("data", [])
                if item.get("text")
            ]
            text = _text(" ".join(parts))
            if text:
                return text
        except (ValueError, TypeError, AttributeError):
            pass
    for pattern in (
        r'<div[^>]*class="[^"]*c-abstract[^"]*"[^>]*>(.*?)</div>',
        r'<span[^>]*class="[^"]*content-right[^"]*"[^>]*>(.*?)</span>',
        r'<div[^>]*class="[^"]*c-span-last[^"]*"[^>]*>(.*?)</div>',
    ):
        hit = re.search(pattern, block, re.DOTALL)
        if hit:
            return _text(hit.group(1))
    return ""


def _parse_baidu(raw: str) -> list:
    out = []
    for block in re.findall(
        r'<div[^>]*class="result[^"]*c-container[^"]*".*?'
        r'(?=<div[^>]*class="result[^"]*c-container|</body>)',
        raw,
        re.DOTALL,
    ):
        m = re.search(
            r'<h3[^>]*>.*?<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.DOTALL
        )
        if not m:
            continue
        href = htmlmod.unescape(m.group(1)).strip()
        # Whole-block ad: the title link itself is a promotion redirect.
        if "baidu.php" in href.lower():
            continue
        # `mu` is the real target for organic results and a placeholder for ads.
        mu = re.search(r'\smu="([^"]*)"', block)
        url = htmlmod.unescape(mu.group(1)).strip() if mu else href
        if _is_ad_url(url) or not url.startswith("http"):
            continue
        title = _text(m.group(2))
        if not title:
            continue
        out.append(
            {
                "title": title,
                "url": url,
                "date": "",
                "snippet": _baidu_summary(block)[:200],
            }
        )
    return out


def _parse_marginalia(raw: str) -> list:
    out = []
    for block in re.findall(
        r'<section[^>]*class="[^"]*search-result[^"]*".*?</section>', raw, re.DOTALL
    ):
        m = re.search(
            r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.DOTALL
        )
        if not m or not m.group(1).startswith("http"):
            continue
        snippet = ""
        hit = re.search(r'<p class="description"[^>]*>(.*?)</p>', block, re.DOTALL)
        if hit:
            snippet = _text(hit.group(1))
        out.append(
            {
                "title": _text(m.group(2)),
                "url": htmlmod.unescape(m.group(1)),
                "date": "",
                "snippet": snippet[:200],
            }
        )
    return out


_PARSERS = {
    "bing": _parse_bing,
    "duckduckgo": _parse_duckduckgo,
    "brave": _parse_brave,
    "sogou": _parse_sogou,
    "so360": _parse_so360,
    "baidu": _parse_baidu,
    "marginalia": _parse_marginalia,
}


# ── Wikipedia ───────────────────────────────────────────────────────────────

_WIKI_GAP = 1.2
_wiki_clock = [0.0]


def _wiki_get(url: str, retries: int = 2) -> dict:
    for attempt in range(retries + 1):
        wait = _WIKI_GAP - (time.monotonic() - _wiki_clock[0])
        if wait > 0:
            time.sleep(wait)
        _wiki_clock[0] = time.monotonic()
        req = urllib.request.Request(url, headers={"User-Agent": WIKI_UA})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code != 429 or attempt == retries:
                raise
            time.sleep(3.0 * (attempt + 1))
        except Exception:
            if attempt == retries:
                raise
            time.sleep(1.5 * (attempt + 1))
    return {}


def _wiki_extract(title: str, lang: str):
    url = (
        f"https://{lang}.wikipedia.org/w/api.php?action=query&prop=extracts"
        f"&explaintext=1&redirects=1&format=json&titles={urllib.parse.quote(title)}"
    )
    for p in _wiki_get(url).get("query", {}).get("pages", {}).values():
        if p.get("extract", "").strip():
            return {
                "title": p["title"],
                "lang": lang,
                "extract": p["extract"],
                "url": f"https://{lang}.wikipedia.org/wiki/{urllib.parse.quote(p['title'])}",
            }
    return None


def _overlap(a: str, b: str) -> int:
    """Length of the longest common substring of a and b."""
    best = 0
    for i in range(len(a)):
        for j in range(i + best + 1, len(a) + 1):
            if a[i:j] in b:
                best = j - i
            else:
                break
    return best


def _wiki_title_for(term: str, lang: str):
    url = (
        f"https://{lang}.wikipedia.org/w/api.php?action=query&list=search"
        f"&srsearch={urllib.parse.quote(term)}&format=json&srlimit=5"
    )
    for h in _wiki_get(url).get("query", {}).get("search", []):
        title = h["title"]
        if _overlap(term.lower(), title.lower()) >= min(len(term), 4):
            return title
    return None


def _wiki_langlink(title: str, src: str, dst: str):
    url = (
        f"https://{src}.wikipedia.org/w/api.php?action=query&prop=langlinks"
        f"&lllang={dst}&redirects=1&format=json&titles={urllib.parse.quote(title)}"
    )
    for p in _wiki_get(url).get("query", {}).get("pages", {}).values():
        links = p.get("langlinks") or []
        if links:
            return links[0]["*"]
    return None


def _wiki_find(term: str, lang: str):
    hit = _wiki_extract(term, lang)
    if hit:
        return hit
    alt = _wiki_title_for(term, lang)
    return _wiki_extract(alt, lang) if alt else None


def wiki(term: str, langs=WIKI_LANGS, min_chars: int = WIKI_MIN_CHARS):
    """Return the authoritative extract for a concept, or None."""
    try:
        return _wiki_lookup(term, langs, min_chars)
    except Exception:
        return None


def _wiki_lookup(term: str, langs, min_chars: int):
    hit = None
    for lang in langs:
        hit = _wiki_find(term, lang)
        if hit:
            break
    if not hit or len(hit["extract"]) >= min_chars:
        return hit
    for other in langs:
        if other == hit["lang"]:
            continue
        alt_title = _wiki_langlink(hit["title"], hit["lang"], other)
        if not alt_title:
            continue
        alt = _wiki_extract(alt_title, other)
        if alt and len(alt["extract"]) > len(hit["extract"]):
            return alt
    return hit


# ── jump resolution ─────────────────────────────────────────────────────────


def _marginalia_retry(raw: str) -> str:
    """Marginalia answers bots with a wait page; follow its manual link once."""
    if "barraged by queries" not in raw.lower():
        return raw
    match = re.search(r'href="(/search\?[^"]+sst=[^"]+)"', raw)
    if not match:
        return raw
    time.sleep(2.0)
    try:
        _, retried, _ = _get(
            "https://old-search.marginalia.nu" + htmlmod.unescape(match.group(1)),
            "marginalia",
        )
        return retried
    except Exception:
        return raw


def _resolve_sogou_jump(url: str) -> str:
    try:
        raw = fetch(url, "sogou", timeout=8)
    except Exception:
        return url
    m = re.search(r"location\.replace\(\s*[\"']([^\"']+)[\"']", raw)
    return htmlmod.unescape(m.group(1)) if m else url


def _resolve_baidu_jump(url: str) -> str:
    try:
        _respect_rate("baidu:jump", 0.5)
        final, _, _ = _request(url, "baidu", timeout=8)
        if final.startswith("http") and "baidu.com/link" not in final:
            return final
    except Exception:
        pass
    return url


def _resolve_jumps(results: list) -> list:
    targets = [
        r for r in results if "/link?url=" in r["url"] or "baidu.com/link?" in r["url"]
    ]
    if not targets:
        return results
    with ThreadPoolExecutor(max_workers=3) as pool:
        for r, real in zip(targets, pool.map(lambda r: _resolve_one_jump(r), targets)):
            r["url"] = real
    return results


def _resolve_one_jump(result: dict) -> str:
    if result.get("engine") == "sogou":
        return _resolve_sogou_jump(result["url"])
    return _resolve_baidu_jump(result["url"])


# ── relevance ───────────────────────────────────────────────────────────────


_ASCII_RUN_RE = re.compile(r"[a-z0-9]+")
_CJK_RUN_RE = re.compile(r"[㐀-鿿]+")


def _query_tokens(query: str) -> list[str]:
    """ASCII words plus CJK bigrams; no dictionary or tokenizer required."""
    q = query.lower()
    tokens = _ASCII_RUN_RE.findall(q)
    for run in _CJK_RUN_RE.findall(q):
        tokens += (
            [run] if len(run) == 1 else [run[i : i + 2] for i in range(len(run) - 1)]
        )
    return tokens


def _score_results(results: list, query: str) -> list:
    """Rank candidates by query-token coverage with corpus-local IDF weights."""
    q = query.lower().strip()
    if not q or not results:
        return results
    tokens = _query_tokens(q) or [q]
    docs = [(r["title"] + " " + r.get("snippet", "")).lower() for r in results]
    n = len(docs)
    weights = {
        t: math.log(1 + n / (1 + sum(1 for d in docs if t in d))) for t in set(tokens)
    }
    total = sum(weights.values()) or 1.0
    for result, doc in zip(results, docs):
        title = result["title"].lower()
        score = sum(w for t, w in weights.items() if t in doc) / total
        if q in doc:
            score += 1.0
        if q in title:
            score += 0.5
        elif any(t in title for t in tokens):
            score += 0.1
        result["score"] = round(score, 4)
    return sorted(results, key=lambda r: (-r["score"], len(r["title"])))


def _order_for(query: str):
    return CJK_ORDER if _CJK_RE.search(query) else LATIN_ORDER


def search_report(query: str, engines=None, min_results: int = 5):
    """Cascade engines and return `(results, report)`; the report explains failures."""
    if isinstance(engines, str):
        engines = tuple(e.strip() for e in engines.split(",") if e.strip())
    order = tuple(engines) if engines else _order_for(query)
    min_results = max(1, int(min_results))
    out: list = []
    status: dict[str, dict] = {}
    attempted = 0
    stopped_at = None
    deadline = time.monotonic() + SEARCH_BUDGET
    for engine in order:
        if engine not in _PARSERS:
            status[engine] = {"status": "unknown_engine"}
            continue
        if not _engine_ok(engine):
            status[engine] = {"status": "cooldown"}
            continue
        if time.monotonic() >= deadline:
            status[engine] = {"status": "skipped_budget"}
            continue
        attempted += 1
        _warm(engine)
        if time.monotonic() >= deadline:
            status[engine] = {"status": "skipped_budget"}
            break
        url = _ENDPOINTS[engine].format(q=urllib.parse.quote(query))
        remaining = max(2.0, deadline - time.monotonic())
        try:
            _, raw, _ = _get(
                url,
                engine,
                timeout=min(SEARCH_TIMEOUT, remaining),
                retries=1,
            )
        except Exception as exc:
            _record_failure(engine)
            status[engine] = {
                "status": "failed",
                "error": f"{type(exc).__name__}: {exc}",
            }
            continue
        _record_success(engine)
        if engine == "marginalia":
            raw = _marginalia_retry(raw)
        try:
            parsed = _PARSERS[engine](raw)
        except Exception as exc:
            parsed = []
            status[engine] = {
                "status": "parse_failed",
                "error": f"{type(exc).__name__}: {exc}",
            }
        else:
            status[engine] = {"status": "ok", "parsed": len(parsed)}
        for r in parsed:
            r.setdefault("engine", engine)
        out.extend(r for r in parsed if not _is_engine_page(r["url"]))
        if len(out) >= _CANDIDATE_TARGET:
            stopped_at = engine
            break
    ranked = _score_results(_resolve_jumps(_dedup(out)), query)
    results = [r for r in ranked if r.get("score", 0) >= _MIN_SCORE][:min_results]
    for engine, info in status.items():
        if info.get("status") == "ok":
            info["kept"] = sum(1 for r in results if r.get("engine") == engine)
    known = [e for e in order if e in _PARSERS]
    all_failed = bool(known) and all(
        status.get(engine, {}).get("status") in ("failed", "cooldown", "parse_failed")
        for engine in known
    )
    report = {
        "total": len(results),
        "candidates": len(out),
        "engines": status,
        "attempted": attempted,
        "stopped_at": stopped_at,
        "all_failed": all_failed,
        "no_engines_available": attempted == 0,
    }
    return results, report


def search(query: str, engines=None, min_results: int = 5) -> list:
    """Backward-compatible wrapper used by the knowledge pipeline."""
    return search_report(query, engines, min_results)[0]


# ── HTML → Markdown ─────────────────────────────────────────────────────────


_VOID_TAGS = {
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
}
_SKIP_TAGS = {
    "script",
    "style",
    "noscript",
    "svg",
    "iframe",
    "form",
    "input",
    "button",
    "select",
    "textarea",
    "canvas",
    "template",
    "nav",
    "footer",
    "aside",
}
_HEADINGS = {f"h{i}": i for i in range(1, 7)}
_BOILERPLATE_RE = re.compile(
    r"(?:^|[-_ ])(nav|menu|footer|sidebar|cookie|banner|advert|ads?|share|social|"
    r"comment|breadcrumb)(?:$|[-_ ])",
    re.IGNORECASE,
)


def _clean_markdown(text: str) -> str:
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _truncate(text: str, max_chars: int) -> str:
    if max_chars and max_chars > 0 and len(text) > max_chars:
        cut = text.rfind("\n", 0, max_chars)
        if cut < max_chars // 2:
            cut = max_chars
        return text[:cut].rstrip() + f"\n\n[... truncated {len(text) - cut} chars ...]"
    return text


def _cell_text(value: str) -> str:
    return _clean_markdown(value).replace("|", "\\|").replace("\n", " ")


class _MarkdownParser(HTMLParser):
    def __init__(self, base_url: str = ""):
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.parts: list[str] = []
        self.skip = 0
        self.skip_stack: list[str] = []
        self.pre = 0
        self.links: list[str] = []
        self.lists: list[str] = []
        self.ol_index: list[int] = []
        self.title_parts: list[str] = []
        self.in_title = False
        self.table_rows: list[list[str]] | None = None
        self.row: list[str] | None = None
        self.cell: list[str] | None = None

    def _newline(self, count: int = 2) -> None:
        if self.parts and not self.parts[-1].endswith("\n" * count):
            self.parts.append("\n" * count)

    def _abs(self, href: str) -> str:
        return urllib.parse.urljoin(self.base_url, href) if href else ""

    def _is_boilerplate(self, attrs: dict) -> bool:
        marker = " ".join(filter(None, (attrs.get("class", ""), attrs.get("id", ""))))
        return bool(marker and _BOILERPLATE_RE.search(marker))

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        attrs = dict(attrs)
        if tag == "title":
            self.in_title = True
            return
        if tag in _SKIP_TAGS:
            if tag not in _VOID_TAGS:
                self.skip += 1
                self.skip_stack.append(tag)
            return
        if self.skip:
            return
        if self.cell is not None:
            return
        if self._is_boilerplate(attrs):
            self.skip += 1
            self.skip_stack.append(tag)
            return
        if tag in _HEADINGS:
            self._newline(2)
            self.parts.append("#" * _HEADINGS[tag] + " ")
        elif tag in ("p", "div", "section", "article", "main"):
            self._newline(2)
        elif tag in ("ul", "ol"):
            self._newline(2)
            self.lists.append(tag)
            self.ol_index.append(0)
        elif tag == "li":
            self._newline(1)
            if self.lists and self.lists[-1] == "ol":
                self.ol_index[-1] += 1
                self.parts.append(f"{self.ol_index[-1]}. ")
            else:
                self.parts.append("- ")
        elif tag == "br":
            self._newline(1)
        elif tag == "hr":
            self._newline(2)
            self.parts.append("---")
            self._newline(2)
        elif tag == "blockquote":
            self._newline(2)
            self.parts.append("> ")
        elif tag == "pre":
            self._newline(2)
            self.parts.append("```\n")
            self.pre += 1
        elif tag == "code":
            if not self.pre:
                self.parts.append("`")
        elif tag in ("strong", "b"):
            self.parts.append("**")
        elif tag in ("em", "i"):
            self.parts.append("*")
        elif tag == "a":
            href = attrs.get("href", "")
            self.links.append(href)
            self.parts.append("[")
        elif tag == "img":
            alt = attrs.get("alt", "")
            src = self._abs(attrs.get("src", ""))
            if src:
                self.parts.append(f"![{alt}]({src})")
        elif tag == "table":
            self._newline(2)
            self.table_rows = []
        elif tag == "tr":
            self.row = []
        elif tag in ("td", "th"):
            self.cell = []

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "title":
            self.in_title = False
            return
        if self.skip_stack:
            if self.skip_stack[-1] == tag:
                self.skip_stack.pop()
                self.skip = max(0, self.skip - 1)
            return
        if tag in _SKIP_TAGS:
            return
        if tag in ("td", "th"):
            if self.cell is not None:
                if self.row is None:
                    self.row = []
                self.row.append(_cell_text("".join(self.cell)))
                self.cell = None
            return
        if tag == "tr":
            if self.table_rows is not None and self.row:
                self.table_rows.append(self.row)
            self.row = None
            return
        if tag == "table":
            self._render_table()
            return
        if self.cell is not None:
            return
        if tag in _HEADINGS or tag in ("p", "div", "section", "article", "main"):
            self._newline(2)
        elif tag in ("ul", "ol"):
            if self.lists:
                self.lists.pop()
                self.ol_index.pop()
            self._newline(2)
        elif tag == "li":
            self._newline(1)
        elif tag == "blockquote":
            self._newline(2)
        elif tag == "pre":
            self.pre = max(0, self.pre - 1)
            self.parts.append("\n```\n")
        elif tag == "code":
            if not self.pre:
                self.parts.append("`")
        elif tag in ("strong", "b"):
            self.parts.append("**")
        elif tag in ("em", "i"):
            self.parts.append("*")
        elif tag == "a":
            href = self.links.pop() if self.links else ""
            self.parts.append(f"]({self._abs(href)})" if href else "]")

    def handle_data(self, data):
        if self.skip:
            return
        if self.in_title:
            self.title_parts.append(data)
        elif self.cell is not None:
            self.cell.append(data)
        else:
            self.parts.append(data)

    def _render_table(self) -> None:
        rows = [r for r in (self.table_rows or []) if r]
        self.table_rows = None
        if not rows:
            return
        cols = max(len(r) for r in rows)
        rows = [r + [""] * (cols - len(r)) for r in rows]
        lines = [
            "| " + " | ".join(rows[0]) + " |",
            "| " + " | ".join("---" for _ in range(cols)) + " |",
        ]
        lines.extend("| " + " | ".join(r) + " |" for r in rows[1:])
        self._newline(2)
        self.parts.append("\n".join(lines))
        self._newline(2)


def html_to_markdown(raw: str, base_url: str = "", max_chars: int = 0) -> str:
    parser = _MarkdownParser(base_url)
    try:
        parser.feed(raw or "")
        parser.close()
    except Exception:
        pass
    body = _clean_markdown("".join(parser.parts))
    title = _clean_markdown("".join(parser.title_parts))
    if title and title not in body[:300]:
        body = f"# {title}\n\n{body}"
    return _truncate(body, max_chars)


def html_to_text(raw: str, base_url: str = "", max_chars: int = 0) -> str:
    """Alias kept for callers that only need plain text; the output is Markdown."""
    return html_to_markdown(raw, base_url, max_chars)


# ── public tool entry ───────────────────────────────────────────────────────


def fetch_markdown(url: str, max_chars: int = 6000, timeout: int = TIMEOUT) -> dict:
    host = urllib.parse.urlparse(url).netloc.lower()
    _respect_rate("host:" + host, 0.8)
    # Page fetches see the same transient SSL/EOF failures as search; retry once.
    final, raw, _ = _get(url, "page", timeout=timeout, retries=1)
    markdown = html_to_markdown(raw, base_url=final, max_chars=max_chars)
    return {"url": final, "markdown": markdown, "chars": len(markdown)}


def websearch(
    query: str,
    limit: int = 5,
    fetch_top: int = 1,
    max_chars: int = 6000,
    engines=None,
) -> dict:
    """Search, then read the top `fetch_top` pages as Markdown (bounded by total budget)."""
    limit = max(1, min(int(limit), 10))
    fetch_top = max(0, min(int(fetch_top), 3))
    max_chars = max(1000, min(int(max_chars), 10000))
    started = time.monotonic()
    results, report = search_report(query, engines=engines, min_results=limit)
    results = results[:limit]
    pages = []
    page_errors = []
    budget = MAX_TOTAL_CHARS
    page_deadline = started + SEARCH_BUDGET + PAGE_BUDGET
    # A top result can be anti-bot protected; try a couple more before giving up.
    for attempts, result in enumerate(results, 1):
        if len(pages) >= fetch_top or attempts > fetch_top + 2 or budget <= 0:
            break
        remaining = page_deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            page = fetch_markdown(
                result["url"],
                max_chars=min(max_chars, budget),
                timeout=min(PAGE_TIMEOUT, remaining),
            )
            pages.append(
                {
                    "url": page["url"],
                    "title": result["title"],
                    "markdown": page["markdown"],
                    "chars": page["chars"],
                }
            )
            budget -= page["chars"]
        except Exception as exc:
            page_errors.append(
                {
                    "url": result["url"],
                    "title": result["title"],
                    "error": f"{type(exc).__name__}: {exc}",
                }
            )
    payload = {
        "query": query,
        "results": results,
        "pages": pages,
        "elapsed_ms": int((time.monotonic() - started) * 1000),
    }
    if page_errors and not pages:
        payload["page_errors"] = page_errors
        payload["page_error"] = f"all page fetches failed ({len(page_errors)} tried)"
    if not results:
        if report.get("no_engines_available"):
            payload["error"] = (
                "no search engine available (all failed, cooling down, or skipped)"
            )
        elif report.get("all_failed"):
            detail = "; ".join(
                f"{name}: {info.get('error', info.get('status'))}"
                for name, info in report["engines"].items()
                if info.get("status") in ("failed", "cooldown", "parse_failed")
            )
            payload["error"] = f"all search engines failed: {detail or 'unknown error'}"
        else:
            ok = [
                name
                for name, info in report["engines"].items()
                if info.get("status") == "ok"
            ]
            payload["error"] = "no relevant results" + (
                f" (engines responded: {', '.join(ok)})" if ok else ""
            )
        payload["engine_report"] = report["engines"]
    return payload


if __name__ == "__main__":
    import sys

    q = " ".join(sys.argv[1:])
    try:
        hit = wiki(q)
    except Exception as exc:
        hit = None
        print(f"== wiki: {type(exc).__name__}: {exc}")
    if hit:
        print(
            f"== wiki [{hit['lang']}] {hit['title']} ({len(hit['extract'])} chars)\n"
            f"   {hit['url']}"
        )
    else:
        print("== wiki: no hit")
    print()
    for i, r in enumerate(search(q), 1):
        print(f"[{i}] {r['title']}\n    {r['url']}\n    {r['snippet'][:120]}")
