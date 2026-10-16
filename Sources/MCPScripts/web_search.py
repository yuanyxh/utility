"""多引擎网页搜索:抓取 + 解析,返回结构化结果。

移植自示例 skill 的 scripts/(四个引擎的抓取脚本 + 解析脚本),抓取改用 urllib ——
原实现由 shell 调 curl 与 PATH 里的 python3,而 app 经 launchd 启动时 PATH 受限。
"""

import html as htmlmod
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"
)
# 维基要求可辨识身份:浏览器 UA 会被当作匿名抓取而限流
WIKI_UA = "utility-knowledge-panel/1.0 (personal use)"
TIMEOUT = 20

# 维基是官方 API 而非 HTML 抓取:对「原理/概念」类查询质量最高,且不随对方页面改版失效
WIKI_LANGS = ("zh", "en")
WIKI_MIN_CHARS = 600  # 中文短于此就再取英文 —— 中文条目常只有一两句

_ENDPOINTS = {
    "bing": "https://www.bing.com/search?q={q}&count=10",
    "duckduckgo": "https://html.duckduckgo.com/html/?q={q}",
    "brave": "https://search.brave.com/search?q={q}",
    "sogou": "https://www.sogou.com/web?query={q}",
    "so360": "https://www.so.com/s?q={q}",
}
# 顺序即优先级。2026-10 实测:没有一家结构性可靠 —— Bing 对中文长查询退化成字词
# 词典页、DDG 返 202 挑战页、Brave 时通时断(几家还会轮流限流);搜狗/360 对中文最稳
# 且不与前面重叠。级联 + 相关性过滤是主要保障。
#
# Google 不在列:它对未登录请求做 JS 挑战,首响应一律是 /httpservice/retry/enablejs
# 中间页,只有执行过 JS 的客户端(浏览器)才拿得到结果页 —— 实测同名同结构的 cookie
# 由浏览器给出时 737KB/<h3>×10,由本模块自己首次请求取得时 92KB/<h3>×0。curl 无法
# 执行 JS,故结构上走不通;要接需在 App 内嵌 WKWebView 跑真实浏览器流程。
DEFAULT_ENGINES = ("bing", "sogou", "so360", "duckduckgo", "brave")


def _headers(engine: str) -> dict:
    return {"User-Agent": UA, "Accept": "text/html"}


def fetch(url: str, engine: str = "bing", timeout: int = TIMEOUT) -> str:
    """用浏览器 UA 抓任意 URL 的 HTML —— app 环境下替代 curl(无 PATH 依赖)。"""
    req = urllib.request.Request(url, headers=_headers(engine))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        charset = resp.headers.get_content_charset() or "utf-8"
        return resp.read().decode(charset, errors="ignore")


def _text(fragment: str) -> str:
    return htmlmod.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()


def _unredirect(url: str) -> str:
    if url.startswith("/url?q="):
        return url[8:].split("&")[0]
    if "uddg=" in url:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        return q.get("uddg", [url])[0]
    return url


def _dedup(results: list, limit: int = 15) -> list:
    seen, out = set(), []
    for r in results:
        if r["url"] not in seen and r["title"]:
            seen.add(r["url"])
            out.append(r)
    return out[:limit]


