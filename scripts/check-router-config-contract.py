#!/usr/bin/env python3
"""Check that the cross-language contracts between Swift and Python are consistent.

**The filename keeps its historical name** (it originally covered only the router, a feature that
has since been removed); the actual coverage has expanded to the entire cross-language contract
surface, in seven groups, each cross-asserted between "the real Swift source" and "the real Python
source" (groups 6/7 are Python-side static AST invariants: their failures are likewise "silent",
just not cross-language):

  1. providers —— `MODEL_PROXY_PROVIDERS` <-> `proxy_provider.KEY_*`
  2. client    —— `MODEL_PROXY_CLIENT_ACCEL` / `MODEL_PROXY_CLIENT_TEXT`
                  <-> `proxy_client.ACCEL_CONTRACT_KEYS` / `ACCEL_CLIENT_KEYS` /
                     `CLIENT_TEXT_CONTRACT_KEYS`
  3. env names —— the Swift-side **actual injection points** (`env["NAME"] = …` / `env[EnvKeys.xxx] = …`)
                  ⊇ the env var names read by `config.py`; the reverse asserts that every constant
                  declared in `EnvKeys` has an injection point
  4. process/convention —— service name (server.py <-> MCPProcessManager.swift), script names
                  (`PythonScripts` <-> actual files under `Sources/MCPScripts/*.py`),
                  synonym-table env name (`synonyms.SYNONYMS_ENV_KEY` <-> `synonymsEnvKey`),
                  tool-defaults env name (`tool_defaults.TOOL_DEFAULTS_ENV_KEY` <-> `toolDefaultsEnvKey`),
                  output-filter env name (`proxy_output_filter.OUTPUT_FILTER_ENV_KEY` <-> `outputFilterEnvKey`),
                  response-note env name (`proxy_response_note.RESPONSE_NOTE_ENV_KEY` <-> `responseNoteEnvKey`)
  5. prompts   —— `MCPScripts/prompts/<lang>/<feature>.md` is accepted by the **production parser**
                  (`prompt_loader.parse_template`), the placeholders match the baseline registration,
                  and the translated version's `json_keys` match the baseline; features with an L10n
                  fallback on the Swift side additionally require the body to be verbatim-identical
                  to `Resources/<lang>.json`; the baseline language is the same value on both sides
  6. param descriptions —— every parameter description in `server.py`'s `handle_list_tools()` must
                  come from `tool_text.param_text(...)` (no bare literals), referenced keys must
                  exist in `PARAM_TEXT`, the table must have no orphan keys, and each key's language
                  set must be consistent and include the baseline; the baseline language is the same
                  value as group 5
  7. upstream encoding —— when forwarding upstream, `token_proxy.py` must not pass through the
                  client's `accept-encoding`, must explicitly declare a whitelist, and every
                  encoding in the whitelist must be decodable by this process (the criterion comes
                  from aiohttp's `HAS_BROTLI`/`HAS_ZSTD`)

Background: once the two sides fall out of sync, Python silently falls back to a default value——
the feature looks fine, but the configuration never took effect. Historically 4 keys such as
`max_retries` were broken for a long time, because the fallback value happened to equal the
documented value so nobody noticed; the providers side likewise has a silent path where a missing
`api_format` falls back to anthropic, and that default flips the protocol-conversion direction
outright. The same holds for env names and script names: if Swift renames and Python does not
follow, an empty value is read, and the error only becomes visible on the next scheduled task.

This script extracts from **the real sources on both sides** (it does not read runtime state and
does not depend on built artifacts):
  - Swift: parse the `*Payload: Encodable` fields of `TokenProxyManager.swift` (the providers
    `Payload` is additionally mapped by `CodingKeys`, which is the key finally written into JSON),
    the `EnvKeys`/`PythonScripts` of `Constants.swift`, and the service name of
    `MCPProcessManager.swift`.
  - Python: import the contract constants of `proxy_provider` / `proxy_client`,
    and regex-read the env var names of `config.py` and the service name of `server.py`.

A failure exits with code 1. Usage (from the repo root):
    python3 scripts/check-router-config-contract.py
    python3 scripts/check-router-config-contract.py --selftest
"""

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

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources")
SWIFT = os.path.join(SOURCES, "MCP", "TokenProxyManager.swift")
SCRIPTS = os.path.join(SOURCES, "MCPScripts")
CONSTANTS = os.path.join(SOURCES, "Core", "Constants.swift")
MCP_MANAGER = os.path.join(SOURCES, "MCP", "MCPProcessManager.swift")
CONFIG_PY = os.path.join(SCRIPTS, "config.py")
SERVER_PY = os.path.join(SCRIPTS, "server.py")
SYNONYMS_PY = os.path.join(SCRIPTS, "synonyms.py")
TOOL_DEFAULTS_PY = os.path.join(SCRIPTS, "tool_defaults.py")
OUTPUT_FILTER_PY = os.path.join(SCRIPTS, "proxy_output_filter.py")
RESPONSE_NOTE_PY = os.path.join(SCRIPTS, "proxy_response_note.py")
TOOL_TEXT_PY = os.path.join(SCRIPTS, "tool_text.py")
TOKEN_PROXY_PY = os.path.join(SCRIPTS, "token_proxy.py")
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
    "contradiction": ("items_text", "content"),
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


def _read(path: str) -> str | None:
    try:
        return open(path, encoding="utf-8").read()
    except OSError:
        return None


def _extract_block(src: str, header: re.Pattern[str]) -> str | None:
    """Extract the body of the block matched by `header`, by brace balancing.

    Cannot reuse the non-greedy `struct … \\{ (.*?) \\n\\s*\\}`: the providers Payload has a nested
    CodingKeys, and non-greedy matching truncates there, dropping all the following fields.
    It works for both enums and structs like `EnvKeys` / `PythonScripts`, so it is extracted as a
    shared function.
    """
    m = header.search(src)
    if not m:
        return None
    depth = 1
    i = start = m.end()
    while i < len(src) and depth > 0:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return src[start : i - 1] if depth == 0 else None


def _extract_struct_body(src: str, struct_name: str) -> str | None:
    """Extract the body of `struct <name>: Encodable`, by brace balancing."""
    return _extract_block(
        src, re.compile(rf"struct\s+{re.escape(struct_name)}\s*:\s*Encodable\s*\{{")
    )


def _extract_enum_body(src: str, enum_name: str) -> str | None:
    """Extract the body of `enum <name> { … }`, by brace balancing (a trailing `: String` is also tolerated)."""
    return _extract_block(src, re.compile(rf"enum\s+{re.escape(enum_name)}\b[^{{]*\{{"))


def parse_swift_payloads(path: str) -> dict[str, set[str]]:
    src = _read(path)
    if src is None:
        print(f"[contract] cannot read {path}")
        sys.exit(2)

    out: dict[str, set[str]] = {}
    for name in (PROVIDER_STRUCT, *CLIENT_STRUCTS):
        body = _extract_struct_body(src, name)
        if body is not None:
            out[name] = set(_FIELD_RE.findall(body))
    if not out:
        print(
            f"[contract] parsed no *Payload struct in {path} —— regex mismatch, please update this script"
        )
        sys.exit(2)
    return out


