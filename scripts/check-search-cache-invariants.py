#!/usr/bin/env python3
"""校验向量检索缓存的两条不变量（2026-09-11 性能修复的回归门）。

背景：`project_search` 与 `project_notes` 各有一层 embedding 缓存，两条不变量都
是「看起来对、破坏后只是变慢或变旧」的隐性契约，重构时极易被无意打破：

  A. 符号缓存键必须覆盖 embedding 的全部输入字段
     - `symbols.id` 会因全量重扫（clearAll → DELETE + 重插）而整体换号，
       以 id 为键会让缓存每次重扫后全部失效（曾导致单次向量检索重算 349s）
     - 键若漏掉某个输入字段，字段变化时不会重算 → 返回陈旧向量

  B. 笔记缓存必须能感知深层文件的改动
     - 曾用「项目根目录 mtime」判断失效，而它只在直接子项增删时变化 →
       改深层已有文件被判为「未变」，返回陈旧搜索结果

用法（在项目根目录执行）：
    PYTHONPATH=Sources/MCPScripts \\
    FASTEMBED_CACHE_PATH=~/.cache/utility/fastembed \\
    ~/.config/utility/mcp-venv/bin/python3 scripts/check-search-cache-invariants.py

退出码 0 = 全部通过；1 = 有不变量被破坏。仅使用临时目录，不触碰真实数据。
"""

from __future__ import annotations

import os
import shutil
import sqlite3
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, os.path.join(_ROOT, "Sources", "MCPScripts"))

SYMBOL_TABLE_SQL = """
CREATE TABLE symbols (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
    signature TEXT, doc_comment TEXT, visibility TEXT,
    start_line INTEGER, end_line INTEGER)
"""

_failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"  {'✅' if ok else '❌'} {label}" + (f"  {detail}" if detail else ""))
    if not ok:
        _failures.append(label)


def _new_symbol_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute(SYMBOL_TABLE_SQL)
    return conn


def _insert(conn: sqlite3.Connection, sig: str, start_line: int | None = None) -> None:
    conn.execute(
        "INSERT INTO symbols (file_path, name, kind, signature, start_line) "
        "VALUES ('/p/a.swift', 'alpha', 'func', ?, ?)",
        (sig, start_line),
    )
    conn.commit()


def check_symbol_cache_key(tmp: str) -> None:
    """A. 符号缓存键不变量。

    判定用「本轮实际嵌入了几条」（包一层计数 embedder）而不是「向量是否相同」——
    单条符号重算得到的向量本来就与缓存值逐位相同，比向量测不出「白重算」这个缺陷。
    """
    print("\nA. 符号缓存键（symbol_embeddings）")

    import server_search as S

    db = os.path.join(tmp, "symbols.sqlite")
    conn = _new_symbol_db(db)
    _insert(conn, "func alpha()")

    real_getter = S._get_shared_embedder
    embedded: list[str] = []

    class _CountingEmbedder:
        def __init__(self, inner):
            self._inner = inner

        def embed(self, texts):
            texts = list(texts)
            embedded.extend(texts)
            return self._inner.embed(texts)

    def run() -> None:
        embedded.clear()
        S._get_shared_embedder = lambda: _CountingEmbedder(real_getter())
        try:
            S._ensure_symbol_embeddings(db)
        finally:
            S._get_shared_embedder = real_getter

    def edge_rows() -> int:
        return conn.execute("SELECT COUNT(*) FROM symbol_embeddings").fetchone()[0]

    run()
    check("首次为符号计算 embedding", len(embedded) == 1, f"实际 {len(embedded)} 条")

    # A1: 仅 id 变化（模拟 clearAll 后的 DELETE + 重插）→ 不得重算、不得留孤儿
    conn.execute("DELETE FROM symbols")
    _insert(conn, "func alpha()")
    run()
    check(
        "重扫换 id 后不重算",
        len(embedded) == 0,
        f"重算了 {len(embedded)} 条 —— 失败 = 键又绑回了易漂移的 symbols.id",
    )
    check(
        "重扫后边表无孤儿累积",
        edge_rows() == 1,
        f"边表 {edge_rows()} 行（存活符号 1 个）",
    )

    # A2: 参与 embedding 文本的字段变化 → 必须重算
    conn.execute("UPDATE symbols SET signature='func alpha(x: Int, y: Int) -> R'")
    conn.commit()
    run()
    check(
        "签名变化后必须重算",
        len(embedded) == 1,
        f"实际 {len(embedded)} 条 —— 失败 = 键漏掉了 signature，会返回陈旧向量",
    )

    # A3: 不参与 embedding 文本的字段变化 → 不应重算
    conn.execute("UPDATE symbols SET start_line=999")
    conn.commit()
    run()
    check(
        "仅行号漂移不触发重算",
        len(embedded) == 0,
        f"重算了 {len(embedded)} 条 —— 失败 = 键里混进了位置字段",
    )

    # A4: 符号被删除后，其 embedding 必须被清理（否则边表无界增长）
    conn.execute("DELETE FROM symbols")
    conn.commit()
    run()
    check("符号删除后边表无孤儿", edge_rows() == 0, f"残留 {edge_rows()} 行")

    # A5: DB 内容变化但进程未重启 → 内存缓存必须失效
    # 缺陷形态：缓存只按 db_path 查，DB 被重扫后仍返回旧符号元数据（旧路径、已删符号），
    # 新符号也搜不到，直到进程重启。关键是**不清内存缓存**去调用，才测得出这个缺陷。
    conn.execute("DELETE FROM symbol_embeddings")
    conn.execute("DELETE FROM symbols")
    conn.commit()
    _insert(conn, "func alpha()")
    # 先经 _search_vectors 预热内存缓存（_ensure_symbol_embeddings 本身不填该缓存）
    S._symbol_embeddings.clear()
    S._search_vectors(db, "warmup")
    rows_before = edge_rows()

    # 新增一个符号并提交：DB 内容与文件 mtime 同时变化，而进程缓存仍停在旧状态
    conn.execute(
        "INSERT INTO symbols (file_path,name,kind,signature) "
        "VALUES ('/p/b.swift','beta','var','var beta')"
    )
    conn.commit()
    S._search_vectors(db, "beta")  # 不清 _symbol_embeddings
    rows_after = edge_rows()
    check(
        "DB 变化后缓存失效并为新符号建 embedding",
        rows_after == rows_before + 1,
        f"边表 {rows_before} → {rows_after} —— 未增长说明仍在用陈旧的内存缓存",
    )
    conn.close()


