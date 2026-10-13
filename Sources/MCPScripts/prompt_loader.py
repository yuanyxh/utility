"""Unified entry point for Python-side prompts: built-in defaults + user overrides + declarative contract.

Prompts used to be hard-coded across 10 functions/constants (f-strings or long constants),
which had three consequences: changing a single prompt sentence required digging through the
source; the user is not necessarily a Chinese speaker; and a mistake neither raised an error nor
fell back. This module collapses "get a prompt" into one thing.

Directories and priority (for the same feature, only the highest-priority file is used):

    <config-dir>/prompts/<feature>.md              user override, highest priority, **language-independent**
    <MCPScripts>/prompts/<lang>/<feature>.md       built-in default, shipped with the package (.copy preserves the dir tree)

The language dimension of the two locations is **intentionally different**: built-in templates
target "users who may speak different native languages", so they are split into language dirs and
fall back to the baseline when a language is missing; a user override is a single file that **the
user controls**——the person writing the prompt has only one native language, so making "which
directory it goes in" depend on the UI language is both meaningless and would break when the
language is switched.

The config dir reuses the **existing** env contract: the `UTILITY_DATA_DIR` injected by Swift is
`~/.config/utility` (`AppPaths.configDir`), so no new env item is added.

The language comes from `UTILITY_LANG` (Swift sets it from `general.language`, empty falls back to
the system primary); the default is `zh-Hans`; when the language has no such file it **falls back
to the `zh-Hans` baseline** and logs a warning——a not-yet-translated feature should not stall the
feature, but it must not be silent either (otherwise "the translation didn't take effect" would be
impossible to discover).

Declarative contract (front-matter, flat keys, no YAML dependency):

    ---
    name: aggregate
    placeholders: [label, facts_text]
    json_keys: []
    ---

- `name` must match the feature name: a misplaced file (e.g. writing a.md's content into b.md)
  is exposed immediately, instead of silently using the wrong prompt.
- `placeholders` must match the placeholders actually appearing in the body (file self-check);
  at call time the arguments must cover the declaration (missing → raise `PromptLoadError`,
  otherwise `{topic}` would be sent to the model verbatim); extra arguments only log a warning.
- `json_keys` are the **keys expected in the model output**, for post-call validation
  (`missing_json_keys`); empty = not declared.

Rendering does **not use `str.format`**: prompts contain many JSON braces (`{"action": "merge"}`),
and format would treat them as placeholders. Instead it uses "one-shot replacement by name"——
unregistered `{...}` are kept verbatim, and substituted values are not replaced a second time
(otherwise a value containing `{x}` would be clobbered by a later replacement).
This is the same pattern as Swift `PromptManager.applyVariables`.

Failure-handling chain during load: an invalid user override file → error log + **keep looking for
the built-in default** (a user's mistake should not stall the feature); the built-in default is also
unreadable → raise `PromptLoadError` (a corrupt install is a development-time error; silently
passing an empty prompt to the model is worse than failing outright).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from config import data_dir, ui_language
from log_utils import setup_logging

logger = setup_logging("prompt_loader")

#: Baseline language. Any language missing this feature falls back to it; the built-in defaults
#: must guarantee this language is complete.
FALLBACK_LANG = "zh-Hans"

# The language is read via `config.ui_language()` (`UTILITY_LANG`, injected by Swift from
# `general.language`)——the authoritative env name lives in Swift `EnvKeys.utilityLang`, and the
# sole entry point for Python-side config reading is config.py.

#: Characters allowed in a feature name (used for filename concatenation, guards against directory traversal)
_FEATURE_RE = re.compile(r"^[a-z][a-z0-9_]*$")

#: front-matter: the file must start with `---` and end with `---`
_FRONTMATTER_RE = re.compile(r"\A---\r?\n(.*?)\r?\n---\r?\n", re.DOTALL)
_KEY_RE = re.compile(r"^([a-zA-Z_]+)\s*:\s*(.*)$")
_LIST_RE = re.compile(r"^\[(.*)\]$")

#: Placeholders in the body: only the "alphanumeric+underscore" form is recognized, so JSON
#: `{"action": ...}` is not misdetected
_PLACEHOLDER_RE = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}")


class PromptLoadError(RuntimeError):
    """Prompt unavailable (built-in default missing, call arguments mismatched with the declaration, etc.)."""


@dataclass(frozen=True)
class PromptTemplate:
    feature: str
    lang: str
    path: str
    text: str
    placeholders: tuple[str, ...]
    json_keys: tuple[str, ...]


_cache: dict[str, PromptTemplate] = {}


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------


def _builtin_root() -> Path:
    return Path(__file__).resolve().parent / "prompts"


def _override_root() -> Path | None:
    """User override root directory (config dir). None when `UTILITY_DATA_DIR` is not injected."""
    base = data_dir()
    return Path(base) / "prompts" if base else None


def current_lang() -> str:
    return ui_language().strip() or FALLBACK_LANG


# ---------------------------------------------------------------------------
# Parsing and validation
# ---------------------------------------------------------------------------


def _parse_list(raw: str) -> tuple[str, ...]:
    m = _LIST_RE.match(raw.strip())
    if not m:
        return ()
    items = [item.strip().strip("\"'") for item in m.group(1).split(",")]
    return tuple(item for item in items if item)


def parse_template(raw: str, feature: str, path: Path | str) -> PromptTemplate:
    """Parse and self-check a template text; any contract violation raises `PromptLoadError`.

    Decoupled from "read a file": `_parse_file` is its file form, while the contract-check script
    needs to feed text directly——what it asserts is "would a hypothetical bad file be rejected",
    and it should not have to write a real temp file to disk for that. Both sides share the same
    parsing function, so the checker asserts exactly the path that really runs at runtime.
    """
    path = Path(path)
    m = _FRONTMATTER_RE.match(raw)
    if not m:
        raise PromptLoadError(
            f"{path}: missing front-matter (--- name/placeholders/json_keys ---)"
        )
    meta: dict[str, str] = {}
    for line in m.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        km = _KEY_RE.match(line.strip())
        if not km:
            raise PromptLoadError(f"{path}: cannot parse front-matter line {line!r}")
        meta[km.group(1)] = km.group(2)

    name = meta.get("name", "").strip()
    if name != feature:
        raise PromptLoadError(
            f"{path}: name={name!r} does not match the requested feature={feature!r}"
        )

    text = raw[m.end() :]
    declared = _parse_list(meta.get("placeholders", ""))
    found = tuple(dict.fromkeys(_PLACEHOLDER_RE.findall(text)))
    if set(declared) != set(found):
        raise PromptLoadError(
            f"{path}: placeholders declaration does not match actual (declared {sorted(declared)} / actual {sorted(found)})"
        )
    return PromptTemplate(
        feature=feature,
        lang=path.parent.name,
        path=str(path),
        text=text,
        placeholders=declared,
        json_keys=_parse_list(meta.get("json_keys", "")),
    )


def _parse_file(path: Path, feature: str) -> PromptTemplate:
    """Parse and self-check a template file; any contract violation raises `PromptLoadError`."""
    return parse_template(path.read_text(encoding="utf-8"), feature, path)


def _candidate_paths(feature: str) -> list[tuple[Path, str | None]]:
    """Return candidate files by priority: (path, lang); a lang of `None` means **language-independent**.

    User overrides (`_override_root()`) are not split by language: the person writing the prompt has
    only one native language, and that file is for themselves, so making "which directory it goes in"
    depend on the UI language is both meaningless and would break when the language is switched.
    Built-in templates are the opposite——users may have different native languages, so they are split
    by language and fall back to the baseline.
    """
    langs = [current_lang()]
    if langs[0] != FALLBACK_LANG:
        langs.append(FALLBACK_LANG)

    paths: list[tuple[Path, str | None]] = []
    override = _override_root()
    if override is not None:
        paths.append((override / f"{feature}.md", None))
    paths.extend((_builtin_root() / lang / f"{feature}.md", lang) for lang in langs)
    return paths


def template(feature: str) -> PromptTemplate:
    """Get a template by priority (cached in-process)."""
    if feature in _cache:
        return _cache[feature]
    if not _FEATURE_RE.match(feature):
        raise PromptLoadError(f"invalid feature name: {feature!r}")

    errors: list[str] = []
    for path, lang in _candidate_paths(feature):
        if not path.is_file():
            continue
        try:
            tpl = _parse_file(path, feature)
        except (PromptLoadError, OSError, UnicodeDecodeError) as e:
            # A broken user override file must not stop execution (fall back to built-in), but it
            # must never be silent——otherwise "the prompt I changed didn't take effect" would be
            # impossible to discover. A broken built-in file is recorded and raised together at the end.
            #
            # The caught range must **also cover read failures**: catching only PromptLoadError
            # lets `read_text`'s OSError (deleted externally / insufficient permission) and
            # UnicodeDecodeError (saved back as non-UTF-8) pass straight through, making the line
            # above about "a user's mistake should not stall the feature" vacuous——the first stage
            # of the summarize chain has no try, so a single override file saved as GBK is enough to
            # break the whole pipeline. Swift's `PromptManager.loadTemplate` uses `try?` to move to
            # the next candidate, and both sides must behave identically.
            errors.append(str(e))
            logger.error(str(e))
            continue
        # Only built-in templates have "language fallback"; user overrides are language-independent
        # and must not be reported as a fallback
        if lang is not None and lang != current_lang():
            logger.warning(
                f"{feature}: language {current_lang()!r} has no such template, falling back to {FALLBACK_LANG!r} ({path})"
            )
        _cache[feature] = tpl
        return tpl

    raise PromptLoadError(
        f"prompt unavailable feature={feature!r}: {'; '.join(errors) or 'no candidate file found'}"
    )


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def render(tpl: PromptTemplate, variables: dict) -> str:
    """One-shot replacement of placeholders by name; unregistered `{...}` are kept verbatim."""
    missing = [p for p in tpl.placeholders if p not in variables]
    if missing:
        raise PromptLoadError(
            f"{tpl.feature}: call missing argument {missing} (declared {list(tpl.placeholders)})——"
            "a missing argument sends the {placeholder} to the model verbatim"
        )
    extra = [k for k in variables if k not in tpl.placeholders]
    if extra:
        logger.warning(
            f"{tpl.feature}: call passes extra argument {extra} (unused by the template, usually left over after renaming a call site)"
        )

    def _sub(match: re.Match[str]) -> str:
        name = match.group(1)
        return str(variables[name]) if name in variables else match.group(0)

    return _PLACEHOLDER_RE.sub(_sub, tpl.text)


def prompt(feature: str, **variables) -> str:
    """Get and render a prompt (the sole entry point for Python-side prompts)."""
    return render(template(feature), variables)


def missing_json_keys(feature: str, parsed: dict | None) -> tuple[str, ...]:
    """Check which keys the model output is missing per the template's `json_keys` (not declared / not a dict → empty)."""
    if not isinstance(parsed, dict):
        return ()
    return tuple(k for k in template(feature).json_keys if k not in parsed)
