"""Aggregated inputs and the check_all entry."""
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
    CONFIG_PY, CONSTANTS, MCP_MANAGER, OUTPUT_FILTER_PY, PROMPT_MANAGER,
    PROXY_CONFIG_PY, PROXY_REWRITE_PY, RESPONSE_NOTE_PY, SCRIPTS, SERVER_PY, SOURCES,
    SWIFT, SYNONYMS_PY, TOKEN_PROXY_PY, TOOL_DEFAULTS_PY, TOOL_SCHEMA_PY,
    _PY_CONTEXT_WARN_ENV_RE, _PY_OUTPUT_FILTER_ENV_RE, _PY_RESPONSE_NOTE_ENV_RE,
    _PY_SERVER_NAME_RE, _PY_SYNONYMS_ENV_RE, _PY_TOOL_DEFAULTS_ENV_RE,
    _SWIFT_CONTEXT_WARN_ENV_RE, _SWIFT_FALLBACK_LANG_RE, _SWIFT_OUTPUT_FILTER_ENV_RE,
    _SWIFT_RESPONSE_NOTE_ENV_RE, _SWIFT_SERVICE_RE, _SWIFT_SYNONYMS_ENV_RE,
    _SWIFT_TOOL_DEFAULTS_ENV_RE,
)
from router_contract.content_checks import (
    collect_l10n_prompts, collect_param_descriptions, collect_prompt_files,
    find_baseline_lang_violations, find_param_text_violations, find_prompt_violations,
)
from router_contract.env_checks import (
    collect_swift_env_injections, find_context_warn_env_violations,
    find_env_injection_violations, find_env_key_violations, find_env_violations,
    find_output_filter_env_violations, find_response_note_env_violations,
    find_script_env_violations, find_script_violations, find_service_name_violations,
    find_synonym_env_violations, find_tool_defaults_env_violations,
    parse_python_env_reads, parse_python_script_envs,
)
from router_contract.parsers import _read
from router_contract.proxy_checks import (
    collect_upstream_accept_encoding, find_client_violations, find_provider_violations,
    find_upstream_accept_encoding_violations, parse_provider_json_keys, parse_static_lets,
    parse_swift_payloads,
)
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
    py_context_warn_env: str | None
    swift_context_warn_env: str | None
    param_ref_keys: set[str]
    param_problems: list[str]
    param_table: dict[str, str]
    python_l10n_baseline: str | None
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
    param_table: dict[str, str],
    python_l10n_baseline: str | None,
) -> ContractInputs:
    """Collect the contract inputs from the real sources on both sides (the sole collection point)."""
    param_ref_keys, param_problems = collect_param_descriptions(
        SERVER_PY, TOOL_SCHEMA_PY
    )
    # EnvKeys must be parsed first: the constant keys of the injection points (`env[EnvKeys.xxx] = …`) are expanded to real env names via it
    env_keys = parse_static_lets(CONSTANTS, "EnvKeys")
    (
        upstream_guards,
        upstream_accept_encoding,
        upstream_encoding_problems,
    ) = collect_upstream_accept_encoding(
        [TOKEN_PROXY_PY, PROXY_CONFIG_PY, PROXY_REWRITE_PY]
    )
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
        py_context_warn_env=_first_match(
            _PY_CONTEXT_WARN_ENV_RE, _read(RESPONSE_NOTE_PY) or ""
        ),
        swift_context_warn_env=_first_match(
            _SWIFT_CONTEXT_WARN_ENV_RE, _read(SWIFT) or ""
        ),
        param_ref_keys=param_ref_keys,
        param_problems=param_problems,
        param_table=param_table,
        python_l10n_baseline=python_l10n_baseline,
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
        + find_env_key_violations(
            inp.env_keys, inp.python_env_reads, inp.python_script_env_reads
        )
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
        + find_context_warn_env_violations(
            inp.py_context_warn_env, inp.swift_context_warn_env
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
        )
        + find_baseline_lang_violations(
            {
                "PromptManager.fallbackLanguage": inp.swift_fallback_lang,
                "prompt_loader.FALLBACK_LANG": inp.python_fallback_lang,
                "l10n.BASELINE_LANG": inp.python_l10n_baseline,
            }
        )
    )


