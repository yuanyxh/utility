"""summarize phase 3 rules-extraction module.

Split out of summarize.py (2026-08-30, refactor phase 3): extraction, trimming, and
rendering of rule/convention memories -> MCP/Rules/*.md. Code was moved as-is, logic
unchanged.
"""

from __future__ import annotations

import re
from pathlib import Path

import prompt_loader
from log_utils import setup_logging
from summary_llm import (
    _llm_chat,
    _parse_json_any,
    write_error_log,
    NOTES_DIR,
    SUMMARY_LLM_TIMEOUT,
)

# ---------------------------------------------------------------------------
# Configuration (same as summarize.py before the split)
# ---------------------------------------------------------------------------

MCP_DIR = NOTES_DIR / "MCP"
SKILLS_RULES_DIR = MCP_DIR / "Rules"
RULES_MIN_CANDIDATES = 3  # Skip extraction when this cycle's valid rule/convention memories are fewer than this value
RULES_MAX_PER_FILE = (
    60  # Max entries per rules file; over the limit they are pruned by the LLM
)
RULES_LLM_TEMPERATURE = (
    0.2  # Extraction allows generalization, consistent with aggregation
)
#: LLM timeout for rules extraction. Taken from the same source (config `ai.llmTimeout`) --
#: shared with single summary and batch aggregation, unlike the old assumption that "this
#: stage's prompt is bigger so it needs longer": in practice all three hit the same upstream timeout.
RULES_LLM_TIMEOUT = SUMMARY_LLM_TIMEOUT
# Multi-level rules: global + per-project-type; anything the LLM can't classify falls into global
RULES_LEVELS = {
    "global": "全局通用",
    "web_frontend": "Web 前端",
    "mobile": "移动端",
    "macos_tool": "macOS 工具",
    "backend": "后端/服务",
}

logger = setup_logging("summarize")


def _parse_rules_entries(text: str) -> list[dict]:
    """Parse the entry list from the body of a rules file."""
    entries = []
    cur = None
    for line in text.splitlines():
        if line.startswith("### "):
            if cur:
                entries.append(cur)
            cur = {
                "title": line[4:].strip(),
                "domain": "",
                "norm": "",
                "source": "",
                "date": "",
                "keywords": [],
            }
        elif cur:
            if line.startswith("- 领域: "):
                cur["domain"] = line[len("- 领域: ") :].strip()
            elif line.startswith("- 规范: "):
                cur["norm"] = line[len("- 规范: ") :].strip()
            elif line.startswith("- 来源: "):
                cur["source"] = line[len("- 来源: ") :].strip()
            elif line.startswith("- 提炼于: "):
                cur["date"] = line[len("- 提炼于: ") :].strip()
            elif line.startswith("- 关键词: "):
                cur["keywords"] = [
                    k.strip()
                    for k in re.split(r"[、,，]", line[len("- 关键词: ") :].strip())
                    if k.strip()
                ]
    if cur:
        entries.append(cur)
    return entries


