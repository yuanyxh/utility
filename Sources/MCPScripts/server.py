#!/usr/bin/env python3
"""
MCP MinoBraiN — 冷热双层共享记忆 + 项目依赖图查询

热层: Mem0 → Qdrant (原始碎片记忆, 自动提取/去重/冲突解决)
冷层: Qdrant 独立集合 (已归档知识索引)
项目: SQLite 依赖图查询 (FTS5 + 同义词扩展)

从 self-service-docker 移植, 适配 Utility.app 子进程模式。
"""

# mem0 内置 PostHog 遥测在无网络环境会卡死初始化, 必须在任何 import 前禁用
import os

os.environ["POSTHOG_DISABLED"] = "1"

import json
import uuid
import sys
import time
import asyncio
import anyio
import logging
import logging.handlers
import subprocess
import sqlite3
import httpx
import numpy as np
from datetime import datetime, timedelta

from mem0 import Memory
from qdrant_client import QdrantClient
import uvicorn
from qdrant_client import models
from qdrant_client.models import (
    VectorParams,
    Distance,
    PointStruct,
    Filter,
    FieldCondition,
    MatchValue,
)
from fastembed import TextEmbedding
from mcp.server import Server
from mcp.server import InitializationOptions
from mcp.server.models import ServerCapabilities
from mcp.server.streamable_http import StreamableHTTPServerTransport
from mcp.types import (
    Tool,
    TextContent,
    ToolsCapability,
)
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

from synonyms import SYNONYM_MAP  # 同义词扩展表


