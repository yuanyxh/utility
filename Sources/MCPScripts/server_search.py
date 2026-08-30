"""server 的项目依赖图查询 + 笔记语义检索模块。

从 server.py 拆分（2026-08-30，重构阶段4）：项目符号/文件/Package 搜索
（tool_project_* 底层函数 + FTS/LIKE/向量多层检索）、project_notes 语义检索。
代码原样搬移不改逻辑。

注意：
- 本模块不 import mem0/qdrant——server.py 的模块级副作用顺序
  （POSTHOG_DISABLED/MEM0_TELEMETRY + _patch_mem0_fastembed 先于 import mem0）
  不受影响。
- 共享 embedder 在 server_embed.py（_get_shared_embedder/EMBEDDER_DIMS）；
  tool_project_* 是底层函数（返回 dict），MCP handler 包装器（_handle_project_*，
  @_register 装饰）留在 server.py，import 本模块的底层函数后经 arguments 解析调用。
"""

from __future__ import annotations

import os
import sqlite3
import threading

import numpy as np

from log_utils import setup_logging
from server_embed import _get_shared_embedder
from synonyms import SYNONYM_MAP

# ---------------------------------------------------------------------------
# 配置（与拆分前 server.py 一致；NOTE_*/PROJECT_MARKER_* 为 server 专属）
# ---------------------------------------------------------------------------

NOTE_DB_FILENAME = "note_vectors.sqlite"
NOTE_EXCLUDE_DIRS = frozenset(
    {
        ".build",
        "node_modules",
        "dist",
        ".git",
        ".utility",
        "Pods",
        ".venv",
        "__pycache__",
        ".svn",
        ".hg",
        ".gradle",
        "build",
        "DerivedData",
        "Utility.app",
    }
)
NOTE_CHUNK_MIN_SIZE = 50
NOTE_CHUNK_MAX_SIZE = 512
NOTE_CHUNK_OVERLAP = 48
NOTE_SIMILARITY_THRESHOLD = 0.35
NOTE_MAX_CHUNKS_PER_PROJECT = 50000
NOTE_MAX_RESULTS = 20
NOTE_PREVIEW_LEN = 300
PROJECT_MARKER_FILES = frozenset(
    {
        # JS/TS
        "package.json",
        "package-lock.json",
        "yarn.lock",
        "pnpm-lock.yaml",
        # Swift/Apple
        "Package.swift",
        "Podfile",
        "Podfile.lock",
        # Go
        "go.mod",
        "go.sum",
        # Rust
        "Cargo.toml",
        # Java/Kotlin
        "pom.xml",
        "build.gradle",
        "build.gradle.kts",
        "settings.gradle",
        # Python
        "requirements.txt",
        "pyproject.toml",
        "setup.py",
        "Pipfile",
        # 其他
        "composer.json",
        "Gemfile",
        "mix.exs",
    }
)
PROJECT_MARKER_MAX_DEPTH = 2
PROJECT_MARKER_FILE_SUFFIXES = (".csproj", ".sln")
PROJECT_MARKER_DIR_SUFFIXES = (".xcodeproj", ".xcworkspace")
_MAX_VECTOR_CACHE = 3
_MAX_VECTOR_ROWS = 50000
_symbol_embeddings: dict[str, tuple[list[dict], np.ndarray | None]] = {}
_note_cache_lock = threading.Lock()

logger = setup_logging("server")

_HAS_PATHSPEC = False
try:
    import pathspec

    _HAS_PATHSPEC = True
except ImportError:
    pass


def expand_query(query: str) -> str:
    terms = query.lower().split()
    expanded = set(terms)
    for term in terms:
        if term in SYNONYM_MAP:
            for syn in SYNONYM_MAP[term].split():
                expanded.add(syn)
    return " OR ".join(f'"{t}"' if " " in t else t for t in expanded)


def _search_symbols_fts(
    db_path: str, expanded: str, file_path: str, kind: str
) -> list[dict] | None:
    """Layer 1a: FTS5 symbol search. Returns None if FTS5 unavailable (degrade to LIKE)."""
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        sql = (
            "SELECT s.name, s.kind, s.signature, s.file_path, s.visibility, "
            "s.start_line, s.end_line "
            "FROM symbols s JOIN symbols_fts fts ON s.id = fts.rowid "
            "WHERE symbols_fts MATCH ?"
        )
        params: list[str] = [expanded]
        if file_path:
            sql += " AND s.file_path LIKE ?"
            params.append(f"%{file_path}%")
        if kind:
            sql += " AND s.kind = ?"
            params.append(kind)
        sql += " ORDER BY rank LIMIT 30"
        return [
            {
                "name": r["name"],
                "kind": r["kind"],
                "signature": r["signature"],
                "file": r["file_path"],
                "visibility": r["visibility"],
                "startLine": r["start_line"],
                "endLine": r["end_line"],
            }
            for r in conn.execute(sql, params).fetchall()
        ]
    except sqlite3.OperationalError:
        return None
    finally:
        conn.close()


