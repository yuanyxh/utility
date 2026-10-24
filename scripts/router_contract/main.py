"""CLI entry point for the cross-language contract checks."""
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


from router_contract.consts import SCRIPTS
from router_contract.inputs import (
    ContractInputs, _drop_from_payload, _drop_struct, _first_match, check_all, collect_inputs,
)
from router_contract.proxy_checks import _ACCEPT_ENCODING_HEADER
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
        "context-warn env name: mismatched on the two sides": replace(
            base, swift_context_warn_env="MODEL_PROXY_CONTEXT_WARN_RENAMED"
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
        # tool parameter descriptions (fixed English)
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
            param_table={**base.param_table, "param.orphan": "orphan"},
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
    scripts_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = dict(os.environ)
    env["PYTHONPATH"] = scripts_dir + (
        os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""
    )
    os.execve(VENV_PYTHON, [VENV_PYTHON, os.path.abspath(__file__), *sys.argv[1:]], env)


def main() -> int:
    _reexec_with_venv()
    sys.path.insert(0, SCRIPTS)
    try:
        from utility.services.proxy.proxy_client import (
            ACCEL_CLIENT_KEYS,
            ACCEL_CONTRACT_KEYS,
            CLIENT_TEXT_CONTRACT_KEYS,
        )
        from utility.services.proxy.proxy_provider import (
            KEY_API_FORMAT,
            KEY_API_KEY,
            KEY_MODELS,
            KEY_NAME,
            KEY_URL,
        )

        # The prompt group's criterion comes from the production parser itself, avoiding "the checker and the runtime parser not being from the same source"
        from utility.core.prompt_loader import (
            FALLBACK_LANG as PY_FALLBACK_LANG,
            parse_template as parse_prompt_template,
        )

        # The parameter-description table is fixed English and lives in tool_text
        from utility.core.l10n import BASELINE_LANG as PY_L10N_BASELINE
        from utility.core.tool_text import PARAM_DESCRIPTIONS as PY_PARAM_TEXT
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
            client_groups, PY_FALLBACK_LANG, PY_PARAM_TEXT, PY_L10N_BASELINE
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