def _setup_logging():
    log_dir = os.environ.get(
        "LOG_DIR",
        os.path.join(
            os.environ.get(
                "NOTES_DIR", os.path.expanduser("~/Documents/selfdata/notes")
            ),
            "logs",
        ),
    )
    os.makedirs(log_dir, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    console = logging.StreamHandler()
    console.setFormatter(fmt)
    root.addHandler(console)
    fh = logging.handlers.TimedRotatingFileHandler(
        filename=os.path.join(log_dir, "server.log"),
        when="midnight",
        interval=1,
        backupCount=30,
        encoding="utf-8",
    )
    fh.setFormatter(fmt)
    root.addHandler(fh)
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.error").setLevel(logging.WARNING)


_setup_logging()

# ============================================================
# 配置(环境变量驱动, 由 Swift MCPProcessManager 注入)
# ============================================================

QDRANT_PATH = os.environ.get(
    "QDRANT_PATH", os.path.expanduser("~/Documents/selfdata/qdrant_data")
)
MEM0_QDRANT_PATH = os.path.join(QDRANT_PATH, "mem0")


def _cleanup_qdrant_locks() -> None:
    """Qdrant Local 模式崩溃后锁文件残留会阻塞下次启动, 启动前清理。"""
    for root_dir in (
        QDRANT_PATH,
        MEM0_QDRANT_PATH,
        os.path.expanduser("~/.mem0/migrations_qdrant"),
    ):
        lock = os.path.join(root_dir, ".lock")
        if os.path.isfile(lock):
            try:
                os.remove(lock)
                logging.info(f"Cleaned stale lock: {lock}")
            except OSError as e:
                logging.warning(f"Failed to remove lock {lock}: {e}")


_cleanup_qdrant_locks()
COLD_COLLECTION = "knowledge_base"
EMBEDDER_MODEL = os.environ.get(
    "EMBEDDER_MODEL", "sentence-transformers/all-MiniLM-L6-v2"
)
EMBEDDER_DIMS = 384
FASTEMBED_CACHE_DIR = os.environ.get(
    "FASTEMBED_CACHE_PATH", os.path.expanduser("~/.cache/fastembed_cache")
)
os.environ.setdefault("FASTEMBED_CACHE_PATH", FASTEMBED_CACHE_DIR)
logging.info(
    f"ENV CHECK: FASTEMBED_CACHE_PATH={FASTEMBED_CACHE_DIR}, MCP_PORT={os.environ.get('MCP_PORT')}, QDRANT_PATH={os.environ.get('QDRANT_PATH')}"
)
NOTES_DIR = os.environ.get(
    "NOTES_DIR", os.path.expanduser("~/Documents/selfdata/notes")
)
LOG_DIR = os.path.join(NOTES_DIR, "logs")
PROMPTS_DIR = os.path.join(NOTES_DIR, "MCP", "Prompts")
SKILLS_DIR = os.path.join(NOTES_DIR, "MCP", "Skills")
DESCRIPTIONS_FILE = os.path.join(NOTES_DIR, "MCP", "DESCRIPTIONS.md")

TOOL_DEFAULTS: dict[str, str] = {
    "house_rules": "当对项目规则、编码风格、目录结构或操作约束不确定时 → 调用本工具。获取最高行为准则和系统说明书。",
    "remember": "用户说「记住/记录」、bug 修复完成或有关键发现 → 必须调用本工具。写入单条事实到共享记忆。多条内容请用 remember_batch。",
    "remember_batch": "有多条内容需要记录时优先使用, 可大幅减少调用次数。批量写入多条记忆, 功能与 remember 一致。",
    "recall": "用户说「查一下/搜索/找一下/之前那个」、提到历史/已有信息 → 必须调用本工具。在共享记忆库、知识库和笔记中搜索。禁止用 grep/git log 代替。常识性问题无需调用。",
    "catch_up": "用户说「刚才/上次/之前/上回/近期」或问做了什么/进展/未解决问题 → 必须调用本工具。禁止用 git log 代替。获取最近记忆列表, 用于跨会话上下文恢复。",
    "forget": "用户要求删除记忆, 或记忆内容有误/过时 → 调用本工具。删除指定 ID 的记忆。",
    "project_search": "优先使用本工具查找(符号/文件/Package)的定义和位置, 避免全量读取文件。支持中文同义词扩展。项目依赖图查找。",
    "project_structure": "优先使用本工具了解项目目录结构，替代 ls/find 遍历。指定子路径查看下一级。",
    "project_packages": "列出项目三方依赖。",
    "project_exports": "优先使用本工具获取文件或目录的公共接口, 避免全量读取文件。",
}

EXCLUDE_DIRS = {"Self_Data", "Works_Jobs", "SaveWebPages", "Resources", "Attachments"}
NOTE_EXTENSIONS = (".md", ".txt", ".py", ".yaml", ".yml", ".json", ".toml")
DEFAULT_TIMEOUT = 60.0
SUMMARY_LLM_MODEL = os.environ.get("SUMMARY_MODEL", "deepseek-v4-flash")
SUMMARY_LLM_API_URL = os.environ.get("SUMMARY_API_URL", "https://api.deepseek.com")
DEEPSEEK_API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
SUMMARY_LLM_TEMPERATURE = 0.1
DEFAULT_HEAT_SCORE = 1.0
HEAT_INCREMENT = 0.1
HEAT_MAX = 1.0
HEAT_DECAY_PER_DAY = 0.01
HOT_INIT_RUNTIME_COOLDOWN = 60
HOT_INIT_MAX_RUNTIME_FAILURES = 5
ARCHIVE_DAYS = 90
HOT_RETENTION_DAYS = 180
ARCHIVE_INTERVAL_HOURS = 24
DEFAULT_USER_ID = "yuanyxh"
CONTRADICTION_SIMILARITY_THRESHOLD = 0.8
CONTRADICTION_TOP_K = 5
SERVER_NAME = "mino-brain"
SERVER_VERSION = "1.0.0"
MCP_PORT = int(os.environ.get("MCP_PORT", "9001"))

# 同义词扩展表 (Layer 2) — 从 synonyms.py 导入
# 编辑 Sources/MCPScripts/synonyms.py 添加/修改映射


# ============================================================
# 热层：Mem0 初始化
# ============================================================

MEM0_CONFIG = {
    "vector_store": {
        "provider": "qdrant",
        "config": {
            "path": MEM0_QDRANT_PATH,
            "on_disk": True,
            "embedding_model_dims": EMBEDDER_DIMS,
        },
    },
    "llm": {
        "provider": "openai",
        "config": {
            "model": SUMMARY_LLM_MODEL,
            "openai_base_url": SUMMARY_LLM_API_URL,
            "api_key": DEEPSEEK_API_KEY,
            "temperature": SUMMARY_LLM_TEMPERATURE,
        },
    },
    "embedder": {
        "provider": "fastembed",
        "config": {
            "model": EMBEDDER_MODEL,
        },
    },
}

hot_memory = None
HOT_INIT_MAX_RETRIES = 3
HOT_INIT_RETRY_DELAY = 5
_hot_runtime_failures = 0
_hot_last_init_attempt = 0.0


def _init_hot_memory() -> bool:
    global hot_memory
    # mem0 内置 PostHog 遥测会阻塞初始化，强制禁用
    try:
        import posthog

        posthog.disabled = True
    except ImportError:
        pass
    for attempt in range(HOT_INIT_MAX_RETRIES):
        try:
            hot_memory = Memory.from_config(MEM0_CONFIG)
            logging.info("Mem0 (hot layer) initialized")
            return True
        except Exception as e:
            logging.warning(
                f"Hot layer init attempt {attempt + 1}/{HOT_INIT_MAX_RETRIES} failed: {e}"
            )
            if attempt < HOT_INIT_MAX_RETRIES - 1:
                time.sleep(HOT_INIT_RETRY_DELAY)
    logging.error(f"Hot layer init failed after {HOT_INIT_MAX_RETRIES} attempts")
    return False


# 热层改为惰性初始化（_ensure_hot_memory()），不阻塞服务启动

# ============================================================
# 冷层：Qdrant 直接客户端
# ============================================================

try:
    qdrant = QdrantClient(path=QDRANT_PATH, force_disable_check_same_thread=True)
    existing = [c.name for c in qdrant.get_collections().collections]
    if COLD_COLLECTION not in existing:
        qdrant.create_collection(
            collection_name=COLD_COLLECTION,
            vectors_config=VectorParams(size=EMBEDDER_DIMS, distance=Distance.COSINE),
        )
        logging.info(f"Cold layer collection '{COLD_COLLECTION}' created")
    logging.info("Cold layer (Qdrant direct) initialized")
except Exception as e:
    logging.error(f"Cold layer Qdrant init failed: {e}")
    qdrant = None

try:
    embedder = TextEmbedding(model_name=EMBEDDER_MODEL, cache_dir=FASTEMBED_CACHE_DIR)
except Exception as e:
    logging.warning(f"Cold layer embedder init failed (retry on search): {e}")
    embedder = None


# ============================================================
# 项目工具：依赖图查询
# ============================================================


def expand_query(query: str) -> str:
    terms = query.lower().split()
    expanded = set(terms)
    for term in terms:
        if term in SYNONYM_MAP:
            for syn in SYNONYM_MAP[term].split():
                expanded.add(syn)
    return " OR ".join(f'"{t}"' if " " in t else t for t in expanded)


# ── Multi-layer project search ──


def _search_symbols_fts(
    db_path: str, expanded: str, file_path: str, kind: str
) -> list[dict] | None:
    """Layer 1a: FTS5 symbol search. Returns None if FTS5 unavailable (degrade to LIKE)."""
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        sql = (
            "SELECT s.name, s.kind, s.signature, s.file_path, s.visibility "
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
            "SELECT name, kind, signature, file_path, visibility "
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


# ── Layer 4: Vector search (fastembed + in-memory cache) ──

_symbol_embeddings: dict[str, tuple[list[dict], np.ndarray | None]] = {}
_project_embedder = None


def _get_project_embedder():
    global _project_embedder
    if _project_embedder is None:
        try:
            _project_embedder = TextEmbedding(model_name=EMBEDDER_MODEL)
        except Exception:
            return None
    return _project_embedder


def _search_vectors(db_path: str, query: str) -> list[dict]:
    """Layer 4: Vector similarity search against all project symbols.

    Lazy-caches symbol embeddings per db_path on first call.
    Silently falls back to empty list on any error.
    """
    embedder = _get_project_embedder()
    if embedder is None:
        return []

    try:
        # Lazy-load and cache symbol embeddings for this project
        if db_path not in _symbol_embeddings:
            conn = sqlite3.connect(db_path, timeout=5)
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT s.name, s.signature, COALESCE(s.doc_comment, '') AS doc, s.file_path "
                "FROM symbols s"
            ).fetchall()
            conn.close()

            if not rows:
                _symbol_embeddings[db_path] = ([], None)
                return []

            symbols = []
            texts = []
            for r in rows:
                text = r["name"]
                if r["signature"]:
                    text += " " + r["signature"]
                if r["doc"]:
                    text += " " + r["doc"]
                texts.append(text)
                symbols.append(
                    {
                        "name": r["name"],
                        "file": r["file_path"],
                        "signature": r["signature"],
                    }
                )

            embeddings = list(embedder.embed(texts))
            emb_matrix = np.array(embeddings, dtype=np.float32)
            norms = np.linalg.norm(emb_matrix, axis=1, keepdims=True)
            norms[norms < 1e-10] = 1
            emb_matrix = emb_matrix / norms  # pre-normalize → dot = cosine
            _symbol_embeddings[db_path] = (symbols, emb_matrix)

        symbols, emb_matrix = _symbol_embeddings[db_path]
        if emb_matrix is None or len(symbols) == 0:
            return []

        # Encode query + normalize
        query_emb = list(embedder.embed([query]))[0]
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
        logging.warning(f"[vector_search] {e}")
        return []


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
                "SELECT name, kind, signature FROM symbols "
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
                        }
                        for s in syms
                    ],
                }
            )
        conn.close()
        return {"path": path, "isDirectory": True, "files": result_files}
    else:
        syms = conn.execute(
            "SELECT name, kind, signature, visibility FROM symbols "
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
                    "visibility": s["visibility"],
                }
                for s in syms
            ],
            "total": len(syms),
        }