def _parse_bing(raw: str) -> list:
    out = []
    for block in re.findall(r'<li class="b_algo".*?</li>', raw, re.S):
        # 标题在 h2 内;块里另有 <cite> 包着的引用行,直接取首个 <a> 会抓成它
        m = re.search(r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        if not m or not m.group(1).startswith("http"):
            continue
        snippet = ""
        p = re.search(r"<p[^>]*>(.*?)</p>", block, re.S)
        if p:
            snippet = _text(p.group(1))
        md = re.search(r"\d{4}年\d{1,2}月\d{1,2}日", snippet)
        out.append(
            {
                "title": _text(m.group(2)),
                "url": m.group(1),
                "date": md.group(0) if md else "",
                "snippet": snippet,
            }
        )
    return out


def _parse_duckduckgo(raw: str) -> list:
    out = []
    for block in re.findall(r'<div class="result[^"]*".*?</div>\s*</div>', raw, re.S):
        m = re.search(
            r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S
        )
        if not m:
            continue
        url = _unredirect(m.group(1))
        if not url.startswith("http"):
            continue
        snippet = ""
        hit = re.search(r'<a class="result__snippet"[^>]*>(.*?)</a>', block, re.S)
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
    for block in re.findall(r'<div class="snippet[^"]*".*?</div>\s*</div>', raw, re.S):
        m = re.search(
            r'<a[^>]*class="result-header"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
            block,
            re.S,
        ) or re.search(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        if not m or not m.group(1).startswith("http"):
            continue
        snippet = ""
        hit = re.search(
            r'<p class="snippet-description[^"]*"[^>]*>(.*?)</p>', block, re.S
        )
        if hit:
            snippet = _text(hit.group(1))
        date = ""
        dm = re.search(r'<time[^>]*datetime="([^"]*)"', block, re.S)
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
        r'<li class="res-list[^"]*".*?(?=<li class="res-list|</ol>)', raw, re.S
    ):
        m = re.search(
            r'<h3[^>]*class="res-title[^"]*"[^>]*>\s*<a\s([^>]*)>(.*?)</a>', block, re.S
        )
        if not m:
            continue
        # href 是 360 的跳转链,data-mdurl 才是站点真实地址
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
        out.append(
            {
                "title": _text(m.group(2)),
                "url": url,
                "date": d.group(0) if d else "",
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
}


_WIKI_GAP = 1.2  # 秒:维基对连发请求返 429
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
            # SSL 断连 / 连接重置 / 读超时都是瞬时故障,退避后重试
            if attempt == retries:
                raise
            time.sleep(1.5 * (attempt + 1))
    return {}


def _wiki_extract(title: str, lang: str):
    """条目纯文本全文。redirects=1 —— 概念名未必等于条目名(端到端原则 → 端到端原則)。"""
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
    """a、b 的最长公共子串长度。"""
    best = 0
    for i in range(len(a)):
        for j in range(i + best + 1, len(a) + 1):
            if a[i:j] in b:
                best = j - i
            else:
                break
    return best


def _wiki_title_for(term: str, lang: str):
    """按词找条目名。维基搜索对查不到的词会尽力返回无关条目(搜「依赖倒置原则」给《證據》),
    故候选必须与查询真有重叠 —— 查不到宁可为空,拿无关条目当证据比没有更糟。"""
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
    """同一概念在另一语言的条目名 —— 精确映射,免得拿中文词去英文维基瞎搜。"""
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
    """按概念名取权威条目全文 —— 卡片证据的主来源。取不到就返回 None。

    限流/网络异常一律吞成 None:证据拿不到就不出这张卡,不该拖垮整条流程。
    """
    try:
        return _wiki_lookup(term, langs, min_chars)
    except Exception:
        return None


def _wiki_lookup(term: str, langs, min_chars: int):
    """中文条目常只有一两句(端到端原則 126 字),不够长就顺 langlinks 换语言取同一概念
    (英文同名条目上万字)—— 而不是拿中文词去英文维基搜,那会搜出毫不相干的条目。"""
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


def _resolve_sogou_jump(url: str) -> str:
    """把搜狗跳转链接换成站点真实地址。

    它不发 HTTP 重定向,而是回一个 296 字节的页面执行 location.replace ——
    跟随重定向拿到的是原地不动,只能抓下来读那行 JS。
    """
    try:
        html = fetch(url, "sogou", timeout=8)
    except Exception:
        return url
    m = re.search(r"location\.replace\(\s*[\"']([^\"']+)[\"']", html)
    return htmlmod.unescape(m.group(1)) if m else url


def _resolve_jumps(results: list) -> list:
    """并发解掉搜狗的跳转链接;单个失败保留原链,不影响其他结果。"""
    targets = [r for r in results if "/link?url=" in r["url"]]
    if not targets:
        return results
    with ThreadPoolExecutor(max_workers=5) as pool:
        for r, real in zip(
            targets, pool.map(lambda r: _resolve_sogou_jump(r["url"]), targets)
        ):
            r["url"] = real
    return results


def _matches(result: dict, query: str) -> bool:
    """结果是否真的关于这个查询 —— 识破引擎降级:搜「端到端原则」却给「端」的字典页。"""
    hay = (result["title"] + " " + result["snippet"]).lower()[:400]
    q = query.lower().strip()
    if not q:
        return True
    if q in hay:
        return True
    terms = [t for t in q.split() if t]
    if len(terms) > 1:
        return all(t in hay for t in terms)
    # 门槛 4:只取前两字符会把同前缀的异概念全放进来(「观察者模式」→「观察者网」),
    # 而「CAP定理」前两字符是 ca,更等于把词典的 cap 条目当结果
    return _overlap(q, hay) >= min(len(q), 4)


def search(query: str, engines=DEFAULT_ENGINES, min_results: int = 5) -> list:
    """级联多引擎,累积到 min_results 条即停。单个引擎失败只跳过,全部失败返回空。"""
    out = []
    for engine in engines:
        try:
            raw = fetch(_ENDPOINTS[engine].format(q=urllib.parse.quote(query)), engine)
        except Exception:
            continue
        out.extend(r for r in _PARSERS[engine](raw) if _matches(r, query))
        if len(out) >= min_results:
            break
    return _resolve_jumps(_dedup(out))


if __name__ == "__main__":
    import sys

    q = " ".join(sys.argv[1:])
    try:
        hit = wiki(q)
    except Exception as exc:
        hit = None
        print(f"== 维基:异常 {type(exc).__name__}: {exc}")
    if hit:
        print(
            f"== 维基 [{hit['lang']}] {hit['title']}({len(hit['extract'])} 字)==\n   {hit['url']}"
        )
        print("   " + hit["extract"][:300].replace("\n", " ") + "...")
    elif not hit:
        print("== 维基:未命中")
    print()
    for i, r in enumerate(search(q), 1):
        print(f"[{i}] {r['title']}\n    {r['url']}\n    {r['snippet'][:120]}")
