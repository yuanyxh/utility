"""Environment and process/convention checks."""
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


from router_contract.consts import (
    CONFIG_PY, ROOT, SCRIPTS, _PY_ENV_READ_RE, _PY_SCRIPT_ENV_READ_RE,
    _PY_SCRIPT_ENV_SET_RE, _SCRIPT_ENV_EXEMPT, _SWIFT_ENV_ASSIGN_RE,
)
from router_contract.parsers import _read
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
    env_keys: dict[str, str],
    python_reads: set[str],
    python_script_reads: set[str],
) -> list[str]:
    """Pure function: names declared by `EnvKeys` that differ from the names Python actually reads.

    `EnvKeys` is the **single source** of these env names, and both directions are asserted: Swift
    injects but no one reads = dead config; Python reads but no one injects = always empty. A
    half-done rename is exactly the typical failure.

    Script-specific envs (`RSS_DAILY_CONFIG` / `UTILITY_CLI_PATH`) are read directly with
    `os.environ.get` instead of through `config.py`, so both read surfaces count; group 3 already
    asserts that every direct read has an injection point.
    """
    if not env_keys:
        return [
            "parsed no EnvKeys from Constants.swift —— regex mismatch, please update this script"
        ]
    return [
        f"EnvKeys.{const} = {value!r} is injected by Swift, but Python (config.py or a script) never reads this name"
        for const, value in sorted(env_keys.items())
        if value not in python_reads and value not in python_script_reads
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


def find_context_warn_env_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """Pure function: the context-warn threshold env name must match on both sides.

    Same shape as the response-note toggle above. When the two sides differ, Python reads its own
    default and the configured threshold silently stops applying — the symptom is "I set 300000
    but the hint behaviour did not change".
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="context-warn env name",
        py_hint="CONTEXT_WARN_ENV_KEY of proxy_response_note.py",
        swift_hint="contextWarnEnvKey of TokenProxyManager.swift",
    )


