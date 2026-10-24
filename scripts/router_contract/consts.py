"""Shared paths and constants for the cross-language contract checks."""
from __future__ import annotations

import ast
import copy
import json
import os
import pathlib
import re
import sys
from dataclasses import dataclass, replace

try:
    #: Group 7's criterion comes from aiohttp's own response-decoding capability probe, rather than
    #: maintaining a separate table of "which encodings are decodable" (a rewritten table would
    #: inevitably drift from the real capability). If aiohttp changes its internal layout, this
    #: **goes red** instead of staying silent: anything undetectable is treated as "not decodable",
    #: favoring a loud error over letting it pass.
    from aiohttp.compression_utils import HAS_BROTLI, HAS_ZSTD
except ImportError:  # pragma: no cover
    HAS_BROTLI = HAS_ZSTD = False


SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(SCRIPTS_DIR)
SOURCES = os.path.join(ROOT, "Sources")
SWIFT = os.path.join(SOURCES, "MCP", "TokenProxyManager.swift")
SCRIPTS = os.path.join(SOURCES, "MCPScripts")
CONSTANTS = os.path.join(SOURCES, "Core", "Constants.swift")
MCP_MANAGER = os.path.join(SOURCES, "MCP", "MCPProcessManager.swift")
CONFIG_PY = os.path.join(SCRIPTS, "utility", "core", "config.py")
SERVER_PY = os.path.join(SCRIPTS, "utility", "services", "mcp", "server.py")
TOOL_SCHEMA_PY = os.path.join(
    SCRIPTS, "utility", "services", "mcp", "server_tool_schema.py"
)
SYNONYMS_PY = os.path.join(SCRIPTS, "utility", "core", "synonyms.py")
TOOL_DEFAULTS_PY = os.path.join(SCRIPTS, "utility", "core", "tool_defaults.py")
OUTPUT_FILTER_PY = os.path.join(
    SCRIPTS, "utility", "services", "proxy", "proxy_output_filter.py"
)
RESPONSE_NOTE_PY = os.path.join(
    SCRIPTS, "utility", "services", "proxy", "proxy_response_note.py"
)
TOOL_TEXT_PY = os.path.join(SCRIPTS, "utility", "core", "tool_text.py")
TOKEN_PROXY_PY = os.path.join(SCRIPTS, "utility", "services", "proxy", "token_proxy.py")
PROXY_CONFIG_PY = os.path.join(SCRIPTS, "utility", "services", "proxy", "proxy_config.py")
PROXY_REWRITE_PY = os.path.join(SCRIPTS, "utility", "services", "proxy", "proxy_rewrite.py")
RESOURCES = os.path.join(SOURCES, "Resources")
PROMPTS = os.path.join(SCRIPTS, "prompts")
PROMPT_MANAGER = os.path.join(SOURCES, "Core", "PromptManager.swift")

#: Features of prompts already externalized into files → declared placeholders (the authoritative
#: value for the **baseline language**). Shared by Swift (`PromptManager`) and Python (`prompt_loader`).
PROMPT_FEATURES = {
    # Swift side (Translator)
    "translate": ("source", "target"),
    "translate_auto": ("first", "second"),
    # Python side (summarize / summary_rules / server)
    "quality_judge": (),
    "quality_judge_user": ("text",),
    "aggregate": ("label", "facts_text"),
    "merge_cross_batch": ("entries",),
    "extract_keywords": (
        "SUMMARY_KEYWORD_COUNT",
        "topic",
        "facts",
        "SEARCH_MIN_TOKEN_LEN",
    ),
    "decide_merge": ("topic", "facts", "candidates"),
    "gen_new": ("topic", "facts", "dir_tree", "tops_block", "exclude_dirs"),
    "gen_merge": ("topic", "facts", "target", "context"),
    "extract_rules": ("facts_text", "level_labels", "titles_block"),
    "prune_rules": ("level", "limit", "items"),
    "contradiction": ("items_text", "content"),
    # Python side (knowledge panel refill pipeline)
    "knowledge_expand": ("theme", "done", "scope", "exclude", "disliked"),
    "knowledge_gate": ("theme", "scope", "exclude", "concept", "why_now", "disliked"),
    "knowledge_card": ("theme", "concept", "evidence", "scope", "exclude"),
}
#: Baseline language: every feature must have it (it is the fallback target of any language, and missing it is universal breakage)
PROMPT_BASELINE_LANG = "zh-Hans"
#: Other provided languages. These are validated **by existence**: incremental translation is a
#: normal cadence, and forcing completeness would block normal flows like "write Chinese first, add English later".
PROMPT_OTHER_LANGS = ("en",)
#: Features with an L10n JSON fallback——only these require `Resources/<lang>.json` to contain the
#: same body text (Swift falls back to that text when the file is missing; Python has no such path).
L10N_BACKED_FEATURES = ("translate", "translate_auto")

#: Struct name of the providers Payload (defined in the inner scope of `providersJSON()`)
PROVIDER_STRUCT = "Payload"

#: Struct names of the clientAccel / clientText Payloads (also defined in the inner scope of the
#: method). Field names are directly snake_case (no CodingKeys needed) and match the Python contract key names.
CLIENT_STRUCTS = ("AccelPayload", "MatcherPayload", "TextPayload")

