#!/usr/bin/env python3
"""
MCP MinoBraiN — hot/cold two-tier shared memory + project dependency-graph query

Hot layer: Mem0 → Qdrant (raw fragment memories, auto extract/dedup/conflict resolution)
Cold layer: Qdrant separate collection (archived knowledge index)
Project: SQLite dependency-graph query (FTS5 + synonym expansion)

Ported from self-service-docker, adapted for the Utility.app subprocess model.

Refactor (2026-08-30, phase 4): shared embedder → server_embed.py; project
dependency-graph query and note semantic search → server_search.py; this entry point
keeps memory operations / cold layer / skills / HTTP service / main().
"""

# mem0's built-in PostHog telemetry hangs initialization in an offline environment,
# so it must be disabled before any import
import os

os.environ["POSTHOG_DISABLED"] = "1"
# mem0 ships its own PostHog telemetry (a separate instance, unaffected by
# posthog.disabled); set this env var before import so AnonymousTelemetry skips init
os.environ["MEM0_TELEMETRY"] = "False"

import json
import uuid
import sys
import time
import asyncio
import anyio
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

from config import (
    ai_api_key,
    summary_model,
    summary_api_url,
    notes_dir,
)
from server_embed import (
    EMBEDDER_MODEL,
    EMBEDDER_DIMS,
    FASTEMBED_CACHE_DIR,
    _get_shared_embedder,
    describe_dim_mismatch,
    embed_query,
)
from server_search import (
    DEFAULT_PROJECT_SEARCH_LIMIT,
    DEFAULT_PROJECT_STRUCTURE_LIMIT,
    tool_project_search,
    tool_project_structure,
    tool_project_exports,
    _query_project_notes,
)
import llm_client
import prompt_loader
from tool_defaults import arg_default
from tool_text import param_text
from log_utils import setup_logging

logger = setup_logging("server")

QDRANT_PATH = os.environ.get(
    "QDRANT_PATH", os.path.expanduser("~/Documents/selfdata/database/qdrant_data")
)

MEM0_QDRANT_PATH = os.path.join(QDRANT_PATH, "mem0")


def _cleanup_qdrant_locks() -> None:
    """After a Qdrant Local mode crash, a leftover lock file blocks the next startup, so clean it up before starting."""
    for root_dir in (
        QDRANT_PATH,
        MEM0_QDRANT_PATH,
        os.path.expanduser("~/.mem0/migrations_qdrant"),
    ):
        lock = os.path.join(root_dir, ".lock")
        if os.path.isfile(lock):
            try:
                os.remove(lock)
                logger.info(f"Cleaned stale lock: {lock}")
            except OSError as e:
                logger.warning(f"Failed to remove lock {lock}: {e}")


_cleanup_qdrant_locks()

COLD_COLLECTION = "knowledge_base"

logger.info(
    f"ENV CHECK: FASTEMBED_CACHE_PATH={FASTEMBED_CACHE_DIR}, MCP_PORT={os.environ.get('MCP_PORT')}, "
    f"QDRANT_PATH={os.environ.get('QDRANT_PATH')}, MEM0_TELEMETRY={os.environ.get('MEM0_TELEMETRY')}"
)

NOTES_DIR = notes_dir()

SKILLS_DIR = os.path.join(NOTES_DIR, "MCP", "Skills")

#: Default result limit for recall. Authoritative source is
#: `tool_defaults.arg_default` (config surface: config.yaml `mcp.toolDefaults`); the
#: tool schema's default and the runtime fallback both use this constant, avoiding two
#: copies of the literal drifting into "schema declares 6, actually takes 8".
DEFAULT_RECALL_LIMIT = arg_default("recall", "limit")

#: Default result limit for project_notes. Same as above: the schema's default and the
#: handler fallback share it; previously both wrote the literal 5, and going through the
#: same table as the other tools leaves no room for drift.
DEFAULT_PROJECT_NOTES_LIMIT = arg_default("project_notes", "limit")

#: Fixed English tool descriptions; parameter guidance lives in `tool_text.PARAM_DESCRIPTIONS`.
TOOL_DESCRIPTIONS: dict[str, str] = {
    "remember": "Trigger: user says remember/record, a bug is fixed, an insight is learned, or an architecture design changes. Writes one fact to shared memory.",
    "remember_batch": "Batch version of remember; prefer it for multiple facts to cut calls.",
    "recall": "Trigger: user says look up/search/find that earlier one, or refers to history or existing information. Searches shared memory, knowledge base, and notes.",
    "catch_up": "Trigger: user says just now/last time/previously/recently, or asks what was done, the progress, or what remains unresolved. Do not substitute git log.",
    "forget": "Trigger: user asks to delete a memory, or a memory is wrong/outdated. Deletes it permanently.",
    "project_search": "Prefer over reading whole files to locate symbols, files, and packages. Searches the project dependency graph.",
    "project_structure": "Prefer over ls/find traversal to understand the project layout.",
    "project_exports": "Prefer over reading a whole file to get its public interface.",
    "project_notes": "Like recall, but searches local project notes only.",
    "tool_resource": "Load a file under references or a script under scripts when instructed.",
    "set_memory_processed": "Set or reset the processed bit of memories. Idempotent.",
}

EXCLUDE_DIRS = {"Self_Data", "Works_Jobs", "SaveWebPages", "Resources", "Attachments"}

NOTE_EXTENSIONS = (".md", ".txt", ".py", ".yaml", ".yml", ".json", ".toml")

# Can be overridden via the SERVER_TIMEOUT env var (the Swift layer reads it from GeneralConfig.httpTimeout)
DEFAULT_TIMEOUT = float(os.environ.get("SERVER_TIMEOUT", "60.0"))

SUMMARY_LLM_MODEL = summary_model()

