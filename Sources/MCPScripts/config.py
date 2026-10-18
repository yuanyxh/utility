"""Shared config reading layer.

The duplicated env reads and defaults of the three monoliths
(server.py / summarize.py / token_proxy.py) are consolidated here,
eliminating "the same variable read in 2-3 files, defaults hardcoded
and scattered" duplication.

Usage (flat same-directory import, reusing the log_utils/agent_call pattern):
    from config import ai_api_key, summary_model, summary_api_url, notes_dir, data_dir

Notes:
- This module is a pure function layer depending only on the os standard
  library; importing it has no side effects -- server.py's module-level
  side-effect ordering (setting POSTHOG_DISABLED/MEM0_TELEMETRY before
  importing mem0) is unaffected.
- All returns are expanded strings (defaults run through expanduser); the
  caller decides whether to wrap them in Path (e.g. summarize.py wraps with
  Path(...)).
- Script-specific env (MCP_PORT / MODEL_PROXY_* / QDRANT_PATH / EMBEDDER_MODEL
  etc.) is not in this layer -- only common variables duplicated across files
  are consolidated.
- SUMMARY_MODEL / SUMMARY_API_URL defaults differ per script: server/summarize
  use the real defaults, token_proxy uses an empty string as a
  "unconfigured = disable LLM calls" guard (see token_proxy _ask_model), so the
  accessors accept a default argument and behave exactly as before the split.
"""

from __future__ import annotations

import json
import os

# Empty string = injected by the Swift layer via env var; when not injected, the related feature is disabled
_DEFAULT_SUMMARY_MODEL = ""
_DEFAULT_SUMMARY_API_URL = ""
_DEFAULT_NOTES_DIR = ""
_DEFAULT_DATA_DIR = ""


def get(key: str, default: str = "") -> str:
    """Unified env read entry point."""
    return os.environ.get(key, default)


def ai_api_key() -> str:
    """Generic AI API key (shared by text generation and vector embedding, decoupled from provider).

    The env var `AI_API_KEY` is injected by Swift `EnvKeys.aiAPIKey`; the
    consistency of both sides is asserted by
    `scripts/check-router-config-contract.py`.
    """
    return get("AI_API_KEY", "")


def llm_timeout(default: float = 120.0) -> float:
    """LLM single-inference timeout (seconds). The env var `AI_LLM_TIMEOUT` is injected by Swift from `ai.llmTimeout`.

    Missing / non-numeric / non-positive values all fall back to `default`,
    consistent with the "0 = use default" convention of Swift's
    `OpenAIClient.init`. **Do not** apply the `general.httpTimeout` convention
    of "0 = unlimited": the same 0 means the opposite in the two configs and is
    the easiest way to misconfigure "never timeout".
    """
    raw = get("AI_LLM_TIMEOUT", "")
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def ui_language(default: str = "") -> str:
    """UI/prompt language (`zh-Hans` / `en`). Swift injects `UTILITY_LANG` from `general.language`.

    The prompt directory is selected by it (`prompts/<lang>/<feature>.md`), so
    it must share the same source as the UI language. When not injected it
    returns an empty string, and the caller (prompt_loader) falls back to the
    baseline language.
    """
    return get("UTILITY_LANG", default)


def summary_model(default: str = _DEFAULT_SUMMARY_MODEL) -> str:
    return get("SUMMARY_MODEL", default)


def summary_api_url(default: str = _DEFAULT_SUMMARY_API_URL) -> str:
    return get("SUMMARY_API_URL", default)


def notes_dir(default: str = _DEFAULT_NOTES_DIR) -> str:
    raw = get("NOTES_DIR", default)
    if not raw:
        return ""
    return os.path.expanduser(raw)


def data_dir(default: str = _DEFAULT_DATA_DIR) -> str:
    raw = get("UTILITY_DATA_DIR", default)
    if not raw:
        return ""
    return os.path.expanduser(raw)


def summary_exclude_tags() -> set[str]:
    """Read the excluded tag list (comma-separated) from env var SUMMARY_EXCLUDE_TAGS."""
    raw = get("SUMMARY_EXCLUDE_TAGS", "")
    return {t.strip() for t in raw.split(",") if t.strip()}


def _int(raw: str, default: int) -> int:
    try:
        return int(raw)
    except (ValueError, TypeError):
        return default


def _json_list(raw: str) -> list:
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return []
    return data if isinstance(data, list) else []


def knowledge_domains() -> list:
    """碎片领域池种子（JSON 数组）。"""
    return _json_list(get("KNOWLEDGE_DOMAINS", ""))


def knowledge_topics() -> list[dict]:
    """主题种子（JSON 数组，元素 {name, kind}）。"""
    return [t for t in _json_list(get("KNOWLEDGE_TOPICS", "")) if isinstance(t, dict)]


def knowledge_topic_target(default: int = 3) -> int:
    return _int(get("KNOWLEDGE_TOPIC_TARGET", ""), default)


def knowledge_fragment_target(default: int = 5) -> int:
    return _int(get("KNOWLEDGE_FRAGMENT_TARGET", ""), default)


def knowledge_max_fail_streak(default: int = 3) -> int:
    return _int(get("KNOWLEDGE_MAX_FAIL_STREAK", ""), default)


def knowledge_max_shown(default: int = 2) -> int:
    """一张卡展示多少次后不再算「新鲜」；非正值回退默认（0 = 未配置）。"""
    value = _int(get("KNOWLEDGE_MAX_SHOWN", ""), default)
    return value if value > 0 else default
