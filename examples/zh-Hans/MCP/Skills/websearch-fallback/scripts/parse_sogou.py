#!/usr/bin/env python3
"""从搜狗搜索结果 HTML 提取结构化结果（标题/URL/日期/摘要）。

用法:
    python3 parse_sogou.py <html文件>              # 解析文件
    python3 parse_sogou.py --resolve <html文件>    # 并把 /link?url= 换成站点真实地址
    cat <html> | python3 parse_sogou.py -          # 从 stdin 读取
输出:
    [n] 标题
        URL: <真实链接>
        日期: <YYYY年M月D日 或 ->
        摘要: <snippet>

依赖搜狗标准结果块 <div class="vrwrap">，与 sogou_search.sh 配合使用。

注意跳转链：搜狗结果的 href 常是 /link?url=...，它**不发 HTTP 重定向**，
而是回一个 296 字节的页面执行 window.location.replace("真实地址")。
跟随重定向只会停在原地，必须再抓一次该页并读出那行 JS —— 即 --resolve 所做的事。
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
    """把搜狗跳转链接换成站点真实地址；抓不到时原样返回。"""
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
    """解析 <div class="vrwrap"> 结果块，返回 {title,url,date,snippet} 列表。"""
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
        print(f"    日期: {r['date'] or '-'}")
        print(f"    摘要: {r['snippet']}")


if __name__ == "__main__":
    main()