SUMMARY_LLM_API_URL = summary_api_url()

AI_API_KEY = ai_api_key()

SUMMARY_LLM_TEMPERATURE = 0.1

DEFAULT_HEAT_SCORE = 1.0

HEAT_INCREMENT = 0.1

HEAT_MAX = 1.0

HEAT_DECAY_PER_DAY = 0.01

HOT_INIT_RUNTIME_COOLDOWN = 60

HOT_INIT_MAX_RUNTIME_FAILURES = 5

PROCESSED_FIELD = "processed"

PROCESSED_MAX_BIT = 7

#: Argument-validation text for `set_memory_processed`. The HTTP endpoint
#: (`api_memories_processed`) and the MCP tool (`_handle_set_memory_processed`) **share
#: the same set** — writing one copy each means changing one and forgetting the other,
#: giving the same error different messages on the two entry points; and this text is
#: *shown to the model*, so inconsistent wording only makes it harder to tell which
#: argument to fix. Unified to English: this layer (tool returns / internal logs) is not
#: tied to `UTILITY_LANG`; end-user-facing text is covered on the Swift side by `L10n`.
ERR_MEMORY_IDS_EMPTY = "memory_ids must not be empty"
ERR_VALUE_INVALID = "value must be 0 (reset) or 1 (set)"
ERR_BIT_VALUE_NOT_INT = "bit/value must be integers"

#: Entry-layer generic error: hot layer not ready. **6 places** (each tool handler + HTTP
#: endpoint) share one string — writing one copy each means changing one and forgetting
#: another, and the same state gets different messages under different tools, making it
#: hard for the caller to generalize how to retry.
ERR_HOT_LAYER_NOT_READY = "Hot layer not initialized"


def err_bit_out_of_range(bit: int | None = None) -> str:
    """Out-of-range text for bit. When `bit` is given, the actual value is appended — internal exceptions use it, and the log shows directly which value is out of range."""
    return f"bit out of range 0-{PROCESSED_MAX_BIT}" + (
        "" if bit is None else f": {bit}"
    )


ARCHIVE_DAYS = 90

HOT_RETENTION_DAYS = 180

ARCHIVE_INTERVAL_HOURS = 24

# Empty string = injected by the Swift layer via an env var (passes the current system username)
DEFAULT_USER_ID = os.environ.get("UTILITY_USER_ID", "")

CONTRADICTION_SIMILARITY_THRESHOLD = 0.8

CONTRADICTION_TOP_K = 5

SERVER_NAME = "mino-brain"

SERVER_VERSION = "1.0.0"

MCP_PORT = int(os.environ.get("MCP_PORT", "9001"))


def _patch_mem0_fastembed():
    """Monkey-patch mem0's FastEmbedEmbedding to enable memory-optimization parameters.

    The original mem0 implementation passes only model_name to TextEmbedding, missing
    optimization parameters like cache_dir/threads/providers. Here we replace the init
    logic directly, skipping the waste of creating the original TextEmbedding and then
    rebuilding it.
    """
    try:
        from mem0.embeddings.fastembed import FastEmbedEmbedding
        from mem0.embeddings.base import EmbeddingBase
        import fastembed

        def _optimized_init(self, config=None):
            # Call EmbeddingBase.__init__ directly to set config, skipping the
            # unoptimized TextEmbedding creation in FastEmbedEmbedding's original init
            EmbeddingBase.__init__(self, config)
            self.config.model = self.config.model or "thenlper/gte-large"
            self.dense_model = fastembed.TextEmbedding(
                model_name=self.config.model,
                cache_dir=FASTEMBED_CACHE_DIR,
                threads=1,
                providers=["CPUExecutionProvider"],
                enable_cpu_mem_arena=False,
            )
            if not self.config.embedding_dims:
                self.config.embedding_dims = self.dense_model.embedding_size

        FastEmbedEmbedding.__init__ = _optimized_init
        logger.info("Patched mem0 FastEmbedEmbedding with memory-optimized config")
    except ImportError:
        pass


_patch_mem0_fastembed()

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
            "api_key": AI_API_KEY,
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
    # mem0's built-in PostHog telemetry blocks initialization, so force-disable it
    try:
        import posthog

        posthog.disabled = True
    except ImportError:
        pass
    logger.info(
        f"Mem0 telemetry disabled (MEM0_TELEMETRY={os.environ.get('MEM0_TELEMETRY')}), "
        "PostHog network calls will be skipped"
    )
    for attempt in range(HOT_INIT_MAX_RETRIES):
        try:
            hot_memory = Memory.from_config(MEM0_CONFIG)
            logger.info("Mem0 (hot layer) initialized")
            return True
        except Exception as e:
            logger.warning(
                f"Hot layer init attempt {attempt + 1}/{HOT_INIT_MAX_RETRIES} failed: {e}"
            )
            if attempt < HOT_INIT_MAX_RETRIES - 1:
                time.sleep(HOT_INIT_RETRY_DELAY)
    logger.error(f"Hot layer init failed after {HOT_INIT_MAX_RETRIES} attempts")
    return False


def _collection_vector_size(client, collection_name: str) -> int | None:
    """Read a collection's vector dims; returns None if unreadable (the caller treats it
    as "cannot determine" and skips validation).

    This project uses a single-vector config; the named-vector (dict) form is also
    supported — crashing on the startup path just to read one dims value costs far more
    than the few lines it takes to support it.
    """
    try:
        vectors = client.get_collection(collection_name).config.params.vectors
    except Exception as e:
        logger.warning(f"failed to read dimension of collection {collection_name}: {e}")
        return None
    size = getattr(vectors, "size", None)
    if isinstance(size, int):
        return size
    if isinstance(vectors, dict):
        for config in vectors.values():
            value = getattr(config, "size", None)
            if isinstance(value, int):
                return value
    return None


