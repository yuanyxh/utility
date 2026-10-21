#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Language pack: language-specific lexical rules, thresholds, prompts."""

from __future__ import annotations

import json
import re
from pathlib import Path

from utility.core.prompt_template import PromptTemplate, parse_template, render


class PackError(ValueError):
    pass


_TEXT_PLACEHOLDER = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)(?::(\.\d+f|d))?\}")


def _render_text(template: str, values: dict, key: str) -> str:
    def replace(match: re.Match) -> str:
        name, spec = match.group(1), match.group(2)
        if name not in values:
            raise PackError(f"{key}: missing value for placeholder {name!r}")
        value = values[name]
        if spec == "d":
            return str(int(value))
        if spec:
            return format(float(value), spec)
        return str(value)

    return _TEXT_PLACEHOLDER.sub(replace, template)


REQUIRED_PACK_KEYS = (
    "id",
    "sentence_end",
    "sentence_end_lookbehind",
    "opening_sentence_end",
    "paragraph_split",
    "sentence_join",
    "sentence_terminal",
    "assets",
    "question_marks",
    "default_genre",
    "list_separator",
    "topic_min_units",
    "fallback_title",
    "title_trim_chars",
    "topic_trim_chars",
    "default_angle",
    "clause_separator",
    "term_sizes",
)
REQUIRED_LEXICON_KEYS = (
    "patterns",
    "words",
    "ai_patterns",
    "material",
    "router",
    "markdown",
)
REQUIRED_PATTERN_KEYS = (
    "background",
    "causal_opening",
    "checksum_context",
    "colloquial_heading",
    "commit_context",
    "concrete_opening",
    "def_opening",
    "definition_guard",
    "example_cue",
    "first_project_explain",
    "half_punct",
    "internal_id",
    "lab_opening",
    "opaque_term",
    "paren_gloss",
    "placeholder",
    "scope_mark",
    "scope_opening",
    "struct_def",
    "title_colloquial",
    "title_formal",
    "title_split",
    "topic_split",
    "transferable",
    "universal_claim",
    "unresolved",
    "slug_invalid",
    "opening_hook",
    "topic_suffix",
    "query_split",
)
REQUIRED_WORD_KEYS = (
    "angles",
    "background_subject_stop",
    "colloquial",
    "connectives",
    "context",
    "dead",
    "en_stop",
    "generic_acronyms",
    "generic_tags",
    "generic_topic",
    "genres",
    "high_tags",
    "narrative",
    "opening_modes",
    "problem",
    "pronouns",
    "tech",
    "tradeoff",
    "seeds",
)
REQUIRED_MATERIAL_KEYS = (
    "strong_low",
    "weak_low",
    "ephemeral",
    "tech",
    "evidence",
    "reasoning",
)
REQUIRED_MARKDOWN_KEYS = (
    "reference_sources",
    "diagram_genres",
    "blockquote_cue",
)
REQUIRED_TEXT_KEYS = (
    "genarticles.preflight_failed",
    "genarticles.busy",
    "genarticles.timeout",
    "genarticles.material_insufficient",
    "genarticles.review.header",
    "genarticles.review.none",
    "genarticles.report.header",
    "genarticles.material.header",
)
REQUIRED_THRESHOLD_KEYS = (
    "base_call_limit",
    "base_inline_per_1k",
    "base_hardcore_floor",
    "strict_call_limit",
    "strict_inline_per_1k",
    "strict_hardcore_floor",
    "strict_depth_floor",
    "colloquial_limit",
    "colloquial_warn",
    "min_han",
    "max_comments",
    "max_para",
    "uniform_cv",
    "inline_warn_per_1k",
    "mermaid_nodes_warn",
    "mermaid_nodes_fail",
    "mermaid_depth_warn",
    "mermaid_depth_fail",
    "mermaid_out_degree_warn",
    "mermaid_branch_warn",
    "mermaid_edges_extra",
    "mermaid_subgraphs_warn",
    "mermaid_sequence_participants_warn",
    "mermaid_sequence_messages_warn",
    "strong_warn_per_1k",
)


