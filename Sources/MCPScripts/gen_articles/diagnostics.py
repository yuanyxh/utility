#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stable diagnostic codes + English render templates.

Consumers branch on `code`, never on message text.
"""

from __future__ import annotations

TEMPLATES = {
    "half_width_punct": "Half-width punctuation next to text: {count} (limit 5): {sample}",
    "strong_ai_template": "Strong AI template: {hits}",
    "soft_ai_template": "Soft AI template hits ({count}): {hits}",
    "lab_opening": "Opening reads like a lab report: problem/observation/minimal repro, no trigger context",
    "colloquial_density": "Colloquial density {density}/1k chars, above 5",
    "colloquial_density_warn": "Colloquial density {density}/1k chars; keep below 3",
    "inline_calls": "Inline code contains calls/expressions: {count} (limit {limit}): {sample}",
    "inline_density": "Inline code density {density}/1k, above {limit}: {sample}",
    "inline_calls_warn": "Inline code contains calls/expressions: {count}",
    "inline_density_warn": "Inline code density {density}/1k is high",
    "title_project_name": "Title contains a project-internal name; third-party readers cannot identify the topic",
    "first_paragraph_project_name": "First paragraph uses a project-internal name before the general problem",
    "opening_context": "Opening lacks context: state what system/general scenario this is before implementation",
    "internal_identifiers": "Unlinked internal identifiers: {count} (commit/hash); readers cannot trace them: {sample}",
    "opening_abstract": "Opening is an abstract definition; start with a trigger or observable symptom",
    "opening_scope": "Opening is a scope statement; start with a concrete problem",
    "example_promise": "Example promised but no code/data follows: {sample}",
    "placeholders": "Placeholders in body: {sample}; fill real values or remove",
    "universal_claim": "Unsupported universal claim: {sample}",
    "no_causal_links": "First two paragraphs lack explicit causal links (because/therefore/leads to/once)",
    "no_transferable": "Missing transferable conclusion: how other systems reuse this judgment",
    "project_name_repeated": "Project-internal name appears {count} times; ensure the first use is explained",
    "hardcore_density": "Hardcore density low: {score}/100; depth signals {depth}/8; missing: {missing}",
    "question_title": "Title is a question; prefer a noun phrase",
    "informal_title": "Title lacks a formal noun phrase (analysis/debugging/design/implementation) or is colloquial",
    "colloquial_heading": "Colloquial section heading: {sample}",
    "comment_block": "A code block has {count} comment lines; may distract readers",
    "comment_ratio": "Comment ratio too high; comments should explain key steps only",
    "uniform_sections": "Section lengths too uniform ({sections}, CV={cv})",
    "long_paragraph": "Longest paragraph: {chars} chars",
    "short_body": "Body has only {count} characters",
    "no_code": "No code blocks; technical article lacks reproducible detail",
    "no_unresolved": "Ending has no unresolved item; likely a correct but useless summary",
    "missing_mermaid": "Missing Mermaid diagram: add at least one for architecture/flow/timing",
    "mermaid_syntax": "Mermaid syntax issue: {detail}",
    "too_many_mermaid": "Mermaid diagrams: {count}; more than 3 becomes decoration",
    "flat_structure": "No tables, lists, or blockquotes; structure is too flat",
    "bare_references": "Third-party references without links: {sample}",
    "code_language_missing": "{count} code blocks missing a language label",
    "no_blockquotes": "Key conclusions are not in blockquotes (>)",
}


def issue(code: str, **params) -> dict:
    template = TEMPLATES.get(code)
    if template is None:
        raise KeyError(f"unregistered diagnostic code: {code}")
    return {"code": code, "message": template.format(**params), "params": params}
