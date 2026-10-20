#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""写作计划：把主题压成触发条件、因果问题链、证据与边界。"""

from __future__ import annotations

import json
import re

from gen_articles import runtime
from gen_articles.i18n import t as tr
from gen_articles.llm import LLMClient


def build_plan_prompt(topic: str, genre: str, material_md: str) -> tuple[str, str]:
    return (
        runtime.pack().prompt("gen_articles_plan_system"),
        runtime.pack().prompt("gen_articles_plan_user", topic=topic, genre=genre,
                    material_md=material_md),
    )


def parse_plan(text: str) -> dict | None:
    decoder = json.JSONDecoder()
    for match in re.finditer(r"\{", text):
        try:
            plan, _ = decoder.raw_decode(text[match.start():])
        except json.JSONDecodeError:
            continue
        if isinstance(plan, dict) and plan.get("question_chain"):
            return plan
    return None


def make_plan(topic: str, genre: str, material_md: str,
              max_tokens: int = 1600) -> dict:
    client = LLMClient()
    system, user = build_plan_prompt(topic, genre, material_md)
    for attempt in range(2):
        raw = client.chat(user, system=system, temperature=0.3,
                          max_tokens=max_tokens * (attempt + 1),
                          disable_thinking=True)
        plan = parse_plan(raw)
        if plan is not None:
            return plan
        user += tr("genarticles.plan.retry")
    raise ValueError(tr("genarticles.plan.invalid_json"))


def render_plan(plan: dict) -> str:
    separator = runtime.pack().raw["clause_separator"]
    chain = plan.get("question_chain") or []
    lines = [tr("genarticles.plan.general_problem",
                value=plan.get("general_problem", ""))]
    if plan.get("audience"):
        lines.append(tr("genarticles.plan.audience", value=plan["audience"]))
    if plan.get("terms_to_define"):
        lines.append(tr("genarticles.plan.terms_to_define",
                        value=separator.join(plan["terms_to_define"])))
    if plan.get("transferable_principle"):
        lines.append(tr("genarticles.plan.transferable",
                        value=plan["transferable_principle"]))
    lines.append(tr("genarticles.plan.trigger", value=plan.get("trigger", "")))
    lines.append(tr("genarticles.plan.chain"))
    lines += [f"{i}. {q}" for i, q in enumerate(chain, 1)]
    turns = plan.get("turns") or []
    if turns:
        lines.append(tr("genarticles.plan.turns"))
        lines += [f"- {t}" for t in turns]
    evidence = plan.get("evidence") or []
    if evidence:
        lines.append(tr("genarticles.plan.evidence", value=separator.join(evidence)))
    if plan.get("boundary"):
        lines.append(tr("genarticles.plan.boundary", value=plan["boundary"]))
    return "\n".join(lines)