# ============================================================
# 记忆工具 — 从 self-service-docker 移植, 已适配 Utility 子进程模式
# ============================================================

_ensure_hot_lock = asyncio.Lock()


async def _ensure_hot_memory() -> bool:
    global hot_memory, _hot_runtime_failures, _hot_last_init_attempt
    if hot_memory is not None:
        return True
    now = time.time()
    if now - _hot_last_init_attempt < HOT_INIT_RUNTIME_COOLDOWN:
        return False
    async with _ensure_hot_lock:
        if hot_memory is not None:
            return True
        if time.time() - _hot_last_init_attempt < HOT_INIT_RUNTIME_COOLDOWN:
            return False
        _hot_last_init_attempt = time.time()
        success = _init_hot_memory()
    if success:
        _hot_runtime_failures = 0
        return True
    _hot_runtime_failures += 1
    logging.error(
        f"Hot layer runtime recovery failed ({_hot_runtime_failures}/{HOT_INIT_MAX_RUNTIME_FAILURES})"
    )
    if _hot_runtime_failures >= HOT_INIT_MAX_RUNTIME_FAILURES:
        fail_msg = f"[{datetime.now().isoformat()}] HOT LAYER FATAL: {_hot_runtime_failures} consecutive init failures"
        logging.critical(fail_msg)
        sys.exit(1)
    return False


def search_cold_layer(
    query: str, limit: int = 5, include_archived: bool = False
) -> list[dict]:
    results = []
    if qdrant:
        global embedder
        if embedder is None:
            try:
                embedder = TextEmbedding(
                    model_name=EMBEDDER_MODEL, cache_dir=FASTEMBED_CACHE_DIR
                )
            except Exception:
                pass
    if qdrant and embedder:
        try:
            vec = list(embedder.embed(query))[0].tolist()
            qfilter = None
            if not include_archived:
                qfilter = Filter(
                    must_not=[
                        FieldCondition(key="archived", match=MatchValue(value=True))
                    ]
                )
            resp = qdrant.query_points(
                collection_name=COLD_COLLECTION,
                query=vec,
                limit=limit,
                query_filter=qfilter,
            )
            for h in resp.points:
                results.append(
                    {
                        "id": h.id,
                        "content": h.payload.get("content", ""),
                        "source_file": h.payload.get("source_file", ""),
                        "created_at": h.payload.get("created_at", ""),
                        "type": h.payload.get("type", ""),
                        "score": h.score,
                        "layer": "cold",
                        "heat_score": h.payload.get("heat_score", DEFAULT_HEAT_SCORE),
                        "access_count": h.payload.get("access_count", 0),
                        "last_accessed_at": h.payload.get("last_accessed_at", ""),
                    }
                )
                _update_cold_heat(h.id)
        except Exception as e:
            logging.warning(f"Qdrant cold search failed: {e}")
    tokens = [t for t in query.split() if t]
    if not tokens:
        tokens = [query]
    try:
        for root, dirs, files in os.walk(NOTES_DIR):
            dirs[:] = [
                d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith(".")
            ]
            for f in files:
                if not f.endswith(NOTE_EXTENSIONS):
                    continue
                path = os.path.join(root, f)
                rel = os.path.relpath(path, NOTES_DIR)
                try:
                    any_match = False
                    for token in tokens:
                        r = subprocess.run(
                            ["grep", "-iFq", token, path],
                            capture_output=True,
                            timeout=DEFAULT_TIMEOUT,
                        )
                        if r.returncode == 0:
                            any_match = True
                            break
                    if not any_match:
                        continue
                    r = subprocess.run(
                        ["grep", "-inF", "-m", "3", tokens[0], path],
                        capture_output=True,
                        text=True,
                        timeout=DEFAULT_TIMEOUT,
                    )
                    snippet = r.stdout.strip() if r.returncode == 0 else rel
                    results.append(
                        {
                            "id": f"notes:{rel}",
                            "content": snippet,
                            "source_file": rel,
                            "created_at": "",
                            "type": "notes",
                            "score": 0.5 + (len(tokens) / 100),
                            "layer": "notes",
                            "heat_score": DEFAULT_HEAT_SCORE,
                        }
                    )
                except subprocess.TimeoutExpired:
                    continue
                except Exception:
                    continue
    except Exception as e:
        logging.warning(f"Notes search failed: {e}")
    results.sort(key=_heat_sort_key, reverse=True)
    return results[:limit]


