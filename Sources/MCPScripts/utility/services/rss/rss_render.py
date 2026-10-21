"""Markdown rendering, history dedup, and format self-checks for the RSS digest."""

from __future__ import annotations

import re
from pathlib import Path

_URL_RE = re.compile(r"https?://[^\s\"'<>)\]]+")
_CJK_RE = re.compile(r"[一-龥]")
_QUARTERS = {1: "一季度", 2: "二季度", 3: "三季度", 4: "四季度"}


def normalize_url(url: str) -> str:
    """Dedup key: strip query/fragment and trailing slash."""
    return re.sub(r"[?#].*$", "", (url or "").strip()).rstrip("/")


def collect_history_urls(root: Path, exclude: Path | None = None) -> set[str]:
    urls: set[str] = set()
    if not root.is_dir():
        return urls
    for path in root.rglob("*.md"):
        if exclude is not None and path == exclude:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for match in _URL_RE.finditer(text):
            urls.add(normalize_url(match.group(0)))
    urls.discard("")
    return urls


def archive_path(root: Path, day: str) -> Path:
    month = int(day[5:7])
    quarter = _QUARTERS[(month - 1) // 3 + 1]
    return root / day[:4] / quarter / f"{day}.md"


def decorate_title(title: str, translation: str) -> str:
    title = (title or "").strip()
    translation = (translation or "").strip()
    if not translation or translation == title or _CJK_RE.search(title):
        return title
    return f"{title}({translation})"


def render(day: str, articles: list[dict], filtered: list[dict]) -> str:
    lines = [f"# RSS 日报 — {day}", ""]
    if not articles:
        lines.append("今日无有效内容。")
        lines.append("")
    for item in articles:
        lines.extend(
            [
                "---",
                "",
                f"## [{decorate_title(item['title'], item.get('title_translation', ''))}]({item['url']})",
                "",
                f"> {(item.get('summary') or '').strip()}",
                "",
            ]
        )
    if articles:
        lines.extend(["---", ""])
    if filtered:
        lines.extend(["## 已过滤条目", ""])
        for item in filtered:
            title = (item.get("title") or item.get("url") or "").strip()
            url = (item.get("url") or "").strip()
            feed = (item.get("feed") or "").strip()
            reason = (item.get("reason") or "").strip()
            if url:
                lines.append(f"- [{title}]({url}) — [{feed}] {reason}")
            else:
                lines.append(f"- {title} — [{feed}] {reason}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def validate(text: str) -> list[str]:
    """Return format issues; rendering already guarantees the layout, so this is a guard only."""
    issues: list[str] = []
    for match in re.finditer(r"^## \[([^\]]+)\]\((http[^)]+)\)", text, re.MULTILINE):
        if not _CJK_RE.search(match.group(1)):
            issues.append(f"主条目标题无中文翻译：{match.group(1)[:50]}")
    if re.search(r"\]\(http[^)]*\)[（(][^）)]*[一-龥]", text):
        issues.append("存在 [英文](url)(中文) 格式残留")
    for match in re.finditer(
        r"^- \[[^\]]+\]\([^)]+\)\s*—\s*([^\s\[])", text, re.MULTILINE
    ):
        issues.append(f"过滤条目来源缺方括号：{match.group(0)[:60]}")
    return issues
