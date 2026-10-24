"""Prompt and parameter-description checks."""
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
    L10N_BACKED_FEATURES, PROMPTS, PROMPT_BASELINE_LANG, PROMPT_FEATURES,
    PROMPT_OTHER_LANGS, RESOURCES, ROOT, TOOL_TEXT_PY,
)
from router_contract.parsers import _read
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


def collect_param_descriptions(*paths: str) -> tuple[set[str], list[str]]:
    """Usage of parameter descriptions inside the tool schema factory: `(referenced key set, list not going through i18n)`.

    The schema moved out of `handle_list_tools()` in server.py into `build_tools()` in
    server_tool_schema.py, so both names are accepted across the given files.

    Uses AST rather than regex: the word `description` has several other meanings in server.py
    (the tool-level `Tool(description=...)`), and a regex over the whole file would count them too,
    whereas this contract applies **only** to parameter descriptions in `inputSchema`.

    It only looks inside the function and only recognizes dict `"description"` keys: a tool-level
    description goes through the `Tool(description=...)` keyword argument and is naturally out of
    scope.
    """
    refs: set[str] = set()
    problems: list[str] = []
    found = False
    for path in paths:
        src = _read(path)
        if src is None:
            problems.append(f"cannot read {os.path.relpath(path, ROOT)}")
            continue
        try:
            tree = ast.parse(src)
        except SyntaxError as e:
            problems.append(f"{os.path.relpath(path, ROOT)} syntax error: {e}")
            continue

        func = next(
            (
                n
                for n in ast.walk(tree)
                if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
                and n.name in ("handle_list_tools", "build_tools")
            ),
            None,
        )
        if func is None:
            problems.append(
                f"{os.path.relpath(path, ROOT)}: neither handle_list_tools nor build_tools found"
            )
            continue
        found = True

        for node in ast.walk(func):
            if not isinstance(node, ast.Dict):
                continue
            for key_node, value_node in zip(node.keys, node.values):
                if not (
                    isinstance(key_node, ast.Constant)
                    and key_node.value == "description"
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
    if not found and not problems:
        problems.append(
            "tool schema factory not found —— renamed, please update this script"
        )
    return refs, problems


def find_param_text_violations(
    refs: set[str],
    problems: list[str],
    table: dict[str, str],
) -> list[str]:
    """Pure function: the contract violation list of tool parameter descriptions.

    Each of the three assertions corresponds to a real failure:
    - a description in the schema not going through `param_text` → a parameter silently loses its
      guidance, and no one inspects every parameter;
    - a referenced key that doesn't exist in the table → raises `MissingParamText` at runtime,
      making **the entire tool list unusable**;
    - a key in the table that no one references → left over after a rename, and later readers
      assume editing one place is enough.
    """
    violations = [
        f"server.py's parameter description does not go through param_text: {p}"
        for p in problems
    ]
    if not table:
        violations.append(
            f"parsed no parameter text from {os.path.relpath(TOOL_TEXT_PY, ROOT)} —— the table was renamed, please update this script"
        )
        return violations

    violations += [
        f"parameter description references an unregistered key {key!r} —— raises MissingParamText at runtime, making the whole tool list unusable"
        for key in sorted(refs - set(table))
    ]
    violations += [
        f"{key!r} in PARAM_DESCRIPTIONS has no schema reference (left over after a rename?)"
        for key in sorted(set(table) - refs)
    ]
    return violations


def find_baseline_lang_violations(langs: dict[str, str | None]) -> list[str]:
    """Pure function: the baseline language must have the same value in **all** modules that hold it.

    It decides "which set of text to fall back to when the current language lacks it"——prompts and
    the L10n catalog share the same criterion. If any one drifts, the same missing text yields
    different results on the two paths, and neither side raises an error.
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
