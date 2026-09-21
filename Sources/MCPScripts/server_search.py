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

import hashlib
import os
import sqlite3
import threading

import numpy as np

from db import conn as dbconn
from log_utils import setup_logging
from server_embed import _get_shared_embedder, embed_query
from synonyms import load_synonyms

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
# 单次喂给 embedder 的文本条数（ONNX 推理分批，避免一次性构造过大的 batch）
_EMBED_BATCH_SIZE = 32
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
    # 内置默认 + 用户增量（config.yaml `mcp.synonyms`）；合并与缓存都在 synonyms 层
    synonyms = load_synonyms()
    terms = query.lower().split()
    expanded = set(terms)
    for term in terms:
        if term in synonyms:
            for syn in synonyms[term].split():
                expanded.add(syn)
    return " OR ".join(f'"{t}"' if " " in t else t for t in expanded)


def _search_symbols_fts(
    db_path: str, expanded: str, file_path: str, kind: str
) -> list[dict] | None:
    """Layer 1a: FTS5 symbol search. Returns None if FTS5 unavailable (degrade to LIKE)."""
    try:
        with dbconn(db_path) as conn:
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


def _search_symbols_like(
    db_path: str, query: str, file_path: str, kind: str
) -> list[dict]:
    """Layer 1b: LIKE fallback when FTS5 is unavailable."""
    with dbconn(db_path) as conn:
        conn.row_factory = sqlite3.Row
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


def _search_files(db_path: str, query: str) -> list[dict]:
    """Layer 2: Search files table by name or path."""
    with dbconn(db_path) as conn:
        conn.row_factory = sqlite3.Row
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


def _search_packages(db_path: str, query: str) -> list[dict]:
    """Layer 3: Search packages table by name or description."""
    with dbconn(db_path) as conn:
        conn.row_factory = sqlite3.Row
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


