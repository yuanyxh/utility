"""Token usage recording layer for token_proxy.

Split out from token_proxy.py (2026-08-30, refactor stage 2): DB initialization,
usage field path resolution (UsageFieldResolver), request/response context
extraction, usage persistence. The code was moved verbatim without logic changes.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
from datetime import datetime, timedelta, timezone

import llm_client
from config import data_dir
from db import conn as dbconn
from log_utils import setup_logging
from proxy_client import load_client_text
from proxy_normalize import _result_text as result_text
from proxy_protocol import strip_injected_rules

# ---------------------------------------------------------------------------
# Configuration (identical to token_proxy.py before the split)
# ---------------------------------------------------------------------------

DB_DIR = data_dir()
DB_PATH = os.path.join(DB_DIR, "token_usage.sqlite")
# Independent DB for tool_output_log (same directory as token_usage.sqlite, managed separately)
TOOL_OUTPUT_DB_PATH = os.path.join(DB_DIR, "tool_output.sqlite")
# api_usage retention days (about 3 months); expired records are cleaned at startup
API_USAGE_RETENTION_DAYS = 90
# tool_output_log retention days (short-term, for shape analysis)
TOOL_OUTPUT_RETENTION_DAYS = 5
# gateway_log recording scope and retention: non-2xx + request body >=512KB warnings, retained 90 days
GATEWAY_LOG_SIZE_THRESHOLD = 512 * 1024
GATEWAY_LOG_RETENTION_DAYS = 90
# LLM configuration (for usage field path resolution, see UsageFieldResolver._ask_model) is now
# uniformly read by llm_client. The former three aliases LLM_API_URL/LLM_API_KEY/LLM_MODEL
# amounted to reading the same config a second time, and the "disabled when unconfigured" guard
# was scattered here — when the config is renamed here it would not error, only silently disable
# resolution.

# Client-injected text/tags (continuation prompts, summary prefixes, client tags): each client's
# values differ and change with versions, so they exist as a **configurable table**
# (config.yaml modelProxy.clientText → MODEL_PROXY_CLIENT_TEXT); when absent the built-in
# defaults of proxy_client are used (= behavior before the config surface, zero behavior change).
CLIENT_TEXT = load_client_text(os.environ.get("MODEL_PROXY_CLIENT_TEXT", ""))

logger = setup_logging("token_proxy", json_format=True)


def init_db():
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS api_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            request_type TEXT,
            context_summary TEXT,
            input_preview TEXT,
            input_message_count INTEGER,
            has_tool_result INTEGER DEFAULT 0,
            output_preview TEXT,
            output_type TEXT,
            stop_reason TEXT,
            response_valid INTEGER DEFAULT 1,
            model TEXT,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            latency_ms INTEGER DEFAULT 0,
            api_format TEXT,
            request_level TEXT DEFAULT 'core',
            tool_name TEXT,
            parent_id INTEGER,
            actual_user_input TEXT,
            error_message TEXT,
            route_tier TEXT,
            route_reason TEXT,
            profile_hash TEXT
        );
        CREATE TABLE IF NOT EXISTS usage_field_cache (
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            input_path TEXT,
            output_path TEXT,
            cache_read_path TEXT,
            cache_write_path TEXT,
            updated_at TEXT,
            PRIMARY KEY (provider, model)
        );
        -- Gateway-layer log: records non-2xx responses and oversized requests (written by middleware).
        -- Distinguished from api_usage: api_usage records token usage of successful requests;
        -- gateway_log records rejected/failed/warning requests, resolving the troubleshooting
        -- blind spot where an aiohttp-layer 413 over-limit etc. prevents the handler from running,
        -- leaving no record at all.
        CREATE TABLE IF NOT EXISTS gateway_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            method TEXT,
            path TEXT,
            content_length INTEGER,
            status_code INTEGER,
            error_type TEXT,
            error_message TEXT,
            latency_ms INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_gateway_log_timestamp ON gateway_log(timestamp);
        CREATE INDEX IF NOT EXISTS idx_api_usage_timestamp ON api_usage(timestamp);
        CREATE INDEX IF NOT EXISTS idx_api_usage_level ON api_usage(request_level);
    """)

    # Migration: add new columns to old tables (if absent)
    cursor = conn.execute("PRAGMA table_info(api_usage)")
    columns = [row[1] for row in cursor.fetchall()]
    if "request_level" not in columns:
        conn.execute(
            "ALTER TABLE api_usage ADD COLUMN request_level TEXT DEFAULT 'core'"
        )
        conn.execute("ALTER TABLE api_usage ADD COLUMN tool_name TEXT")
        conn.execute("ALTER TABLE api_usage ADD COLUMN parent_id INTEGER")
        conn.execute("ALTER TABLE api_usage ADD COLUMN actual_user_input TEXT")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_api_usage_level ON api_usage(request_level)"
        )
        # Backfill request_level from stop_reason
        conn.execute(
            "UPDATE api_usage SET request_level = 'process' WHERE stop_reason = 'tool_use'"
        )
        conn.commit()
    if "error_message" not in columns:
        conn.execute("ALTER TABLE api_usage ADD COLUMN error_message TEXT")
        conn.commit()

    # Migration: tiered-routing diagnostic columns (route_tier tier / route_reason decision
    # reason / profile_hash fingerprint of the conversation's agent type). It is the only means
    # to troubleshoot "why did this turn take this model" — the routing decision logs roll off
    # in token_proxy.log, and these two columns are the traceable history.
    if "route_tier" not in columns:
        conn.execute("ALTER TABLE api_usage ADD COLUMN route_tier TEXT")
        conn.execute("ALTER TABLE api_usage ADD COLUMN route_reason TEXT")
        conn.execute("ALTER TABLE api_usage ADD COLUMN profile_hash TEXT")
        conn.commit()
    # Migration: routing decision detail column. When a downgrade is blocked, record the
    # outside tool list; when upgrading, record the triggering signal name. The routing logs
    # roll off in token_proxy.log, and the detail column is the only persistent means to
    # troubleshoot "why was it not downgraded" — without it, the 3 hold_not_readonly return
    # points cannot be distinguished from the data side.
    if "route_detail" not in columns:
        conn.execute("ALTER TABLE api_usage ADD COLUMN route_detail TEXT")
        conn.commit()

    # Migration: remove three deprecated fields (session_id/project_path/estimated_cost_usd)
    # First DROP the indexes referencing the columns, then DROP COLUMN (SQLite constraint)
    if "session_id" in columns:
        conn.execute("DROP INDEX IF EXISTS idx_api_usage_session")
        conn.execute("ALTER TABLE api_usage DROP COLUMN session_id")
    if "project_path" in columns:
        conn.execute("DROP INDEX IF EXISTS idx_api_usage_project")
        conn.execute("ALTER TABLE api_usage DROP COLUMN project_path")
    if "estimated_cost_usd" in columns:
        conn.execute("ALTER TABLE api_usage DROP COLUMN estimated_cost_usd")
    conn.commit()

    # Fix history: a first-day interruption (stop_reason empty string '') was backfilled to
    # core by default; correct it to process. The current write logic maps empty stop_reason
    # to process, so new data will not produce this combination; idempotent and harmless.
    conn.execute(
        "UPDATE api_usage SET request_level = 'process' "
        "WHERE request_level = 'core' AND (stop_reason IS NULL OR stop_reason = '')"
    )
    conn.commit()

    # Three-month auto-cleanup: cutoff uses the same ISO format as timestamp, avoiding the
    # datetime('now') space format missing deletions on the boundary day
    cutoff = (
        datetime.now(timezone.utc) - timedelta(days=API_USAGE_RETENTION_DAYS)
    ).isoformat()
    conn.execute("DELETE FROM api_usage WHERE timestamp < ?", (cutoff,))
    conn.commit()
    conn.close()