def _search_symbols_like(
    db_path: str, query: str, file_path: str, kind: str
) -> list[dict]:
    """Layer 1b: LIKE fallback when FTS5 is unavailable."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        sql = (
            "SELECT name, kind, signature, file_path, visibility, start_line, end_line "
            "FROM symbols WHERE (name LIKE ? OR signature LIKE ?)"
        )
        params: list[str] = [f"%{query}%", f"%{query}%"]
        if file_path:
            sql += " AND file_path LIKE ?"
            params.append(f"%{file_path}%")
        if kind:
            sql += " AND kind = ?"
            params.append(kind)
        sql += " LIMIT 30"
        return [
            {
                "name": r["name"],
                "kind": r["kind"],
                "signature": r["signature"],
                "file": r["file_path"],
                "visibility": r["visibility"],
                "startLine": r["start_line"],
                "endLine": r["end_line"],
            }
            for r in conn.execute(sql, params).fetchall()
        ]
    finally:
        conn.close()


def _search_files(db_path: str, query: str) -> list[dict]:
    """Layer 2: Search files table by name or path."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        like = f"%{query}%"
        rows = conn.execute(
            "SELECT path, name, ext FROM files "
            "WHERE name LIKE ? OR path LIKE ? "
            "ORDER BY CASE WHEN name LIKE ? THEN 0 ELSE 1 END "
            "LIMIT 10",
            [like, like, f"{query}%"],
        ).fetchall()
        return [
            {
                "name": r["name"],
                "kind": "file",
                "file": r["path"],
                "signature": f".{r['ext']}",
                "visibility": None,
            }
            for r in rows
        ]
    finally:
        conn.close()


