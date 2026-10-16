#!/usr/bin/env python3
"""按查询词过滤结果,丢弃搜索引擎降级给出的无关条目。

用法:
    python3 parse_xxx.py <html> | python3 filter_results.py <查询词>

为什么需要:Bing 对多词查询会退化成字词词典页 —— 搜「eventual consistency」
返回的是「EVENTUAL 中文翻译·剑桥词典」,中文长查询同理(搜「端到端原则」给出
「端」字词典)。这类条目条数足够多,会让级联误判「已拿到足够结果」而停下,
把无关内容当有效结果返回。
"""

import re
import sys


def overlap(a: str, b: str) -> int:
    """a、b 的最长公共子串长度。"""
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
    # 门槛 4:只取前两字符会把同前缀的异概念全放进来(「观察者模式」→「观察者网」、
    # 「CAP定理」前两字符是 ca → 词典的 cap 条目)
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
        # 摘要字段名中英不一致（parse_*.py 输出「摘要:」或「Snippet:」），故不按键名取，
        # 而是把标题与 URL/日期之外的正文一并作为匹配文本
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