def _symbol_cache_key(
    file_path: str, name: str, kind: str, signature: str, doc: str
) -> str:
    """符号的稳定缓存键 —— 由「定义 embedding 输入的那些字段」派生。

    刻意不用 `symbols.id`：该列是 GRDB 的 AUTOINCREMENT，而两条写入路径都会让
    同一个符号拿到新 id —— ProjectScanner 全量扫描经 `clearAll()` 先
    `DELETE FROM symbols` 再重插；batchWriteFiles 先按 file_path 删再重插。
    以 id 为键时每次重扫所有 embedding 立即失效（实测边表 67438 行、有效 0 行、
    占 132MB），下一次向量检索被迫重算全部符号（实测 349s）。

    改用业务字段后，符号本身没变则重扫不触发重算；任一参与 embedding 文本的
    字段变了，键随之改变、自然重算 —— 键即输入，不存在脏读。
    """
    raw = "\x1f".join((file_path, name, kind, signature, doc))
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def _ensure_symbol_embeddings_schema(conn: sqlite3.Connection) -> None:
    """建边表；旧版按 symbol_id 建的边表直接丢弃重建。

    旧行以 id 为键，无法映射到新的业务键；embedding 是纯派生数据（随时可重算），
    丢弃的代价只是一次重算，留着则是永不复用的空间泄漏。
    """
    cols = {row[1] for row in conn.execute("PRAGMA table_info(symbol_embeddings)")}
    if cols and "sym_key" not in cols:
        logger.info(
            "[symbol_embeddings] dropping legacy symbol_id-keyed table "
            "(derived data, recomputed on demand)"
        )
        conn.execute("DROP TABLE symbol_embeddings")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS symbol_embeddings (
            sym_key TEXT PRIMARY KEY,
            embedding BLOB NOT NULL
        )
    """)


def _load_symbol_embeddings(conn: sqlite3.Connection) -> dict[str, bytes]:
    """读出全部 embedding（稳定键 → BLOB）。"""
    return {
        row["sym_key"]: row["embedding"]
        for row in conn.execute("SELECT sym_key, embedding FROM symbol_embeddings")
    }


def _prune_symbol_embeddings(
    conn: sqlite3.Connection,
    cached: dict[str, bytes],
    live_keys: set[str],
    truncated: bool,
) -> None:
    """删除不再被任何符号引用的 embedding，避免边表随重扫无界增长。"""
    if truncated:
        # 符号查询被 LIMIT 截断时 live_keys 不完整，清理会误删仍有效的行
        return
    stale = cached.keys() - live_keys
    if not stale:
        return
    conn.executemany(
        "DELETE FROM symbol_embeddings WHERE sym_key = ?", [(k,) for k in stale]
    )
    conn.commit()
    for k in stale:
        cached.pop(k, None)
    logger.info(f"[symbol_embeddings] pruned {len(stale)} stale rows")


def _ensure_symbol_embeddings(db_path: str) -> tuple[list[dict], np.ndarray | None]:
    """Persist symbol embeddings in SQLite, lazily fill missing ones.

    1. Creates/uses the symbol_embeddings side-table in deps.sqlite
    2. Computes embeddings only for symbols whose stable key is absent
    3. Prunes keys no longer referenced by any symbol
    4. Returns (symbols_list, embedding_matrix)
    """
    emb = _get_shared_embedder()
    if emb is None:
        return [], None

    try:
        with dbconn(db_path, timeout=5) as conn:
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            _ensure_symbol_embeddings_schema(conn)

            # 多取一行判断是否被 LIMIT 截断（截断时不可做孤儿清理）
            rows = conn.execute(
                """
                SELECT file_path, name, kind, signature, doc_comment
                FROM symbols
                LIMIT ?
            """,
                (_MAX_VECTOR_ROWS + 1,),
            ).fetchall()
            truncated = len(rows) > _MAX_VECTOR_ROWS
            rows = rows[:_MAX_VECTOR_ROWS]

            if not rows:
                # 符号表为空 → 边表里全是孤儿，清干净再返回。
                # 这里必须显式清理：下面的正常路径才走到 _prune_symbol_embeddings，
                # 直接 return 会让「项目变空」这一情形永久留下无效 embedding。
                _prune_symbol_embeddings(
                    conn, _load_symbol_embeddings(conn), set(), False
                )
                return [], None

            entries: list[tuple[str, str, sqlite3.Row]] = []
            for r in rows:
                sig = r["signature"] or ""
                doc = r["doc_comment"] or ""
                key = _symbol_cache_key(r["file_path"], r["name"], r["kind"], sig, doc)
                text = r["name"]
                if sig:
                    text += " " + sig
                if doc:
                    text += " " + doc
                entries.append((key, text, r))

            cached = _load_symbol_embeddings(conn)

            # 只补齐缺失的：键与 embedding 输入一一对应，命中即无需重算
            missing = [e for e in entries if e[0] not in cached]
            if missing:
                batches = [
                    missing[i : i + _EMBED_BATCH_SIZE]
                    for i in range(0, len(missing), _EMBED_BATCH_SIZE)
                ]
                for batch in batches:
                    vectors = list(emb.embed([e[1] for e in batch]))
                    for (key, _text, _row), vec in zip(batch, vectors):
                        conn.execute(
                            "INSERT OR REPLACE INTO symbol_embeddings "
                            "(sym_key, embedding) VALUES (?, ?)",
                            (key, np.asarray(vec, dtype=np.float32).tobytes()),
                        )
                    conn.commit()
                cached = _load_symbol_embeddings(conn)

            _prune_symbol_embeddings(conn, cached, {e[0] for e in entries}, truncated)

            symbols: list[dict] = []
            vectors_list: list[np.ndarray] = []
            for key, _text, r in entries:
                blob = cached.get(key)
                if blob is None:
                    continue
                try:
                    vec = np.frombuffer(blob, dtype=np.float32).copy()
                except Exception:
                    continue
                norm = np.linalg.norm(vec)
                if norm < 1e-10:
                    continue
                vectors_list.append(vec / norm)
                symbols.append(
                    {
                        "name": r["name"],
                        "file": r["file_path"],
                        "signature": r["signature"],
                    }
                )

            if not vectors_list:
                return [], None

            return symbols, np.array(vectors_list, dtype=np.float32)

    except Exception as e:
        logger.warning(f"[symbol_embeddings] init failed: {e}")
        return [], None


def _symbols_signature(db_path: str) -> tuple[int, int] | None:
    """符号表的廉价变更指纹 `(行数, MAX(id))`，用于判定内存向量缓存是否失效。

    刻意**不**用 DB 文件的 mtime/size：库跑在 WAL 模式下，提交只写 `-wal` 文件，
    主库文件的 mtime/size 纹丝不动（实测确认），以它为判据会永远认为「没变」。
    两列都取是因为：全量重扫会清空重插、换新 id（MAX 增大），纯删除则只有行数变。
    表不存在等异常返回 None，调用方回退到「无缓存」路径。
    """
    try:
        with dbconn(db_path, timeout=5) as conn:
            row = conn.execute(
                "SELECT COUNT(*), COALESCE(MAX(id), -1) FROM symbols"
            ).fetchone()
        return (row[0], row[1])
    except Exception:
        return None


def _search_vectors(db_path: str, query: str) -> list[dict]:
    """Layer 4: Vector similarity search against persisted symbol embeddings.

    Persists embeddings in SQLite (symbol_embeddings side-table) so cold
    starts read from disk (~70ms) instead of recomputing from scratch (~110s).
    Missing embeddings are filled lazily on next query.
    In-memory cache keeps subsequent calls fast, keyed by a cheap signature of
    the symbols table so an external rescan invalidates it (otherwise a rescan
    would leave the cache serving removed/renamed symbols' stale paths).
    """
    try:
        # Lazy-load from SQLite + cache in memory；用符号表指纹判定失效
        sig = _symbols_signature(db_path)
        cached = _symbol_embeddings.get(db_path)
        if cached is None or cached[2] != sig:
            symbols, emb_matrix = _ensure_symbol_embeddings(db_path)
            # 淘汰最旧缓存
            while len(_symbol_embeddings) >= _MAX_VECTOR_CACHE:
                oldest = next(iter(_symbol_embeddings))
                logger.info(f"[vector] evicting cached embeddings for: {oldest}")
                del _symbol_embeddings[oldest]
            _symbol_embeddings[db_path] = (symbols, emb_matrix, sig)

        symbols, emb_matrix = _symbol_embeddings[db_path][:2]
        if emb_matrix is None or len(symbols) == 0:
            return []

        # Encode query + normalize（走共享查询缓存）
        query_emb = embed_query(query)
        if query_emb is None:
            return []
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


def _embed_in_batches(emb, texts: list[str]) -> list:
    """分批推理，输出顺序与输入严格一一对应。"""
    out: list = []
    for i in range(0, len(texts), _EMBED_BATCH_SIZE):
        out.extend(emb.embed(texts[i : i + _EMBED_BATCH_SIZE]))
    return out


def _ensure_note_cache(
    project_path: str,
) -> tuple[sqlite3.Connection, str, int]:
    """Incremental cache update: scan .md files, diff mtime/size, embed only changed."""
    project_path = os.path.normpath(project_path)
    cache_dir = os.path.join(project_path, ".utility")
    os.makedirs(cache_dir, exist_ok=True)
    db_path = os.path.join(cache_dir, NOTE_DB_FILENAME)

    conn = _get_note_db(db_path)

    # 这里曾用「项目根目录 mtime <= 缓存中 .md 的最大 mtime」做快速跳过，但两者
    # 语义不同：前者是项目【根目录】的 mtime（只在直接子项增删时变化），后者是缓存
    # 里各 .md 文件的 mtime（最后一次写入时间）。失真双向发生——改深层已有文件
    # 不触发重扫（返回陈旧结果），根目录有增删则触发全量重扫。
    # 改为始终扫描 + 逐文件 diff：实测 453 个 .md 的扫描仅 7ms，而失效判定一旦
    # 出错就是全量重新 embedding（平均 6.3s、最坏 150s）。扫描成本可以忽略。

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

            # 阶段1：读文件、切块（纯只读，不碰库 —— 读失败的文件直接跳过，
            # 库里旧行原样保留，不留「删了旧行却没写新行」的空窗）
            prepared: list[tuple[dict, list[dict]]] = []
            for mf in changed:
                try:
                    with open(
                        mf["path"], "r", encoding="utf-8", errors="replace"
                    ) as fh:
                        text = fh.read()
                except Exception as e:
                    logger.warning(f"[project_notes] error reading {mf['path']}: {e}")
                    continue
                chunks = _chunk_md_text(text, mf["path"])
                if chunks:
                    prepared.append((mf, chunks))

            # 阶段2：按全局配额裁剪（保持 NOTE_MAX_CHUNKS_PER_PROJECT 上限语义）。
            # 基线要把待重写文件的旧 chunk 扣掉 —— 它们在阶段4会被整文件替换。
            total = conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
            for mf, _chunks in prepared:
                total -= conn.execute(
                    "SELECT COUNT(*) FROM chunks WHERE file_path = ?", (mf["path"],)
                ).fetchone()[0]
            accepted: list[tuple[dict, list[dict]]] = []
            for mf, chunks in prepared:
                if total + len(chunks) > NOTE_MAX_CHUNKS_PER_PROJECT:
                    logger.warning(
                        f"[project_notes] {project_path}: "
                        f"truncating at {NOTE_MAX_CHUNKS_PER_PROJECT} chunks"
                    )
                    chunks = chunks[: NOTE_MAX_CHUNKS_PER_PROJECT - total]
                if not chunks:
                    continue
                accepted.append((mf, chunks))
                total += len(chunks)

            # 阶段3：对全部待嵌入文本统一分批推理。逐文件调用会把 Python↔ONNX 的
            # 往返次数放大到文件数量级，合批后只与总条数有关。
            vectors: list = []
            if emb is not None:
                texts = [c["chunk_text"] for _mf, chunks in accepted for c in chunks]
                vectors = _embed_in_batches(emb, texts)

            # 阶段4：写回（vectors 与 accepted 展平后的顺序一一对应）。
            # 单文件的「删旧行 + 插新行」在同一事务内提交，保持原子性。
            cursor = 0
            for mf, chunks in accepted:
                try:
                    conn.execute(
                        "DELETE FROM chunks WHERE file_path = ?", (mf["path"],)
                    )
                    for c in chunks:
                        vec = vectors[cursor] if cursor < len(vectors) else None
                        cursor += 1
                        if vec is not None:
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
                                    np.asarray(vec, dtype=np.float32).tobytes(),
                                ),
                            )
                        else:
                            # No embedder: store without embedding (keyword fallback later)
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
                    logger.warning(f"[project_notes] error writing {mf['path']}: {e}")
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

    # Try vector search first（走共享查询缓存）
    query_vec = embed_query(query)
    vector_results: list[dict] = []

    if query_vec is not None:
        try:
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
    with dbconn(db_path) as conn:
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
    with dbconn(db_path) as conn:
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
    with dbconn(db_path) as conn:
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
            return {"path": path, "isDirectory": True, "files": result_files}
        else:
            syms = conn.execute(
                "SELECT name, kind, signature, visibility, start_line, end_line FROM symbols "
                "WHERE file_path = ? ORDER BY kind, name",
                (path,),
            ).fetchall()
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
