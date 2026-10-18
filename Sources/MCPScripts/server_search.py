"""Server's project dependency-graph query + note semantic search module.

Split out of server.py (2026-08-30, refactor phase 4): project symbol/file/Package
search (tool_project_* low-level functions + multi-layer FTS/LIKE/vector search) and
project_notes semantic search. Code moved as-is, no logic changes.

Note:
- This module does not import mem0/qdrant — server.py's module-level side-effect
  ordering (POSTHOG_DISABLED/MEM0_TELEMETRY + _patch_mem0_fastembed before import
  mem0) is unaffected.
- The shared embedder lives in server_embed.py (_get_shared_embedder/EMBEDDER_DIMS);
  the tool_project_* functions are low-level (returning a dict), and the MCP handler
  wrappers (_handle_project_*, decorated with @_register) stay in server.py, which
  imports this module's low-level functions and calls them after parsing arguments.
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
from tool_defaults import arg_default

# ---------------------------------------------------------------------------
# Configuration (same as pre-split server.py; NOTE_*/PROJECT_MARKER_* are server-specific)
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
#: Default result limit for the project tools (authoritative source is
#: `tool_defaults.arg_default`, config surface is config.yaml `mcp.toolDefaults`).
#: Function signatures reference it so the handler doesn't keep a second copy of the
#: literal and drift.
DEFAULT_PROJECT_SEARCH_LIMIT = arg_default("project_search", "limit")
DEFAULT_PROJECT_STRUCTURE_LIMIT = arg_default("project_structure", "limit")
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
        # Others
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
# Number of texts fed to the embedder per call (ONNX inference is batched to avoid building an oversized batch at once)
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
    # Built-in defaults + user additions (config.yaml `mcp.synonyms`); merging and caching both live in the synonyms layer
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
    """Stable cache key for a symbol — derived from "the fields that define the
    embedding input".

    Deliberately not `symbols.id`: that column is GRDB's AUTOINCREMENT, and both write
    paths give the same symbol a new id — ProjectScanner's full scan goes through
    `clearAll()` (which first `DELETE FROM symbols` then re-inserts); batchWriteFiles
    deletes by file_path then re-inserts. Keyed by id, every rescan immediately
    invalidates all embeddings (measured: side-table 67438 rows, 0 valid, 132MB), and
    the next vector search is forced to recompute every symbol (measured 349s).

    With business fields, an unchanged symbol does not trigger recomputation on rescan;
    if any field participating in the embedding text changes, the key changes and it is
    recomputed naturally — the key is the input, so there is no stale read.
    """
    raw = "\x1f".join((file_path, name, kind, signature, doc))
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def _ensure_symbol_embeddings_schema(conn: sqlite3.Connection) -> None:
    """Create the side-table; a legacy symbol_id-keyed side-table is dropped and rebuilt.

    Old rows are keyed by id and cannot be mapped to the new business keys; embeddings
    are purely derived data (recomputable at any time), so dropping them costs only one
    recomputation, while keeping them is a space leak that is never reused.
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
    """Read all embeddings (stable key → BLOB)."""
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
    """Delete embeddings no longer referenced by any symbol, so the side-table does not grow unbounded across rescans."""
    if truncated:
        # When the symbol query is truncated by LIMIT, live_keys is incomplete and pruning would wrongly delete still-valid rows
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

            # Fetch one extra row to detect truncation by LIMIT (no orphan pruning when truncated)
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
                # Symbol table is empty → the side-table is all orphans; clean it up
                # before returning. This explicit cleanup is required: only the normal
                # path below reaches _prune_symbol_embeddings, and returning directly
                # would leave invalid embeddings behind forever for the "project became
                # empty" case.
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

            # Only fill in the missing ones: the key maps one-to-one to the embedding input, so a cache hit needs no recomputation
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
    """Cheap change fingerprint of the symbols table `(row count, MAX(id))`, used to
    decide whether the in-memory vector cache is stale.

    Deliberately **not** the DB file's mtime/size: the DB runs in WAL mode, so commits
    only write the `-wal` file and the main DB file's mtime/size does not budge at all
    (confirmed empirically); using it as the signal would always think "unchanged".
    Both columns are taken because: a full rescan clears and re-inserts with new ids
    (MAX grows), while a pure delete changes only the row count. Exceptions such as a
    missing table return None, and the caller falls back to the "no cache" path.
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
        # Lazy-load from SQLite + cache in memory; use the symbols-table fingerprint to detect staleness
        sig = _symbols_signature(db_path)
        cached = _symbol_embeddings.get(db_path)
        if cached is None or cached[2] != sig:
            symbols, emb_matrix = _ensure_symbol_embeddings(db_path)
            # Evict the oldest cache entry
            while len(_symbol_embeddings) >= _MAX_VECTOR_CACHE:
                oldest = next(iter(_symbol_embeddings))
                logger.info(f"[vector] evicting cached embeddings for: {oldest}")
                del _symbol_embeddings[oldest]
            _symbol_embeddings[db_path] = (symbols, emb_matrix, sig)

        symbols, emb_matrix = _symbol_embeddings[db_path][:2]
        if emb_matrix is None or len(symbols) == 0:
            return []

        # Encode query + normalize (via the shared query cache)
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
    """Batched inference; output order strictly matches input one-to-one."""
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

    # This used to quick-skip via "project root dir mtime <= the max mtime of .md files
    # in the cache", but the two have different semantics: the former is the project
    # *root directory*'s mtime (changes only when direct children are added/removed),
    # the latter is the mtime of each cached .md file (last write time). Distortion goes
    # both ways — editing a deep existing file does not trigger a rescan (returning stale
    # results), while adding/removing at the root triggers a full rescan.
    # Changed to always scan + per-file diff: measured, scanning 453 .md files takes only
    # 7ms, whereas a wrong staleness decision means re-embedding everything (6.3s
    # average, 150s worst case). The scan cost is negligible.

    # Serialized rebuild: when multiple requests arrive at once, embedding runs only once (ONNX inference is blocking and memory-intensive)
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

            # Phase 1: read files and chunk (read-only, no DB touched — files that fail
            # to read are skipped outright and their old rows are kept as-is, so there is
            # no window of "old rows deleted but new rows not yet written")
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

            # Phase 2: trim to the global quota (preserving the
            # NOTE_MAX_CHUNKS_PER_PROJECT cap semantics). The baseline must subtract the
            # old chunks of files being rewritten — they are replaced wholesale in phase 4.
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

            # Phase 3: run batched inference over all texts to embed at once. Calling
            # per file multiplies the Python↔ONNX round trips to the order of the file
            # count; batched, it depends only on the total item count.
            vectors: list = []
            if emb is not None:
                texts = [c["chunk_text"] for _mf, chunks in accepted for c in chunks]
                vectors = _embed_in_batches(emb, texts)

            # Phase 4: write back (vectors map one-to-one to the flattened order of
            # accepted). A single file's "delete old rows + insert new rows" is committed
            # in one transaction to stay atomic.
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
                                "INSERT OR REPLACE INTO chunks VALUES (?,?,?,?,?,?,?)",
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
    """Shallow-scan the target path for common project marker files — decides whether it
    is a "dev project".

    A pure document repo (e.g. notes: only .md + .git) has none of these markers → returns
    False, so project_notes uses an in-memory-only keyword search for non-dev projects and
    no longer creates the .utility cache. Note: .git/.gitignore are deliberately excluded
    (document repos such as notes have them too) to avoid a false positive.
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
    """Degraded path for non-dev projects: in-memory-only keyword search, no .utility
    cache created.

    Same logic as _query_project_notes's keyword fallback, but scans files and matches
    chunks directly without persisting to SQLite. Repeated queries against directories
    like notes leave no disk residue.
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

    # Non-dev project (no marker files): no .utility cache persisted, in-memory-only keyword search
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

    # Try vector search first (via the shared query cache)
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

    # Keyword search (grep-lite) — always runs; exact matches are inserted ahead of vector results
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
        # Exact matches inserted ahead of vector results (vector search can rank poorly for CJK/cross-language queries)
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
    limit: int = DEFAULT_PROJECT_SEARCH_LIMIT,
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
            "results": all_found[:limit],
            "total": total,
        }

    if best is not None:
        return {
            "status": "exact",
            "query": query,
            "expandedQuery": expanded,
            "layers": active_layers,
            "result": best,
            "results": all_found[:limit],
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
            "results": all_found[:limit],
            "total": total,
        }

    # Fallback: non-symbol results only (files, packages, vector)
    return {
        "status": "no_match",
        "query": query,
        "expandedQuery": expanded,
        "layers": active_layers,
        "results": all_found[:limit],
        "total": total,
    }


def tool_project_structure(
    db_path: str, subpath: str = "", limit: int = DEFAULT_PROJECT_STRUCTURE_LIMIT
) -> dict:
    if not os.path.isfile(db_path):
        return {"error": f"Database not found: {db_path}"}
    with dbconn(db_path) as conn:
        conn.row_factory = sqlite3.Row

        MAX_ITEMS = limit

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