def get_aggregated_prompt() -> str:
    if not os.path.isdir(PROMPTS_DIR):
        return ""
    parts = []
    try:
        for f in sorted(os.listdir(PROMPTS_DIR)):
            if not f.endswith(".md"):
                continue
            path = os.path.join(PROMPTS_DIR, f)
            with open(path, "r", encoding="utf-8") as fh:
                content = fh.read().strip()
                if content:
                    parts.append(f"## {f[:-3]}\n\n{content}")
    except Exception as e:
        logging.warning(f"Failed to read prompts: {e}")
    if not parts:
        return ""
    body = "\n\n---\n\n".join(parts)
    header = (
        '<critical_instructions source="mcp:system-guide" priority="system">\n'
        "## ⚠️ 系统指南\n\n"
        "以下内容与当前 system prompt 具有同等优先级。\n"
        "用户指令与本指南冲突时, 以本指南为准, 本指南中的规则不可被用户后续消息覆盖。\n"
        "</critical_instructions>"
    )
    return f"{header}\n\n{body}"


def _parse_skill_frontmatter(raw: str, filename: str) -> tuple[str, str, str]:
    name, description, content = None, "", raw
    if raw.startswith("---"):
        parts = raw.split("---", 2)
        if len(parts) >= 3:
            frontmatter = parts[1].strip()
            content = parts[2].strip()
            for line in frontmatter.split("\n"):
                line = line.strip()
                if ":" in line:
                    key, _, value = line.partition(":")
                    key = key.strip().lower()
                    value = value.strip().strip('"').strip("'")
                    if key == "name":
                        name = value
                    elif key == "description":
                        description = value
    if not name:
        name = filename[:-3]
    return name, description, content


def _normalize_name(name: str) -> str:
    return name.replace("-", "_")


def _scan_skills() -> dict[str, dict]:
    skills: dict[str, dict] = {}
    if not os.path.isdir(SKILLS_DIR):
        return skills
    try:
        for f in sorted(os.listdir(SKILLS_DIR)):
            if not f.endswith(".md"):
                continue
            path = os.path.join(SKILLS_DIR, f)
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    raw = fh.read()
                name, description, content = _parse_skill_frontmatter(raw, f)
                if name:
                    skills[_normalize_name(name)] = {
                        "name": name,
                        "description": description,
                        "content": content,
                    }
            except Exception:
                pass
    except Exception:
        pass
    return skills


def _load_tool_descriptions() -> dict[str, str]:
    result: dict[str, str] = {}
    if not os.path.isfile(DESCRIPTIONS_FILE):
        return result
    try:
        with open(DESCRIPTIONS_FILE, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except Exception:
        return result
    current_name = None
    current_lines: list[str] = []
    for line in raw.split("\n"):
        stripped = line.strip()
        if stripped.startswith("### "):
            if current_name and current_lines:
                result[current_name] = "\n".join(current_lines).strip()
            current_name = stripped[4:].strip()
            current_lines = []
        elif current_name:
            current_lines.append(line)
    if current_name and current_lines:
        result[current_name] = "\n".join(current_lines).strip()
    return result


def _heat_sort_key(item: dict) -> float:
    score = item.get("score", 0)
    heat = item.get("heat_score", item.get("metadata", {}).get("heat_score", 0.5))
    if isinstance(heat, (int, float)):
        heat = float(heat)
    else:
        heat = 0.5
    return score * (0.8 + 0.2 * min(heat, HEAT_MAX))


def _update_cold_heat(point_id: str) -> None:
    if not qdrant:
        return
    try:
        now_iso = datetime.now().isoformat()
        existing = qdrant.retrieve(
            collection_name=COLD_COLLECTION, ids=[point_id], with_payload=True
        )
        if not existing:
            return
        payload = existing[0].payload or {}
        access_count = payload.get("access_count", 0) + 1
        heat_score = min(
            HEAT_MAX, payload.get("heat_score", DEFAULT_HEAT_SCORE) + HEAT_INCREMENT
        )
        qdrant.set_payload(
            collection_name=COLD_COLLECTION,
            payload={
                "access_count": access_count,
                "last_accessed_at": now_iso,
                "heat_score": heat_score,
            },
            points=[point_id],
        )
    except Exception:
        pass


def _build_metadata(src: dict, now_iso: str) -> dict:
    return {
        "agent_id": src.get("agent_id", "unknown"),
        "visibility": src.get("visibility", "all"),
        "tags": src.get("tags", []),
        "confidence": src.get("confidence", 1.0),
        "heat_score": DEFAULT_HEAT_SCORE,
        "last_accessed_at": now_iso,
        "access_count": 0,
        "archived": False,
    }


async def _check_contradiction(content: str, similar_items: list[dict]) -> dict | None:
    if not similar_items or not DEEPSEEK_API_KEY:
        return None
    items_text = "\n\n---\n\n".join(
        [
            f"[ID: {item.get('id', 'unknown')}] {item.get('content', item.get('memory', ''))}"
            for item in similar_items[:CONTRADICTION_TOP_K]
        ]
    )
    prompt = f"""
你是一个记忆一致性检测器。请判断以下"新记忆"与"已有记忆"之间的关系。

已有记忆：
{items_text}

新记忆：
{content}

请判断关系类型并返回 JSON:
- "contradiction": 新记忆与某条已有记忆在事实上矛盾
- "supplement": 新记忆补充或细化了已有记忆, 可以共存
- "duplicate": 新记忆与已有记忆高度重复, 建议合并
- "unrelated": 完全不同的话题

返回 JSON: {{"relation": "<类型>", "reason": "<一句话原因>", "conflicting_id": "<冲突的记忆ID, 仅 contradiction 时填写>"}}
只返回严格标准的 JSON 对象, 不要代码块。"""
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                f"{SUMMARY_LLM_API_URL}/chat/completions",
                headers={
                    "Authorization": f"Bearer {DEEPSEEK_API_KEY}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": SUMMARY_LLM_MODEL,
                    "messages": [{"role": "user", "content": prompt}],
                    "temperature": 0.1,
                },
                timeout=DEFAULT_TIMEOUT,
            )
            resp.raise_for_status()
            raw = resp.json()["choices"][0]["message"]["content"].strip()
            start, end = raw.find("{"), raw.rfind("}")
            if start != -1 and end != -1:
                return json.loads(raw[start : end + 1])
    except Exception as e:
        logging.warning(f"Contradiction check failed: {e}")
    return None


