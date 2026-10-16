#!/usr/bin/env python3
"""Drop results that are not actually about the query.

Usage:
    python3 parse_xxx.py <html> | python3 filter_results.py <query>

Why this is needed: Bing answers a multi-word query with single-word dictionary pages —
searching "eventual consistency" returns the Cambridge entry for "eventual", and a long
Chinese query degrades the same way (searching "端到端原则" yields the dictionary entry
for the character "端"). Those pages come in numbers large enough that the cascade takes
them for "enough results" and stops.
"""

import re
import sys


def overlap(a: str, b: str) -> int:
    """Length of the longest common substring of a and b."""
    best = 0
    for i in range(len(a)):
        for j in range(i + best + 1, len(a) + 1):
            if a[i:j] in b:
                best = j - i
            else:
                break
    return best


def matches(title: str, snippet: str, query: str) -> bool:
    hay = (title + " " + snippet).lower()
    q = query.lower().strip()
    if not q:
        return True
    if q in hay:
        return True
    terms = [t for t in q.split() if t]
    if len(terms) > 1:
        return all(t in hay for t in terms)
    # Threshold 4: taking only the first two characters lets same-prefix but unrelated
    # concepts through ("观察者模式" → "观察者网"; "CAP定理" starts with ca → the dictionary
    # entry for "cap")
    return overlap(q, hay) >= min(len(q), 4)


def main() -> None:
    query = sys.argv[1] if len(sys.argv) > 1 else ""
    raw = sys.stdin.read()
    kept = 0
    for block in re.split(r"(?m)^(?=\[\d+\] )", raw):
        if not block.strip():
            continue
        lines = block.splitlines()
        title = re.sub(r"^\[\d+\]\s*", "", lines[0]).strip()
        # The snippet line's field name differs between the Chinese and English parsers
        # ("摘要:" vs "Snippet:"), so take everything but the title and the URL/date lines
        # rather than looking for a particular key.
        body = " ".join(
            line.strip()
            for line in lines[1:]
            if not line.strip().startswith(("URL:", "Date:", "日期:"))
        )
        if not matches(title, body, query):
            continue
        kept += 1
        print(f"[{kept}] {title}")
        for line in lines[1:]:
            print(line)


if __name__ == "__main__":
    main()