def parse_provider_json_keys(path: str) -> set[str]:
    """The set of keys that the providers Payload finally writes into JSON.

    Swift property names are first mapped through `CodingKeys` (`apiFormat` → `api_format`);
    those without a mapping use the property name itself. Recognizing only property names would
    point the check at the wrong string.
    """
    src = _read(path)
    if src is None:
        return set()
    body = _extract_struct_body(src, PROVIDER_STRUCT)
    if body is None:
        return set()

    props = set(_FIELD_RE.findall(body))
    ck = re.search(
        r"enum\s+CodingKeys\s*:\s*String\s*,\s*CodingKey\s*\{(.*?)\}", body, re.S
    )
    mapped = dict(_CASE_MAP_RE.findall(ck.group(1))) if ck else {}
    # JSONEncoder writes property names verbatim by default; only those explicitly given in CodingKeys are rewritten
    return {mapped.get(p, p) for p in props}


def find_provider_violations(
    json_keys: set[str], contract: tuple[str, ...]
) -> list[str]:
    """Pure function: the providers contract violation list (also reverse-testable)."""
    if not json_keys:
        return [
            "Swift side could not parse the providers Payload struct (providersJSON)"
        ]
    return [
        f"providers.{key} missing —— Python silently falls back to the default after failing to read this key"
        for key in contract
        if key not in json_keys
    ]


def parse_static_lets(path: str, enum_name: str) -> dict[str, str]:
    """`static let CONST_NAME = "literal"` inside `enum <name>` body → {const name: literal}."""
    src = _read(path)
    if src is None:
        return {}
    body = _extract_enum_body(src, enum_name)
    return dict(_STATIC_LET_RE.findall(body)) if body else {}


def collect_swift_env_injections(
    sources_dir: str, env_keys: dict[str, str]
) -> set[str]:
    """The set of env names **actually injected** on the Swift side——not "this name appears in the source".

    The difference between the two is the entire point of this criterion. `EnvKeys`'s declaration is
    itself a string of `"UPPER_SNAKE"` literals, and collecting by "appears" makes it satisfy "if
    Python reads it, someone must inject it" on its own, so group 3 becomes **vacuously true**: it
    cannot catch the very class of missing injection it exists to prevent. `AI_LLM_TIMEOUT` and
    `UTILITY_LANG` were added only to `baseEnvironment()` and not to the internal `.sh` task
    whitelist, and that is how they slipped through——users who configured a timeout and a language
    got the default 120s and the Chinese prompt on the scheduled-summary path, with no error at all.

    Two forms are recognized (all injection points in this repo; verified there is no other form):
      `env["NAME"] = …` / `overrides["NAME"] = …`          literal key
      `env[EnvKeys.xxx] = …`                               constant key, expanded via `env_keys`
    """
    out: set[str] = set()
    for dirpath, _dirnames, filenames in os.walk(sources_dir):
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            src = _read(os.path.join(dirpath, name))
            if not src:
                continue
            for literal, const in _SWIFT_ENV_ASSIGN_RE.findall(src):
                if literal:
                    out.add(literal)
                elif const:
                    value = env_keys.get(const)
                    if value:
                        out.add(value)
    return out


def parse_python_env_reads(path: str) -> set[str]:
    """Env var names read by `get("NAME")` in `config.py` (the contract surface of the common env layer)."""
    return set(_PY_ENV_READ_RE.findall(_read(path) or ""))


def parse_python_script_envs(scripts_dir: str) -> tuple[set[str], set[str]]:
    """Env names read directly and self-set across all `MCPScripts/**.py`: `(reads, self_set)`.

    Besides the common layer (`config.py`) there is another class of **script-specific envs**:
    `MODEL_PROXY_*`, `MCP_SYNONYMS`, `QDRANT_PATH`, etc. are injected directly by Swift and read
    directly by scripts via `os.environ.get`. They were originally outside `config.py`'s collection
    scope, so drift like "Swift renames and Python does not follow" had no assertion at all (only
    `MCP_SYNONYMS` was once caught separately).

    The self-set class must be collected separately: they are set by the scripts themselves before
    import (`POSTHOG_DISABLED` is to stop mem0's telemetry from hanging at connection time), and
    they should have no Swift injection point; mixing them into the assertion would always error.
    """
    reads: set[str] = set()
    self_set: set[str] = set()
    for dirpath, _dirnames, filenames in os.walk(scripts_dir):
        for name in filenames:
            if not name.endswith(".py"):
                continue
            src = _read(os.path.join(dirpath, name))
            if not src:
                continue
            reads |= set(_PY_SCRIPT_ENV_READ_RE.findall(src))
            self_set |= set(_PY_SCRIPT_ENV_SET_RE.findall(src))
    return reads, self_set


def find_env_violations(
    python_reads: set[str], swift_injections: set[str]
) -> list[str]:
    """Pure function: env names that Python reads but have no **injection point** on the Swift side.

    Such names are always empty at runtime——the accessor returns the default and the feature silently
    stalls (e.g. when the AI key cannot be read, summarize just returns). The direction is one-way:
    names injected by Swift but not read by Python are not asserted, since some envs are for
    child processes / third-party clients, and a reverse assertion would produce false positives.

    ⚠️ Here you must pass "actually injected", not "appears in the source": the latter would be
    satisfied by `EnvKeys`'s declaration itself, making the criterion vacuously true. **This group
    guards against "a missing injection point"**——but that is a set-coverage problem, and an
    "appears" criterion can never see it (`collect_swift_env_injections`'s docstring records the
    specific incident).
    """
    if not python_reads:
        return [
            f"parsed no env read from {os.path.relpath(CONFIG_PY, ROOT)}"
            " —— regex mismatch, please update this script"
        ]
    return [
        f"env {name} —— Python reads it in config.py, but there is no injection point on the Swift side, so it is always empty at runtime"
        for name in sorted(python_reads)
        if name not in swift_injections
    ]


def find_script_env_violations(
    script_reads: set[str],
    script_self_set: set[str],
    swift_injections: set[str],
) -> list[str]:
    """Pure function: script-specific envs **read directly** by scripts but with no injection point on the Swift side.

    The common-layer one (`find_env_violations`) only looks at `config.py` and does not cover the
    batch read directly by scripts: `MODEL_PROXY_PORT` / `MODEL_PROXY_PROVIDERS` /
    `MODEL_PROXY_CLIENT_ACCEL` / `MODEL_PROXY_CLIENT_TEXT`, etc. Their names are written as literals
    on both sides, and renaming only one side makes the config **silently fall back to the built-in
    default**——the same class of problem as `MCP_SYNONYMS`, the only difference being that the latter
    was once caught separately.

    The self-set batch (`script_self_set`) must be excluded: those are set by the scripts themselves
    to bypass an external dependency (`POSTHOG_DISABLED`, etc.) and have no Swift injection point to begin with.
    """
    if not script_reads:
        return [
            f"parsed no direct os.environ read from {os.path.relpath(SCRIPTS, ROOT)}"
            " —— regex mismatch, please update this script"
        ]
    return [
        f"env {name} —— the Python script reads it directly, but there is no injection point on the Swift side, so it is always empty at runtime"
        for name in sorted(script_reads - script_self_set - set(_SCRIPT_ENV_EXEMPT))
        if name not in swift_injections
    ]