def _search_packages(db_path: str, query: str) -> list[dict]:
    """Layer 3: Search packages table by name or description."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        like = f"%{query}%"
        rows = conn.execute(
            "SELECT name, version, type, description FROM packages "
            "WHERE name LIKE ? OR description LIKE ? "
            "LIMIT 10",
            [like, like],
        ).fetchall()
        return [
            {
                "name": r["name"],
                "kind": "package",
                "file": None,
                "signature": f"{r['type']}{'@' + r['version'] if r['version'] else ''}",
                "visibility": None,
            }
            for r in rows
        ]
    finally:
        conn.close()


def _ensure_symbol_embeddings(db_path: str) -> tuple[list[dict], np.ndarray | None]:
    """Persist symbol embeddings in SQLite, lazily fill missing ones.

    1. Creates/uses symbol_embeddings side-table in deps.sqlite
    2. Detects symbols without embeddings and computes them incrementally
    3. Returns (symbols_list, embedding_matrix)
    """
    emb = _get_shared_embedder()
    if emb is None:
        return [], None

    conn = sqlite3.connect(db_path, timeout=5)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")

        # 创建 side-table（与 GRDB 管理的 symbols 表解耦）
        conn.execute("""
            CREATE TABLE IF NOT EXISTS symbol_embeddings (
                symbol_id INTEGER PRIMARY KEY,
                embedding BLOB NOT NULL
            )
        """)

        # 找出没有 embedding 的 symbol，增量计算
        missing = conn.execute(
            """
            SELECT s.id, s.name, s.signature, COALESCE(s.doc_comment, '') AS doc
            FROM symbols s LEFT JOIN symbol_embeddings se ON s.id = se.symbol_id
            WHERE se.symbol_id IS NULL
            LIMIT ?
        """,
            (_MAX_VECTOR_ROWS,),
        ).fetchall()

        if missing:
            batches = [missing[i : i + 32] for i in range(0, len(missing), 32)]
            for batch in batches:
                texts = []
                for r in batch:
                    text = r["name"]
                    if r["signature"]:
                        text += " " + r["signature"]
                    if r["doc"]:
                        text += " " + r["doc"]
                    texts.append(text)

                embeddings = list(emb.embed(texts))
                for r, vec in zip(batch, embeddings):
                    vec_bytes = np.asarray(vec, dtype=np.float32).tobytes()
                    conn.execute(
                        "INSERT OR REPLACE INTO symbol_embeddings (symbol_id, embedding) VALUES (?, ?)",
                        (r["id"], vec_bytes),
                    )
                conn.commit()

        # 从 SQLite 读取所有 embedding
        rows = conn.execute(
            """
            SELECT s.name, s.signature, s.file_path, se.embedding
            FROM symbols s
            JOIN symbol_embeddings se ON s.id = se.symbol_id
            LIMIT ?
        """,
            (_MAX_VECTOR_ROWS,),
        ).fetchall()

        if not rows:
            return [], None

        symbols = []
        vectors = []
        for r in rows:
            try:
                vec = np.frombuffer(r["embedding"], dtype=np.float32).copy()
                norm = np.linalg.norm(vec)
                if norm < 1e-10:
                    continue
                vectors.append(vec / norm)
                symbols.append(
                    {
                        "name": r["name"],
                        "file": r["file_path"],
                        "signature": r["signature"],
                    }
                )
            except Exception:
                continue

        if not vectors:
            return [], None

        return symbols, np.array(vectors, dtype=np.float32)

    except Exception as e:
        logger.warning(f"[symbol_embeddings] init failed: {e}")
        return [], None
    finally:
        conn.close()


def _search_vectors(db_path: str, query: str) -> list[dict]:
    """Layer 4: Vector similarity search against persisted symbol embeddings.

    Persists embeddings in SQLite (symbol_embeddings side-table) so cold
    starts read from disk (~70ms) instead of recomputing from scratch (~110s).
    Missing embeddings are filled lazily on next query.
    In-memory cache keeps subsequent calls fast.
    """
    try:
        # Lazy-load from SQLite + cache in memory
        if db_path not in _symbol_embeddings:
            symbols, emb_matrix = _ensure_symbol_embeddings(db_path)
            # 淘汰最旧缓存
            while len(_symbol_embeddings) >= _MAX_VECTOR_CACHE:
                oldest = next(iter(_symbol_embeddings))
                logger.info(f"[vector] evicting cached embeddings for: {oldest}")
                del _symbol_embeddings[oldest]
            _symbol_embeddings[db_path] = (symbols, emb_matrix)

        symbols, emb_matrix = _symbol_embeddings[db_path]
        if emb_matrix is None or len(symbols) == 0:
            return []

        # Encode query + normalize
        emb = _get_shared_embedder()
        query_emb = list(emb.embed([query]))[0]
        qnorm = np.linalg.norm(query_emb)
        if qnorm < 1e-10:
            return []
        query_emb = query_emb / qnorm

        sims = np.dot(emb_matrix, query_emb)

        threshold = 0.35
        indices = np.argsort(-sims)
        results = []
        for idx in indices:
            if sims[idx] < threshold:
                break
            results.append(
                {
                    "name": symbols[idx]["name"],
                    "kind": "symbol",
                    "file": symbols[idx]["file"],
                    "signature": symbols[idx]["signature"],
                    "visibility": None,
                    "score": round(float(sims[idx]), 4),
                }
            )
            if len(results) >= 5:
                break
        return results

    except Exception as e:
        logger.warning(f"[vector_search] {e}")
        return []


def _load_gitignore(project_path: str):
    """Load .gitignore patterns as a PathSpec (or None)."""
    gi = os.path.join(project_path, ".gitignore")
    if not os.path.isfile(gi):
        return None
    try:
        with open(gi, "r") as f:
            spec = pathspec.PathSpec.from_lines(
                pathspec.patterns.GitIgnoreSpecPattern, f
            )
        return spec
    except Exception:
        return None


def _is_ignored(abs_path: str, ignore_spec, project_root: str, is_dir: bool) -> bool:
    """Check if a path is ignored by .gitignore spec."""
    if ignore_spec is None:
        return False
    try:
        rel = os.path.relpath(abs_path, project_root)
        return ignore_spec.match_file(rel) or (
            is_dir and ignore_spec.match_file(rel + "/")
        )
    except Exception:
        return False


def _scan_md_files(project_path: str) -> list[dict]:
    """Recursively scan .md files under project_path, respecting exclusions."""
    ignore_spec = _load_gitignore(project_path)
    files = []
    try:
        for root, dirs, names in os.walk(project_path, followlinks=False):
            # In-place pruning of excluded directories
            dirs[:] = [d for d in dirs if d not in NOTE_EXCLUDE_DIRS]
            # Also check .gitignore on remaining dirs when pathspec available
            if _HAS_PATHSPEC and ignore_spec is not None and root != project_path:
                dirs[:] = [
                    d
                    for d in dirs
                    if not _is_ignored(
                        os.path.join(root, d), ignore_spec, project_path, is_dir=True
                    )
                ]

            for name in names:
                if not name.endswith(".md"):
                    continue
                fpath = os.path.join(root, name)
                if _is_ignored(fpath, ignore_spec, project_path, is_dir=False):
                    continue
                try:
                    st = os.stat(fpath)
                except OSError:
                    continue
                files.append({"path": fpath, "mtime": st.st_mtime, "size": st.st_size})
    except Exception as e:
        logger.warning(f"[project_notes] scan error: {e}")
    return files


def _chunk_md_text(text: str, file_path: str) -> list[dict]:
    """Split markdown text into chunks by paragraph, with max-size enforcement."""
    chunks = []
    paragraphs = text.split("\n\n")
    line_count = 1

    for para in paragraphs:
        stripped = para.strip()
        if not stripped or len(stripped) < NOTE_CHUNK_MIN_SIZE:
            line_count += para.count("\n") + 1
            continue

        if len(stripped) <= NOTE_CHUNK_MAX_SIZE:
            chunks.append(
                {
                    "file_path": file_path,
                    "chunk_index": len(chunks),
                    "chunk_text": stripped,
                    "line_start": line_count,
                }
            )
        else:
            sub = _split_long_text(stripped, file_path, line_count)
            chunks.extend(sub)

        line_count += para.count("\n") + 1

    return chunks


def _split_long_text(text: str, file_path: str, base_line: int) -> list[dict]:
    """Split a long paragraph into overlapping chunks by line."""
    lines = text.split("\n")
    chunks = []
    current_lines: list[str] = []
    current_len = 0
    line_offset = 0

    for idx, line in enumerate(lines):
        current_lines.append(line)
        current_len += len(line) + 1  # +1 for the newline
        if current_len >= NOTE_CHUNK_MAX_SIZE:
            chunk_text = "\n".join(current_lines)
            chunks.append(
                {
                    "file_path": file_path,
                    "chunk_index": len(chunks),
                    "chunk_text": chunk_text,
                    "line_start": base_line + line_offset,
                }
            )
            # Rewind for overlap: drop lines until we're below overlap threshold
            overlap_len = 0
            rewound: list[str] = []
            for l in reversed(current_lines):
                if overlap_len >= NOTE_CHUNK_OVERLAP and rewound:
                    break
                rewound.insert(0, l)
                overlap_len += len(l) + 1
            current_lines = rewound
            current_len = overlap_len
            line_offset = idx + 1 - len(current_lines)

    if current_lines:
        chunk_text = "\n".join(current_lines)
        chunks.append(
            {
                "file_path": file_path,
                "chunk_index": len(chunks),
                "chunk_text": chunk_text,
                "line_start": base_line + line_offset,
            }
        )

    return chunks


def _get_note_db(db_path: str) -> sqlite3.Connection:
    """Open note_vectors.sqlite with WAL mode, create schema if needed."""
    conn = sqlite3.connect(db_path, timeout=5)
    conn.row_factory = sqlite3.Row
    with conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS chunks (
                file_path TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                chunk_text TEXT NOT NULL,
                line_start INTEGER NOT NULL DEFAULT 0,
                mtime REAL NOT NULL,
                file_size INTEGER NOT NULL,
                embedding BLOB,
                PRIMARY KEY (file_path, chunk_index)
            )
        """)
    return conn


