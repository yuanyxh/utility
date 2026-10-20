#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文章风格检测：把 SOUL 中可判定的条款落成确定性检查。

语言相关规则全部来自语言包（patterns / words / thresholds），
本模块只保留与自然语言无关的结构分析。
"""

from __future__ import annotations

import re
import statistics
from gen_articles import runtime
from gen_articles.diagnostics import issue
from gen_articles.language_pack import LanguagePack

CODE_BLOCK = re.compile(r"```.*?```", re.S)
INLINE_CODE = re.compile(r"`([^`\n]+)`")
MARKDOWN_LINK = re.compile(r"\[[^\]]*\]\([^)]*\)")


def _strip_code(text: str) -> str:
    return CODE_BLOCK.sub("", text)


def _paragraphs(pack: LanguagePack, prose: str) -> list[str]:
    out = []
    for p in re.split(pack.paragraph_split, prose):
        s = p.strip()
        if not s or s.startswith(("#", "|", ">", "- ", "* ", "[")):
            continue
        out.append(s)
    return out


def _han(pack: LanguagePack, text: str) -> int:
    return len(pack.unit_re.findall(text))


def _literal_count(text: str, words: tuple[str, ...]) -> int:
    return sum(text.count(word) for word in words)


def _pattern_count(text: str, patterns: tuple[str, ...]) -> int:
    return sum(len(re.findall(pattern, text)) for pattern in patterns)


def _hits(patterns: dict[str, re.Pattern], text: str) -> list[str]:
    return [name for name, pat in patterns.items() if pat.search(text)]


def _first_project_unexplained(pack: LanguagePack, first_para: str,
                               pattern: re.Pattern | None) -> bool:
    if pattern is None:
        return False
    match = pattern.search(first_para)
    if not match:
        return False
    window = first_para[max(0, match.start() - 60): match.end() + 120]
    return not pack.pattern("first_project_explain").search(window)


def _project_pattern(pack: LanguagePack,
                     tokens: tuple[str, ...] | list[str]) -> re.Pattern | None:
    generic = {tag.lower() for tag in pack.words("generic_tags")}
    tokens = [
        t.strip() for t in tokens
        if t and t.strip() and t.strip().lower() not in generic
    ]
    if not tokens:
        return None
    # 标签里的连字符在正文中可能写成空格：token-proxy -> Token Proxy
    escaped = "|".join(
        re.escape(t).replace(r"\ ", r"[-\s]?").replace(r"\-", r"[-\s]?")
        for t in tokens
    )
    return re.compile(rf"(?<![0-9A-Za-z_])(?:{escaped})(?![0-9A-Za-z_])", re.I)


def _internal_ids(pack: LanguagePack, text: str) -> list[str]:
    """正文中未附链接、只能靠内部仓库追溯的 hash/编号。"""
    prose = MARKDOWN_LINK.sub("", _strip_code(text))
    found = []
    for match in pack.pattern("internal_id").finditer(prose):
        token = match.group(0)
        if token.isdigit():
            continue
        window = prose[max(0, match.start() - 30): match.end() + 30]
        if pack.pattern("checksum_context", re.I).search(window):
            continue
        if pack.pattern("commit_context", re.I).search(window) or f"`{token}`" in prose:
            found.append(token)
    return found


def _has_background(pack: LanguagePack, opening: str,
                    tokens: tuple[str, ...] | list[str] = ()) -> bool:
    """首段前两句给通用语境，或前两段出现对象到类别的定义句。"""
    paragraphs = [p for p in re.split(pack.paragraph_split, opening) if p.strip()]
    lead = re.split(pack.sentence_end, paragraphs[0])[:2] if paragraphs else []
    if pack.pattern("background").search(pack.sentence_join.join(lead)):
        return True
    for match in pack.pattern("struct_def").finditer(opening):
        subject, predicate = match.group(1).strip(), match.group(2)
        if subject in pack.words("background_subject_stop"):
            continue
        if _han(pack, predicate) < 4:
            continue
        if tokens and any(t.lower() in match.group(0).lower() for t in tokens):
            continue
        return True
    return False


def _example_gaps(pack: LanguagePack, text: str) -> list[str]:
    """强引导语之后没有代码块、引用或表格，示例停在口头承诺。"""
    blocks: list[tuple[str, str]] = []
    pos = 0
    for match in CODE_BLOCK.finditer(text):
        blocks.append(("prose", text[pos:match.start()]))
        blocks.append(("code", match.group(0)))
        pos = match.end()
    blocks.append(("prose", text[pos:]))

    gaps = []
    for i, (kind, content) in enumerate(blocks):
        if kind != "prose":
            continue
        for para in re.split(pack.paragraph_split, content):
            cue = pack.pattern("example_cue").search(para)
            if not cue:
                continue
            nxt = next((b for b in blocks[i + 1:] if b[1].strip()), None)
            if nxt is None or not re.match(
                r"^(?:```|>|\|)", nxt[1].lstrip()
            ):
                gaps.append(cue.group(0))
    return gaps


def _universal_claims(pack: LanguagePack, prose: str,
                      project_pattern: re.Pattern | None) -> list[str]:
    """把项目实现写成行业规律的断言：普遍量词 + 内部术语，且无范围限定。"""
    claims = []
    generic = {word.upper() for word in pack.words("generic_acronyms")}
    prose = re.sub(r"(?m)^#{1,6}\s+.*$", "", prose)
    for sentence in re.split(pack.sentence_end_lookbehind, prose):
        text = sentence.strip()
        if not text or pack.pattern("scope_mark").search(text):
            continue
        if not pack.pattern("universal_claim").search(text):
            continue
        terms = [
            term for term in pack.pattern("opaque_term").findall(text)
            if term.upper() not in generic
        ]
        if terms or (project_pattern and project_pattern.search(text)):
            claims.append(text[:120])
    return claims


def _max_para(pack: LanguagePack, prose: str) -> int:
    longest = 0
    current = 0
    for line in prose.splitlines():
        s = line.strip()
        if not s or s.startswith(("#", "|", ">", "- ", "* ", "[")):
            longest = max(longest, current)
            current = 0
            continue
        current += _han(pack, s)
    return max(longest, current)


def _section_lengths(pack: LanguagePack, text: str) -> list[int]:
    parts = re.split(r"^##\s+", text, flags=re.M)[1:]
    return [_han(pack, _strip_code(p)) for p in parts]


def _comment_stats(code_blocks: list[str]) -> list[dict]:
    stats = []
    for block in code_blocks:
        lines = [
            line for line in block.splitlines()
            if line.strip() and not line.strip().startswith("```")
        ]
        comments = [
            line for line in lines
            if line.strip().startswith(("#", "//"))
            and not line.strip().startswith("#!")
        ]
        stats.append({"lines": len(lines), "comments": len(comments)})
    return stats


def _depth_metrics(text: str, code_text: str, code_blocks: list[str]) -> dict:
    file_refs = set(re.findall(
        r"(?:[\w.-]+/)*[\w.-]+\.(?:py|js|ts|tsx|json|yaml|yml|md|mdx|go|rs|java|kt|swift|sh|conf|ini|service|sql|toml|lock|log|db|sqlite|sqlite3)(?::\d+)?(?![A-Za-z0-9_])",
        text,
    ))
    commands = re.findall(
        r"(?m)^\s*(?:\$|(?:npm|npx|pnpm|yarn|git|curl|docker|kubectl|python3?|sqlite3|node|go|swift|vim|cat|grep|lsof|ss|netstat|top|ps|kill)\b)[^\n]*",
        code_text,
    )
    stack = re.findall(
        r"Traceback \(most recent call last\)|File \"[^\"]+\", line \d+|^\s+at .+\(.*:\d+:\d+\)",
        text, re.M,
    )
    max_block = max((len(b.splitlines()) for b in code_blocks), default=0)
    qualified = set(re.findall(
        r"\b[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+\b", code_text
    ))
    versions = set(re.findall(r"\b\d+\.(?:\d+|x)(?:\.(?:\d+|x))?\b", text, re.I))
    error_codes = set(re.findall(
        r"\b(?:E[A-Z]{3,}|[A-Z][A-Za-z]+Error|[A-Z][A-Za-z]+Exception|"
        r"[A-Z][A-Z0-9_]*_ERROR|SIG[A-Z]+|SQLSTATE\s+[0-9A-Z]{5}|"
        r"HTTP\s?\d{3}|\d{3}\s+[A-Z][a-z]+|"
        r"[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\b|fatal:",
        text,
    ))
    quotes = len(re.findall(r"^>\s+\S", text, re.M))
    spec_refs = len(re.findall(r"RFC\s?\d+(?:\s?§\s?[\d.]+)?", text))
    signals = {
        "file_or_line": len(file_refs) >= 1,
        "command": len(commands) >= 1,
        "stack": len(stack) >= 1,
        "source_snippet": max_block >= 25,
        "qualified_symbol": len(qualified) >= 5,
        "version": len(versions) >= 2,
        "error_code": len(error_codes) >= 2,
        "spec_reference": quotes >= 1 or spec_refs >= 2,
    }
    return {
        "depth_signals": signals,
        "depth_count": sum(signals.values()),
        "depth_score": round(sum(signals.values()) / len(signals) * 100),
        "depth_missing": [k for k, v in signals.items() if not v],
        "max_code_block_lines": max_block,
    }


def lint_text(text: str, max_inline_code: int = 2, source_profile: bool = False,
              strict_hardcore: bool = False, third_party: bool = False,
              project_tokens: tuple[str, ...] | list[str] = ()) -> dict:
    pack = runtime.pack()
    prose = _strip_code(text)
    paras = _paragraphs(pack, prose)
    section_lengths = _section_lengths(pack, text)
    mean = statistics.mean(section_lengths) if section_lengths else 0
    cv = statistics.pstdev(section_lengths) / mean if mean else 0.0
    uniform = (
        len(section_lengths) >= 4
        and cv < pack.threshold("uniform_cv")
    )

    inline = INLINE_CODE.findall(prose)
    call_like = [
        s for s in inline
        if not re.fullmatch(r"[A-Za-z_][\w.-]*=[\w./:-]+", s.strip())
        and re.search(r"[()=]|\[|\]", s)
    ]
    punct = pack.pattern("half_punct").findall(prose)
    paren = pack.pattern("paren_gloss").findall(prose)
    hard_ai = _hits(pack.pattern_map("hard"), prose)
    soft_ai = _hits(pack.pattern_map("soft"), prose)

    opening = " ".join(paras[:2])
    first_sentence = re.split(pack.opening_sentence_end, paras[0])[0] if paras else ""
    definition_opening = (
        bool(pack.pattern("def_opening").search(first_sentence))
        and not pack.pattern("definition_guard").search(first_sentence)
    )
    scope_opening = bool(pack.pattern("scope_opening").search(opening))
    causal_opening = bool(pack.pattern("causal_opening").search(opening))
    concrete_opening = bool(pack.pattern("concrete_opening").search(opening))
    problem_hits = _literal_count(opening, pack.words("problem"))
    has_context = _literal_count(opening, pack.words("context")) > 0
    lab_opening = bool(
        pack.pattern("lab_opening").search(opening) or problem_hits >= 3
    )
    opening_background = _has_background(pack, opening, project_tokens)
    internal_ids = _internal_ids(pack, text)
    placeholders = pack.pattern("placeholder").findall(prose)
    example_gaps = _example_gaps(pack, text)
    project_pattern = _project_pattern(pack, project_tokens)
    universal_claims = _universal_claims(pack, prose, project_pattern)

    code_blocks = CODE_BLOCK.findall(text)
    code_text = "\n".join(code_blocks)
    title = next((line[2:].strip() for line in text.splitlines() if line.startswith("# ")), "")
    formal_title = bool(pack.pattern("title_formal").search(title))
    colloquial_title = bool(
        pack.pattern("title_colloquial").search(title)
        or _pattern_count(title, pack.words("colloquial"))
    )
    question_title = title.rstrip().endswith(tuple(pack.raw["question_marks"]))
    title_ok = not question_title and formal_title and not colloquial_title
    colloquial_headings = [
        h for h in re.findall(r"^##\s+(.+)$", text, re.M)
        if pack.pattern("colloquial_heading").search(h)
    ]
    comment_stats = _comment_stats(code_blocks)
    max_comments = max((s["comments"] for s in comment_stats), default=0)
    identifiers = set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\s*\(", code_text))
    numbers = [
        n for n in re.findall(r"\d+\.\d+|\d{3,}", prose)
        if not re.fullmatch(r"(19|20)\d{2}", n)
    ]
    error_outputs = sum(
        1 for b in code_blocks
        if re.search(r"\b(Error|Exception|Traceback|False|True|timeout|exit|failed)\b", b)
    )
    pronoun_re = re.compile("|".join(re.escape(w) for w in pack.words("pronouns")))
    first_person = len(pronoun_re.findall(prose))
    dead = sum(1 for w in pack.words("dead") if w in prose)
    trade = sum(1 for w in pack.words("tradeoff") if w in prose)
    narrative_verbs = _literal_count(prose, pack.words("narrative"))

    han = _han(pack, prose)
    colloquial = _pattern_count(prose, pack.words("colloquial"))
    technical = _literal_count(prose, pack.words("tech"))
    colloquial_per_1k = round(colloquial / han * 1000, 1) if han else 0.0
    technical_per_1k = round(technical / han * 1000, 1) if han else 0.0
    inline_per_1k = round(len(inline) / han * 1000, 1) if han else 0.0
    project_hits = project_pattern.findall(text) if project_pattern else []
    project_title = bool(project_pattern and project_pattern.search(title))
    project_first = (
        _first_project_unexplained(pack, paras[0], project_pattern) if paras else False
    )
    project_per_1k = round(len(project_hits) / han * 1000, 1) if han else 0.0
    transferable = bool(pack.pattern("transferable").search(text))
    generality_score = 1.0
    if project_title:
        generality_score -= 0.35
    if project_first:
        generality_score -= 0.35
    generality_score -= min(0.3, project_per_1k * 0.04)
    generality_score -= min(0.2, len(universal_claims) * 0.1)
    if not transferable:
        generality_score -= 0.2
    generality_score = round(max(0.0, min(1.0, generality_score)), 3)
    register = max(0, min(100, 100 - max(0, colloquial_per_1k - 2) * 15
                          + min(20, technical_per_1k * 0.5)))

    density = min(100, len(code_blocks) * 8 + len(identifiers) * 2 + len(numbers) * 3
                  + dead * 6 + trade * 6 + error_outputs * 8)
    depth = _depth_metrics(text, code_text, code_blocks)
    hardcore = round(density * 0.35 + depth["depth_score"] * 0.45 + register * 0.20)
    narrative = min(100, first_person * 5 + dead * 8 + (20 if has_context else 0)
                    + min(20, narrative_verbs * 2))
    anti_ai = max(0, 100 - len(hard_ai) * 25 - len(soft_ai) * 8
                  - (30 if lab_opening else 0) - (10 if uniform else 0))
    format_score = max(0, 100 - len(punct) * 10 - len(paren) * 10
                       - (20 if _max_para(pack, prose) > pack.threshold("max_para") else 0)
                       - (10 if len(inline) > max_inline_code else 0))
    overall = round(hardcore * 0.35 + narrative * 0.25 + anti_ai * 0.25 + format_score * 0.15)

    hard_issues = []
    if len(punct) > 5:
        hard_issues.append(issue("half_width_punct", count=len(punct),
                                 sample=punct[:3]))
    if hard_ai:
        hard_issues.append(issue("strong_ai_template",
                                 hits="/".join(hard_ai)))
    if len(soft_ai) >= 3:
        hard_issues.append(issue("soft_ai_template", count=len(soft_ai),
                                 hits="/".join(soft_ai)))
    if lab_opening:
        hard_issues.append(issue("lab_opening"))
    if strict_hardcore and colloquial_per_1k > pack.threshold("colloquial_limit"):
        hard_issues.append(issue("colloquial_density",
                                 density=colloquial_per_1k))
    call_limit = pack.threshold(
        "strict_call_limit" if strict_hardcore else "base_call_limit"
    )
    inline_limit = pack.threshold(
        "strict_inline_per_1k" if strict_hardcore else "base_inline_per_1k"
    )
    if not source_profile and len(call_like) > call_limit:
        hard_issues.append(issue("inline_calls", count=len(call_like),
                                 limit=call_limit, sample=call_like[:3]))
    if not source_profile and len(inline) >= 10 and inline_per_1k > inline_limit:
        hard_issues.append(issue("inline_density", density=inline_per_1k,
                                 limit=inline_limit, sample=inline[:3]))
    if third_party and project_title:
        hard_issues.append(issue("title_project_name"))
    if third_party and project_first:
        hard_issues.append(issue("first_paragraph_project_name"))
    if third_party and not opening_background:
        hard_issues.append(issue("opening_context"))
    if internal_ids:
        hard_issues.append(issue("internal_identifiers",
                                 count=len(internal_ids),
                                 sample=internal_ids[:3]))

    warnings = []
    if definition_opening:
        warnings.append(issue("opening_abstract"))
    elif scope_opening:
        warnings.append(issue("opening_scope"))
    if not opening_background:
        warnings.append(issue("opening_context"))
    if example_gaps:
        warnings.append(issue("example_promise", sample=example_gaps[:3]))
    if placeholders:
        warnings.append(issue("placeholders", sample=placeholders[:3]))
    if universal_claims:
        warnings.append(issue("universal_claim", sample=universal_claims[:2]))
    if not causal_opening:
        warnings.append(issue("no_causal_links"))
    if not transferable:
        warnings.append(issue("no_transferable"))
    if project_hits and not project_first and not project_title:
        warnings.append(issue("project_name_repeated", count=len(project_hits)))
    if pack.threshold("colloquial_warn") < colloquial_per_1k <= pack.threshold("colloquial_limit"):
        warnings.append(issue("colloquial_density_warn",
                              density=colloquial_per_1k))
    if 0 < len(call_like) <= call_limit:
        warnings.append(issue("inline_calls_warn", count=len(call_like)))
    if (len(inline) >= 10
            and pack.threshold("inline_warn_per_1k") < inline_per_1k <= inline_limit):
        warnings.append(issue("inline_density_warn", density=inline_per_1k))
    base_low = hardcore < pack.threshold("base_hardcore_floor")
    strict_low = (
        hardcore < pack.threshold("strict_hardcore_floor")
        or depth["depth_count"] < pack.threshold("strict_depth_floor")
    )
    hardcore_issue = issue("hardcore_density", score=hardcore,
                           depth=depth["depth_count"],
                           missing="/".join(depth["depth_missing"]))
    if base_low or (strict_hardcore and strict_low):
        hard_issues.append(hardcore_issue)
    elif strict_low:
        warnings.append(hardcore_issue)
    if 0 < len(punct) <= 5:
        warnings.append(issue("half_width_punct", count=len(punct),
                              sample=punct[:3]))
    if question_title:
        warnings.append(issue("question_title"))
    elif not title_ok:
        warnings.append(issue("informal_title"))
    if colloquial_headings:
        warnings.append(issue("colloquial_heading",
                              sample="/".join(colloquial_headings)))
    if max_comments > pack.threshold("max_comments"):
        warnings.append(issue("comment_block", count=max_comments))
    if any(s["lines"] >= 8 and s["comments"] / s["lines"] > 0.5 for s in comment_stats):
        warnings.append(issue("comment_ratio"))
    if uniform:
        warnings.append(issue("uniform_sections", sections=section_lengths,
                              cv=f"{cv:.2f}"))
    max_para = _max_para(pack, prose)
    if max_para > pack.threshold("max_para"):
        warnings.append(issue("long_paragraph", chars=max_para))
    if han < pack.threshold("min_han"):
        warnings.append(issue("short_body", count=han))
    if not code_blocks:
        warnings.append(issue("no_code"))
    tail = prose[int(len(prose) * 0.8):]
    if not pack.pattern("unresolved").search(tail):
        warnings.append(issue("no_unresolved"))

    return {
        "han": han,
        "colloquial_markers": colloquial,
        "technical_markers": technical,
        "colloquial_per_1k": colloquial_per_1k,
        "technical_per_1k": technical_per_1k,
        "register_score": register,
        "title": title,
        "title_style_ok": title_ok,
        "colloquial_headings": colloquial_headings,
        "code_comment_lines": sum(s["comments"] for s in comment_stats),
        "max_comments_per_block": max_comments,
        "sections": section_lengths,
        "section_cv": round(cv, 2),
        "uniform_sections": uniform,
        "max_para": max_para,
        "inline_code_prose": len(inline),
        "inline_code_samples": inline[:5],
        "inline_call_like": call_like,
        "code_blocks": len(code_blocks),
        "identifiers": len(identifiers),
        "specific_numbers": len(numbers),
        "error_output_blocks": error_outputs,
        "first_person": first_person,
        "dead_ends": dead,
        "tradeoffs": trade,
        "hard_ai_hits": hard_ai,
        "soft_ai_hits": soft_ai,
        "lab_opening": lab_opening,
        "opening_definition": definition_opening,
        "opening_scope": scope_opening,
        "opening_causal": causal_opening,
        "opening_concrete": concrete_opening,
        "opening_background": opening_background,
        "internal_ids": internal_ids,
        "placeholders": placeholders,
        "universal_claims": universal_claims,
        "example_gaps": example_gaps,
        "project_title": project_title,
        "project_first": project_first,
        "project_token_count": len(project_hits),
        "project_tokens": project_hits[:8],
        "transferable": transferable,
        "generality_score": generality_score,
        "has_context": has_context,
        "punctuation_issues": len(punct),
        "parenthetical_gloss": len(paren),
        **depth,
        "scores": {
            "density": density,
            "hardcore": hardcore,
            "narrative": narrative,
            "anti_ai": anti_ai,
            "format": format_score,
            "overall": overall,
        },
        "hard_issues": hard_issues,
        "warnings": warnings,
        "result": "PASS" if not hard_issues else "FAIL",
    }


def format_report(path: str, result: dict) -> str:
    scores = result["scores"]
    lines = [
        f"=== {path} ===",
        f"Title: {result['title']} | title style: {'OK' if result['title_style_ok'] else 'needs work'}"
        f" | colloquial headings: {'/'.join(result['colloquial_headings']) or 'none'}",
        f"Chars {result['han']} | sections {len(result['sections'])} | max paragraph {result['max_para']} "
        f"| inline code {result['inline_code_prose']} | code blocks {result['code_blocks']} "
        f"| code comments {result['code_comment_lines']}  lines (max per block {result['max_comments_per_block']})",
        f"Register: colloquial {result['colloquial_per_1k']}/1k | technical {result['technical_per_1k']}/1k "
        f"| score {result['register_score']}",
        f"Hardcore {scores['hardcore']} (density {scores['density']} / depth {result['depth_score']} ) "
        f"| narrative {scores['narrative']} | anti-AI {scores['anti_ai']} "
        f"| format {scores['format']} | overall {scores['overall']}",
        f"Depth signals {result['depth_count']}/8: "
        f"{', '.join(k for k, v in result['depth_signals'].items() if v) or 'none'}",
        f"Strong templates: {'/'.join(result['hard_ai_hits']) or 'none'} | "
        f"Weak templates: {'/'.join(result['soft_ai_hits']) or 'none'}",
        f"Opening context: {'yes' if result['opening_background'] else 'no'} | "
        f"Internal IDs: {'/'.join(result['internal_ids']) or 'none'} | "
        f"Example gaps: {'/'.join(result['example_gaps']) or 'none'}",
        f"Hard issues: {'; '.join(i['message'] for i in result['hard_issues']) or 'none'}",
        f"Warnings: {'; '.join(i['message'] for i in result['warnings']) or 'none'}",
        f"Result: {result['result']}",
    ]
    return "\n".join(lines)