try:
    qdrant = QdrantClient(path=QDRANT_PATH, force_disable_check_same_thread=True)
    existing = [c.name for c in qdrant.get_collections().collections]
    if COLD_COLLECTION not in existing:
        qdrant.create_collection(
            collection_name=COLD_COLLECTION,
            vectors_config=VectorParams(size=EMBEDDER_DIMS, distance=Distance.COSINE),
        )
        logger.info(f"Cold layer collection '{COLD_COLLECTION}' created")
    else:
        # Collection dims are fixed at first creation: after swapping the model (dims
        # change) the old vectors are not comparable with the new query vectors, and the
        # search side swallows the exception into a single warning — presenting as
        # cold-layer search silently failing. Call it out at startup.
        advice = describe_dim_mismatch(
            _collection_vector_size(qdrant, COLD_COLLECTION), EMBEDDER_DIMS
        )
        if advice:
            logger.error(advice)
            # Disable the cold layer, but hot layer / project search proceed as usual (all other qdrant usages have an `if qdrant` guard)
            qdrant = None
    if qdrant is not None:
        logger.info("Cold layer (Qdrant direct) initialized")
except Exception as e:
    logger.error(f"Cold layer Qdrant init failed: {e}")
    qdrant = None

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
    logger.error(
        f"Hot layer runtime recovery failed ({_hot_runtime_failures}/{HOT_INIT_MAX_RUNTIME_FAILURES})"
    )
    if _hot_runtime_failures >= HOT_INIT_MAX_RUNTIME_FAILURES:
        fail_msg = f"[{datetime.now().isoformat()}] HOT LAYER FATAL: {_hot_runtime_failures} consecutive init failures"
        logger.critical(fail_msg)
        sys.exit(1)
    return False


def _notes_snippet(text: str, needle: str, max_lines: int = 3) -> str:
    """Take the first max_lines lines containing needle, in the same format as the
    original `grep -inF -m <max_lines>`.

    Output looks like `12:foo\\n45:bar` (line number:line content, joined by newlines);
    returns an empty string when there is no hit.
    """
    if not needle:
        return ""
    hits: list[str] = []
    for line_no, line in enumerate(text.splitlines(), 1):
        if needle in line.lower():
            hits.append(f"{line_no}:{line}")
            if len(hits) >= max_lines:
                break
    return "\n".join(hits)


def search_cold_layer(
    query: str, limit: int = 5, include_archived: bool = False
) -> list[dict]:
    results = []
    qvec = embed_query(query) if qdrant else None
    if qdrant and qvec is not None:
        try:
            vec = qvec.tolist()
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
            logger.warning(f"Qdrant cold search failed: {e}")
    tokens = [t for t in query.split() if t]
    if not tokens:
        tokens = [query]
    needles = [t.lower() for t in tokens]
    head = needles[0]

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
                    with open(path, "r", encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    continue
                # A hit on any term counts as a hit (equivalent to the original
                # grep -iFq short-circuit semantics). The original implementation spawned
                # a grep subprocess per file per term; measured on 454 files × N terms:
                # 2.4s (N=1) / 4.5s (N=2) / 7.5s (N=4), recall's single biggest cost.
                low = text.lower()
                if not any(n in low for n in needles):
                    continue
                results.append(
                    {
                        "id": f"notes:{rel}",
                        "content": _notes_snippet(text, head) or rel,
                        "source_file": rel,
                        "created_at": "",
                        "type": "notes",
                        "score": 0.5 + (len(tokens) / 100),
                        "layer": "notes",
                        "heat_score": DEFAULT_HEAT_SCORE,
                    }
                )
    except Exception as e:
        logger.warning(f"Notes search failed: {e}")
    results.sort(key=_heat_sort_key, reverse=True)
    return results[:limit]


def _parse_skill_frontmatter(raw: str, filename: str) -> tuple[str, str, str, bool]:
    name, description, content, enabled = None, "", raw, True
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
                    elif key == "enable":
                        # 缺省或任何非 false 值都注册；只有显式 false 才跳过
                        enabled = value.lower() != "false"
    if not name:
        name = filename[:-3]
    return name, description, content, enabled


def _normalize_name(name: str) -> str:
    return name.replace("-", "_")


_SKILL_SKIP_DIRS = {"references", "agents", "scripts"}


def _scan_skills() -> dict[str, dict]:
    skills: dict[str, dict] = {}
    if not os.path.isdir(SKILLS_DIR):
        return skills
    try:
        # Recursively walk all subdirectories under SKILLS_DIR, scanning .md files deeply.
        # Only when the current directory is a Waza-style directory skill (containing
        # SKILL.md) do we skip its references/agents/scripts companion subdirectories and
        # register only SKILL.md itself; a plain directory without SKILL.md is not
        # skipped, and all .md files inside it (including those in references etc.
        # subdirectories) are registered as usual.
        for root, dirs, files in os.walk(SKILLS_DIR):
            if "SKILL.md" in files:
                dirs[:] = [d for d in dirs if d not in _SKILL_SKIP_DIRS]
                files = [f for f in files if f == "SKILL.md"]
            dirs.sort()
            for f in sorted(files):
                if not f.endswith(".md"):
                    continue
                path = os.path.join(root, f)
                try:
                    with open(path, "r", encoding="utf-8") as fh:
                        raw = fh.read()
                    name, description, content, enabled = _parse_skill_frontmatter(raw, f)
                    if name and enabled:
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


def _find_skill_dir(name: str) -> str | None:
    """Locate a skill directory by its registered name (post-normalize); returns the absolute path, or None if not found."""
    direct = os.path.join(SKILLS_DIR, name)
    if os.path.isfile(os.path.join(direct, "SKILL.md")):
        return direct
    # The registered name comes from SKILL.md frontmatter's name (post-normalize); the directory name may keep the original name/hyphens
    try:
        entries = os.listdir(SKILLS_DIR)
    except OSError:
        return None
    for entry in sorted(entries):
        skill_dir = os.path.join(SKILLS_DIR, entry)
        skill_md = os.path.join(skill_dir, "SKILL.md")
        if not os.path.isfile(skill_md):
            continue
        try:
            with open(skill_md, "r", encoding="utf-8") as fh:
                raw = fh.read()
        except Exception:
            continue
        fname, _, _, _ = _parse_skill_frontmatter(raw, skill_md)
        if fname and _normalize_name(fname) == name:
            return skill_dir
    return None


def _dumps(obj) -> str:
    """Unified outlet for tool output: ensure_ascii=False lets CJK be emitted as UTF-8 as-is.

    ASCII escaping inflates each non-ASCII character to 6 bytes \\uXXXX — measured at
    30% of recall's output.
    """
    return json.dumps(obj, ensure_ascii=False)


def _int_arg(arguments: dict, key: str, default: int) -> int:
    """Read an integer argument; missing/None/non-integer all fall back to default.

    When the client explicitly passes `null`, `arguments.get` returns None, and slicing
    with it directly (`all_found[:None]`) is **no truncation** — silently turning token
    governance off.
    """
    try:
        return int(arguments.get(key, default))
    except (TypeError, ValueError):
        return default


# mem0 hot-layer results are emitted as-is, and fields vary across versions; a blacklist
# would miss some, so a whitelist is used. Removal rationale: memory and content are
# byte-identical duplicates (measured 248/248, 38% of output); hash/role/user_id are
# unused by the model or always the same value; inside metadata, archived is already
# filtered server-side and heat_score is already lifted to the top level.
_HOT_RESULT_KEYS = (
    "id",
    "content",
    "score",
    "created_at",
    "updated_at",
    "agent_id",
    "attributed_to",
    "heat_score",
    "layer",
)
_HOT_META_KEYS = (
    "tags",
    "confidence",
    "last_accessed_at",
    "access_count",
    "disputed",
    "disputed_by",
    "dispute_reason",
)


def _project_hot_result(r: dict) -> dict:
    """Hot-layer result → model-facing shape. When `content` is missing, normalize it
    from `memory` — `get_all`'s raw result only has `memory`, and trimming strictly by
    the whitelist would trim the body away."""
    out = {k: r[k] for k in _HOT_RESULT_KEYS if k in r}
    if "content" not in out:
        out["content"] = r.get("memory", "")
    meta = r.get("metadata")
    if isinstance(meta, dict):
        kept = {k: meta[k] for k in _HOT_META_KEYS if k in meta}
        if kept:
            out["metadata"] = kept
    return out


def _heat_sort_key(item: dict) -> float:
    score = item.get("score", 0)
    heat = item.get("heat_score", (item.get("metadata") or {}).get("heat_score", 0.5))
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
        # Processed bitmask: bit0=1 means successfully processed by the summarization script (remaining bits reserved)
        "processed": 0,
    }