def _ensure_note_cache(
    project_path: str,
) -> tuple[sqlite3.Connection, str, int]:
    """Incremental cache update: scan .md files, diff mtime/size, embed only changed."""
    project_path = os.path.normpath(project_path)
    cache_dir = os.path.join(project_path, ".utility")
    os.makedirs(cache_dir, exist_ok=True)
    db_path = os.path.join(cache_dir, NOTE_DB_FILENAME)

    conn = _get_note_db(db_path)

    # 快速跳过：项目目录 mtime 未变 → 无需扫描
    try:
        last_build = conn.execute("SELECT MAX(mtime) FROM chunks").fetchone()[0]
        project_mtime = os.stat(project_path).st_mtime
        if last_build is not None and project_mtime <= last_build:
            total_chunks = conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
            return conn, db_path, total_chunks
    except (sqlite3.DatabaseError, OSError):
        pass

    # 序列化重建：同时多个请求到来时只跑一次 embedding（ONNX 推理阻塞且内存密集）
    _note_cache_lock.acquire()
    try:
        md_files = _scan_md_files(project_path)
        cached = {}
        try:
            rows = conn.execute(
                "SELECT DISTINCT file_path, mtime, file_size FROM chunks"
            ).fetchall()
            cached = {r[0]: {"mtime": r[1], "size": r[2]} for r in rows}
        except sqlite3.DatabaseError:
            conn.close()
            try:
                os.remove(db_path)
            except OSError:
                pass
            conn = _get_note_db(db_path)

        changed = [
            mf
            for mf in md_files
            if mf["path"] not in cached
            or cached[mf["path"]]["mtime"] != mf["mtime"]
            or cached[mf["path"]]["size"] != mf["size"]
        ]

        if changed:
            logger.info(
                f"[project_notes] {project_path}: {len(changed)} files need embedding "
                f"(of {len(md_files)} total .md files)"
            )
            emb = _get_shared_embedder()
            if emb is None:
                logger.warning(
                    "[project_notes] embedder unavailable, skipping embedding"
                )

            for mf in changed:
                try:
                    conn.execute(
                        "DELETE FROM chunks WHERE file_path = ?", (mf["path"],)
                    )
                    with open(
                        mf["path"], "r", encoding="utf-8", errors="replace"
                    ) as fh:
                        text = fh.read()
                    chunks = _chunk_md_text(text, mf["path"])
                    if not chunks:
                        continue

                    total = conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
                    if total + len(chunks) > NOTE_MAX_CHUNKS_PER_PROJECT:
                        logger.warning(
                            f"[project_notes] {project_path}: "
                            f"truncating at {NOTE_MAX_CHUNKS_PER_PROJECT} chunks"
                        )
                        chunks = chunks[: NOTE_MAX_CHUNKS_PER_PROJECT - total]
                        if not chunks:
                            continue

                    if emb is not None:
                        texts = [c["chunk_text"] for c in chunks]
                        embeddings = list(emb.embed(texts))
                        for c, vec in zip(chunks, embeddings):
                            vec_bytes = np.asarray(vec, dtype=np.float32).tobytes()
                            conn.execute(
                                "INSERT OR REPLACE INTO chunks "
                                "VALUES (?,?,?,?,?,?,?)",
                                (
                                    mf["path"],
                                    c["chunk_index"],
                                    c["chunk_text"],
                                    c["line_start"],
                                    mf["mtime"],
                                    mf["size"],
                                    vec_bytes,
                                ),
                            )
                    else:
                        # No embedder: store without embedding (keyword fallback later)
                        for c in chunks:
                            conn.execute(
                                "INSERT OR REPLACE INTO chunks "
                                "(file_path, chunk_index, chunk_text, line_start, mtime, file_size) "
                                "VALUES (?,?,?,?,?,?)",
                                (
                                    mf["path"],
                                    c["chunk_index"],
                                    c["chunk_text"],
                                    c["line_start"],
                                    mf["mtime"],
                                    mf["size"],
                                ),
                            )
                    conn.commit()
                except Exception as e:
                    logger.warning(
                        f"[project_notes] error processing {mf['path']}: {e}"
                    )
                    conn.rollback()
                    continue

        total_chunks = conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        return conn, db_path, total_chunks
    finally:
        _note_cache_lock.release()