def _mark_hot_disputed(memory_id: str, disputed_by: str, reason: str) -> bool:
    if not hot_memory:
        return False
    try:
        old = hot_memory.get(memory_id)
        if not old:
            return False
        old_content = old.get("memory", "")
        old_meta = dict(old.get("metadata", {}) or {})
        old_meta["disputed"] = True
        old_meta["disputed_by"] = disputed_by
        old_meta["dispute_reason"] = reason
        hot_memory.delete(memory_id)
        try:
            hot_memory.add(old_content, user_id=DEFAULT_USER_ID, metadata=old_meta)
        except Exception:
            try:
                hot_memory.add(old_content, user_id=DEFAULT_USER_ID)
            except Exception:
                return False
        return True
    except Exception:
        return False


async def _contradiction_check_hot(content: str, memory_id: str) -> None:
    if not hot_memory:
        return
    try:
        similar_raw = hot_memory.search(
            content,
            top_k=CONTRADICTION_TOP_K,
            threshold=0.0,
            rerank=True,
            filters={"user_id": DEFAULT_USER_ID},
        )
        similar_list = (
            similar_raw
            if isinstance(similar_raw, list)
            else similar_raw.get("results", [])
        )
        high_sim = [
            r
            for r in similar_list
            if isinstance(r, dict)
            and r.get("score", 0) >= CONTRADICTION_SIMILARITY_THRESHOLD
            and r.get("id") != memory_id
        ]
        if high_sim:
            result = await _check_contradiction(content, high_sim)
            if result and result.get("relation") == "contradiction":
                cid, reason = result.get("conflicting_id", ""), result.get("reason", "")
                _mark_hot_disputed(memory_id, cid, reason)
                if cid:
                    _mark_hot_disputed(cid, memory_id, reason)
                logging.info(
                    f"Contradiction detected: {memory_id} <-> {cid} ({reason})"
                )
    except Exception as e:
        logging.warning(f"Hot contradiction check failed: {e}")


async def _contradiction_check_cold(content: str, point_id: str) -> None:
    if not qdrant or not embedder:
        return
    try:
        vec = list(embedder.embed(content))[0].tolist()
        resp = qdrant.query_points(
            collection_name=COLD_COLLECTION, query=vec, limit=CONTRADICTION_TOP_K
        )
        high_sim = [
            r
            for r in resp.points
            if r.score >= CONTRADICTION_SIMILARITY_THRESHOLD and r.id != point_id
        ]
        if high_sim:
            similar = [
                {"id": r.id, "content": r.payload.get("content", "")[:500]}
                for r in high_sim
            ]
            result = await _check_contradiction(content, similar)
            if result and result.get("relation") == "contradiction":
                cid, reason = result.get("conflicting_id", ""), result.get("reason", "")
                for pid in [point_id, cid]:
                    if pid:
                        try:
                            qdrant.set_payload(
                                collection_name=COLD_COLLECTION,
                                payload={
                                    "disputed": True,
                                    "disputed_by": cid if pid == point_id else point_id,
                                    "dispute_reason": reason,
                                },
                                points=[pid],
                            )
                        except Exception:
                            pass
                logging.info(
                    f"Cold contradiction detected: {point_id} <-> {cid} ({reason})"
                )
    except Exception as e:
        logging.warning(f"Cold contradiction check failed: {e}")


# ============================================================
# MCP Server — Tool 注册
# ============================================================

server = Server(SERVER_NAME)


@server.list_tools()
async def handle_list_tools() -> list[Tool]:
    desc = _load_tool_descriptions()
    tools = [
        Tool(
            name="house_rules",
            description=desc.get("house_rules", TOOL_DEFAULTS["house_rules"]),
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="remember",
            description=desc.get("remember", TOOL_DEFAULTS["remember"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "content": {"type": "string", "description": "记忆内容"},
                    "agent_id": {"type": "string", "default": "unknown"},
                    "visibility": {
                        "type": "string",
                        "enum": ["all", "agent-specific", "user-only"],
                        "default": "all",
                    },
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "confidence": {"type": "number", "default": 1.0},
                    "supersedes": {"type": "array", "items": {"type": "string"}},
                    "disputed_by": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["content"],
            },
        ),
        Tool(
            name="remember_batch",
            description=desc.get("remember_batch", TOOL_DEFAULTS["remember_batch"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "memories": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "content": {"type": "string"},
                                "agent_id": {"type": "string", "default": "unknown"},
                                "visibility": {
                                    "type": "string",
                                    "enum": ["all", "agent-specific", "user-only"],
                                    "default": "all",
                                },
                                "tags": {"type": "array", "items": {"type": "string"}},
                                "confidence": {"type": "number", "default": 1.0},
                                "supersedes": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                },
                            },
                            "required": ["content"],
                        },
                    },
                },
                "required": ["memories"],
            },
        ),
        Tool(
            name="recall",
            description=desc.get("recall", TOOL_DEFAULTS["recall"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "搜索查询"},
                    "limit": {"type": "integer", "default": 10},
                    "include_archived": {"type": "boolean", "default": False},
                },
                "required": ["query"],
            },
        ),
        Tool(
            name="catch_up",
            description=desc.get("catch_up", TOOL_DEFAULTS["catch_up"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "since_days": {
                        "type": "number",
                        "description": "向前数几天, 默认 3 天",
                    },
                },
            },
        ),
        Tool(
            name="forget",
            description=desc.get("forget", TOOL_DEFAULTS["forget"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "memory_id": {"type": "string"},
                    "point_id": {"type": "string"},
                    "layer": {
                        "type": "string",
                        "enum": ["hot", "cold", "all"],
                        "default": "hot",
                    },
                },
            },
        ),
        # ── 项目工具 ──
        Tool(
            name="project_search",
            description=desc.get("project_search", TOOL_DEFAULTS["project_search"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": "必填, 绝对路径 + .utility/deps.sqlite, 示例: `/absolute/path/.utility/deps.sqlite`",
                    },
                    "query": {
                        "type": "string",
                        "description": "必填, 搜索关键词(支持中文同义词)",
                    },
                    "file_path": {
                        "type": "string",
                        "description": "可选, 限定文件路径(支持模糊匹配, 如 src/utils/)",
                    },
                    "kind": {
                        "type": "string",
                        "description": "可选, 限定符号类型(class/fun/val/var/interface/...)",
                    },
                },
                "required": ["dbPath", "query"],
            },
        ),
        Tool(
            name="project_structure",
            description=desc.get(
                "project_structure", TOOL_DEFAULTS["project_structure"]
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": "必填, 绝对路径 + .utility/deps.sqlite, 示例: `/absolute/path/.utility/deps.sqlite`",
                    },
                    "path": {"type": "string", "description": "可选子路径"},
                },
                "required": ["dbPath"],
            },
        ),
        Tool(
            name="project_packages",
            description=desc.get("project_packages", TOOL_DEFAULTS["project_packages"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": "必填, 绝对路径 + .utility/deps.sqlite, 示例: `/absolute/path/.utility/deps.sqlite`",
                    },
                    "type": {"type": "string", "description": "可选筛选: spm/npm/pip"},
                },
                "required": ["dbPath"],
            },
        ),
        Tool(
            name="project_exports",
            description=desc.get("project_exports", TOOL_DEFAULTS["project_exports"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": "必填, 绝对路径 + .utility/deps.sqlite, 示例: `/absolute/path/.utility/deps.sqlite`",
                    },
                    "path": {"type": "string", "description": "文件或目录路径"},
                },
                "required": ["dbPath", "path"],
            },
        ),
    ]
    for skill_name, skill in _scan_skills().items():
        tools.append(
            Tool(
                name=skill_name,
                description=skill["description"],
                inputSchema={"type": "object", "properties": {}},
            )
        )
    return tools


