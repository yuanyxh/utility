"""summarize 阶段3 规范提炼模块。

从 summarize.py 拆分（2026-08-30，重构阶段3）：规则/规范类记忆 →
MCP/Rules/*.md 的提炼、修剪、渲染。代码原样搬移不改逻辑。
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
# 配置（与拆分前 summarize.py 一致）
# ---------------------------------------------------------------------------

MCP_DIR = NOTES_DIR / "MCP"
SKILLS_RULES_DIR = MCP_DIR / "Rules"
RULES_MIN_CANDIDATES = 3  # 本周期规则/规范类有效记忆少于该值则跳过提炼
RULES_MAX_PER_FILE = 60  # 每规范文件条目上限，超出由 LLM 淘汰
RULES_LLM_TEMPERATURE = 0.2  # 提炼允许归纳，与聚合一致
#: 规则提炼的 LLM 超时。取自同一来源（config `ai.llmTimeout`）——与单次摘要、批量聚合
#: 共用，区别于「本阶段的提示词更大所以要更长」的旧假设：实测三者撞的是同一条上游超时。
RULES_LLM_TIMEOUT = SUMMARY_LLM_TIMEOUT
# 多级规范：global 全局通用 + 各项目类型通用；LLM 判定不了的归入 global
RULES_LEVELS = {
    "global": "全局通用",
    "web_frontend": "Web 前端",
    "mobile": "移动端",
    "macos_tool": "macOS 工具",
    "backend": "后端/服务",
}

logger = setup_logging("summarize")


def _parse_rules_entries(text: str) -> list[dict]:
    """从规范文件正文解析条目列表。"""
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
    """渲染规范文件完整内容（frontmatter + 条目区）。

    description 按规范级别定制触发语，供 _scan_skills 注册成 MCP 工具后，
    大模型据此判断何时调用：
    - global：行为约束 + 通用原则，涉及多领域 → 宽泛触发「操作前获取本行为规范」
    - 项目类型：按「开始开发该类型项目时」触发
    keywords 保留在正文条目作覆盖范围说明，不拼进 description（避免词堆）。
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
    """读取指定级别规范文件的现有条目；文件不存在时返回空列表与目标路径。"""
    path = SKILLS_RULES_DIR / f"norms_{level}.md"
    if not path.exists():
        return [], path
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        logger.warning(f"读取规范文件失败 {path}: {e}")
        return [], path
    if text.startswith("---"):
        parts = text.split("---", 2)
        if len(parts) == 3:
            text = parts[2]
    return _parse_rules_entries(text), path


def _trim_rules_entries(level: str, entries: list[dict]) -> list[dict]:
    """容量超限时由 LLM 淘汰低复用价值条目，保留不超过上限。"""
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
        logger.warning(f"规范文件淘汰 LLM 调用失败，保留前 {RULES_MAX_PER_FILE} 条")
        return entries[:RULES_MAX_PER_FILE]
    parsed = _parse_json_any(raw)
    keep = parsed.get("keep_indexes", []) if parsed else []
    keep = [int(i) for i in keep if str(i).strip().isdigit()]
    kept = [entries[i] for i in keep if 0 <= i < len(entries)]
    if not kept:
        logger.warning("淘汰结果为空，保留前 N 条兜底")
        return entries[:RULES_MAX_PER_FILE]
    return kept[:RULES_MAX_PER_FILE]


def _run_phase3(groups: list[dict], today_str: str) -> dict:
    """阶段3：从本周期聚合记忆中提炼"规则/规范类"规范，写入 MCP/Rules/*.md。

    只提炼可复用、稳定、能指导行动的知识；偶遇 bug、一次性修复、
    版本绑定 workaround 不提炼。本周期有效候选 < RULES_MIN_CANDIDATES 时跳过。
    """
    if not groups:
        return {"skipped": "no_groups"}

    facts_text = "\n".join(
        f"- {g.get('topic', '')}：{g.get('facts', '')}" for g in groups
    )

    # 已有标题清单，供 LLM 提炼时避开重复
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
        write_error_log("阶段3 规范提炼 LLM 调用失败", code="RULES_LLM")
        return {"skipped": "llm_failed"}
    parsed = _parse_json_any(raw)
    if not parsed:
        write_error_log(
            f"阶段3 规范提炼 JSON 解析错误：\n{raw[:1000]}", code="RULES_JSON"
        )
        return {"skipped": "json_failed"}

    candidates = parsed.get("candidates", []) or []
    norms = parsed.get("norms", []) or []
    # 门槛以实际提炼出的 norms 为准（candidates 是 LLM 自评主题列表，
    # 一个主题可提炼多条规范，数量与 norms 天然不一致，不能作门槛依据）
    if not norms:
        logger.info("阶段3 跳过：无提炼出的规范条目")
        return {"skipped": "no_norms"}
    if len(norms) < RULES_MIN_CANDIDATES:
        logger.info(f"阶段3 跳过：提炼出的规范 {len(norms)} < {RULES_MIN_CANDIDATES}")
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
            logger.info(f"阶段3 跳过重复规范：{title}")
            continue
        # keywords 兼容 LLM 返回字符串（逗号分隔）或数组两种形态
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

    logger.info(f"阶段3 完成：{updated}")
    # 无实际写入时返回空字符串，main() 据此跳过 git_commit，避免空提交
    return {"updated": ", ".join(f"{k}+{v}" for k, v in updated.items())}