def find_env_injection_violations(
    env_keys: dict[str, str], swift_injections: set[str]
) -> list[str]:
    """Pure function: constants declared in `EnvKeys` that no injection point uses.

    Complementary to the previous one: that one guards against "config not readable" (Python reads
    but no one injects), this one guards against "registered but no one uses it"——the latter is
    exactly the half-done rename (the declaration changed, the `env[EnvKeys.xxx] = …` line was
    missed), which likewise yields an empty value at runtime.
    """
    if not env_keys:
        return [
            "parsed no EnvKeys from Constants.swift —— regex mismatch, please update this script"
        ]
    return [
        f"EnvKeys.{const} = {value!r} is declared, but no injection point on the Swift side uses it"
        for const, value in sorted(env_keys.items())
        if value not in swift_injections
    ]


def find_env_key_violations(
    env_keys: dict[str, str], python_reads: set[str]
) -> list[str]:
    """Pure function: names declared by `EnvKeys` that differ from the names Python actually reads.

    `EnvKeys` is the **single source** of these env names, and both directions are asserted: Swift
    injects but no one reads = dead config; Python reads but no one injects = always empty. A
    half-done rename is exactly the typical failure.
    """
    if not env_keys:
        return [
            "parsed no EnvKeys from Constants.swift —— regex mismatch, please update this script"
        ]
    return [
        f"EnvKeys.{const} = {value!r} is injected by Swift, but Python (config.py) never reads this name"
        for const, value in sorted(env_keys.items())
        if value not in python_reads
    ]


def find_script_violations(scripts: dict[str, str], script_dir: str) -> list[str]:
    """Pure function: filenames declared by `PythonScripts` must actually exist.

    Finding the wrong file shows up as the child process exiting immediately / the whole feature
    being unavailable, but the error happens inside the child process and the parent only sees
    "task failed"; asserting here drives the locating cost to zero. The reverse (a .py in the
    directory that is unregistered) is not asserted: many .py files are modules imported by other
    .py files, not Swift call targets.
    """
    if not scripts:
        return [
            "parsed no PythonScripts from Constants.swift —— regex mismatch, please update this script"
        ]
    return [
        f"PythonScripts.{const} = {name!r} does not exist under {os.path.relpath(script_dir, ROOT)}"
        for const, name in sorted(scripts.items())
        if not os.path.isfile(os.path.join(script_dir, name))
    ]


def find_cross_language_const_violations(
    py_value: str | None,
    swift_value: str | None,
    *,
    label: str,
    py_hint: str,
    swift_hint: str,
) -> list[str]:
    """Pure function: the same constant must have the same value in both sources.

    "Each side writes its own literal and only one is changed" is a silent-failure mode that recurs
    in this project——after reading an empty value it takes the fallback, showing a completely
    unrelated symptom. The criterion is collected here, so adding such a constant only needs a label
    and its sources.
    """
    if not py_value or not swift_value:
        return [
            f"parsed no {label} ({py_hint} or {swift_hint}) —— regex mismatch, please update this script"
        ]
    if py_value != swift_value:
        return [
            f"{label} mismatch: {py_hint} = {py_value!r}, {swift_hint} = {swift_value!r}"
        ]
    return []


def find_service_name_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """Pure function: the service name used by the port-reuse probe must match on both sides.

    The probe uses the `service` field to check "is the service on the same port one of ours";
    writing the name wrong makes it judge the service as foreign and give up reuse, so a new
    process/port is started——showing up as port drift and duplicate launches.
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="service name",
        py_hint="SERVER_NAME of server.py",
        swift_hint="service: of MCPProcessManager.swift",
    )


def find_synonym_env_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """Pure function: the synonym-table env name must match on both sides.

    This env is not read by `config.py` (script-specific envs do not go into the common layer), so
    group 3's "if Python reads it, Swift must inject it" does not cover it: when Swift renames and
    Python does not follow, the built-in table keeps working but **the user-configured synonyms
    silently stop working**——with no error at all.
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="synonym-table env name",
        py_hint="SYNONYMS_ENV_KEY of synonyms.py",
        swift_hint="synonymsEnvKey of MCPProcessManager.swift",
    )


def find_tool_defaults_env_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """Pure function: the tool-defaults env name must match on both sides.

    Same reasoning as the synonym table——this env does not go into `config.py`, so group 3 does not
    cover it; when Swift renames and Python does not follow, the built-in defaults keep working but
    **the user-configured defaults silently stop working**, showing up as "I lowered the return
    count but usage didn't drop".
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="tool-defaults env name",
        py_hint="TOOL_DEFAULTS_ENV_KEY of tool_defaults.py",
        swift_hint="toolDefaultsEnvKey of MCPProcessManager.swift",
    )


def find_output_filter_env_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """Pure function: the output-filter config env name must match on both sides.

    This env likewise does not go into `config.py` (the existing convention for script-specific
    envs), so group 3 does not cover it. When the two sides differ, Python reads an empty string
    and falls back to the built-in default, showing up as "I changed maxBytes but the truncation
    threshold didn't change"——with no error at all.
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="output-filter env name",
        py_hint="OUTPUT_FILTER_ENV_KEY of proxy_output_filter.py",
        swift_hint="outputFilterEnvKey of TokenProxyManager.swift",
    )