def _render_rules_file(level: str, entries: list[dict]) -> str:
    """Render the full content of a rules file (frontmatter + entry section).

    description tailors the trigger wording to the rules level so that, once
    registered as an MCP tool by _scan_skills, the LLM can judge when to call it:
    - global: behavioral constraints + general principles, spanning multiple
      domains -> broad trigger "fetch this behavioral spec before acting"
    - project type: triggered "when starting development on that type of project"
    keywords are kept in the body entries as a scope note, and are not folded into
    description (to avoid keyword stuffing).
    """
    label = RULES_LEVELS[level]
    if level == "global":
        description = (
            f"操作前，获取本行为规范；全局通用规范，共 {len(entries)} 条，"
            f"适用于编码、审查、协作、总结等任何操作前的行为约束与通用原则。"
        )
    else:
        description = (
            f"当开始开发{label}项目时触发，获取{label}开发规范指南；"
            f"{label}通用规范，共 {len(entries)} 条。"
        )
    lines = [
        "---",
        f"name: norms_{level}",
        f"description: {description}",
        "---",
        "",
        f"# {label}规范",
        "",
        f"> 由 summarize 阶段3 自动提炼维护。条目带来源可追溯，容量上限 "
        f"{RULES_MAX_PER_FILE} 条。",
        "",
        "## 条目",
        "",
    ]
    for e in entries:
        lines.append(f"### {e['title']}")
        lines.append(f"- 领域: {e.get('domain', '')}")
        lines.append(f"- 规范: {e.get('norm', '')}")
        if e.get("keywords"):
            lines.append(f"- 关键词: {'、'.join(e['keywords'])}")
        lines.append(f"- 来源: {e.get('source', '')}")
        lines.append(f"- 提炼于: {e.get('date', '')}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _load_rules_entries(level: str) -> tuple[list[dict], Path]:
    """Read the existing entries of the given-level rules file; returns an empty list and the target path when the file does not exist."""
    path = SKILLS_RULES_DIR / f"norms_{level}.md"
    if not path.exists():
        return [], path
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        logger.warning(f"Failed to read rules file {path}: {e}")
        return [], path
    if text.startswith("---"):
        parts = text.split("---", 2)
        if len(parts) == 3:
            text = parts[2]
    return _parse_rules_entries(text), path


def _trim_rules_entries(level: str, entries: list[dict]) -> list[dict]:
    """When over capacity, let the LLM prune the least reusable entries, keeping no more than the limit."""
    if len(entries) <= RULES_MAX_PER_FILE:
        return entries
    item_list = "\n".join(
        f"- [{i}] {e['title']}：{e.get('norm', '')[:80]}" for i, e in enumerate(entries)
    )
    prompt = f"""\
规范文件「{RULES_LEVELS[level]}」条目超过上限 {RULES_MAX_PER_FILE} 条，需要淘汰复用价值最低的条目。

现有条目：
{item_list}

要求：保留最有复用价值、最能指导行动的 {RULES_MAX_PER_FILE} 条，淘汰过时/低复用/重复的。

返回 JSON：{{"keep_indexes": [保留的条目下标数组]}}
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    raw = _llm_chat(
        prompt,
        temperature=0.1,
        timeout=RULES_LLM_TIMEOUT,
        max_tokens=16384,
        disable_thinking=True,
    )
    if not raw:
        logger.warning(
            f"Rules-file pruning LLM call failed, keeping the first {RULES_MAX_PER_FILE} entries"
        )
        return entries[:RULES_MAX_PER_FILE]
    parsed = _parse_json_any(raw)
    keep = parsed.get("keep_indexes", []) if parsed else []
    keep = [int(i) for i in keep if str(i).strip().isdigit()]
    kept = [entries[i] for i in keep if 0 <= i < len(entries)]
    if not kept:
        logger.warning("Pruning result is empty, falling back to the first N entries")
        return entries[:RULES_MAX_PER_FILE]
    return kept[:RULES_MAX_PER_FILE]


def _run_phase3(groups: list[dict], today_str: str) -> dict:
    """Phase 3: extract "rule/convention" specs from this cycle's aggregated memories, writing them to MCP/Rules/*.md.

    Only extract reusable, stable, actionable knowledge; incidental bugs, one-off
    fixes, and version-bound workarounds are not extracted. Skipped when this
    cycle's valid candidates < RULES_MIN_CANDIDATES.
    """
    if not groups:
        return {"skipped": "no_groups"}

    facts_text = "\n".join(
        f"- {g.get('topic', '')}：{g.get('facts', '')}" for g in groups
    )

    # Existing title lists, so the LLM can avoid duplicates during extraction
    existing_titles = {}
    for level in RULES_LEVELS:
        entries, _ = _load_rules_entries(level)
        existing_titles[level] = [e["title"] for e in entries]
    titles_block = "\n".join(
        f"[{level}] {'; '.join(titles)}" if titles else f"[{level}] （空）"
        for level, titles in existing_titles.items()
    )
    level_labels = "\n".join(f"- {k}: {v}" for k, v in RULES_LEVELS.items())

    prompt = prompt_loader.prompt(
        "extract_rules",
        facts_text=facts_text,
        level_labels=level_labels,
        titles_block=titles_block,
    )
    raw = _llm_chat(
        prompt,
        temperature=RULES_LLM_TEMPERATURE,
        timeout=RULES_LLM_TIMEOUT,
        max_tokens=16384,
        disable_thinking=True,
    )
    if not raw:
        write_error_log("Phase 3 rules extraction LLM call failed", code="RULES_LLM")
        return {"skipped": "llm_failed"}
    parsed = _parse_json_any(raw)
    if not parsed:
        write_error_log(
            f"Phase 3 rules extraction JSON parse error:\n{raw[:1000]}",
            code="RULES_JSON",
        )
        return {"skipped": "json_failed"}

    norms = parsed.get("norms", []) or []
    # The gate is based on the norms actually extracted — one topic can yield several
    # norms, so the LLM's self-assessed topic count would not be a usable basis.
    if not norms:
        logger.info("Phase 3 skipped: no extracted rules entries")
        return {"skipped": "no_norms"}
    if len(norms) < RULES_MIN_CANDIDATES:
        logger.info(
            f"Phase 3 skipped: extracted rules {len(norms)} < {RULES_MIN_CANDIDATES}"
        )
        return {"skipped": "norms_lt_min", "count": len(norms)}

    updated = {}
    for norm in norms:
        title = str(norm.get("title", "")).strip()
        level = str(norm.get("level", "global")).strip()
        summary = str(norm.get("summary", "")).strip()
        if not title or not summary:
            continue
        if level not in RULES_LEVELS:
            level = "global"
        entries, path = _load_rules_entries(level)
        if any(e["title"] == title for e in entries):
            logger.info(f"Phase 3 skipping duplicate rule: {title}")
            continue
        # keywords is compatible with both forms: the LLM may return a string
        # (comma-separated) or an array
        kws = norm.get("keywords") or []
        if isinstance(kws, str):
            kws = re.split(r"[、,，]", kws)
        keywords = [k.strip() for k in kws if str(k).strip()]
        entries.append(
            {
                "title": title,
                "domain": RULES_LEVELS[level],
                "norm": summary,
                "keywords": keywords,
                "source": str(norm.get("source", "")).strip(),
                "date": today_str,
            }
        )
        entries = _trim_rules_entries(level, entries)
        SKILLS_RULES_DIR.mkdir(parents=True, exist_ok=True)
        path.write_text(_render_rules_file(level, entries), encoding="utf-8")
        updated[path.name] = updated.get(path.name, 0) + 1

    logger.info(f"Phase 3 done: {updated}")
    # Return an empty string when nothing was actually written; main() uses this to
    # skip git_commit and avoid an empty commit
    return {"updated": ", ".join(f"{k}+{v}" for k, v in updated.items())}