def init_tool_output_db():
    """Initialize the independent tool_output_log DB (5-day retention).

    Column notes:
    - output_text_raw: raw output (the true value before proxy filtering), used for delta analysis
    - output_text: the content the proxy actually sent (equals raw when there is no filtering;
      diverges once filtering is live)
    - session_key: a hash of system+tools+first_user, aggregating total token consumption within one session
    """
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(TOOL_OUTPUT_DB_PATH)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS tool_output_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            api_usage_id INTEGER,
            timestamp TEXT NOT NULL,
            tool_name TEXT,
            tool_call_id TEXT,
            output_text TEXT,
            output_text_raw TEXT,
            output_size INTEGER,
            output_lines INTEGER,
            is_error INTEGER,
            stop_reason TEXT,
            model TEXT,
            route_tier TEXT,
            session_key TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_tool_output_timestamp ON tool_output_log(timestamp);
        CREATE INDEX IF NOT EXISTS idx_tool_output_tool_name ON tool_output_log(tool_name);
    """)

    # Migration: add new columns to the old DB (idempotent). Column names are hard-coded literals, not external input.
    existing = {
        row[1] for row in conn.execute("PRAGMA table_info(tool_output_log)").fetchall()
    }
    for col in ("output_text_raw", "session_key"):
        if col not in existing:
            conn.execute(f"ALTER TABLE tool_output_log ADD COLUMN {col} TEXT")

    # The session_key index must be created **after** the migration: the old DB must
    # first gain that column, otherwise "CREATE INDEX referencing a non-existent column"
    # makes initialization raise directly and the proxy fails to start.
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_tool_output_session ON tool_output_log(session_key)"
    )
    conn.commit()

    # Five-day auto-cleanup
    cutoff = (
        datetime.now(timezone.utc) - timedelta(days=TOOL_OUTPUT_RETENTION_DAYS)
    ).isoformat()
    conn.execute("DELETE FROM tool_output_log WHERE timestamp < ?", (cutoff,))
    conn.commit()
    conn.close()


# Gateway-layer log: middleware uniformly records rejected/failed/oversized requests,
# covering api_usage's troubleshooting blind spot. api_usage only records token usage of
# successful requests; when an aiohttp-layer 413 over-limit etc. prevents the handler from
# running, nothing is persisted.
_gateway_log_write_count = 0


def record_gateway_log(
    method, path, content_length, status_code, error_type, error_message, latency_ms
):
    """Write the gateway log: non-2xx responses + oversized request bodies. Retained 90 days; expired data is deleted every 200 writes."""
    global _gateway_log_write_count
    if status_code < 400 and (content_length or 0) < GATEWAY_LOG_SIZE_THRESHOLD:
        return
    try:
        with dbconn(DB_PATH) as c:
            c.execute(
                "INSERT INTO gateway_log (timestamp, method, path, content_length, status_code, "
                "error_type, error_message, latency_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    datetime.now(timezone.utc).isoformat(),
                    method,
                    path,
                    content_length,
                    status_code,
                    error_type,
                    error_message,
                    latency_ms,
                ),
            )
            _gateway_log_write_count += 1
            if _gateway_log_write_count % 200 == 0:
                cutoff = (
                    datetime.now(timezone.utc)
                    - timedelta(days=GATEWAY_LOG_RETENTION_DAYS)
                ).isoformat()
                c.execute("DELETE FROM gateway_log WHERE timestamp < ?", (cutoff,))
    except Exception:
        # A gateway-log failure does not affect the main flow
        pass


class UsageFieldResolver:
    """Intelligently locate the usage field path by provider/model.

    Known provider path mappings (avoiding LLM callbacks):
      - Anthropic/DeepSeek: usage.input_tokens / usage.output_tokens
      - OpenAI: usage.prompt_tokens / usage.completion_tokens
    """

    # Known field paths (model name prefix match → paths dict)
    _KNOWN_PATTERNS: list[tuple[str, dict]] = [
        (
            "anthropic",
            {
                "input_path": "usage.input_tokens",
                "output_path": "usage.output_tokens",
                "cache_read_path": "usage.cache_read_input_tokens",
                "cache_write_path": "usage.cache_creation_input_tokens",
            },
        ),
        (
            "claude",
            {
                "input_path": "usage.input_tokens",
                "output_path": "usage.output_tokens",
                "cache_read_path": "usage.cache_read_input_tokens",
                "cache_write_path": "usage.cache_creation_input_tokens",
            },
        ),
        (
            "deepseek",
            {
                "input_path": "usage.input_tokens",
                "output_path": "usage.output_tokens",
                "cache_read_path": "usage.cache_read_input_tokens",
                "cache_write_path": "usage.cache_creation_input_tokens",
            },
        ),
        (
            "gpt",
            {
                "input_path": "usage.prompt_tokens",
                "output_path": "usage.completion_tokens",
                "cache_read_path": "usage.prompt_tokens_details.cached_tokens",
                "cache_write_path": "",
            },
        ),
        (
            "o1",
            {
                "input_path": "usage.prompt_tokens",
                "output_path": "usage.completion_tokens",
                "cache_read_path": "",
                "cache_write_path": "",
            },
        ),
        (
            "o3",
            {
                "input_path": "usage.prompt_tokens",
                "output_path": "usage.completion_tokens",
                "cache_read_path": "",
                "cache_write_path": "",
            },
        ),
    ]

    def __init__(self):
        self._cache: dict[tuple[str, str], dict] = {}

    def _load_from_db(self, provider: str, model: str) -> dict | None:
        try:
            with dbconn(DB_PATH) as conn:
                row = conn.execute(
                    "SELECT input_path, output_path, cache_read_path, cache_write_path "
                    "FROM usage_field_cache WHERE provider=? AND model=?",
                    (provider, model),
                ).fetchone()
            if row:
                return {
                    "input_path": row[0],
                    "output_path": row[1],
                    "cache_read_path": row[2],
                    "cache_write_path": row[3],
                }
        except Exception:
            pass
        return None

    def _save_to_db(self, provider: str, model: str, paths: dict):
        try:
            with dbconn(DB_PATH) as conn:
                conn.execute(
                    "INSERT OR REPLACE INTO usage_field_cache "
                    "(provider, model, input_path, output_path, cache_read_path, cache_write_path, updated_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (
                        provider,
                        model,
                        paths.get("input_path", ""),
                        paths.get("output_path", ""),
                        paths.get("cache_read_path", ""),
                        paths.get("cache_write_path", ""),
                        datetime.now(timezone.utc).isoformat(),
                    ),
                )
        except Exception:
            pass

    async def _ask_model(self, sample_response: dict) -> dict | None:
        """Call the main model to identify the usage field path."""
        if not llm_client.is_configured():
            return None

        prompt = (
            "Analyze this API response JSON and identify the exact field paths for token usage. "
            "Return ONLY a JSON object with these keys: "
            "input_path, output_path, cache_read_path, cache_write_path. "
            "Each value is a dot-separated path like 'usage.input_tokens'. "
            "If a field doesn't exist, use empty string.\n\n"
            "Note: streaming SSE responses may nest usage under 'delta', "
            "e.g. delta.usage.input_tokens. Use the ACTUAL structure in the sample.\n\n"
            f"Response sample:\n{json.dumps(sample_response, indent=2)[:2000]}"
        )

        raw = await llm_client.achat(
            prompt,
            temperature=0,
            max_tokens=300,
            timeout=15,
            label="usage_resolver_ask_failed",
        )
        return llm_client.parse_json(raw)

    def _get_by_path(self, obj: dict, path: str):
        """Get a value by dot-separated path."""
        if not path:
            return None
        parts = path.split(".")
        cur = obj
        for p in parts:
            if isinstance(cur, dict) and p in cur:
                cur = cur[p]
            else:
                return None
        return cur

    async def resolve(self, response_body: dict, provider: str = "default") -> dict:
        """Resolve the usage fields, returning {input_tokens, output_tokens, cache_read_tokens, cache_write_tokens}."""
        model = response_body.get("model", "unknown")
        key = (provider, model)

        paths = self._cache.get(key) or self._load_from_db(provider, model)

        if not paths:
            # Try matching against known patterns
            for prefix, known_paths in self._KNOWN_PATTERNS:
                if model.lower().startswith(prefix):
                    paths = known_paths
                    self._cache[key] = paths
                    self._save_to_db(provider, model, paths)
                    break

        if not paths:
            # Auto-detect from the response body's usage field names
            usage_data = response_body.get("usage", {})
            if isinstance(usage_data, dict):
                if "input_tokens" in usage_data:
                    paths = {
                        "input_path": "usage.input_tokens",
                        "output_path": "usage.output_tokens",
                        "cache_read_path": "usage.cache_read_input_tokens",
                        "cache_write_path": "usage.cache_creation_input_tokens",
                    }
                elif "prompt_tokens" in usage_data:
                    paths = {
                        "input_path": "usage.prompt_tokens",
                        "output_path": "usage.completion_tokens",
                        "cache_read_path": "usage.prompt_tokens_details.cached_tokens",
                        "cache_write_path": "",
                    }
            if paths:
                self._cache[key] = paths
                self._save_to_db(provider, model, paths)

        if not paths:
            # First time seeing this model; call the model to identify
            paths = await self._ask_model(response_body)
            if paths:
                self._cache[key] = paths
                self._save_to_db(provider, model, paths)
                logger.info(
                    json.dumps(
                        {
                            "msg": "usage_resolver_new_model",
                            "model": model,
                            "paths": paths,
                        }
                    )
                )
            else:
                # Cannot identify; return zero values
                return self._zero_usage()

        # Extract values using the cached paths
        usage = {
            "input_tokens": self._safe_int(
                self._get_by_path(response_body, paths.get("input_path", ""))
            ),
            "output_tokens": self._safe_int(
                self._get_by_path(response_body, paths.get("output_path", ""))
            ),
            "cache_read_tokens": self._safe_int(
                self._get_by_path(response_body, paths.get("cache_read_path", ""))
            ),
            "cache_write_tokens": self._safe_int(
                self._get_by_path(response_body, paths.get("cache_write_path", ""))
            ),
        }

        # If all extracted values are 0, the paths may be stale; refresh once
        if all(v == 0 for v in usage.values()):
            refreshed_paths = await self._ask_model(response_body)
            if refreshed_paths and refreshed_paths != paths:
                self._cache[key] = refreshed_paths
                self._save_to_db(provider, model, refreshed_paths)
                usage = {
                    "input_tokens": self._safe_int(
                        self._get_by_path(
                            response_body, refreshed_paths.get("input_path", "")
                        )
                    ),
                    "output_tokens": self._safe_int(
                        self._get_by_path(
                            response_body, refreshed_paths.get("output_path", "")
                        )
                    ),
                    "cache_read_tokens": self._safe_int(
                        self._get_by_path(
                            response_body, refreshed_paths.get("cache_read_path", "")
                        )
                    ),
                    "cache_write_tokens": self._safe_int(
                        self._get_by_path(
                            response_body, refreshed_paths.get("cache_write_path", "")
                        )
                    ),
                }
                logger.info(
                    json.dumps(
                        {
                            "msg": "usage_resolver_refreshed",
                            "model": model,
                            "new_paths": refreshed_paths,
                        }
                    )
                )

        return usage

    @staticmethod
    def _safe_int(val) -> int:
        if val is None:
            return 0
        try:
            return int(val)
        except (ValueError, TypeError):
            return 0

    @staticmethod
    def _zero_usage() -> dict:
        return {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
        }


resolver = UsageFieldResolver()


#: **Registered** client-injected tags to strip from user text.
#:
#: Strip by name only; do not treat any `<...>` as a tag: when the user input contains
#: comparison operators (`if x < y and y > z`) or HTML fragments, a generic tag cleanup
#: eats the whole middle section — measured: `'if x < y and y > z: pass'` was cleaned to
#: `'if x z: pass'`, seriously distorting the log fields.
CLIENT_INJECTED_TAGS = CLIENT_TEXT.injected_tags

_TAG_RE = re.compile(
    r"</?(?:" + "|".join(re.escape(t) for t in CLIENT_INJECTED_TAGS) + r")\b[^>]*>",
    re.IGNORECASE,
)


def _extract_user_text(content) -> str:
    """Extract plain text from message content, skipping registered client-injected tags.

    Compatible with the Anthropic (content list of blocks) and OpenAI (content string) formats.
    """
    if content is None:
        return ""
    if isinstance(content, list):
        text_parts = [
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        content = " ".join(text_parts) if text_parts else ""
    # Strip the injected rule block first, **then** clean tags: the rule block precedes
    # the real user input, and running tag cleanup first could let the angle brackets in
    # the rule body eat `---rule_end` as well, causing the strip function to fail to find
    # the end marker and discard the real user input after the block.
    content_str = strip_injected_rules(str(content))
    # Strip only registered tags (both open and close tags); keep the remaining text as-is
    return _TAG_RE.sub("", content_str).strip()


#: Continuation-prompt prefixes (each client has its own value) — their body is the
#: previous turn's summary, not user input, so both the session identifier and user-input
#: extraction must skip them. See CLIENT_TEXT for the source.
CONTINUATION_PREFIXES = CLIENT_TEXT.continuation_prefixes

#: Compression-summary prefixes — the continuation request body after context compression
#: begins with it, and it is likewise the previous turn's summary rather than user input,
#: so it is skipped along with the continuation prompt (both input_preview and
#: actual_user_input read these two constants).
SUMMARY_PREFIXES = CLIENT_TEXT.summary_prefixes

#: The threshold (chars) for a "large user message" that misses the registered text. A user
#: message exceeding this length that is neither a continuation prompt nor a summary prefix
#: most likely comes from **unregistered** client-injected content. Register a sample so the
#: new client's text can be added to config.yaml modelProxy.clientText — otherwise it only
#: silently pollutes actual_user_input and the session identifier anchor (both are inputs to
#: downstream statistics and routing decisions).
UNREGISTERED_BLOB_MIN_CHARS = 2000


_OBSERVED_BLOBS: set[str] = set()
_OBSERVED_BLOB_LOG_LIMIT = 20


def _observe_unregistered_blob(content_str: str) -> None:
    if len(content_str) < UNREGISTERED_BLOB_MIN_CHARS:
        return
    # The same unregistered text repeats every turn: log each distinct head once, cap the total.
    sample = content_str[:80]
    if sample in _OBSERVED_BLOBS or len(_OBSERVED_BLOBS) >= _OBSERVED_BLOB_LOG_LIMIT:
        return
    _OBSERVED_BLOBS.add(sample)
    logger.info(
        json.dumps(
            {
                "msg": "client_text_miss",
                "length": len(content_str),
                "sample": sample,
            }
        )
    )


#: Truncation cap for the session identifier's system prefix (same order of magnitude as
#: proxy_normalize.SYSTEM_PREFIX_LIMIT). The cost of recomputing SHA256 per request for a
#: long system grows with the session; truncation does not affect the discriminating power
#: of "grouping the same kind of agent".
SESSION_SYSTEM_LIMIT = 4096

#: Truncation cap for the session identifier's first user instruction. The first instruction
#: is the task anchor; later feedback/confirmation turns do not affect it.
SESSION_FIRST_USER_LIMIT = 2048


def compute_session_key(body: dict) -> str:
    """Request body → session identifier (first 12 hex chars of SHA256).

    Semantics: same system + tools + first user instruction = same session. Used to
    aggregate session-level total token consumption and measure "whether filtering really
    saves money" — saving tokens once does not equal a lower total task cost (truncation
    makes the model re-read files and increases turns, so the total cost may rise).

    This function is implemented independently and relies on no upper-layer policy —
    aggregating sessions is purely about recording, unrelated to the forwarding layer.
    """
    parts: list[str] = []

    # system: **both protocols must be read**, not just the top-level field.
    # Anthropic's system is a top-level field (string or an array of text blocks);
    # OpenAI has no such field, its system is a message with role="system" in
    # messages[0]. Reading only the top level makes the system of an OpenAI request
    # always empty — session keys of different agents (the main/sub agent's system
    # differs) degenerate into the same one, and aggregate analysis is directly distorted.
    system = body.get("system", "")
    if not system:
        for msg in body.get("messages", []):
            if isinstance(msg, dict) and msg.get("role") == "system":
                system = msg.get("content", "")
                break
    if isinstance(system, list):
        system = "\n".join(
            b.get("text", "")
            for b in system
            if isinstance(b, dict) and b.get("type") == "text"
        )
    if system:
        parts.append(str(system)[:SESSION_SYSTEM_LIMIT])

    # tools: sort by name to eliminate client sort differences
    tool_names = []
    for t in body.get("tools") or []:
        if not isinstance(t, dict):
            continue
        fn = t.get("function")
        if isinstance(fn, dict):
            tool_names.append(fn.get("name", ""))
        else:
            tool_names.append(t.get("name", ""))
    parts.append("\x01".join(sorted(n for n in tool_names if n)))

    # first_user: skip the continuation prompt (its body is the previous turn's summary, not a user instruction)
    for msg in body.get("messages", []):
        if not isinstance(msg, dict) or msg.get("role") != "user":
            continue
        text = _extract_user_text(msg.get("content", ""))
        if text.startswith(CONTINUATION_PREFIXES):
            continue
        if text:
            parts.append(text[:SESSION_FIRST_USER_LIMIT])
            break

    h = hashlib.sha256()
    for p in parts:
        h.update(p.encode("utf-8", errors="replace"))
        h.update(b"\x00")
    return h.hexdigest()[:12]


def extract_request_context(body: dict) -> dict:
    """Extract context information from the Claude Code request body."""
    ctx = {
        "request_type": "conversation",
        "context_summary": "",
        "input_preview": "",
        "actual_user_input": "",
        "input_message_count": 0,
        "has_tool_result": 0,
    }

    messages = body.get("messages", [])
    ctx["input_message_count"] = len(messages)

    if body.get("tools"):
        ctx["request_type"] = "tool_use"

    # Check whether there is a tool_result (compatible with both formats)
    for msg in messages:
        if msg.get("role") == "tool":
            ctx["has_tool_result"] = 1
            ctx["request_type"] = "tool_result"
            break
        if isinstance(msg.get("content"), list):
            for block in msg["content"]:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    ctx["has_tool_result"] = 1
                    ctx["request_type"] = "tool_result"
                    break

    # Extract the last user message as context_summary
    for msg in reversed(messages):
        if msg.get("role") == "user":
            content_str = _extract_user_text(msg.get("content", ""))
            ctx["context_summary"] = content_str[:100]
            break

    # input_preview: concatenate the first 200 chars of all user messages, skipping continuation prompts
    user_texts = []
    for msg in messages:
        if msg.get("role") == "user":
            content_str = _extract_user_text(msg.get("content", ""))
            # skip continuation prompts
            if content_str.startswith(CONTINUATION_PREFIXES):
                continue
            # skip pure summary content
            if content_str.strip().startswith(SUMMARY_PREFIXES):
                continue
            # a long message that misses the registered text → register a sample (discover unregistered client injections)
            _observe_unregistered_blob(content_str)
            if content_str.strip():
                user_texts.append(content_str[:200])
    ctx["input_preview"] = " | ".join(user_texts)

    # actual_user_input: extract the user's actual input, skipping continuation prompts and system-reminder
    actual_parts = []
    for msg in messages:
        if msg.get("role") == "user":
            content_str = _extract_user_text(msg.get("content", ""))
            # skip the continuation prompt (its body is the previous turn's summary, not user input)
            if content_str.startswith(CONTINUATION_PREFIXES):
                continue
            # skip pure summary content
            if content_str.strip().startswith(SUMMARY_PREFIXES):
                continue
            # a long message that misses the registered text → register a sample (discover unregistered client injections)
            _observe_unregistered_blob(content_str)
            if content_str.strip():
                actual_parts.append(content_str[:500])
    ctx["actual_user_input"] = " | ".join(actual_parts) if actual_parts else ""

    return ctx


def extract_response_context(usage_data: dict) -> dict:
    """Extract response context from the usage data."""
    stop_reason = (
        usage_data.get("stop_reason")
        or (usage_data.get("delta") or {}).get("stop_reason")
        or ""
    )
    # Only error and empty responses count as invalid; max_tokens/end_turn/stop_sequence are all normal
    response_valid = 0 if stop_reason == "error" else 1

    # Extract error information
    error_message = ""
    if stop_reason == "error":
        error_data = usage_data.get("error", {})
        if isinstance(error_data, dict):
            error_message = error_data.get("message", str(error_data))
        elif isinstance(error_data, str):
            error_message = error_data
    elif usage_data.get("error"):
        error_data = usage_data.get("error", {})
        if isinstance(error_data, dict):
            error_message = error_data.get("message", str(error_data))
        elif isinstance(error_data, str):
            error_message = error_data

    return {
        "output_type": "text",
        "stop_reason": stop_reason,
        "response_valid": response_valid,
        "error_message": error_message,
    }


def extract_tool_outputs(body: dict, api_format: str = "anthropic") -> list[dict]:
    """Extract all tool outputs of the latest round of tool_result from the request body.

    Only the most recent round of tool_result is extracted — historical tool_result were
    already recorded in earlier requests; each request carries the full message history but
    old tool_result are not recorded again.

    The output text is extracted with `proxy_normalize._result_text` (the authoritative
    implementation for tool return content) and is **not cleaned at all** — this is the data
    source for shape analysis, and stripping injected rules or removing client tags would
    distort content like "the file happens to contain `<system-reminder>`". Rule injection
    only affects the last real user message and never lands on tool_result blocks, so no
    stripping is needed here anyway.

    Returns a list; each item contains: tool_name, tool_call_id, output_text, output_size,
    output_lines, is_error.
    """
    messages = body.get("messages", [])
    if not messages:
        return []

    tool_results = []

    if api_format == "openai":
        # OpenAI: role="tool" is a standalone message; search backwards for consecutive tool messages
        for msg in reversed(messages):
            if msg.get("role") != "tool":
                break
            text = result_text(msg.get("content", ""))
            tool_results.append(
                {
                    "tool_name": _resolve_openai_tool_name(messages, msg),
                    "tool_call_id": msg.get("tool_call_id", ""),
                    "output_text": text,
                    "output_text_raw": text,  # equals output_text when there is no filtering
                    "output_size": len(text.encode("utf-8")),
                    "output_lines": text.count("\n") + 1 if text else 0,
                    "is_error": None,  # OpenAI has no is_error field
                }
            )
        tool_results.reverse()  # restore chronological order
    else:
        # Anthropic: a role=user message contains content blocks with type=="tool_result"
        # search backwards for the last user message containing tool_result
        for msg in reversed(messages):
            if msg.get("role") != "user":
                continue
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            blocks = [
                b
                for b in content
                if isinstance(b, dict) and b.get("type") == "tool_result"
            ]
            if not blocks:
                continue
            # look up the paired tool_use to get the tool name
            tool_names = _resolve_tool_names(messages, blocks)
            for b in blocks:
                text = result_text(b.get("content", ""))
                is_err = b.get("is_error")
                tool_results.append(
                    {
                        "tool_name": tool_names.get(b.get("tool_use_id", ""), ""),
                        "tool_call_id": b.get("tool_use_id", ""),
                        "output_text": text,
                        "output_text_raw": text,  # equals output_text when there is no filtering
                        "output_size": len(text.encode("utf-8")),
                        "output_lines": text.count("\n") + 1 if text else 0,
                        # three states: True=failure / False=confirmed success / None=not provided by the protocol
                        "is_error": (
                            1 if is_err is True else (0 if is_err is False else None)
                        ),
                    }
                )
            break  # only process the last user message containing tool_result

    return tool_results


def _resolve_openai_tool_name(messages: list[dict], tool_msg: dict) -> str:
    """OpenAI tool message → paired tool_call function name.

    OpenAI role="tool" messages carry no tool name and require looking up the tool_calls
    in the assistant message by tool_call_id.
    """
    call_id = tool_msg.get("tool_call_id", "")
    if not call_id:
        return ""
    for msg in reversed(messages):
        for tc in msg.get("tool_calls") or []:
            if isinstance(tc, dict) and tc.get("id") == call_id:
                fn = tc.get("function") or {}
                return fn.get("name", "") if isinstance(fn, dict) else ""
    return ""


def _resolve_tool_names(
    messages: list[dict], tool_result_blocks: list[dict]
) -> dict[str, str]:
    """Look up the tool_use tool names paired with tool_result from the message history.

    Returns a {tool_use_id: tool_name} mapping.
    """
    needed_ids = {
        b.get("tool_use_id", "") for b in tool_result_blocks if b.get("tool_use_id")
    }
    if not needed_ids:
        return {}

    names: dict[str, str] = {}
    for msg in reversed(messages):
        if len(names) == len(needed_ids):
            break
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use":
                continue
            bid = block.get("id", "")
            if bid in needed_ids and bid not in names:
                names[bid] = block.get("name", "")
    return names


def record_tool_outputs(
    tool_outputs: list[dict],
    api_usage_id: int | None = None,
    stop_reason: str = "",
    model: str = "",
    session_key: str = "",
):
    """Write tool outputs into the independent tool_output_log DB.

    It belongs to a different DB file from api_usage and cannot share a transaction, so a
    separate connection is opened. A write failure is only logged and does not affect the
    main flow — tool output is analysis material and should not drag down usage recording.
    """
    if not tool_outputs:
        return

    now = datetime.now(timezone.utc).isoformat()
    try:
        with dbconn(TOOL_OUTPUT_DB_PATH) as c:
            c.executemany(
                "INSERT INTO tool_output_log "
                "(api_usage_id, timestamp, tool_name, tool_call_id, "
                "output_text, output_text_raw, output_size, output_lines, "
                "is_error, stop_reason, model, session_key) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                [
                    (
                        api_usage_id,
                        now,
                        t.get("tool_name", ""),
                        t.get("tool_call_id", ""),
                        t.get("output_text", ""),
                        t.get("output_text_raw", ""),
                        t.get("output_size", 0),
                        t.get("output_lines", 0),
                        t.get("is_error"),
                        stop_reason,
                        model,
                        session_key,
                    )
                    for t in tool_outputs
                ],
            )
    except Exception as e:
        logger.error(json.dumps({"msg": "tool_output_record_failed", "error": str(e)}))


async def record_usage(
    request_body: dict,
    response_body: dict,
    status: int,
    latency_ms: int,
    output_preview: str = "",
    error_message: str = "",
    tool_name_override: str = "",
    api_format: str = "anthropic",
    tool_outputs: list[dict] | None = None,
):
    """Record the token usage of one API call.

    The optional `tool_outputs` (produced by `extract_tool_outputs`) is written into
    tool_output_log as well, carrying this row's `api_usage_id` — the two tables belong to
    different DB files, and the auto-increment id can only be obtained here; splitting them
    into two background tasks to write would leave that column always NULL, breaking the
    correlation analysis between tool-output volume and token usage.
    """
    if status != 200:
        return

    # Resolve usage
    usage = await resolver.resolve(response_body)

    # Extract context
    req_ctx = extract_request_context(request_body)
    resp_ctx = extract_response_context(response_body)

    model = response_body.get("model", "unknown")
    stop_reason = resp_ctx["stop_reason"]

    # Use error_message from resp_ctx (if not provided)
    if not error_message:
        error_message = resp_ctx.get("error_message", "")

    # Determine request_level
    request_level = "core" if stop_reason == "end_turn" else "process"

    # Extract tool_name: SSE stream extraction takes priority > request-body assistant message fallback
    tool_name = tool_name_override
    if not tool_name and stop_reason == "tool_use":
        # Extract the tool name from the request (fallback)
        messages = request_body.get("messages", [])
        for msg in reversed(messages):
            if msg.get("role") == "assistant":
                content = msg.get("content", [])
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tool_name = block.get("name", "")
                            break
                if tool_name:
                    break

    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "request_type": req_ctx["request_type"],
        "context_summary": req_ctx["context_summary"],
        "input_preview": req_ctx["input_preview"],
        "actual_user_input": req_ctx["actual_user_input"],
        "input_message_count": req_ctx["input_message_count"],
        "has_tool_result": req_ctx["has_tool_result"],
        "output_preview": output_preview,
        "output_type": resp_ctx["output_type"],
        "stop_reason": stop_reason,
        "response_valid": resp_ctx["response_valid"],
        "model": model,
        "input_tokens": usage["input_tokens"],
        "output_tokens": usage["output_tokens"],
        "cache_read_tokens": usage["cache_read_tokens"],
        "cache_write_tokens": usage["cache_write_tokens"],
        "latency_ms": latency_ms,
        "api_format": api_format,
        "request_level": request_level,
        "tool_name": tool_name,
        "parent_id": None,
        "error_message": error_message,
    }

    try:
        with dbconn(DB_PATH) as conn:
            cursor = conn.execute(
                "INSERT INTO api_usage "
                "(timestamp, request_type, context_summary, "
                "input_preview, actual_user_input, input_message_count, has_tool_result, output_preview, "
                "output_type, stop_reason, response_valid, model, input_tokens, "
                "output_tokens, cache_read_tokens, cache_write_tokens, "
                "latency_ms, api_format, request_level, tool_name, parent_id, error_message) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    record["timestamp"],
                    record["request_type"],
                    record["context_summary"],
                    record["input_preview"],
                    record["actual_user_input"],
                    record["input_message_count"],
                    record["has_tool_result"],
                    record["output_preview"],
                    record["output_type"],
                    record["stop_reason"],
                    record["response_valid"],
                    record["model"],
                    record["input_tokens"],
                    record["output_tokens"],
                    record["cache_read_tokens"],
                    record["cache_write_tokens"],
                    record["latency_ms"],
                    record["api_format"],
                    record["request_level"],
                    record["tool_name"],
                    record["parent_id"],
                    record["error_message"],
                ),
            )
            record_id = cursor.lastrowid
        logger.info(
            json.dumps(
                {
                    "msg": "usage_recorded",
                    "model": model,
                    "input_tokens": usage["input_tokens"],
                    "output_tokens": usage["output_tokens"],
                    "latency_ms": latency_ms,
                    "request_level": request_level,
                    "tool_name": tool_name,
                }
            )
        )

        # Persist tool outputs: with api_usage_id association, for cross-analysis of "output volume ↔ token usage"
        if tool_outputs:
            record_tool_outputs(
                tool_outputs,
                api_usage_id=record_id,
                stop_reason=stop_reason,
                model=model,
                session_key=compute_session_key(request_body),
            )
    except Exception as e:
        logger.error(json.dumps({"msg": "usage_record_failed", "error": str(e)}))