def find_response_note_env_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """Pure function: the response-note toggle env name must match on both sides.

    Also a script-specific env, not covered by group 3. When the two sides differ, Python reads the
    default value and the toggle config silently stops working——the symptom is "I turned the toggle
    off but the line is still there" or vice versa.
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="response-note env name",
        py_hint="RESPONSE_NOTE_ENV_KEY of proxy_response_note.py",
        swift_hint="responseNoteEnvKey of TokenProxyManager.swift",
    )


#: Inbound header to exclude when forwarding upstream (group 7)
_ACCEPT_ENCODING_HEADER = "accept-encoding"


def _module_string_constants(path: str) -> dict[str, str]:
    """Module-level `NAME = "literal"` constant table (the Python version of `parse_static_lets`)."""
    src = _read(path)
    if src is None:
        return {}
    out: dict[str, str] = {}
    for node in ast.parse(src).body:
        if (
            isinstance(node, ast.Assign)
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str)
        ):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    out[target.id] = node.value.value
    return out


def _set_literals_by_name(tree: ast.AST) -> dict[str, set[str] | None]:
    """The set table of `NAME = {…literals…}`; the same name assigned more than once is recorded as `None` (ambiguous).

    Ambiguity is **not silently passed**: when it cannot be resolved, `collect_upstream_accept_encoding`
    reports red, rather than treating it as "the guard doesn't have it" or "it has it"——both would
    make the criterion lie.
    """
    out: dict[str, set[str] | None] = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Set):
            continue
        values = {
            elt.value.lower()
            for elt in node.value.elts
            if isinstance(elt, ast.Constant) and isinstance(elt.value, str)
        }
        for target in node.targets:
            if isinstance(target, ast.Name):
                out[target.id] = None if target.id in out else values
    return out


def collect_upstream_accept_encoding(
    path: str,
) -> tuple[set[str], str | None, list[str]]:
    """Extract `token_proxy.py`'s (pass-through guard set, explicitly declared whitelist, collection problems).

    It collects the **actual code structure** rather than "this name appears in the source" (the
    latter would be satisfied by the constant's declaration itself, making the criterion vacuously
    true and unable to see set-coverage problems like "one header is not skipped" or "the declaration
    doesn't match the capability"):
      - guard: `if k.lower() not in <set>` in the pass-through loop (an inline literal or a **variable**,
        where a variable is resolved one level via its `NAME = {…}` assignment, i.e. this repo's
        `skip_headers` form) —— if the client's `accept-encoding` is not among them, it is sent
        upstream verbatim; note this is a **union**: this repo has two guards of the same shape (the
        forwarding `skip_headers` and the return-path response-header stripping `forward_headers`),
        and both count. The criterion requires "a guard that excludes it exists" AND "an explicit
        declaration exists" to hold together, so it is not loosened by the merge;
      - declaration: an assignment of the form `headers[<accept-encoding>] = <module constant | literal>`,
        where the constant name is expanded to its real value via the module-level constant table.
        Returning `None` means there is no explicit declaration.
    """
    src = _read(path)
    if src is None:
        return set(), None, [f"cannot read {path}"]
    tree = ast.parse(src)
    consts = _module_string_constants(path)
    sets_by_name = _set_literals_by_name(tree)
    guards: set[str] = set()
    declared: str | None = None
    problems: list[str] = []
    for node in ast.walk(tree):
        # Pass-through guard: `<X>.lower() not in <set>`
        if (
            isinstance(node, ast.Compare)
            and isinstance(node.left, ast.Call)
            and isinstance(node.left.func, ast.Attribute)
            and node.left.func.attr == "lower"
            and any(isinstance(op, ast.NotIn) for op in node.ops)
        ):
            for side in node.comparators:
                if isinstance(side, ast.Set):
                    for elt in side.elts:
                        if isinstance(elt, ast.Constant) and isinstance(elt.value, str):
                            guards.add(elt.value.lower())
                elif isinstance(side, ast.Name):
                    resolved = sets_by_name.get(side.id, None)
                    if resolved is None:
                        problems.append(
                            f"pass-through guard {side.id!r} is not the only set literal —— "
                            "this check cannot determine which headers it excludes (a form it cannot resolve is not accepted)"
                        )
                    else:
                        guards |= resolved
        # Explicit declaration: `headers["Accept-Encoding"] = UPSTREAM_ACCEPT_ENCODING`
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if (
                isinstance(target, ast.Subscript)
                and isinstance(target.slice, ast.Constant)
                and isinstance(target.slice.value, str)
                and target.slice.value.lower() == _ACCEPT_ENCODING_HEADER
            ):
                if isinstance(node.value, ast.Constant) and isinstance(
                    node.value.value, str
                ):
                    declared = node.value.value
                elif isinstance(node.value, ast.Name):
                    declared = consts.get(node.value.id)
    return guards, declared, problems


def _decodable_encodings() -> set[str]:
    """The response compression encodings this process can decode."""
    out = {"identity", "gzip", "deflate"}
    if HAS_BROTLI:
        out.add("br")
    if HAS_ZSTD:
        out.add("zstd")
    return out


def find_upstream_accept_encoding_violations(
    guards: set[str], declared: str | None, problems: list[str]
) -> list[str]:
    """Pure function: the response compression encodings the proxy declares upstream must be ones it can decode.

    The upstream picks a compression method by `Accept-Encoding` (measured on deepseek: declare zstd
    and it returns zstd, **a 200 SSE stream is compressed just the same**). The proxy must read and
    rewrite the response body (usage extraction, model-name injection, skill dedup, output filtering),
    so failing to decode means dropping the entire response along with the **upstream's real status
    code**: when the aiohttp decoder is unavailable it raises `ContentEncodingError` (inheriting
    `PayloadEncodingError` → `BadHttpMessage`, with **code always 400**), which is wrapped as
    `ClientResponseError` and turned into a 502 by `token_proxy` —— the 400 in the error is not the
    upstream status code, and the client just keeps retrying (the 2026-10-12 user report was exactly
    this form: the client's `gzip, deflate, br, zstd` was passed through verbatim, while this venv had
    neither Brotli nor backports.zstd).
    """
    out: list[str] = list(problems)
    if _ACCEPT_ENCODING_HEADER not in guards:
        out.append(
            "the request-header pass-through loop in token_proxy that forwards upstream does not exclude accept-encoding —— "
            "the client's Accept-Encoding will be sent upstream verbatim"
        )
    if declared is None:
        out.append(
            "token_proxy does not explicitly declare the Accept-Encoding for forwarding upstream (missing "
            "`headers[...] = <module constant>`) —— falling back to the aiohttp default decouples it from this process's capability"
        )
        return out
    names = {e.strip().lower() for e in declared.split(",") if e.strip()}
    undecodable = names - _decodable_encodings()
    if undecodable:
        out.append(
            f"the encodings token_proxy declares upstream {sorted(undecodable)} cannot be decoded by this process"
            f" (aiohttp: brotli={HAS_BROTLI}, zstd={HAS_ZSTD}) —— install the libraries before declaring"
        )
    return out


def find_client_violations(
    payloads: dict[str, set[str]], groups: dict[str, tuple[str, tuple[str, ...]]]
) -> list[str]:
    """Pure function: the clientAccel / clientText Swift payload fields ⊇ the Python contract keys."""
    violations: list[str] = []
    for label, (struct, keys) in groups.items():
        fields = payloads.get(struct)
        if fields is None:
            violations.append(f"Swift side cannot find struct {struct} ({label})")
            continue
        for key in keys:
            if key not in fields:
                violations.append(
                    f"{struct}.{key} missing —— Python's {label}.{key} will silently take the fallback value"
                )
    return violations


def collect_prompt_files() -> dict[tuple[str, str], str | None]:
    """Raw text of the built-in prompt template files; (lang, feature) → text, missing is None."""
    return {
        (lang, feature): _read(os.path.join(PROMPTS, lang, f"{feature}.md"))
        for lang in (PROMPT_BASELINE_LANG, *PROMPT_OTHER_LANGS)
        for feature in PROMPT_FEATURES
    }


def collect_l10n_prompts() -> dict[tuple[str, str], str | None]:
    """Fallback text in the L10n JSON; covers only features that have a fallback. Any read failure makes the whole group None."""
    out: dict[tuple[str, str], str | None] = {}
    for lang in (PROMPT_BASELINE_LANG, *PROMPT_OTHER_LANGS):
        raw = _read(os.path.join(RESOURCES, f"{lang}.json"))
        data: dict = {}
        if raw is None:
            print(f"[contract] cannot read Resources/{lang}.json")
        else:
            try:
                data = json.loads(raw)
            except ValueError as e:
                print(f"[contract] Resources/{lang}.json is not valid JSON: {e}")
        for feature in L10N_BACKED_FEATURES:
            out[(lang, feature)] = data.get(f"prompt.{feature}")
    return out


def find_prompt_violations(
    prompt_files: dict[tuple[str, str], str | None],
    l10n_prompts: dict[tuple[str, str], str | None],
    parse_template,
) -> list[str]:
    """Pure function: the contract violation list of the prompt template files.

    It uses the **production parser** (`prompt_loader.parse_template`) instead of writing another one
    here——when the checker and the runtime parser are not from the same source, this assertion can
    only prove "the file's style suits the checker", unrelated to the path that actually runs.
    Parsing takes the input text rather than re-reading from disk, so that a "hypothetical bad file"
    can also be asserted (the selftest depends on this).

    It iterates over the **expected set** (language × feature) rather than the keys of the input dict:
    when a file is missing the item simply isn't in the dict, and iterating the dict would silently
    skip it——and "a template was not shipped" is precisely the most common failure form.

    Each of the four assertions corresponds to a real failure:
    - baseline language file missing / not accepted by the parser → all languages fall back to the
      fallback, showing up as "the prompt I changed didn't take effect"
    - declared placeholders don't match the registration → the file's self-check rejects it, again a
      silent fallback; and the arguments passed at the call site are written against the baseline, so
      a renamed placeholder in the translation causes a missing-argument render
    - the translated version's `json_keys` differ from the baseline → the key names are a
      **code-parsed** contract (`missing_json_keys` validates the model output by them), so a
      mistranslation makes "the model didn't follow the contract" undetectable
    - the body differs from the L10n → the Swift fallback path ships a different set of text, and
      only on the machine that has the problem
    """
    violations: list[str] = []
    parsed: dict[tuple[str, str], object] = {}

    for lang in (PROMPT_BASELINE_LANG, *PROMPT_OTHER_LANGS):
        required = lang == PROMPT_BASELINE_LANG
        for feature in PROMPT_FEATURES:
            rel = f"prompts/{lang}/{feature}.md"
            raw = prompt_files.get((lang, feature))
            if raw is None:
                if required:
                    violations.append(
                        f"{rel} does not exist —— the baseline language must be complete, missing it makes all languages fall back to the fallback text"
                    )
                continue  # a non-baseline language being missing is normal (not translated, runtime falls back to baseline)

            try:
                tpl = parse_template(
                    raw, feature, pathlib.Path(PROMPTS) / lang / f"{feature}.md"
                )
            except (
                Exception
            ) as e:  # PromptLoadError or any parse exception counts as a contract break
                violations.append(
                    f"{rel} is not accepted by the production parser: {type(e).__name__}: {e}"
                )
                continue
            parsed[(lang, feature)] = tpl

            if set(tpl.placeholders) != set(PROMPT_FEATURES[feature]):
                violations.append(
                    f"{rel} placeholders={sorted(tpl.placeholders)} do not match the baseline-registered"
                    f" {sorted(PROMPT_FEATURES[feature])}"
                )

    # Cross-language: json_keys are the code-parsed contract keys; a mistranslation during translation raises no error, it only disables the check
    for feature in PROMPT_FEATURES:
        base = parsed.get((PROMPT_BASELINE_LANG, feature))
        if base is None:
            continue
        for lang in PROMPT_OTHER_LANGS:
            other = parsed.get((lang, feature))
            if other is None:
                continue
            if tuple(other.json_keys) != tuple(base.json_keys):
                violations.append(
                    f"prompts/{lang}/{feature}.md's json_keys={list(other.json_keys)}"
                    f" differ from the baseline {list(base.json_keys)} —— the key names are a code-parsed contract"
                )

    # L10n fallback text (only for features with this path on the Swift side)
    for feature in L10N_BACKED_FEATURES:
        for lang in (PROMPT_BASELINE_LANG, *PROMPT_OTHER_LANGS):
            tpl = parsed.get((lang, feature))
            if tpl is None:
                continue  # missing was already reported in the loop above (baseline) or is a normal fallback (other languages)
            l10n = l10n_prompts.get((lang, feature))
            if l10n is None:
                violations.append(
                    f"Resources/{lang}.json is missing prompt.{feature} (Swift's fallback text)"
                )
            elif tpl.text.strip() != l10n.strip():
                violations.append(
                    f"prompts/{lang}/{feature}.md's body differs from Resources/{lang}.json's"
                    f" prompt.{feature} —— the fallback path ships a different set of text"
                )
    return violations


def _param_text_key(node: ast.AST) -> str | None:
    """`param_text("x")` (or `tool_text.param_text("x")`) → `"x"`; any other form → None."""
    if not isinstance(node, ast.Call) or len(node.args) != 1:
        return None
    func = node.func
    is_param_text = (isinstance(func, ast.Name) and func.id == "param_text") or (
        isinstance(func, ast.Attribute) and func.attr == "param_text"
    )
    if not is_param_text:
        return None
    arg = node.args[0]
    if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
        return arg.value
    return None


def collect_param_descriptions(path: str) -> tuple[set[str], list[str]]:
    """Usage of parameter descriptions inside `handle_list_tools()`: `(referenced key set, list not going through i18n)`.

    Uses AST rather than regex: the word `description` has several other meanings in server.py
    (parsing `DESCRIPTIONS.md`, the tool-level `Tool(description=...)`), and a regex over the whole
    file would count them too, whereas this contract applies **only** to parameter descriptions in
    `inputSchema`.

    It only looks inside the function and only recognizes dict `"description"` keys: a tool-level
    description goes through the `Tool(description=...)` keyword argument and is naturally out of
    scope——it is determined by the user-overridable `DESCRIPTIONS.md`, and no built-in multilingual
    support is provided.
    """
    src = _read(path)
    if src is None:
        return set(), [f"cannot read {os.path.relpath(path, ROOT)}"]
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        return set(), [f"{os.path.relpath(path, ROOT)} syntax error: {e}"]

    func = next(
        (
            n
            for n in ast.walk(tree)
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
            and n.name == "handle_list_tools"
        ),
        None,
    )
    if func is None:
        return set(), [
            "handle_list_tools not found in server.py —— function renamed, please update this script"
        ]

    refs: set[str] = set()
    problems: list[str] = []
    for node in ast.walk(func):
        if not isinstance(node, ast.Dict):
            continue
        for key_node, value_node in zip(node.keys, node.values):
            if not (
                isinstance(key_node, ast.Constant) and key_node.value == "description"
            ):
                continue
            key = _param_text_key(value_node)
            if key is not None:
                refs.add(key)
            elif isinstance(value_node, ast.Constant) and isinstance(
                value_node.value, str
            ):
                problems.append(
                    f"line {node.lineno}: bare literal {value_node.value[:40]!r} (not via param_text)"
                )
            else:
                problems.append(
                    f"line {node.lineno}: undeterminable description form {type(value_node).__name__}"
                )
    return refs, problems


def find_param_text_violations(
    refs: set[str],
    problems: list[str],
    table: dict[str, dict[str, str]],
    baseline_lang: str | None,
) -> list[str]:
    """Pure function: the contract violation list of tool parameter description i18n.

    Each of the five assertions corresponds to a real failure:
    - a description in the schema not going through `param_text` → that parameter ever has only one
      language (this is how a missed edit happens), only visible when languages are mixed, and no one
      looks at every parameter;
    - a referenced key that doesn't exist in the table → raises `MissingParamText` at runtime, making
      **the entire tool list unusable** (not one description degrading to fallback text, but the
      client getting no tool at all);
    - a key in the table that no one references → left over after a rename, and later readers assume
      editing one place is enough;
    - a key missing the baseline language → that key resolves to nothing under any language while the
      other keys work, the hardest to notice;
    - inconsistent language sets across keys → the schema is presented as a whole at once, and having
      some parameters in Chinese and some in English is worse than "all untranslated".
    """
    violations = [
        f"server.py's parameter description does not go through param_text (i18n not covered): {p}"
        for p in problems
    ]
    if not table:
        violations.append(
            f"parsed no PARAM_TEXT from {os.path.relpath(TOOL_TEXT_PY, ROOT)} —— constant renamed, please update this script"
        )
        return violations

    violations += [
        f"parameter description references an unregistered key {key!r} —— raises MissingParamText at runtime, making the whole tool list unusable"
        for key in sorted(refs - set(table))
    ]
    violations += [
        f"{key!r} in PARAM_TEXT has no schema reference (left over after a rename?)"
        for key in sorted(set(table) - refs)
    ]

    if not baseline_lang:
        violations.append(
            "parsed no tool_text.FALLBACK_LANG —— constant renamed, please update this script"
        )
        return violations

    for key in sorted(table):
        if baseline_lang not in table[key]:
            violations.append(
                f"PARAM_TEXT[{key!r}] is missing the baseline language {baseline_lang!r} —— it resolves to nothing under any language"
            )

    # Consistent language sets: report the minority against the "majority", avoiding a whole-table error drowning out the real difference
    lang_sets = {key: frozenset(langs) for key, langs in table.items()}
    distinct = set(lang_sets.values())
    if len(distinct) > 1:
        majority = max(
            distinct, key=lambda s: sum(1 for v in lang_sets.values() if v == s)
        )
        violations += [
            f"PARAM_TEXT[{key!r}]'s languages {sorted(langs)} differ from the majority keys' {sorted(majority)}"
            " —— the schema is presented as a whole, and mixed languages are worse than uniformly untranslated"
            for key, langs in sorted(lang_sets.items())
            if langs != majority
        ]
    return violations


def find_baseline_lang_violations(langs: dict[str, str | None]) -> list[str]:
    """Pure function: the baseline language must have the same value in **all** modules that hold it.

    It decides "which set of text to fall back to when the current language lacks it"——prompts and
    tool parameter descriptions share the same criterion. If any one drifts, the same missing text
    yields different results on the two paths, and neither side raises an error.
    """
    missing = sorted(source for source, value in langs.items() if not value)
    if missing:
        return [
            f"parsed no baseline language ({', '.join(missing)}) —— constant renamed or regex mismatch, please update this script"
        ]
    if len(set(langs.values())) > 1:
        return [
            "baseline language mismatch: "
            + ", ".join(
                f"{source} = {value!r}" for source, value in sorted(langs.items())
            )
        ]
    return []


@dataclass(frozen=True)
class ContractInputs:
    """A one-time input collected from the real sources on both sides.

    Bundled into one object so that `check_all` and `--selftest` go through the **same criterion**:
    if the selftest re-assembled the input itself, it could prove itself clean outside the real path
    (changed the real parsing while the selftest stayed green).
    """

    swift_payloads: dict[str, set[str]]
    provider_keys: set[str]
    client_groups: dict[str, tuple[str, tuple[str, ...]]]
    swift_env_injections: set[str]
    env_keys: dict[str, str]
    python_env_reads: set[str]
    python_script_env_reads: set[str]
    python_script_env_sets: set[str]
    python_scripts: dict[str, str]
    py_server_name: str | None
    swift_service_name: str | None
    prompt_files: dict[tuple[str, str], str | None]
    l10n_prompts: dict[tuple[str, str], str | None]
    swift_fallback_lang: str | None
    python_fallback_lang: str | None
    py_synonyms_env: str | None
    swift_synonyms_env: str | None
    py_tool_defaults_env: str | None
    swift_tool_defaults_env: str | None
    py_output_filter_env: str | None
    swift_output_filter_env: str | None
    py_response_note_env: str | None
    swift_response_note_env: str | None
    param_ref_keys: set[str]
    param_problems: list[str]
    param_table: dict[str, dict[str, str]]
    python_tool_text_lang: str | None
    upstream_header_guards: set[str]
    upstream_accept_encoding: str | None
    upstream_encoding_problems: list[str]


def _first_match(pattern: re.Pattern[str], src: str) -> str | None:
    m = pattern.search(src)
    return m.group(1) if m else None


def _drop_from_payload(
    inp: ContractInputs, struct: str, field: str
) -> dict[str, set[str]]:
    """Return the payloads after "deleting a field of a struct" (used by the selftest to build mutations)."""
    out = {k: set(v) for k, v in inp.swift_payloads.items()}
    out.setdefault(struct, set()).discard(field)
    return out


def _drop_struct(inp: ContractInputs, struct: str) -> dict[str, set[str]]:
    out = {k: set(v) for k, v in inp.swift_payloads.items()}
    out.pop(struct, None)
    return out


def collect_inputs(
    client_groups: dict[str, tuple[str, tuple[str, ...]]],
    python_fallback_lang: str | None,
    param_table: dict[str, dict[str, str]],
    python_tool_text_lang: str | None,
) -> ContractInputs:
    """Collect the contract inputs from the real sources on both sides (the sole collection point)."""
    param_ref_keys, param_problems = collect_param_descriptions(SERVER_PY)
    # EnvKeys must be parsed first: the constant keys of the injection points (`env[EnvKeys.xxx] = …`) are expanded to real env names via it
    env_keys = parse_static_lets(CONSTANTS, "EnvKeys")
    (
        upstream_guards,
        upstream_accept_encoding,
        upstream_encoding_problems,
    ) = collect_upstream_accept_encoding(TOKEN_PROXY_PY)
    script_env_reads, script_env_sets = parse_python_script_envs(SCRIPTS)
    return ContractInputs(
        swift_payloads=parse_swift_payloads(SWIFT),
        provider_keys=parse_provider_json_keys(SWIFT),
        client_groups=client_groups,
        env_keys=env_keys,
        swift_env_injections=collect_swift_env_injections(SOURCES, env_keys),
        python_env_reads=parse_python_env_reads(CONFIG_PY),
        python_script_env_reads=script_env_reads,
        python_script_env_sets=script_env_sets,
        python_scripts=parse_static_lets(CONSTANTS, "PythonScripts"),
        py_server_name=_first_match(_PY_SERVER_NAME_RE, _read(SERVER_PY) or ""),
        swift_service_name=_first_match(_SWIFT_SERVICE_RE, _read(MCP_MANAGER) or ""),
        prompt_files=collect_prompt_files(),
        l10n_prompts=collect_l10n_prompts(),
        swift_fallback_lang=_first_match(
            _SWIFT_FALLBACK_LANG_RE, _read(PROMPT_MANAGER) or ""
        ),
        python_fallback_lang=python_fallback_lang,
        py_synonyms_env=_first_match(_PY_SYNONYMS_ENV_RE, _read(SYNONYMS_PY) or ""),
        swift_synonyms_env=_first_match(
            _SWIFT_SYNONYMS_ENV_RE, _read(MCP_MANAGER) or ""
        ),
        py_tool_defaults_env=_first_match(
            _PY_TOOL_DEFAULTS_ENV_RE, _read(TOOL_DEFAULTS_PY) or ""
        ),
        swift_tool_defaults_env=_first_match(
            _SWIFT_TOOL_DEFAULTS_ENV_RE, _read(MCP_MANAGER) or ""
        ),
        py_output_filter_env=_first_match(
            _PY_OUTPUT_FILTER_ENV_RE, _read(OUTPUT_FILTER_PY) or ""
        ),
        swift_output_filter_env=_first_match(
            _SWIFT_OUTPUT_FILTER_ENV_RE, _read(SWIFT) or ""
        ),
        py_response_note_env=_first_match(
            _PY_RESPONSE_NOTE_ENV_RE, _read(RESPONSE_NOTE_PY) or ""
        ),
        swift_response_note_env=_first_match(
            _SWIFT_RESPONSE_NOTE_ENV_RE, _read(SWIFT) or ""
        ),
        param_ref_keys=param_ref_keys,
        param_problems=param_problems,
        param_table=param_table,
        python_tool_text_lang=python_tool_text_lang,
        upstream_header_guards=upstream_guards,
        upstream_accept_encoding=upstream_accept_encoding,
        upstream_encoding_problems=upstream_encoding_problems,
    )


def check_all(
    inp: ContractInputs,
    provider_contract: tuple[str, ...],
    parse_template,
) -> list[str]:
    """Violation list of all cross-language contracts (group order matches the numbering in the module docstring)."""
    return (
        find_provider_violations(inp.provider_keys, provider_contract)
        + find_client_violations(inp.swift_payloads, inp.client_groups)
        + find_env_violations(inp.python_env_reads, inp.swift_env_injections)
        + find_script_env_violations(
            inp.python_script_env_reads,
            inp.python_script_env_sets,
            inp.swift_env_injections,
        )
        + find_env_injection_violations(inp.env_keys, inp.swift_env_injections)
        + find_env_key_violations(inp.env_keys, inp.python_env_reads)
        + find_script_violations(inp.python_scripts, SCRIPTS)
        + find_service_name_violations(inp.py_server_name, inp.swift_service_name)
        + find_synonym_env_violations(inp.py_synonyms_env, inp.swift_synonyms_env)
        + find_tool_defaults_env_violations(
            inp.py_tool_defaults_env, inp.swift_tool_defaults_env
        )
        + find_output_filter_env_violations(
            inp.py_output_filter_env, inp.swift_output_filter_env
        )
        + find_response_note_env_violations(
            inp.py_response_note_env, inp.swift_response_note_env
        )
        + find_upstream_accept_encoding_violations(
            inp.upstream_header_guards,
            inp.upstream_accept_encoding,
            inp.upstream_encoding_problems,
        )
        + find_prompt_violations(inp.prompt_files, inp.l10n_prompts, parse_template)
        + find_param_text_violations(
            inp.param_ref_keys,
            inp.param_problems,
            inp.param_table,
            inp.python_tool_text_lang,
        )
        + find_baseline_lang_violations(
            {
                "PromptManager.fallbackLanguage": inp.swift_fallback_lang,
                "prompt_loader.FALLBACK_LANG": inp.python_fallback_lang,
                "tool_text.FALLBACK_LANG": inp.python_tool_text_lang,
            }
        )
    )


def _rename_frontmatter(raw: str) -> str:
    """Change the front-matter `name:` to another value (used by the selftest to build mutations)."""
    return re.sub(r"^name:\s*\S+", "name: mutated", raw, count=1, flags=re.M)


def _blank_json_keys(raw: str) -> str:
    """Blank out the front-matter `json_keys:` (used by the selftest to build mutations)."""
    return re.sub(r"^json_keys:\s*\[.*?\]", "json_keys: []", raw, count=1, flags=re.M)


def selftest(
    inp: ContractInputs,
    provider_contract: tuple[str, ...],
    parse_template,
) -> int:
    """Reverse validation: every form of "the two sides decoupling" must be detected.

    A checker that is always empty is the same as no checker, so a mutation is built for each contract
    group. A mutation that doesn't take effect (meaning the field no longer exists / was renamed)
    also counts as a failure——that means the selftest itself is lying, not that the contract is fine.
    """
    base = copy.deepcopy(inp)
    cases: dict[str, ContractInputs] = {
        # providers
        "providers: delete api_format": replace(
            base, provider_keys=base.provider_keys - {"api_format"}
        ),
        "providers: key name reverts to camelCase (CodingKeys ineffective)": replace(
            base, provider_keys=(base.provider_keys - {"api_format"}) | {"apiFormat"}
        ),
        "providers: Payload disappears entirely": replace(base, provider_keys=set()),
        # client (added in stage 0)
        "client: delete TextPayload.injected_tags": replace(
            base,
            swift_payloads=_drop_from_payload(base, "TextPayload", "injected_tags"),
        ),
        "client: delete the whole MatcherPayload struct": replace(
            base, swift_payloads=_drop_struct(base, "MatcherPayload")
        ),
        # env names
        "env: Python reads a name Swift never injects": replace(
            base, python_env_reads=base.python_env_reads | {"SWIFT_NEVER_INJECTS_THIS"}
        ),
        "env: EnvKeys renamed but Python does not follow": replace(
            base, env_keys={**base.env_keys, "aiAPIKey": "AI_API_KEY_RENAMED"}
        ),
        "env: one injection point missing (injected only on some paths)": replace(
            base, swift_env_injections=base.swift_env_injections - {"AI_LLM_TIMEOUT"}
        ),
        "env: EnvKeys declares a key with no injection point": replace(
            base,
            env_keys={**base.env_keys, "ghostKey": "SWIFT_DECLARED_NEVER_INJECTED"},
        ),
        "env: a script-specific env read directly has no Swift injection point": replace(
            base,
            python_script_env_reads=base.python_script_env_reads
            | {"SCRIPT_READS_NEVER_INJECTED"},
        ),
        # process convention
        "script name: PythonScripts points to a nonexistent file": replace(
            base, python_scripts={**base.python_scripts, "server": "server_v2.py"}
        ),
        "service name: mismatched on the two sides": replace(
            base, swift_service_name="other-service"
        ),
        "synonym env name: mismatched on the two sides": replace(
            base, swift_synonyms_env="MCP_SYNONYM_RENAMED"
        ),
        "tool-defaults env name: mismatched on the two sides": replace(
            base, swift_tool_defaults_env="MCP_TOOL_DEFAULT_RENAMED"
        ),
        "output-filter env name: mismatched on the two sides": replace(
            base, swift_output_filter_env="MODEL_PROXY_OUTPUT_RENAMED"
        ),
        "response-note env name: mismatched on the two sides": replace(
            base, swift_response_note_env="MODEL_PROXY_NOTE_RENAMED"
        ),
        # upstream response encoding (added in stage 8)
        "accept-encoding: the pass-through loop no longer excludes it": replace(
            base,
            upstream_header_guards=base.upstream_header_guards
            - {_ACCEPT_ENCODING_HEADER},
        ),
        "accept-encoding: delete the explicit declaration": replace(
            base, upstream_accept_encoding=None
        ),
        "accept-encoding: declares an encoding this process cannot decode": replace(
            base, upstream_accept_encoding="gzip, deflate, snappy"
        ),
        "accept-encoding: the guard set cannot be resolved": replace(
            base,
            upstream_encoding_problems=[
                *base.upstream_encoding_problems,
                "pass-through guard 'guard' is not the only set literal",
            ],
        ),
        # prompt templates (added in stage 6)
        "prompt: md body differs from the L10n fallback": replace(
            base,
            prompt_files={
                **base.prompt_files,
                ("en", "translate"): (base.prompt_files.get(("en", "translate")) or "")
                + " mutated",
            },
        ),
        "prompt: baseline language missing a template file": replace(
            base,
            prompt_files={
                k: v
                for k, v in base.prompt_files.items()
                if k != ("zh-Hans", "aggregate")
            },
        ),
        "prompt: translated json_keys differ from the baseline": replace(
            base,
            prompt_files={
                **base.prompt_files,
                ("en", "decide_merge"): _blank_json_keys(
                    base.prompt_files.get(("en", "decide_merge")) or ""
                ),
            },
        ),
        "prompt: front-matter name written wrong (file in the wrong place)": replace(
            base,
            prompt_files={
                **base.prompt_files,
                ("zh-Hans", "translate"): _rename_frontmatter(
                    base.prompt_files.get(("zh-Hans", "translate")) or ""
                ),
            },
        ),
        "prompt: baseline language mismatched on the two sides": replace(
            base, swift_fallback_lang="en"
        ),
        # tool parameter description i18n (added in stage 7)
        "param: schema contains a bare description not via param_text": replace(
            base,
            param_problems=[
                *base.param_problems,
                "line 1: bare literal 'hardcoded description'",
            ],
        ),
        "param: references an unregistered key": replace(
            base, param_ref_keys=base.param_ref_keys | {"param.never_registered"}
        ),
        "param: the table has a key no one references": replace(
            base,
            param_table={
                **base.param_table,
                "param.orphan": {"zh-Hans": "orphan text", "en": "orphan"},
            },
        ),
        "param: a key is missing the baseline language": replace(
            base,
            param_table={**base.param_table, "param.query": {"en": "Search query"}},
        ),
        "param: a key's language set differs from the majority": replace(
            base,
            param_table={
                **base.param_table,
                "param.query": {"zh-Hans": "search query"},
            },
        ),
        "param: baseline language differs from the prompt side": replace(
            base, python_tool_text_lang="en"
        ),
    }

    ineffective: list[str] = []
    missed: list[str] = []
    for name, mutated in cases.items():
        if mutated == base:
            ineffective.append(name)
        elif not check_all(mutated, provider_contract, parse_template):
            missed.append(name)

    if ineffective:
        print(
            "[contract] ✗ selftest ineffective: the following mutations changed no input (fields may have been renamed) ——",
            "; ".join(ineffective),
        )
        return 2
    if missed:
        print(
            "[contract] ✗ selftest failed: the following mutations were not detected ——",
            "; ".join(missed),
        )
        return 2
    print(f"[contract] ✓ selftest passed: all {len(cases)} mutations were detected")
    return 0


#: Project venv interpreter (the script needs to import the Python-side contract modules, whose dependencies are installed only here)
VENV_PYTHON = os.path.expanduser("~/.config/utility/mcp-venv/bin/python3")


def _reexec_with_venv() -> None:
    """Re-exec itself with the project venv's interpreter.

    This script imports `proxy_provider` / `proxy_client` to take the contract constants, and those
    modules pull in `httpx` / `aiohttp` / `db` and other dependencies——available only in the venv.
    Running with the system python3 fails at the import stage, and the error (`No module named
    'httpx'`) looks completely unrelated to "contract mismatch", so a debugger would think the
    contract is broken. After bootstrapping, the `python3 scripts/...` usage stays the same.
    """
    if os.environ.get("_CONTRACT_REEXEC") == "1" or not os.path.isfile(VENV_PYTHON):
        return
    if os.path.realpath(sys.executable) == os.path.realpath(VENV_PYTHON):
        return
    os.environ["_CONTRACT_REEXEC"] = "1"
    os.execv(VENV_PYTHON, [VENV_PYTHON, os.path.abspath(__file__), *sys.argv[1:]])


def main() -> int:
    _reexec_with_venv()
    sys.path.insert(0, SCRIPTS)
    try:
        from proxy_client import (
            ACCEL_CLIENT_KEYS,
            ACCEL_CONTRACT_KEYS,
            CLIENT_TEXT_CONTRACT_KEYS,
        )
        from proxy_provider import (
            KEY_API_FORMAT,
            KEY_API_KEY,
            KEY_MODELS,
            KEY_NAME,
            KEY_URL,
        )

        # The prompt group's criterion comes from the production parser itself, avoiding "the checker and the runtime parser not being from the same source"
        from prompt_loader import (
            FALLBACK_LANG as PY_FALLBACK_LANG,
            parse_template as parse_prompt_template,
        )

        # The parameter-description group's key table and baseline likewise come from the production module itself
        from tool_text import (
            FALLBACK_LANG as PY_TOOL_TEXT_LANG,
            PARAM_TEXT as PY_PARAM_TEXT,
        )
    except Exception as e:  # an import failure means the Python side is already broken, which likewise must not be silent
        print(
            f"[contract] failed to import the Python contracts: {type(e).__name__}: {e}"
        )
        return 2

    provider_contract = (KEY_NAME, KEY_URL, KEY_API_FORMAT, KEY_API_KEY, KEY_MODELS)
    client_groups = {
        "clientAccel": ("AccelPayload", ACCEL_CONTRACT_KEYS),
        "clientAccel.clients": ("MatcherPayload", ACCEL_CLIENT_KEYS),
        "clientText": ("TextPayload", CLIENT_TEXT_CONTRACT_KEYS),
    }

    try:
        inputs = collect_inputs(
            client_groups, PY_FALLBACK_LANG, PY_PARAM_TEXT, PY_TOOL_TEXT_LANG
        )
    except SystemExit as e:  # parse_swift_payloads exits directly on a regex mismatch
        return int(e.code or 2)

    if "--selftest" in sys.argv[1:]:
        return selftest(inputs, provider_contract, parse_prompt_template)

    violations = check_all(inputs, provider_contract, parse_prompt_template)
    if violations:
        print("[contract] ✗ cross-language contract mismatch:")
        for v in violations:
            print("  -", v)
        print(
            "\nFix: change the Swift-side definitions (Constants.swift / TokenProxyManager.swift / "
            "MCPProcessManager.swift) and the Python-side contract constants and read points together, and update default-config.yaml accordingly."
        )
        return 1

    total = len(provider_contract) + sum(
        len(keys) for _, keys in client_groups.values()
    )
    print(
        f"[contract] ✓ cross-language contracts consistent (providers + client, {total} keys in total;"
        f" env injection points {len(inputs.swift_env_injections)} (EnvKeys {len(inputs.env_keys)}),"
        f" scripts {len(inputs.python_scripts)},"
        f" service name {inputs.py_server_name!r}, prompts "
        f"{sum(1 for v in inputs.prompt_files.values() if v is not None)} templates,"
        f" parameter descriptions {len(inputs.param_table)} entries"
        f" (baseline {inputs.swift_fallback_lang!r}) are all aligned)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
