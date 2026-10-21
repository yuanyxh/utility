"""Constants shared by the MCP server modules.

Split out of server.py so `server_archive` (and later the memory handlers) can
read the same heat/processed/archive values without importing the entry module.
"""

from __future__ import annotations

import os

from utility.core.config import (
    ai_api_key,
    note_exclude_dirs,
    note_extensions,
    notes_dir,
    summary_api_url,
    summary_model,
)

COLD_COLLECTION = "knowledge_base"

# Paths and note-scan settings shared by server.py (cold client, lock cleanup)
# and server_memory.py (hot-layer config, notes search).
QDRANT_PATH = os.environ.get("QDRANT_PATH", "").strip()
if not QDRANT_PATH:
    raise RuntimeError(
        "QDRANT_PATH is required; Swift injects it for app-launched processes"
    )
MEM0_QDRANT_PATH = os.path.join(QDRANT_PATH, "mem0")

NOTES_DIR = notes_dir()
EXCLUDE_DIRS = note_exclude_dirs()
NOTE_EXTENSIONS = note_extensions(
    (".md", ".txt", ".py", ".yaml", ".yml", ".json", ".toml")
)

SUMMARY_LLM_MODEL = summary_model()
SUMMARY_LLM_API_URL = summary_api_url()
SUMMARY_LLM_TEMPERATURE = 0.1
AI_API_KEY = ai_api_key()

HOT_INIT_MAX_RETRIES = 3
HOT_INIT_RETRY_DELAY = 5

# Overridable via SERVER_TIMEOUT (Swift reads it from GeneralConfig.httpTimeout)
DEFAULT_TIMEOUT = float(os.environ.get("SERVER_TIMEOUT", "60.0"))

DEFAULT_HEAT_SCORE = 1.0
HEAT_INCREMENT = 0.1
HEAT_MAX = 1.0
HEAT_DECAY_PER_DAY = 0.01

HOT_INIT_RUNTIME_COOLDOWN = 60
HOT_INIT_MAX_RUNTIME_FAILURES = 5

PROCESSED_FIELD = "processed"
PROCESSED_MAX_BIT = 7

ERR_MEMORY_IDS_EMPTY = "memory_ids must not be empty"
ERR_VALUE_INVALID = "value must be 0 (reset) or 1 (set)"
ERR_BIT_VALUE_NOT_INT = "bit/value must be integers"
ERR_HOT_LAYER_NOT_READY = "Hot layer not initialized"


def err_bit_out_of_range(bit: int | None = None) -> str:
    """Out-of-range text for bit; the actual value is appended when provided."""
    return f"bit out of range 0-{PROCESSED_MAX_BIT}" + (
        "" if bit is None else f": {bit}"
    )


ARCHIVE_DAYS = 90
HOT_RETENTION_DAYS = 180
ARCHIVE_INTERVAL_HOURS = 24

# Empty string = injected by the Swift layer (current system username)
DEFAULT_USER_ID = os.environ.get("UTILITY_USER_ID", "")

CONTRADICTION_SIMILARITY_THRESHOLD = 0.8
CONTRADICTION_TOP_K = 5