async def _check_contradiction(content: str, similar_items: list[dict]) -> dict | None:
    if not similar_items or not llm_client.is_configured():
        return None
    items_text = "\n\n---\n\n".join(
        [
            f"[ID: {item.get('id', 'unknown')}] {item.get('content', item.get('memory', ''))}"
            for item in similar_items[:CONTRADICTION_TOP_K]
        ]
    )
    prompt = prompt_loader.prompt(
        "contradiction",
        items_text=items_text,
        content=content,
    )
    raw = await llm_client.achat(
        prompt,
        temperature=0.1,
        timeout=DEFAULT_TIMEOUT,
        label="Contradiction check failed",
    )
    return llm_client.parse_json(raw)


def _mark_hot_disputed(memory_id: str, disputed_by: str, reason: str) -> bool:
    if not hot_memory:
        return False
    try:
        old = hot_memory.get(memory_id)
        if not old:
            return False
        old_content = old.get("memory", "")
        old_meta = dict(old.get("metadata", {}) or {})
        old_meta.setdefault(
            "processed", 0
        )  # carry over the processed bit so delete+add rebuild does not lose it
        old_meta["disputed"] = True
        old_meta["disputed_by"] = disputed_by
        old_meta["dispute_reason"] = reason
        hot_memory.delete(memory_id)
        try:
            hot_memory.add(old_content, user_id=DEFAULT_USER_ID, metadata=old_meta)
        except Exception as e:
            # A failure on the main path must be logged: previously it silently
            # degraded to an add without metadata, writing metadata=null and letting that
            # memory bypass the processed bit and be rescanned repeatedly
            logger.warning(
                f"[dispute] metadata rebuild failed, falling back to rebuild without it: {e}"
            )
            fallback_meta = {
                "processed": old_meta.get("processed", 0),
                "disputed": True,
                "disputed_by": disputed_by,
                "dispute_reason": reason,
            }
            try:
                hot_memory.add(
                    old_content, user_id=DEFAULT_USER_ID, metadata=fallback_meta
                )
            except Exception:
                return False
        return True
    except Exception:
        return False


def _set_processed_bit(memory_id: str, bit: int, value: int) -> bool:
    """Set/reset a specific bit of a memory's metadata['processed'] (bit0=summarized).

    Via mem0 update it changes only the payload without rebuilding vectors (data=None
    skips embed), and is idempotent; shared by the HTTP endpoint and the MCP tool, a
    single implementation.
    """
    if not hot_memory:
        return False
    if not (0 <= bit <= PROCESSED_MAX_BIT):
        raise ValueError(err_bit_out_of_range(bit))
    try:
        old = hot_memory.get(memory_id)
        if not old:
            return False
        meta = dict(old.get("metadata", {}) or {})
        flags = int(meta.get(PROCESSED_FIELD, 0) or 0)
        mask = 1 << bit
        meta[PROCESSED_FIELD] = flags | mask if value else flags & ~mask
        hot_memory.update(memory_id, metadata=meta)
        return True
    except Exception as e:
        logger.warning(
            f"failed to set processed bit {memory_id} bit={bit} value={value}: {e}"
        )
        return False