class LanguagePack:
    def __init__(self, root: Path):
        self.root = root
        self.raw = self._load("pack.json")
        self.lexicon = self._load("lexicon.json")
        self.thresholds = self._load("thresholds.json")
        self.texts = self._load("texts.json")
        self._prompts: dict[str, PromptTemplate] = {}
        self._patterns: dict[tuple[str, int], re.Pattern] = {}
        if not self.raw.get("id"):
            raise PackError(f"{root}: pack.json missing id")
        for name, data, required in (
            ("pack.json", self.raw, REQUIRED_PACK_KEYS),
            ("lexicon.json", self.lexicon, REQUIRED_LEXICON_KEYS),
            ("thresholds.json", self.thresholds, REQUIRED_THRESHOLD_KEYS),
            ("texts.json", self.texts, REQUIRED_TEXT_KEYS),
        ):
            missing = [key for key in required if key not in data]
            if missing:
                raise PackError(f"{root}/{name}: missing {missing}")
        for group, keys in (
            ("patterns", REQUIRED_PATTERN_KEYS),
            ("words", REQUIRED_WORD_KEYS),
            ("material", REQUIRED_MATERIAL_KEYS),
            ("markdown", REQUIRED_MARKDOWN_KEYS),
        ):
            missing = [key for key in keys if key not in self.lexicon[group]]
            if missing:
                raise PackError(f"{root}/lexicon.json: {group} missing {missing}")
        missing = [
            key for key in ("hard", "soft") if key not in self.lexicon["ai_patterns"]
        ]
        if missing:
            raise PackError(f"{root}/lexicon.json: ai_patterns missing {missing}")

    def _load(self, name: str) -> dict:
        path = self.root / name
        if not path.exists():
            raise PackError(f"{path}: missing")
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise PackError(f"{path}: {exc}") from exc
        if not isinstance(data, dict):
            raise PackError(f"{path}: expected object")
        return data

    @property
    def id(self) -> str:
        return str(self.raw["id"])

    @property
    def unit_re(self) -> re.Pattern:
        return self.pattern("han")

    def pattern(self, name: str, flags: int = 0) -> re.Pattern:
        key = (name, flags)
        if key in self._patterns:
            return self._patterns[key]
        try:
            raw = self.lexicon["patterns"][name]
        except KeyError as exc:
            raise PackError(f"{self.root}: missing pattern {name!r}") from exc
        compiled = re.compile(raw, flags)
        self._patterns[key] = compiled
        return compiled

    def material_pattern(self, name: str, flags: int = 0) -> re.Pattern:
        key = ("material:" + name, flags)
        if key in self._patterns:
            return self._patterns[key]
        try:
            raw = self.lexicon["material"][name]
        except KeyError as exc:
            raise PackError(f"{self.root}: missing material pattern {name!r}") from exc
        compiled = re.compile(raw, flags)
        self._patterns[key] = compiled
        return compiled

    def markdown_pattern(self, name: str, flags: int = 0) -> re.Pattern:
        key = ("markdown:" + name, flags)
        if key in self._patterns:
            return self._patterns[key]
        try:
            raw = self.lexicon["markdown"][name]
        except KeyError as exc:
            raise PackError(f"{self.root}: missing markdown pattern {name!r}") from exc
        compiled = re.compile(raw, flags)
        self._patterns[key] = compiled
        return compiled

    def markdown_words(self, name: str) -> tuple[str, ...]:
        try:
            return tuple(self.lexicon["markdown"][name])
        except KeyError as exc:
            raise PackError(f"{self.root}: missing markdown words {name!r}") from exc

    @property
    def router(self) -> dict[str, list[str]]:
        return self.lexicon["router"]

    def pattern_map(self, name: str) -> dict[str, re.Pattern]:
        try:
            raw = self.lexicon["ai_patterns"][name]
        except KeyError as exc:
            raise PackError(f"{self.root}: missing ai pattern group {name!r}") from exc
        return {key: re.compile(value) for key, value in raw.items()}

    def words(self, name: str) -> tuple[str, ...]:
        try:
            return tuple(self.lexicon["words"][name])
        except KeyError as exc:
            raise PackError(f"{self.root}: missing words {name!r}") from exc

    def threshold(self, name: str) -> float:
        try:
            return self.thresholds[name]
        except KeyError as exc:
            raise PackError(f"{self.root}: missing threshold {name!r}") from exc

    @property
    def sentence_end(self) -> str:
        return str(self.raw["sentence_end"])

    @property
    def sentence_end_lookbehind(self) -> str:
        return str(self.raw["sentence_end_lookbehind"])

    @property
    def opening_sentence_end(self) -> str:
        return str(self.raw["opening_sentence_end"])

    @property
    def paragraph_split(self) -> str:
        return str(self.raw["paragraph_split"])

    @property
    def sentence_join(self) -> str:
        return str(self.raw["sentence_join"])

    def asset(self, name: str) -> Path:
        assets = self.raw.get("assets") or {}
        if name not in assets:
            raise PackError(f"{self.root}: missing asset {name!r}")
        return self.root / assets[name]

    def text(self, key: str, **values) -> str:
        template = self.texts.get(key)
        if template is None:
            raise PackError(f"{self.root}/texts.json: missing {key!r}")
        return _render_text(template, values, key)

    def prompt(self, feature: str, **values) -> str:
        if feature not in self._prompts:
            path = self.asset("prompts") / f"{feature}.md"
            if not path.exists():
                raise PackError(f"{path}: missing prompt")
            self._prompts[feature] = parse_template(
                path.read_text(encoding="utf-8"), feature, path
            )
        return render(self._prompts[feature], values)