_FIELD_RE = re.compile(r"\blet\s+(\w+)\s*:")
_CASE_MAP_RE = re.compile(r'case\s+(\w+)\s*=\s*"([^"]+)"')
#: `static let name = "literal"` (value extraction of `EnvKeys` / `PythonScripts`)
_STATIC_LET_RE = re.compile(r'static\s+let\s+(\w+)\s*=\s*"([^"]+)"')
#: The form in Swift that **passes an env name into the child-process environment**:
#: `env["NAME"] = …` / `env[EnvKeys.xxx] = …` (the identifier before the brackets is arbitrary:
#: env / overrides / a local variable all count; verified there is no other form in this repo).
#: It deliberately does **not** match "any `"UPPER_SNAKE"` literal"——`EnvKeys`'s own declaration is a
#: string of such literals, and collecting by "has appeared" would make group 3 vacuously true;
#: see `collect_swift_env_injections`.
_SWIFT_ENV_ASSIGN_RE = re.compile(
    r'\b\w+\[\s*(?:"([A-Z][A-Z0-9_]{2,})"|EnvKeys\.(\w+))\s*\]\s*='
)
#: Python `get("NAME", ...)`. `config.py` is the sole read entry point of the common env layer
_PY_ENV_READ_RE = re.compile(r'\bget\(\s*"([A-Z][A-Z0-9_]+)"')
#: Env **read directly** by Python scripts (`os.environ.get("NAME"`). Script-specific envs do not go
#: into the `config.py` common layer, so group 3 did not see them at first——names like
#: `MODEL_PROXY_CLIENT_ACCEL` / `MODEL_PROXY_CLIENT_TEXT`, each written as a literal on both sides,
#: therefore had long had no assertion: when Swift renames and Python does not follow, the config
#: silently falls back to the built-in default with zero error (`MCP_SYNONYMS` was once caught
#: separately, which is exactly the same problem).
_PY_SCRIPT_ENV_READ_RE = re.compile(r'os\.environ\.get\(\s*"([A-Z][A-Z0-9_]+)"')
#: Env **self-set** by Python scripts (`os.environ["NAME"] = …`). These do not need Swift injection——
#: they must be excluded from "if read, someone must inject it", otherwise self-sufficient names like
#: `POSTHOG_DISABLED` / `MEM0_TELEMETRY` would always error (they are set by server.py itself before
#: import, precisely to avoid an external dependency).
_PY_SCRIPT_ENV_SET_RE = re.compile(r'os\.environ\[\s*"([A-Z][A-Z0-9_]+)"\s*\]\s*=')

#: Envs read directly by scripts but that **do not need** Swift injection —— the explicit exemptions
#: for the assertion. Each entry must state its reason: the whitelist is the only leak in the gate
#: "if read, someone must inject it", and a wrong entry costs more than a missing one (a real gap
#: would be silenced forever, and would look as if it had been checked).
_SCRIPT_ENV_EXEMPT: dict[str, str] = {
    # Provided by the system/interpreter, given by the shell, launchd, or CPython itself
    "PATH": "provided by the system (ast_extractor uses it to locate external parsers, not injected by Swift)",
    # Internal tuning knob: has a built-in default, is not part of the config.yaml config surface,
    # and is used only when env is set manually / in tests. If it ever becomes user-configurable,
    # a Swift injection point must be added at the same time——and it should then be removed from this table.
    "EMBED_QUERY_CACHE_SIZE": "internal tuning value with a built-in default (server_embed), not a user config surface",
}
#: How the service name is written on both sides
_PY_SERVER_NAME_RE = re.compile(r'SERVER_NAME\s*=\s*"([^"]+)"')
_SWIFT_SERVICE_RE = re.compile(r'service:\s*"([^"]+)"')
#: `PromptManager.fallbackLanguage = "zh-Hans"`
_SWIFT_FALLBACK_LANG_RE = re.compile(r'fallbackLanguage\s*=\s*"([^"]+)"')
#: How the synonym-table env name is written on both sides (this env does not go into config.py, so
#: it is outside group 3's coverage and is cross-asserted separately——otherwise, if Swift renames
#: and Python does not follow, the symptom is "the built-in table keeps working, but the synonyms I
#: configured silently stop working")
_PY_SYNONYMS_ENV_RE = re.compile(r'SYNONYMS_ENV_KEY\s*=\s*"([^"]+)"')
_SWIFT_SYNONYMS_ENV_RE = re.compile(r'synonymsEnvKey\s*=\s*"([^"]+)"')
#: How the tool-defaults env name is written on both sides (same as above; the script-specific env does not go through config.py)
_PY_TOOL_DEFAULTS_ENV_RE = re.compile(r'TOOL_DEFAULTS_ENV_KEY\s*=\s*"([^"]+)"')
_SWIFT_TOOL_DEFAULTS_ENV_RE = re.compile(r'toolDefaultsEnvKey\s*=\s*"([^"]+)"')
#: How the output-filter env name is written on both sides (same as above; the script-specific env does not go through config.py)
_PY_OUTPUT_FILTER_ENV_RE = re.compile(r'OUTPUT_FILTER_ENV_KEY\s*=\s*"([^"]+)"')
_SWIFT_OUTPUT_FILTER_ENV_RE = re.compile(r'outputFilterEnvKey\s*=\s*"([^"]+)"')
#: How the response-note toggle env name is written on both sides (same as above; the script-specific env does not go through config.py)
_PY_RESPONSE_NOTE_ENV_RE = re.compile(r'RESPONSE_NOTE_ENV_KEY\s*=\s*"([^"]+)"')
_SWIFT_RESPONSE_NOTE_ENV_RE = re.compile(r'responseNoteEnvKey\s*=\s*"([^"]+)"')
_PY_CONTEXT_WARN_ENV_RE = re.compile(r'CONTEXT_WARN_ENV_KEY\s*=\s*"([^"]+)"')
_SWIFT_CONTEXT_WARN_ENV_RE = re.compile(r'contextWarnEnvKey\s*=\s*"([^"]+)"')
