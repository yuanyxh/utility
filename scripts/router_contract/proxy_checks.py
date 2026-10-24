"""Provider/client/accept-encoding checks."""
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
    CLIENT_STRUCTS, PROVIDER_STRUCT, _CASE_MAP_RE, _FIELD_RE, _STATIC_LET_RE,
)
from router_contract.parsers import (
    _extract_enum_body, _extract_struct_body, _module_string_constants, _read,
    _set_literals_by_name,
)
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

_ACCEPT_ENCODING_HEADER = "accept-encoding"




def collect_upstream_accept_encoding(
    path: str | list[str],
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
    paths = [path] if isinstance(path, str) else list(path)
    trees: list[ast.AST] = []
    consts: dict[str, str] = {}
    problems: list[str] = []
    for p in paths:
        src = _read(p)
        if src is None:
            problems.append(f"cannot read {p}")
            continue
        trees.append(ast.parse(src))
        consts.update(_module_string_constants(p))
    if not trees:
        return set(), None, problems
    sets_by_name: dict[str, set[str] | None] = {}
    for tree in trees:
        for name, values in _set_literals_by_name(tree).items():
            sets_by_name[name] = values if name not in sets_by_name else None
    guards: set[str] = set()
    declared: str | None = None
    for tree in trees:
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