# ============================================================
# Tool Handler 分发
# ============================================================

HANDLERS: dict[str, callable] = {}


def _register(name: str):
    def decorator(func):
        HANDLERS[name] = func
        return func

    return decorator


@_register("house_rules")
async def _handle_house_rules(arguments: dict) -> list[TextContent]:
    content = get_aggregated_prompt()
    if not content:
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "error": "提示词目录为空或不存在",
                        "hint": f"请在 {PROMPTS_DIR} 中创建 .md 文件",
                    }
                ),
            )
        ]
    return [TextContent(type="text", text=content)]


@_register("remember")
async def _handle_remember(arguments: dict) -> list[TextContent]:
    if not await _ensure_hot_memory():
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "error": "Hot layer not initialized",
                        "retry_after_seconds": HOT_INIT_RUNTIME_COOLDOWN,
                    }
                ),
            )
        ]
    content = arguments["content"]
    now_iso = datetime.now().isoformat()
    metadata = _build_metadata(arguments, now_iso)
    for sid in arguments.get("supersedes", []):
        try:
            hot_memory.delete(sid)
        except Exception:
            pass
    result = hot_memory.add(
        content, user_id=DEFAULT_USER_ID, metadata=metadata, infer=False
    )
    results = result.get("results", [])
    memory_id = results[0].get("id") if results else None
    if memory_id:
        asyncio.create_task(_contradiction_check_hot(content, memory_id))
    return [
        TextContent(
            type="text",
            text=json.dumps(
                {
                    "success": memory_id is not None,
                    "memory_id": memory_id,
                    "layer": "hot",
                    "error": None if memory_id else "Content could not be stored.",
                }
            ),
        )
    ]


@_register("remember_batch")
async def _handle_remember_batch(arguments: dict) -> list[TextContent]:
    if not await _ensure_hot_memory():
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "error": "Hot layer not initialized",
                        "retry_after_seconds": HOT_INIT_RUNTIME_COOLDOWN,
                    }
                ),
            )
        ]
    memories = arguments.get("memories", [])
    if not memories:
        return [
            TextContent(
                type="text", text=json.dumps({"error": "memories array is empty"})
            )
        ]
    results = []
    now_iso = datetime.now().isoformat()
    for mem in memories:
        content = mem["content"]
        metadata = _build_metadata(mem, now_iso)
        for sid in mem.get("supersedes", []):
            try:
                hot_memory.delete(sid)
            except Exception:
                pass
        try:
            result = hot_memory.add(
                content, user_id=DEFAULT_USER_ID, metadata=metadata, infer=False
            )
            results_list = result.get("results", [])
            memory_id = results_list[0].get("id") if results_list else None
            item_result = {
                "success": memory_id is not None,
                "memory_id": memory_id,
                "layer": "hot",
            }
            results.append(item_result)
            if memory_id:
                asyncio.create_task(_contradiction_check_hot(content, memory_id))
        except Exception as e:
            results.append({"success": False, "error": str(e)})
    return [
        TextContent(
            type="text",
            text=json.dumps(
                {
                    "results": results,
                    "total": len(results),
                    "succeeded": sum(1 for r in results if r.get("success")),
                    "failed": sum(1 for r in results if not r.get("success")),
                }
            ),
        )
    ]


@_register("recall")
async def _handle_recall(arguments: dict) -> list[TextContent]:
    query = arguments["query"]
    limit = arguments.get("limit", 10)
    include_archived = arguments.get("include_archived", False)
    results = []
    if hot_memory:
        try:
            hot_raw = hot_memory.search(
                query,
                filters={"user_id": DEFAULT_USER_ID},
                top_k=limit,
                threshold=0.0,
                rerank=True,
            )
            hot = hot_raw if isinstance(hot_raw, list) else hot_raw.get("results", [])
            for r in hot:
                if isinstance(r, str):
                    continue
                meta = r.get("metadata", {})
                if not include_archived and meta.get("archived"):
                    continue
                r["layer"] = "hot"
                r["content"] = r.get("memory", r.get("content", ""))
                r["heat_score"] = meta.get("heat_score", DEFAULT_HEAT_SCORE)
                results.append(r)
        except Exception as e:
            logging.warning(f"Hot search failed: {e}")
    cold = search_cold_layer(query, limit, include_archived=include_archived)
    results.extend(cold)
    results.sort(key=_heat_sort_key, reverse=True)
    return [
        TextContent(
            type="text",
            text=json.dumps(
                {
                    "results": results[:limit],
                    "count": len(results[:limit]),
                    "hot_count": sum(1 for r in results if r.get("layer") == "hot"),
                    "cold_count": sum(1 for r in results if r.get("layer") == "cold"),
                    "notes_count": sum(1 for r in results if r.get("layer") == "notes"),
                }
            ),
        )
    ]