def _is_dev_project(project_path: str) -> bool:
    """浅层扫描目标路径是否含常见工程特征文件 —— 判定是否为「开发项目」。

    纯文档仓库(如 notes:只有 .md + .git)不含这些特征 → 返回 False,
    从而让 project_notes 对非开发项目走纯内存 keyword 搜索,不再创建 .utility 缓存。
    注意:刻意不含 .git/.gitignore(notes 等文档仓库也有),避免误判。
    """
    project_path = os.path.normpath(project_path)

    def _scan(root: str, depth: int) -> bool:
        if depth > PROJECT_MARKER_MAX_DEPTH:
            return False
        try:
            with os.scandir(root) as it:
                for entry in it:
                    if entry.is_dir():
                        if entry.name in NOTE_EXCLUDE_DIRS:
                            continue
                        if entry.name.endswith(PROJECT_MARKER_DIR_SUFFIXES):
                            return True
                        if _scan(entry.path, depth + 1):
                            return True
                    elif entry.is_file():
                        if entry.name in PROJECT_MARKER_FILES:
                            return True
                        if entry.name.endswith(PROJECT_MARKER_FILE_SUFFIXES):
                            return True
        except OSError:
            pass
        return False

    return _scan(project_path, 0)


def _keyword_search_uncached(project_path: str, query: str, limit: int) -> dict:
    """非开发项目降级路径:纯内存 keyword 搜索,不创建 .utility 缓存。

    与 _query_project_notes 的 keyword fallback 逻辑一致,但直接扫文件
    切块匹配,不落盘 SQLite。notes 这类目录反复查询不会产生磁盘残留。
    """
    tokens = [t for t in query.split() if t]
    results: list[dict] = []
    seen: set[tuple[str, int]] = set()

    for mf in _scan_md_files(project_path):
        try:
            with open(mf["path"], "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        for c in _chunk_md_text(text, mf["path"]):
            ct = c["chunk_text"]
            if not tokens or not any(t.lower() in ct.lower() for t in tokens):
                continue
            matched = sum(1 for t in tokens if t.lower() in ct.lower())
            key = (mf["path"], c["chunk_index"])
            if key in seen:
                continue
            seen.add(key)
            results.append(
                {
                    "file": os.path.relpath(mf["path"], project_path),
                    "line": c["line_start"],
                    "content": ct[:NOTE_PREVIEW_LEN],
                    "score": round(matched / max(len(tokens), 1), 4),
                }
            )

    results.sort(key=lambda x: -x["score"])
    return {
        "results": results[:limit],
        "count": min(len(results), limit),
        "total_chunks": len(seen),
    }


def _query_project_notes(project_path: str, query: str, limit: int) -> dict:
    """Semantic search over project .md files using cached vectors."""
    limit = max(1, min(limit, NOTE_MAX_RESULTS))

    # 非开发项目(无工程特征文件):不落 .utility 缓存,纯内存 keyword 搜索
    if not _is_dev_project(project_path):
        logger.info(
            f"[project_notes] non-dev project, uncached keyword search: {project_path}"
        )
        return _keyword_search_uncached(project_path, query, limit)

    try:
        conn, db_path, total_chunks = _ensure_note_cache(project_path)
    except Exception as e:
        logger.error(f"[project_notes] cache init failed: {e}")
        return {"error": f"Cache init failed: {e}", "results": [], "count": 0}

    try:
        rows = conn.execute(
            "SELECT file_path, chunk_index, chunk_text, line_start, embedding FROM chunks"
        ).fetchall()
    except sqlite3.DatabaseError as e:
        conn.close()
        logger.error(f"[project_notes] db error: {e}")
        return {"error": f"DB error: {e}", "results": [], "count": 0}

    conn.close()

    if not rows:
        return {"results": [], "count": 0, "total_chunks": total_chunks}

    # Try vector search first
    emb = _get_shared_embedder()
    vector_results: list[dict] = []

    if emb is not None:
        try:
            query_vec = list(emb.embed([query]))[0].astype(np.float32)
            qnorm = np.linalg.norm(query_vec)
            if qnorm > 1e-10:
                query_vec = query_vec / qnorm

                entries = []
                vectors = []
                for r in rows:
                    blob = r["embedding"]
                    if blob is None:
                        continue
                    try:
                        vec = np.frombuffer(blob, dtype=np.float32).copy()
                        norm = np.linalg.norm(vec)
                        if norm > 1e-10:
                            vectors.append(vec / norm)
                        else:
                            vectors.append(vec)
                        entries.append(
                            {
                                "file_path": r["file_path"],
                                "chunk_text": r["chunk_text"],
                                "line_start": r["line_start"],
                            }
                        )
                    except Exception:
                        continue

                if vectors:
                    matrix = np.array(vectors, dtype=np.float32)
                    sims = np.dot(matrix, query_vec)
                    indices = np.argsort(-sims)
                    for idx in indices:
                        if sims[idx] < NOTE_SIMILARITY_THRESHOLD:
                            break
                        if len(vector_results) >= limit:
                            break
                        e = entries[idx]
                        vector_results.append(
                            {
                                "file": os.path.relpath(e["file_path"], project_path),
                                "line": e["line_start"],
                                "content": e["chunk_text"][:NOTE_PREVIEW_LEN],
                                "score": round(float(sims[idx]), 4),
                            }
                        )

            if vector_results:
                pass  # fall through to keyword merge below
        except Exception as e:
            logger.warning(f"[project_notes] vector search failed: {e}")

    # Keyword search (grep-lite) — 始终执行，精确匹配结果插到 vector 结果前面
    tokens = [t for t in query.split() if t]
    keyword_results: list[dict] = []
    seen_files: set[tuple[str, int]] = set()

    for r in rows:
        text = r["chunk_text"]
        if not tokens or not any(t.lower() in text.lower() for t in tokens):
            continue
        matched = sum(1 for t in tokens if t.lower() in text.lower())
        key = (r["file_path"], r["chunk_index"])
        if key in seen_files:
            continue
        seen_files.add(key)
        keyword_results.append(
            {
                "file": os.path.relpath(r["file_path"], project_path),
                "line": r["line_start"],
                "content": text[:NOTE_PREVIEW_LEN],
                "score": round(matched / max(len(tokens), 1), 4),
            }
        )

    keyword_results.sort(key=lambda x: -x["score"])

    if vector_results:
        # 精确匹配插到 vector 结果前面（vector search 对中文/跨语言查询可能排不准）
        seen_keys = {(r["file"], r["line"]) for r in vector_results}
        exact_hits = [
            r for r in keyword_results if (r["file"], r["line"]) not in seen_keys
        ]
        merged = exact_hits + vector_results
        return {
            "results": merged[:limit],
            "count": len(merged[:limit]),
            "total_chunks": total_chunks,
        }

    return {
        "results": keyword_results[:limit],
        "count": len(keyword_results[:limit]),
        "total_chunks": total_chunks,
    }


def tool_project_search(
    db_path: str,
    query: str,
    file_path: str = "",
    kind: str = "",
) -> dict:
    """Multi-layer project search.

    Chains: FTS5 symbols → LIKE symbols → files → packages → vector similarity.
    Always runs all layers, deduplicates results, returns combined output.
    """
    if not os.path.isfile(db_path):
        return {"error": f"Database not found: {db_path}"}

    expanded = expand_query(query)
    active_layers: list[str] = []
    all_found: list[dict] = []
    seen: set[tuple[str, str]] = set()  # (name, file_path) dedup key

    def _add(results: list[dict], layer: str):
        if not results:
            return
        active_layers.append(layer)
        for r in results:
            key = (r["name"], r.get("file") or "")
            if key not in seen:
                seen.add(key)
                all_found.append(r)

    # Layer 1a: FTS5 symbol search (primary)
    fts_results = _search_symbols_fts(db_path, expanded, file_path, kind)
    if fts_results is not None:
        _add(fts_results, "fts5")
    else:
        # Layer 1b: LIKE fallback when FTS5 unavailable
        like_results = _search_symbols_like(db_path, query, file_path, kind)
        _add(like_results, "like")

    # Layer 2: File name / path search
    _add(_search_files(db_path, query), "file")

    # Layer 3: Package name / description search
    _add(_search_packages(db_path, query), "package")

    # Layer 4: Vector similarity search (only if few results from above)
    if len(all_found) < 5:
        _add(_search_vectors(db_path, query), "vector")

    total = len(all_found)

    # ── Status determination ──
    # Prioritize symbol-level results for backward-compatible status
    symbol_found = [r for r in all_found if r["kind"] not in ("file", "package")]
    file_pkg_found = [r for r in all_found if r["kind"] in ("file", "package")]

    if total == 0:
        return {
            "status": "no_match",
            "query": query,
            "expandedQuery": expanded,
            "layers": active_layers,
            "results": [],
            "total": 0,
        }

    # Determine best single result for "exact" status
    best = None
    if len(symbol_found) == 1:
        best = symbol_found[0]
    elif len(symbol_found) > 1:
        s0, s1 = symbol_found[0], symbol_found[1]
        if s0["name"] != s1["name"] or s0["file"] == s1["file"]:
            best = symbol_found[0]

    if best is not None and total == 1:
        return {
            "status": "exact",
            "query": query,
            "expandedQuery": expanded,
            "layers": active_layers,
            "result": best,
            "results": all_found,
            "total": total,
        }

    if best is not None:
        return {
            "status": "exact",
            "query": query,
            "expandedQuery": expanded,
            "layers": active_layers,
            "result": best,
            "results": all_found,
            "total": total,
        }

    # Check for ambiguous symbols (same name, different files)
    if len(symbol_found) > 1 and symbol_found[0]["name"] == symbol_found[1]["name"]:
        options = []
        for i, r in enumerate(symbol_found[:5], 1):
            loc = r["file"]
            sig = f" {r['signature']}" if r.get("signature") else ""
            options.append(f"  {i}. {r['name']} ({r['kind']}) — {loc}{sig}")
        return {
            "status": "ambiguous",
            "query": query,
            "expandedQuery": expanded,
            "layers": active_layers,
            "disambiguation": (
                f"找到 {len(symbol_found)} 个匹配, 符号名相同, 位于不同文件：\n"
                + "\n".join(options)
                + "\n指定 file_path 或 kind 参数可精确定位。"
            ),
            "results": all_found[:15],
            "total": total,
        }

    # Fallback: non-symbol results only (files, packages, vector)
    return {
        "status": "no_match",
        "query": query,
        "expandedQuery": expanded,
        "layers": active_layers,
        "results": all_found[:10],
        "total": total,
    }


def tool_project_structure(db_path: str, subpath: str = "") -> dict:
    if not os.path.isfile(db_path):
        return {"error": f"Database not found: {db_path}"}
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    MAX_ITEMS = 200

    if subpath:
        prefix = subpath.rstrip("/") + "/"
        dirs = conn.execute(
            "SELECT path, module_name, file_count, has_package_manifest "
            "FROM directories WHERE path LIKE ? AND path NOT LIKE ? "
            "ORDER BY path LIMIT ?",
            (prefix + "%", prefix + "%/%", MAX_ITEMS + 1),
        ).fetchall()
        files = conn.execute(
            "SELECT path, ext FROM files WHERE dir_path = ? ORDER BY path LIMIT ?",
            (subpath, MAX_ITEMS + 1),
        ).fetchall()
    else:
        dirs = conn.execute(
            "SELECT path, module_name, file_count, has_package_manifest "
            "FROM directories WHERE path NOT LIKE '%/%' "
            "ORDER BY path LIMIT ?",
            (MAX_ITEMS + 1,),
        ).fetchall()
        files = conn.execute(
            "SELECT path, ext FROM files WHERE dir_path = '' ORDER BY path LIMIT ?",
            (MAX_ITEMS + 1,),
        ).fetchall()
    conn.close()

    result = {
        "directories": [
            {
                "path": r["path"],
                "name": r["module_name"],
                "fileCount": r["file_count"],
                "isManifest": bool(r["has_package_manifest"]),
            }
            for r in dirs[:MAX_ITEMS]
        ],
        "files": [{"path": f["path"], "ext": f["ext"]} for f in files[:MAX_ITEMS]],
        "totalDirs": len(dirs),
        "totalFiles": len(files),
    }

    if len(dirs) > MAX_ITEMS or len(files) > MAX_ITEMS:
        result["truncated"] = True
        result["hint"] = "结果过多已被截断，指定子路径精确定位"

    return result


def tool_project_packages(db_path: str, pkg_type: str = "") -> dict:
    if not os.path.isfile(db_path):
        return {"error": f"Database not found: {db_path}"}
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    if pkg_type:
        rows = conn.execute(
            "SELECT name, version, type, description, source_url "
            "FROM packages WHERE type = ? ORDER BY name",
            (pkg_type,),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT name, version, type, description, source_url "
            "FROM packages ORDER BY type, name"
        ).fetchall()
    conn.close()
    return {
        "packages": [
            {
                "name": r["name"],
                "version": r["version"],
                "type": r["type"],
                "description": r["description"],
                "sourceUrl": r["source_url"],
            }
            for r in rows
        ],
        "total": len(rows),
    }


def tool_project_exports(db_path: str, path: str) -> dict:
    if not os.path.isfile(db_path):
        return {"error": f"Database not found: {db_path}"}
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    is_dir = conn.execute(
        "SELECT 1 FROM directories WHERE path = ?", (path,)
    ).fetchone()
    if is_dir:
        files = conn.execute(
            "SELECT path, name, ext, sym_count FROM files WHERE dir_path = ? ORDER BY path",
            (path,),
        ).fetchall()
        result_files = []
        for f in files:
            syms = conn.execute(
                "SELECT name, kind, signature, start_line, end_line FROM symbols "
                "WHERE file_path = ? AND (visibility = 'public' OR visibility IS NULL) "
                "ORDER BY kind, name",
                (f["path"],),
            ).fetchall()
            result_files.append(
                {
                    "path": f["path"],
                    "symbols": [
                        {
                            "name": s["name"],
                            "kind": s["kind"],
                            "signature": s["signature"],
                            "startLine": s["start_line"],
                            "endLine": s["end_line"],
                        }
                        for s in syms
                    ],
                }
            )
        conn.close()
        return {"path": path, "isDirectory": True, "files": result_files}
    else:
        syms = conn.execute(
            "SELECT name, kind, signature, visibility, start_line, end_line FROM symbols "
            "WHERE file_path = ? ORDER BY kind, name",
            (path,),
        ).fetchall()
        conn.close()
        return {
            "path": path,
            "isDirectory": False,
            "symbols": [
                {
                    "name": s["name"],
                    "kind": s["kind"],
                    "signature": s["signature"],
                    "startLine": s["start_line"],
                    "endLine": s["end_line"],
                    "visibility": s["visibility"],
                }
                for s in syms
            ],
            "total": len(syms),
        }