_pending_contradictions: set[asyncio.Task] = set()

_MAX_CONTRADICTION_TASKS = 5


async def _contradiction_check_hot(content: str, memory_id: str) -> None:
    if not hot_memory:
        return
    try:
        # No rerank passed: MEM0_CONFIG does not configure a reranker, so mem0's internal
        # `if rerank and self.reranker` is always false — passing it is a no-op that only
        # adds confusion.
        similar_raw = hot_memory.search(
            content,
            top_k=CONTRADICTION_TOP_K,
            threshold=0.0,
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
                logger.info(f"Contradiction detected: {memory_id} <-> {cid} ({reason})")
    except Exception as e:
        logger.warning(f"Hot contradiction check failed: {e}")


def _spawn_contradiction_check(coro) -> None:
    """Spawn a contradiction check task, limiting concurrent tasks to avoid memory leak."""
    # Clean up completed tasks
    done = {t for t in _pending_contradictions if t.done()}
    _pending_contradictions.difference_update(done)
    if len(_pending_contradictions) >= _MAX_CONTRADICTION_TASKS:
        return  # too many backed up, skip and wait for the next round
    task = asyncio.create_task(coro)
    _pending_contradictions.add(task)


async def _contradiction_check_cold(content: str, point_id: str) -> None:
    if not qdrant:
        return
    emb = _get_shared_embedder()
    if emb is None:
        return
    try:
        vec = list(emb.embed(content))[0].tolist()
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
                logger.info(
                    f"Cold contradiction detected: {point_id} <-> {cid} ({reason})"
                )
    except Exception as e:
        logger.warning(f"Cold contradiction check failed: {e}")


server = Server(SERVER_NAME)


@server.list_tools()
async def handle_list_tools() -> list[Tool]:
    tools = [
        Tool(
            name="remember",
            description=TOOL_DESCRIPTIONS["remember"],
            inputSchema={
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": param_text("param.memory_content"),
                    },
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
            description=TOOL_DESCRIPTIONS["remember_batch"],
            inputSchema={
                "type": "object",
                "properties": {
                    "memories": {
                        "type": "array",
                        "description": param_text("param.memories"),
                        "items": {
                            "type": "object",
                            "properties": {
                                "content": {
                                    "type": "string",
                                    "description": param_text("param.memory_content"),
                                },
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
            description=TOOL_DESCRIPTIONS["recall"],
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": param_text("param.query"),
                    },
                    "limit": {
                        "type": "integer",
                        "default": DEFAULT_RECALL_LIMIT,
                        "description": param_text("param.max_results"),
                    },
                    "include_archived": {"type": "boolean", "default": False},
                },
                "required": ["query"],
            },
        ),
        Tool(
            name="catch_up",
            description=TOOL_DESCRIPTIONS["catch_up"],
            inputSchema={
                "type": "object",
                "properties": {
                    "since_days": {
                        "type": "number",
                        "description": param_text("param.since_days"),
                    },
                },
            },
        ),
        Tool(
            name="forget",
            description=TOOL_DESCRIPTIONS["forget"],
            inputSchema={
                "type": "object",
                "properties": {
                    "memory_id": {
                        "type": "string",
                        "description": param_text("param.memory_id"),
                    },
                    "point_id": {
                        "type": "string",
                        "description": param_text("param.point_id"),
                    },
                    "layer": {
                        "type": "string",
                        "enum": ["hot", "cold", "all"],
                        "default": "hot",
                        "description": param_text("param.layer"),
                    },
                },
            },
        ),
        Tool(
            name="set_memory_processed",
            description=TOOL_DESCRIPTIONS["set_memory_processed"],
            inputSchema={
                "type": "object",
                "properties": {
                    "memory_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": param_text("param.memory_ids"),
                    },
                    "bit": {
                        "type": "integer",
                        "default": 0,
                        "description": param_text("param.bit"),
                    },
                    "value": {
                        "type": "integer",
                        "default": 1,
                        "description": param_text("param.bit_value"),
                    },
                },
                "required": ["memory_ids"],
            },
        ),
        # ── Project tools ──
        Tool(
            name="project_search",
            description=TOOL_DESCRIPTIONS["project_search"],
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": param_text("param.db_path"),
                    },
                    "query": {
                        "type": "string",
                        "description": param_text("param.search_keyword"),
                    },
                    "file_path": {
                        "type": "string",
                        "description": param_text("param.file_path"),
                    },
                    "kind": {
                        "type": "string",
                        "description": param_text("param.symbol_kind"),
                    },
                    "limit": {
                        "type": "integer",
                        "default": DEFAULT_PROJECT_SEARCH_LIMIT,
                        "description": param_text("param.max_results"),
                    },
                },
                "required": ["dbPath", "query"],
            },
        ),
        Tool(
            name="project_structure",
            description=TOOL_DESCRIPTIONS["project_structure"],
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": param_text("param.db_path"),
                    },
                    "path": {
                        "type": "string",
                        "description": param_text("param.subpath"),
                    },
                    "limit": {
                        "type": "integer",
                        "default": DEFAULT_PROJECT_STRUCTURE_LIMIT,
                        "description": param_text("param.max_results"),
                    },
                },
                "required": ["dbPath"],
            },
        ),
        Tool(
            name="project_exports",
            description=TOOL_DESCRIPTIONS["project_exports"],
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": param_text("param.db_path"),
                    },
                    "path": {
                        "type": "string",
                        "description": param_text("param.file_or_dir"),
                    },
                },
                "required": ["dbPath", "path"],
            },
        ),
        Tool(
            name="project_notes",
            description=TOOL_DESCRIPTIONS["project_notes"],
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": param_text("param.notes_keyword"),
                    },
                    "path": {
                        "type": "string",
                        "description": param_text("param.project_dir"),
                    },
                    "limit": {
                        "type": "integer",
                        "default": DEFAULT_PROJECT_NOTES_LIMIT,
                        "description": param_text("param.max_results"),
                    },
                },
                "required": ["query", "path"],
            },
        ),
        Tool(
            name="tool_resource",
            description=TOOL_DESCRIPTIONS["tool_resource"],
            inputSchema={
                "type": "object",
                "properties": {
                    "parentName": {
                        "type": "string",
                        "description": param_text("param.parent_name"),
                    },
                    "path": {
                        "type": "string",
                        "description": param_text("param.resource_path"),
                    },
                },
                "required": ["parentName", "path"],
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


HANDLERS: dict[str, callable] = {}


def _register(name: str):
    def decorator(func):
        HANDLERS[name] = func
        return func

    return decorator


@_register("remember")
async def _handle_remember(arguments: dict) -> list[TextContent]:
    if not await _ensure_hot_memory():
        return [
            TextContent(
                type="text",
                text=_dumps(
                    {
                        "error": ERR_HOT_LAYER_NOT_READY,
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
        _spawn_contradiction_check(_contradiction_check_hot(content, memory_id))
    return [
        TextContent(
            type="text",
            text=_dumps(
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
                text=_dumps(
                    {
                        "error": ERR_HOT_LAYER_NOT_READY,
                        "retry_after_seconds": HOT_INIT_RUNTIME_COOLDOWN,
                    }
                ),
            )
        ]
    memories = arguments.get("memories", [])
    if not memories:
        return [
            TextContent(type="text", text=_dumps({"error": "memories array is empty"}))
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
                _spawn_contradiction_check(_contradiction_check_hot(content, memory_id))
        except Exception as e:
            results.append({"success": False, "error": str(e)})
    return [
        TextContent(
            type="text",
            text=_dumps(
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
    limit = _int_arg(arguments, "limit", DEFAULT_RECALL_LIMIT)
    include_archived = arguments.get("include_archived", False)
    # Lazy hot-layer init: skipping this step makes the first recall after a restart
    # silently drop the entire hot layer (`if hot_memory` is false so it is skipped and
    # hot_count is 0). Init failure does not terminate — the cold layer and notes do not
    # depend on the hot layer, so recall should degrade rather than fail.
    await _ensure_hot_memory()
    results = []
    if hot_memory:
        try:
            # No rerank passed: MEM0_CONFIG does not configure a reranker, so mem0's
            # internal `if rerank and self.reranker` is always false — passing it is a
            # no-op that only adds confusion.
            hot_raw = hot_memory.search(
                query,
                filters={"user_id": DEFAULT_USER_ID},
                top_k=limit,
                threshold=0.0,
            )
            hot = hot_raw if isinstance(hot_raw, list) else hot_raw.get("results", [])
            for r in hot:
                if isinstance(r, str):
                    continue
                meta = r.get("metadata") or {}
                if not include_archived and meta.get("archived"):
                    continue
                r["layer"] = "hot"
                r["content"] = r.get("memory", r.get("content", ""))
                r["heat_score"] = meta.get("heat_score", DEFAULT_HEAT_SCORE)
                results.append(_project_hot_result(r))
        except Exception as e:
            logger.warning(f"Hot search failed: {e}")
    cold = search_cold_layer(query, limit, include_archived=include_archived)
    results.extend(cold)
    results.sort(key=_heat_sort_key, reverse=True)
    # Per-layer counts must use the same basis as `count` — both taken from the
    # truncated list. Previously they were counted over the full `results`, and the sum
    # of the three could reach twice `count` (measured 10+1+9 for count=10), leading the
    # caller to think it got all the hot-layer hits.
    top = results[:limit]
    return [
        TextContent(
            type="text",
            text=_dumps(
                {
                    "results": top,
                    "count": len(top),
                    "hot_count": sum(1 for r in top if r.get("layer") == "hot"),
                    "cold_count": sum(1 for r in top if r.get("layer") == "cold"),
                    "notes_count": sum(1 for r in top if r.get("layer") == "notes"),
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
                text=_dumps(
                    {
                        "error": ERR_HOT_LAYER_NOT_READY,
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
        logger.warning(f"Hot layer catch_up failed: {e}")
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
        TextContent(
            type="text",
            text=_dumps(
                {"results": [_project_hot_result(m) for m in data], "count": len(data)}
            ),
        )
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
    return [TextContent(type="text", text=_dumps({"success": True}))]


@_register("set_memory_processed")
async def _handle_set_memory_processed(arguments: dict) -> list[TextContent]:
    if not await _ensure_hot_memory():
        return [
            TextContent(
                type="text",
                text=_dumps(
                    {
                        "error": ERR_HOT_LAYER_NOT_READY,
                        "retry_after_seconds": HOT_INIT_RUNTIME_COOLDOWN,
                    }
                ),
            )
        ]
    memory_ids = arguments.get("memory_ids", [])
    bit = int(arguments.get("bit", 0))
    value = int(arguments.get("value", 1))
    if not memory_ids:
        return [TextContent(type="text", text=_dumps({"error": ERR_MEMORY_IDS_EMPTY}))]
    if not (0 <= bit <= PROCESSED_MAX_BIT):
        return [
            TextContent(
                type="text",
                text=_dumps({"error": err_bit_out_of_range()}),
            )
        ]
    if value not in (0, 1):
        return [
            TextContent(
                type="text",
                text=_dumps({"error": ERR_VALUE_INVALID}),
            )
        ]
    results = []
    for mid in memory_ids:
        try:
            ok = await asyncio.to_thread(_set_processed_bit, mid, bit, value)
            results.append({"memory_id": mid, "success": ok})
        except Exception as e:
            results.append({"memory_id": mid, "success": False, "error": str(e)})
    return [
        TextContent(
            type="text",
            text=_dumps(
                {
                    "results": results,
                    "updated": sum(1 for r in results if r.get("success")),
                    "failed": sum(1 for r in results if not r.get("success")),
                }
            ),
        )
    ]


@_register("project_search")
async def _handle_project_search(arguments: dict) -> list[TextContent]:
    try:
        result = await asyncio.to_thread(
            tool_project_search,
            arguments["dbPath"],
            arguments["query"],
            file_path=arguments.get("file_path", ""),
            kind=arguments.get("kind", ""),
            limit=_int_arg(arguments, "limit", DEFAULT_PROJECT_SEARCH_LIMIT),
        )
        return [TextContent(type="text", text=_dumps(result))]
    except Exception:
        # Re-raise to handle_call_tool: returning {"error": ...} here makes the SDK treat
        # it as success, so a real failure is read by the client as "found it, just no
        # results". Logging is done uniformly by the fallback layer.
        raise


@_register("project_structure")
async def _handle_project_structure(arguments: dict) -> list[TextContent]:
    try:
        result = await asyncio.to_thread(
            tool_project_structure,
            arguments["dbPath"],
            arguments.get("path", ""),
            _int_arg(arguments, "limit", DEFAULT_PROJECT_STRUCTURE_LIMIT),
        )
        return [TextContent(type="text", text=_dumps(result))]
    except Exception:
        # Re-raise to handle_call_tool: returning {"error": ...} here makes the SDK treat
        # it as success, so a real failure is read by the client as "found it, just no
        # results". Logging is done uniformly by the fallback layer.
        raise


@_register("project_exports")
async def _handle_project_exports(arguments: dict) -> list[TextContent]:
    try:
        result = await asyncio.to_thread(
            tool_project_exports, arguments["dbPath"], arguments["path"]
        )
        return [TextContent(type="text", text=_dumps(result))]
    except Exception:
        # Re-raise to handle_call_tool: returning {"error": ...} here makes the SDK treat
        # it as success, so a real failure is read by the client as "found it, just no
        # results". Logging is done uniformly by the fallback layer.
        raise


@_register("project_notes")
async def _handle_project_notes(arguments: dict) -> list[TextContent]:
    try:
        query = arguments["query"]
        path = arguments["path"]
        limit = _int_arg(arguments, "limit", DEFAULT_PROJECT_NOTES_LIMIT)

        if not query or not query.strip():
            return [
                TextContent(
                    type="text",
                    text=_dumps({"error": "query must not be empty"}),
                )
            ]
        if not os.path.isdir(path):
            return [
                TextContent(
                    type="text",
                    text=_dumps({"error": f"project directory not found: {path}"}),
                )
            ]

        # Run on a background thread to avoid blocking the event loop (ONNX embedding is CPU-intensive)
        result = await asyncio.to_thread(
            _query_project_notes, path, query.strip(), limit
        )
        return [TextContent(type="text", text=_dumps(result))]

    except Exception:
        # Same as above: logging and isError are handled uniformly by handle_call_tool's fallback layer
        raise


@_register("tool_resource")
async def _handle_tool_resource(arguments: dict) -> list[TextContent]:
    parent_name = str(arguments.get("parentName", "")).strip()
    rel_path = str(arguments.get("path", "")).strip()
    if not parent_name or not rel_path:
        return [
            TextContent(
                type="text",
                text=_dumps({"error": "parentName and path are required"}),
            )
        ]
    skill_dir = _find_skill_dir(parent_name)
    if skill_dir is None:
        return [
            TextContent(
                type="text",
                text=_dumps({"error": f"skill not found: {parent_name}"}),
            )
        ]
    # Only allow referencing resources inside the companion subdirectories (references/agents/scripts)
    top = rel_path.split("/", 1)[0]
    if top not in _SKILL_SKIP_DIRS:
        return [
            TextContent(
                type="text",
                text=_dumps(
                    {"error": f"path must be under one of: {sorted(_SKILL_SKIP_DIRS)}"}
                ),
            )
        ]
    full = os.path.normpath(os.path.join(skill_dir, rel_path))
    if full != skill_dir and not full.startswith(skill_dir + os.sep):
        return [
            TextContent(
                type="text",
                text=_dumps({"error": "path escapes the skill directory"}),
            )
        ]
    # symlink protection: normpath only blocks syntactic ../ and does not resolve
    # symlinks. After resolving the real path it must still be inside the skill
    # directory's real path, preventing a symlink inside the skill's companion
    # directories from pointing at an external file and leaking information. Reads
    # uniformly use real_full (already resolved), avoiding a second follow between
    # validation and open (TOCTOU).
    real_skill = os.path.realpath(skill_dir)
    real_full = os.path.realpath(full)
    if real_full != real_skill and not real_full.startswith(real_skill + os.sep):
        return [
            TextContent(
                type="text",
                text=_dumps({"error": "path escapes the skill directory via symlink"}),
            )
        ]
    full = real_full
    if not os.path.isfile(full):
        return [
            TextContent(
                type="text",
                text=_dumps({"error": f"resource not found: {rel_path}"}),
            )
        ]
    try:
        with open(full, "r", encoding="utf-8") as fh:
            content = fh.read()
    except UnicodeDecodeError:
        return [
            TextContent(
                type="text",
                text=_dumps({"error": "resource is not utf-8 text"}),
            )
        ]
    except Exception as e:
        # Same as handle_call_tool: unexpected exceptions must be re-raised, otherwise isError is always False
        logger.error(f"[tool_resource] {e}", exc_info=True)
        raise
    return [TextContent(type="text", text=content)]


@server.call_tool()
async def handle_call_tool(name: str, arguments: dict) -> list[TextContent]:
    started = time.perf_counter()
    ok = True
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
        ok = False
        return [
            TextContent(type="text", text=_dumps({"error": f"Unknown tool: {name}"}))
        ]
    except Exception as e:
        # Must keep re-raising: returning a {"error": ...} TextContent here is, to the
        # SDK, "the tool returned normally" with isError staying False — a real failure is
        # treated as success by the client, just with an extra error field in the result,
        # leaving the caller no basis to retry or degrade. After re-raising, the SDK's
        # call_tool fallback turns it into isError=True.
        ok = False
        logger.error(f"Error in {name}: {e}", exc_info=True)
        raise
    finally:
        # Measurement anchor for latency auditing: round-trip time and success/failure of each tool call
        logger.info(
            f"tool_call name={name} ok={ok} "
            f"elapsed_ms={int((time.perf_counter() - started) * 1000)}"
        )


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
            logger.warning(f"Hot cleanup failed: {e}")
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
            logger.warning(f"Cold archive check failed: {e}")
    return deleted_hot, archived_count, decayed_count


async def _run_archive_sync() -> tuple[int, int, int]:
    # Same reason as recall: `_run_archive_sync_impl` only checks `if hot_memory` and does
    # not initialize it. If there is no hot-layer call for more than one archive period
    # (24h), archiving spins idly and only reports hot_deleted=0. It must be invoked on the
    # event loop (impl runs in the executor), hence it is placed here.
    await _ensure_hot_memory()
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, _run_archive_sync_impl)


async def archive_scheduler():
    await asyncio.sleep(300)
    while True:
        logger.info("=== Archive check started ===")
        try:
            deleted_hot, archived_count, decayed_count = await asyncio.wait_for(
                _run_archive_sync(), timeout=300
            )
            logger.info(
                f"=== Archive check finished: hot_deleted={deleted_hot}, "
                f"cold_archived={archived_count}, cold_decayed={decayed_count} ==="
            )
        except asyncio.TimeoutError:
            logger.warning("Archive check timed out")
        except Exception as e:
            logger.warning(f"Archive check failed: {e}")
        await asyncio.sleep(ARCHIVE_INTERVAL_HOURS * 3600)


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
        emb = _get_shared_embedder()
        if not qdrant or emb is None:
            return JSONResponse(
                {"error": "Cold layer not initialized"}, status_code=500
            )
        content = body["content"]
        now_iso = datetime.now().isoformat()
        vec = list(emb.embed(content))[0].tolist()
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
        _spawn_contradiction_check(_contradiction_check_cold(content, point_id))
        return JSONResponse({"success": True, "layer": "cold"})

    async def api_memories_recent(request):
        if not await _ensure_hot_memory():
            return JSONResponse({"error": ERR_HOT_LAYER_NOT_READY}, status_code=503)
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

    async def api_memories_processed(request):
        """Batch set/reset memory processed bits (bit0=summarized), idempotent; used by summarize write-back and test restoration."""
        if not await _ensure_hot_memory():
            return JSONResponse({"error": ERR_HOT_LAYER_NOT_READY}, status_code=503)
        try:
            body = await request.json()
        except Exception:
            return JSONResponse({"error": "invalid JSON body"}, status_code=400)
        memory_ids = body.get("memory_ids", [])
        try:
            bit = int(body.get("bit", 0))
            value = int(body.get("value", 1))
        except (TypeError, ValueError):
            return JSONResponse({"error": ERR_BIT_VALUE_NOT_INT}, status_code=400)
        if not memory_ids:
            return JSONResponse({"error": ERR_MEMORY_IDS_EMPTY}, status_code=400)
        if not (0 <= bit <= PROCESSED_MAX_BIT):
            return JSONResponse({"error": err_bit_out_of_range()}, status_code=400)
        if value not in (0, 1):
            return JSONResponse({"error": ERR_VALUE_INVALID}, status_code=400)
        updated = 0
        failed_ids = []
        for mid in memory_ids:
            try:
                if await asyncio.to_thread(_set_processed_bit, mid, bit, value):
                    updated += 1
                else:
                    failed_ids.append(mid)
            except Exception:
                failed_ids.append(mid)
        return JSONResponse(
            {
                "success": not failed_ids,
                "bit": bit,
                "value": value,
                "updated": updated,
                "failed": len(failed_ids),
                "failed_ids": failed_ids,
            }
        )

    async def api_project_search(request):
        body = await request.json()
        try:
            result = tool_project_search(
                body.get("dbPath", ""),
                body.get("query", ""),
                limit=_int_arg(body, "limit", DEFAULT_PROJECT_SEARCH_LIMIT),
            )
            return JSONResponse(result)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=500)

    async def api_project_structure(request):
        body = await request.json()
        try:
            result = tool_project_structure(
                body.get("dbPath", ""),
                body.get("path", ""),
                _int_arg(body, "limit", DEFAULT_PROJECT_STRUCTURE_LIMIT),
            )
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
            Route(
                "/api/memories/processed",
                endpoint=api_memories_processed,
                methods=["POST"],
            ),
            Route("/api/project/search", endpoint=api_project_search, methods=["POST"]),
            Route(
                "/api/project/structure",
                endpoint=api_project_structure,
                methods=["POST"],
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