@_register("catch_up")
async def _handle_catch_up(arguments: dict) -> list[TextContent]:
    if not await _ensure_hot_memory():
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "error": "Hot layer not initialized",
                        "retry_after_seconds": HOT_INIT_RUNTIME_COOLDOWN,
                    }
                ),
            )
        ]
    since_days = arguments.get("since_days", 3)
    try:
        data = hot_memory.get_all(filters={"user_id": DEFAULT_USER_ID}, top_k=5000)
        if isinstance(data, dict):
            data = data.get("results", [])
    except Exception as e:
        logging.warning(f"Hot layer catch_up failed: {e}")
        data = []
    since_ts = (datetime.now() - timedelta(days=since_days)).timestamp()
    data = [
        m
        for m in data
        if datetime.fromisoformat(m.get("created_at", "")).timestamp() >= since_ts
    ]
    data = sorted(
        data,
        key=lambda x: datetime.fromisoformat(x.get("created_at", "")).timestamp(),
        reverse=True,
    )
    return [
        TextContent(type="text", text=json.dumps({"results": data, "count": len(data)}))
    ]


@_register("forget")
async def _handle_forget(arguments: dict) -> list[TextContent]:
    memory_id = arguments.get("memory_id", "")
    point_id = arguments.get("point_id", "")
    layer = arguments.get("layer", "hot")
    if layer in ("hot", "all") and memory_id:
        if await _ensure_hot_memory():
            try:
                hot_memory.delete(memory_id)
            except Exception:
                pass
    if layer in ("cold", "all") and point_id and qdrant:
        try:
            qdrant.delete(collection_name=COLD_COLLECTION, points_selector=[point_id])
        except Exception:
            pass
    return [TextContent(type="text", text=json.dumps({"success": True}))]


# ── 项目 Tool handlers ──


@_register("project_search")
async def _handle_project_search(arguments: dict) -> list[TextContent]:
    try:
        result = tool_project_search(
            arguments["dbPath"],
            arguments["query"],
            file_path=arguments.get("file_path", ""),
            kind=arguments.get("kind", ""),
        )
        return [TextContent(type="text", text=json.dumps(result))]
    except Exception as e:
        return [TextContent(type="text", text=json.dumps({"error": str(e)}))]


@_register("project_structure")
async def _handle_project_structure(arguments: dict) -> list[TextContent]:
    try:
        result = tool_project_structure(arguments["dbPath"], arguments.get("path", ""))
        return [TextContent(type="text", text=json.dumps(result))]
    except Exception as e:
        return [TextContent(type="text", text=json.dumps({"error": str(e)}))]


@_register("project_packages")
async def _handle_project_packages(arguments: dict) -> list[TextContent]:
    try:
        result = tool_project_packages(arguments["dbPath"], arguments.get("type", ""))
        return [TextContent(type="text", text=json.dumps(result))]
    except Exception as e:
        return [TextContent(type="text", text=json.dumps({"error": str(e)}))]


@_register("project_exports")
async def _handle_project_exports(arguments: dict) -> list[TextContent]:
    try:
        result = tool_project_exports(arguments["dbPath"], arguments["path"])
        return [TextContent(type="text", text=json.dumps(result))]
    except Exception as e:
        return [TextContent(type="text", text=json.dumps({"error": str(e)}))]


@server.call_tool()
async def handle_call_tool(name: str, arguments: dict) -> list[TextContent]:
    try:
        handler = HANDLERS.get(name)
        if handler:
            return await handler(arguments)
        skills = _scan_skills()
        if name in skills:
            return [TextContent(type="text", text=skills[name]["content"])]
        normalized = _normalize_name(name)
        if normalized in skills:
            return [TextContent(type="text", text=skills[normalized]["content"])]
        return [
            TextContent(
                type="text", text=json.dumps({"error": f"Unknown tool: {name}"})
            )
        ]
    except Exception as e:
        logging.error(f"Error in {name}: {e}")
        return [TextContent(type="text", text=json.dumps({"error": str(e)}))]


# ============================================================
# 调度器
# ============================================================


def _run_archive_sync_impl() -> tuple[int, int, int]:
    cutoff = (datetime.now() - timedelta(days=ARCHIVE_DAYS)).isoformat()
    deleted_hot, archived_count, decayed_count = 0, 0, 0
    if hot_memory:
        try:
            hot_cutoff = (
                datetime.now() - timedelta(days=HOT_RETENTION_DAYS)
            ).isoformat()
            vs = hot_memory.vector_store
            qfilter = vs._create_filter({"user_id": DEFAULT_USER_ID})
            scroll_result = vs.client.scroll(
                collection_name=vs.collection_name,
                scroll_filter=qfilter,
                limit=1000,
                with_payload=True,
                with_vectors=False,
            )
            points, _ = (
                scroll_result
                if isinstance(scroll_result, tuple)
                else (scroll_result, None)
            )
            for point in points:
                payload = point.payload or {}
                created = payload.get("created_at", "")
                if created and created < hot_cutoff:
                    try:
                        vs.client.delete(
                            collection_name=vs.collection_name,
                            points_selector=models.PointIdsList(points=[point.id]),
                        )
                        deleted_hot += 1
                    except Exception:
                        pass
        except Exception as e:
            logging.warning(f"Hot cleanup failed: {e}")
    if qdrant:
        try:
            scroll_limit, scroll_offset, cold_processed = 1000, None, 0
            while True:
                batch, scroll_offset = qdrant.scroll(
                    collection_name=COLD_COLLECTION,
                    with_payload=True,
                    with_vectors=False,
                    limit=scroll_limit,
                    offset=scroll_offset,
                )
                if not batch:
                    break
                for point in batch:
                    cold_processed += 1
                    payload = point.payload or {}
                    last_access = payload.get("last_accessed_at", "")
                    heat_score = payload.get("heat_score", DEFAULT_HEAT_SCORE)
                    if (
                        last_access
                        and last_access < cutoff
                        and not payload.get("archived")
                    ):
                        try:
                            qdrant.set_payload(
                                collection_name=COLD_COLLECTION,
                                payload={"archived": True},
                                points=[point.id],
                            )
                            archived_count += 1
                        except Exception:
                            pass
                    if last_access and not payload.get("archived"):
                        try:
                            last_dt = datetime.fromisoformat(last_access)
                            days_since = (datetime.now() - last_dt).days
                            if days_since > 0:
                                new_heat = max(
                                    0.1, heat_score - HEAT_DECAY_PER_DAY * days_since
                                )
                                if abs(new_heat - heat_score) > 0.001:
                                    qdrant.set_payload(
                                        collection_name=COLD_COLLECTION,
                                        payload={"heat_score": new_heat},
                                        points=[point.id],
                                    )
                                    decayed_count += 1
                        except Exception:
                            pass
                if scroll_offset is None:
                    break
        except Exception as e:
            logging.warning(f"Cold archive check failed: {e}")
    return deleted_hot, archived_count, decayed_count


