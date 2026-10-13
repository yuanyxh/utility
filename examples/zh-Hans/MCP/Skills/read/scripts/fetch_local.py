#!/usr/bin/env python3
"""本地 URL → Markdown 提取器。fetch.sh 中隐私优先的第 1 层。

两条路径，运行期选择：

1. **最佳路径**：已安装 `readability-lxml` + `html2text`。通过 readability
   打分提取正文，转换为干净的 Markdown。对静态页面，质量接近
   defuddle.md / r.jina.ai。

2. **兜底路径**：仅用标准库。剥离 HTML 标签、合并空白、丢弃
   <script>/<style>/<nav>/<footer>。对重 JS 页面与复杂版式质量很差，
   但对简单的文章式 HTML 无需任何第三方依赖即可工作。

JS 渲染的页面（X/Twitter、付费墙新闻、SPA）两条路径都够不到。这类请用
`fetch.sh --use-proxy`。

退出码：
  0  成功，Markdown 输出到 stdout
  1  抓取或提取失败；原因输出到 stderr
  2  调用错误（缺少 URL）
"""

from __future__ import annotations

import argparse
import re
import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser


USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 12_0) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
)
FETCH_TIMEOUT_SECS = 20


def fetch_html(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT_SECS) as resp:
        raw = resp.read()
    # 从 Content-Type 头检测字符集；否则回退到 utf-8 并替换非法字节。
    charset = "utf-8"
    ctype = resp.headers.get("Content-Type", "")
    m = re.search(r"charset=([\w\-]+)", ctype, re.IGNORECASE)
    if m:
        charset = m.group(1).lower()
    try:
        return raw.decode(charset, errors="replace")
    except LookupError:
        return raw.decode("utf-8", errors="replace")


def extract_with_readability(html: str, url: str) -> str | None:
    """最佳路径：readability-lxml + html2text。返回 Markdown；依赖缺失时返回
    None。仅在真正的提取失败时才抛异常。"""
    try:
        from readability import Document  # type: ignore
        import html2text  # type: ignore
    except ImportError:
        return None
    doc = Document(html)
    cleaned_html = doc.summary(html_partial=True)
    title = (doc.short_title() or "").strip()
    converter = html2text.HTML2Text()
    converter.body_width = 0
    converter.unicode_snob = True
    converter.ignore_links = False
    converter.ignore_images = False
    body = converter.handle(cleaned_html).strip()
    if not body:
        return None
    header = ""
    if title:
        header = f"# {title}\n\n"
    return f"{header}> Source: {url}\n\n{body}\n"


class _StdlibStripper(HTMLParser):
    """仅用标准库的兜底 HTML → 文本转换器。质量差但确定性强；在未安装
    readability 时作为最后手段。会丢弃常见的非正文块
    （script/style/nav/footer/aside）。"""

    DROP_TAGS = {"script", "style", "nav", "footer", "aside", "noscript", "form"}
    BLOCK_TAGS = {
        "p", "div", "section", "article", "li", "ul", "ol",
        "h1", "h2", "h3", "h4", "h5", "h6", "br", "tr",
    }

    def __init__(self) -> None:
        super().__init__()
        self._buf: list[str] = []
        self._drop_depth = 0
        self._title = ""
        self._in_title = False

    def handle_starttag(self, tag, attrs):
        if tag in self.DROP_TAGS:
            self._drop_depth += 1
        elif tag == "title":
            self._in_title = True
        elif tag in self.BLOCK_TAGS:
            self._buf.append("\n")

    def handle_endtag(self, tag):
        if tag in self.DROP_TAGS:
            self._drop_depth = max(0, self._drop_depth - 1)
        elif tag == "title":
            self._in_title = False
        elif tag in self.BLOCK_TAGS:
            self._buf.append("\n")

    def handle_data(self, data):
        if self._drop_depth:
            return
        if self._in_title:
            self._title += data
            return
        self._buf.append(data)

    def text(self) -> str:
        raw = "".join(self._buf)
        lines = [line.strip() for line in raw.splitlines()]
        # 丢弃空行，但保留段落分隔。
        out: list[str] = []
        prev_blank = False
        for line in lines:
            if not line:
                if not prev_blank:
                    out.append("")
                prev_blank = True
            else:
                out.append(line)
                prev_blank = False
        return "\n".join(out).strip()


def extract_with_stdlib(html: str, url: str) -> str:
    p = _StdlibStripper()
    p.feed(html)
    body = p.text()
    if not body:
        body = "（未提取到文本内容）"
    header = ""
    title = (p._title or "").strip()
    if title:
        header = f"# {title}\n\n"
    return f"{header}> Source: {url}\n\n{body}\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", help="要抓取的 URL")
    parser.add_argument(
        "--prefer",
        choices=("auto", "readability", "stdlib"),
        default="auto",
        help="强制指定某个提取器（默认：auto = 已安装 readability 则用它，否则用 stdlib）",
    )
    args = parser.parse_args()

    try:
        html = fetch_html(args.url)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as exc:
        print(
            f"[fetch] tier=local status=fail reason=\"抓取失败：{exc}\"",
            file=sys.stderr,
        )
        return 1

    used = ""
    body: str | None = None

    if args.prefer in ("auto", "readability"):
        body = extract_with_readability(html, args.url)
        if body is not None:
            used = "readability"
        elif args.prefer == "readability":
            print(
                "[fetch] tier=local status=fail "
                "reason=\"指定了 --prefer readability，但未安装 readability-lxml 或 html2text；"
                "请用以下命令安装：pip install --user readability-lxml html2text\"",
                file=sys.stderr,
            )
            return 1

    if body is None:
        body = extract_with_stdlib(html, args.url)
        used = "stdlib"

    # 最低限度校验：如果连 stdlib 提取器都基本取不到东西，就视为失败，
    # 好让代理兜底（若带 --use-proxy）有机会介入。
    body_lines = [l for l in body.splitlines() if l.strip()]
    if len(body_lines) < 4:
        print(
            f"[fetch] tier=local status=fail reason=\"extractor={used} 产生的非空行少于 4 行\"",
            file=sys.stderr,
        )
        return 1

    if used == "stdlib":
        print(
            "[fetch] tier=local status=ok extractor=stdlib "
            "hint=\"安装 readability-lxml + html2text 可得到更干净的输出\"",
            file=sys.stderr,
        )
    else:
        print(f"[fetch] tier=local status=ok extractor={used}", file=sys.stderr)

    sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