def check_note_cache_freshness(tmp: str) -> None:
    """B. 笔记缓存失效判定不变量。"""
    import server_search as S

    root = os.path.join(tmp, "notes_project")
    deep = os.path.join(root, "deep", "nested")
    os.makedirs(deep, exist_ok=True)

    def write(path: str, marker: str) -> None:
        with open(os.path.join(root, path), "w", encoding="utf-8") as fh:
            fh.write(f"# 标题\n\n{marker}" + "填充内容" * 40)

    write("README.md", "顶层标记")
    write("deep/nested/doc.md", "深层标记甲")
    S._ensure_note_cache(root)

    # B1: 无改动 → 命中缓存
    conn, _, _ = S._ensure_note_cache(root)
    conn.close()

    # B2: 改深层已有文件 → 必须被感知。
    #     关键前置：此操作不改变项目根目录 mtime，正是旧实现漏判的场景。
    root_mtime_before = os.stat(root).st_mtime
    write("deep/nested/doc.md", "深层标记乙")
    root_mtime_unchanged = os.stat(root).st_mtime == root_mtime_before

    conn, db_path, _ = S._ensure_note_cache(root)
    hit = conn.execute(
        "SELECT COUNT(*) FROM chunks WHERE file_path LIKE '%doc.md' "
        "AND chunk_text LIKE '%深层标记乙%'"
    ).fetchone()[0]
    conn.close()
    check(
        "深层文件改动能被感知",
        hit > 0,
        "失败 = 又用回了目录 mtime 做快速跳过"
        + ("（本次改动确实未改变根目录 mtime）" if root_mtime_unchanged else ""),
    )

    # B3: 文件缩短时旧的尾部 chunk 必须消失
    write("deep/nested/doc.md", "只剩一段" + "填充内容" * 10)
    conn, _, _ = S._ensure_note_cache(root)
    n = conn.execute(
        "SELECT COUNT(*) FROM chunks WHERE file_path LIKE '%doc.md'"
    ).fetchone()[0]
    conn.close()
    check("文件缩短后旧 chunk 被清除", n == 1, f"残留 {n} 个 chunk")

    shutil.rmtree(root, ignore_errors=True)


def main() -> int:
    tmp = tempfile.mkdtemp(prefix="utility-cache-invariants-")
    try:
        check_symbol_cache_key(tmp)
        check_note_cache_freshness(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    if _failures:
        print(f"❌ 不变量被破坏 {len(_failures)} 项：")
        for f in _failures:
            print(f"   - {f}")
        return 1
    print("✅ 全部不变量通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