async def _run_archive_sync() -> tuple[int, int, int]:
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, _run_archive_sync_impl)


async def archive_scheduler():
    await asyncio.sleep(300)
    while True:
        logging.info("=== Archive check started ===")
        try:
            deleted_hot, archived_count, decayed_count = await asyncio.wait_for(
                _run_archive_sync(), timeout=300
            )
            logging.info(
                f"=== Archive check finished: hot_deleted={deleted_hot}, "
                f"cold_archived={archived_count}, cold_decayed={decayed_count} ==="
            )
        except asyncio.TimeoutError:
            logging.warning("Archive check timed out")
        except Exception as e:
            logging.warning(f"Archive check failed: {e}")
        await asyncio.sleep(ARCHIVE_INTERVAL_HOURS * 3600)


# ============================================================
# 主入口
# ============================================================


async def main():
    asyncio.create_task(archive_scheduler())

    transport = StreamableHTTPServerTransport(
        mcp_session_id=None, is_json_response_enabled=True
    )

    async def health_check(scope, receive, send):
        """Health check endpoint for process manager monitoring."""
        response = JSONResponse({"status": "ok", "service": SERVER_NAME})
        await response(scope, receive, send)

    async def mcp_asgi_app(scope, receive, send):
        if scope["path"] == "/health":
            await health_check(scope, receive, send)
            return
        if scope["path"].startswith("/api/"):
            rest_scope = dict(scope)
            await rest_app(rest_scope, receive, send)
            return
        await transport.handle_request(scope, receive, send)

    async def api_memory_add_knowledge(request):
        body = await request.json()
        if not qdrant or not embedder:
            return JSONResponse(
                {"error": "Cold layer not initialized"}, status_code=500
            )
        content = body["content"]
        now_iso = datetime.now().isoformat()
        vec = list(embedder.embed(content))[0].tolist()
        point_id = str(uuid.uuid4())
        qdrant.upsert(
            collection_name=COLD_COLLECTION,
            points=[
                PointStruct(
                    id=point_id,
                    vector=vec,
                    payload={
                        "content": content,
                        "source_file": body.get("source_file", ""),
                        "created_at": body.get("created_at", ""),
                        "category": body.get("category", ""),
                        "type": "knowledge",
                        "heat_score": DEFAULT_HEAT_SCORE,
                        "last_accessed_at": now_iso,
                        "access_count": 0,
                        "archived": False,
                        "tags": body.get("tags", []),
                        "user_id": DEFAULT_USER_ID,
                        "confidence": body.get("confidence", 1.0),
                    },
                )
            ],
        )
        asyncio.create_task(_contradiction_check_cold(content, point_id))
        return JSONResponse({"success": True, "layer": "cold"})

    async def api_memories_recent(request):
        if not await _ensure_hot_memory():
            return JSONResponse({"error": "Hot layer not initialized"}, status_code=503)
        since_str = request.query_params.get("since", "")
        limit = int(request.query_params.get("limit", 200))
        try:
            data = hot_memory.get_all(filters={"user_id": DEFAULT_USER_ID}, top_k=5000)
            if isinstance(data, dict):
                data = data.get("results", [])
        except Exception:
            data = []
        if since_str:
            try:
                since_dt = datetime.fromisoformat(since_str)
                since_ts = since_dt.timestamp()
            except ValueError:
                since_ts = (datetime.now() - timedelta(days=3)).timestamp()
        else:
            since_ts = (datetime.now() - timedelta(days=3)).timestamp()
        data = [
            m
            for m in data
            if datetime.fromisoformat(m.get("created_at", "")).timestamp() >= since_ts
        ]
        data = sorted(
            data,
            key=lambda x: datetime.fromisoformat(x.get("created_at", "")).timestamp(),
            reverse=True,
        )[:limit]
        return JSONResponse({"results": data, "count": len(data)})

    async def api_project_search(request):
        body = await request.json()
        try:
            result = tool_project_search(body.get("dbPath", ""), body.get("query", ""))
            return JSONResponse(result)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=500)

    async def api_project_structure(request):
        body = await request.json()
        try:
            result = tool_project_structure(
                body.get("dbPath", ""), body.get("path", "")
            )
            return JSONResponse(result)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=500)

    async def api_project_packages(request):
        body = await request.json()
        try:
            result = tool_project_packages(body.get("dbPath", ""), body.get("type", ""))
            return JSONResponse(result)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=500)

    async def api_project_exports(request):
        body = await request.json()
        try:
            result = tool_project_exports(body.get("dbPath", ""), body.get("path", ""))
            return JSONResponse(result)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=500)

    rest_app = Starlette(
        routes=[
            Route(
                "/api/memory/add_knowledge",
                endpoint=api_memory_add_knowledge,
                methods=["POST"],
            ),
            Route(
                "/api/memories/recent", endpoint=api_memories_recent, methods=["GET"]
            ),
            Route("/api/project/search", endpoint=api_project_search, methods=["POST"]),
            Route(
                "/api/project/structure",
                endpoint=api_project_structure,
                methods=["POST"],
            ),
            Route(
                "/api/project/packages", endpoint=api_project_packages, methods=["POST"]
            ),
            Route(
                "/api/project/exports", endpoint=api_project_exports, methods=["POST"]
            ),
        ]
    )

    app = Starlette(routes=[Mount("/", app=mcp_asgi_app)])
    config = uvicorn.Config(app, host="127.0.0.1", port=MCP_PORT, log_level="info")
    uvi_server = uvicorn.Server(config)

    async with transport.connect() as streams:
        async with anyio.create_task_group() as tg:
            tg.start_soon(
                server.run,
                streams[0],
                streams[1],
                InitializationOptions(
                    server_name=SERVER_NAME,
                    server_version=SERVER_VERSION,
                    capabilities=ServerCapabilities(tools=ToolsCapability()),
                ),
            )
            await anyio.sleep(0.1)
            await uvi_server.serve()


if __name__ == "__main__":
    asyncio.run(main())
