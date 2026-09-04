#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文章生成检测管道：生成只负责生成，检测只负责反馈检测结果。

管道结构（检测侧）：
    Stage 1  format_check   程序化格式检测（硬门槛 + 软得分）——确定性检查用程序化手段
    Stage 2  content_check  程序化内容检测（思考过程/设计取舍/意外/非全结论）
    Stage 3  judge_check    LLM 二次检测（接收 Stage1/2 结果作为上下文，由 llm_judge.judge_article 执行）

素材侧：
    material_check  程序化素材检测（矛盾/过程/决策/事件 + 目标主题一致性 + 篇幅达标）
    judge_material  LLM 素材校验（主题一致性/表述达标，由 llm_judge 执行）

反馈与报告：
    build_feedback  综合 format/content/judge 结果生成注入下一轮 prompt 的反馈
    build_report    生成 .report.md（每轮检测结果，排查修复用，与正文 .md 旁置）

2026-09-01 从 gen_article_generic.py 抽离重组：生成/检测两部分解耦。
"""

from __future__ import annotations

import re as _re

from log_utils import setup_logging

logger = setup_logging("article_pipeline")


# ===== 常量（可配置，拒绝硬编码）=====
MAX_PARA_WORDS = 160  # 硬门槛:最长正文段落(汉字),超出即废稿重跑
MAX_BODY_COMMA = 3  # 软目标:正文半角逗号上限(代码块内不计),超出仅扣分

# 硬门槛关键词(出现即废稿,命中即触发重跑)——只有内容正确性进硬门槛,形式偏好一律软打分
HARD_BLOCKERS = {
    "加戏词": [
        "我明白",
        "有意思",
        "终于",
        "最核心",
        "最有意思",
        "感慨",
        "心得",
        "下马威",
        "这个坑让我明白",
    ],
    "素材外词": [
        "静默失效",
        "实测过",
        "缓存命中率",
        "硬编码签名",
        "isStopping",
        "停止标志",
        "最烧钱",
        "严格验证",
        "费用估算",
    ],
    "杂质词": [
        "已核实",
        "已查证",
        "可以动笔",
        "请指正",
        "请补充",
        "欢迎交流",
        "需要我调整",
        "内容有误",
    ],
}

# 形式软得分目标(优秀线,与反馈 target 同源)
FORM_TARGETS = {
    "lst": 6,  # 列表行数
    "bold": 10,  # 粗体处数
    "quote": 3,  # 块引用处数
    "max_para": 90,  # 最长段落(汉字),越小越好
    "bj": 3,  # 正文半角逗号,越小越好
}


# ===== Stage 1: 程序化格式检测 =====
def format_check(article: str, src_text: str = "") -> tuple[bool, float, dict]:
    """量化一篇文章:返回 (硬门槛是否通过, 软得分, 各维度指标)。

    硬门槛只收「内容正确性」:首行标题/末行非空/最长段≤160/禁词(素材外词动态剔除素材真词)。
    格式评估完全由 judge 的 format 维度负责，此处不计算软得分。
    """
    t = article.strip()
    han = len(_re.findall(r"[一-鿿]", t))

    # 最长正文段落:按行处理,跳过标题/列表/表格/块引用/代码块,只合并连续正文行
    def _skip_line(s: str) -> bool:
        return (
            not s
            or s.startswith("#")
            or s.startswith("|")
            or s.startswith(">")
            or s.startswith("- ")
            or s.startswith("* ")
            or _re.match(r"^\s*\d+\.", s) is not None
        )

    max_para = cur = 0
    in_code = False
    for _l in t.split("\n"):
        _s = _l.strip()
        if _s.startswith("```"):
            in_code = not in_code
            if cur:
                max_para = max(max_para, cur)
                cur = 0
            continue
        if in_code or _skip_line(_s):
            if cur:
                max_para = max(max_para, cur)
                cur = 0
            continue
        cur += len(_re.findall(r"[一-鿿]", _l))
    if cur:
        max_para = max(max_para, cur)

    lst = len(_re.findall(r"^\s*[-*] ", t, _re.M)) + len(
        _re.findall(r"^\s*\d+\. ", t, _re.M)
    )
    quote = len(_re.findall(r"^>", t, _re.M))
    bold = t.count("**") // 2
    mermaid = t.count("```mermaid")
    code_blocks = len(_re.findall(r"```", t)) // 2
    body_no_code = _re.sub(r"```.*?```", "", t, flags=_re.S)
    table_rows = len(_re.findall(r"^\|[^\n]+\|$", body_no_code, _re.M))

    code_chunks = _re.findall(r"```.*?```", t, _re.S)
    bj_body = t.count(",") - sum(c.count(",") for c in code_chunks)

    lines = t.split("\n")
    first, last = lines[0].strip(), lines[-1].strip()

    hard_issues = []
    if max_para > MAX_PARA_WORDS:
        hard_issues.append(f"最长段{max_para}字")
    if not first.startswith("#"):
        hard_issues.append("首行非标题")
    if not last:
        hard_issues.append("末行为空")
    for name, words in HARD_BLOCKERS.items():
        # 「素材外词」以写作依据为准:src 里出现过的词不算素材外词。
        # 静态黑名单面向特定素材,换新素材会误拦素材真词,加戏词/杂质词与素材无关,保持静态。
        if name == "素材外词":
            words = [w for w in words if w not in src_text]
        hit = [w for w in words if w in t]
        if hit:
            hard_issues.append(f"{name}:{'/'.join(hit)}")

    hard_pass = not hard_issues
    # 格式软得分由 judge 的 format 维度负责，此处返回 0
    score = 0.0
    return (
        hard_pass,
        score,
        {
            "han": han,
            "max_para": max_para,
            "lst": lst,
            "quote": quote,
            "bold": bold,
            "mermaid": mermaid,
            "code": code_blocks,
            "tables": table_rows // 3,
            "bj": bj_body,
            "issues": hard_issues,
            "score": 0.0,
        },
    )


# ===== Stage 2: 程序化内容检测 =====
def content_check(article: str) -> dict:
    """检查文章是否有思考过程、设计取舍、排查路径。返回各维度布尔值 + 综合分。"""
    paragraphs = article.split("\n\n")
    total_paras = len(paragraphs)

    has_process = bool(
        _re.search(
            r"(排查|调试|测试|验证|实验|对比|排除|弯路|试了|第一步|决定性|定位)",
            article,
        )
    )
    has_tradeoff = bool(
        _re.search(
            r"(取舍|权衡|代价|vs|对比|之所以选|没选|好处是.*代价|方案[AB]|选了.*放弃)",
            article,
        )
    )
    has_surprise = bool(
        _re.search(
            r"(我当时|当时以为|本来以为|一开始|最初|意外|没想到|第一反应|第一轮|第二轮|原来)",
            article,
        )
    )
    conclusion_words = (
        article.count("教训是")
        + article.count("结论是")
        + article.count("最终，")
        + article.count("最终。")
    )
    not_all_conclusions = conclusion_words < max(total_paras * 0.3, 1)

    content_score = sum([has_process, has_tradeoff, has_surprise, not_all_conclusions])
    return {
        "has_process": has_process,
        "has_tradeoff": has_tradeoff,
        "has_surprise": has_surprise,
        "not_all_conclusions": not_all_conclusions,
        "content_score": content_score,
    }


# ===== 素材侧: 程序化检测 =====
def material_check(src_text: str, topic: str = "") -> dict:
    """素材准入检查:是否有足够的内容支撑一篇文章 + 目标主题一致性 + 篇幅达标。

    返回各维度布尔值。sum(values) < 通过线则素材不达标(不生成)。
    """
    text = src_text.strip()

    def _present(kw: str) -> bool:
        return bool(_re.search(kw, src_text))

    result = {
        "has_tension": _present(
            r"(矛盾|冲突|两难|取舍|错误|失败|坑|没想到|其实|意外|问题|报错|故障|bug|限制)"
        ),
        "has_process": _present(
            r"(排查|调试|测试|验证|实验|对比|排除|修复|解决|迁移|重构)"
        ),
        "has_decision": _present(
            r"(选择|决定|权衡|取舍|替代|方案|设计|架构|演进|优化)"
        ),
        "min_events": len(
            _re.findall(
                r"(事实|事件|事故|\d{4}[-/]\d{1,2}|\d{4}年\d{1,2}月|场景|矛盾|决策)",
                src_text,
            )
        )
        >= 3,
        # 表述达标:篇幅足以支撑一篇文章(汉字 >= 400)
        "has_length": len(_re.findall(r"[一-鿿]", text)) >= 400,
    }
    # 主题一致性:显式目标主题的主题词出现在素材中(取主题的主干词)
    if topic.strip():
        t = topic.strip()
        stem = _re.split(r"[\/\s,，、。:：]+", t)
        stems = [w for w in stem if len(w) >= 2]
        result["has_topic"] = any(w in src_text for w in stems)
    return result


# ===== 反馈: 综合 format/content/judge =====
def build_feedback(
    format_metrics: dict,
    content_metrics: dict | None,
    judge_result: dict | None,
    section_judge_result: dict | None = None,
) -> str:
    """综合各检测结果生成注入下一轮 prompt 的反馈。

    合并策略:硬门槛 issues + judge 反馈 + 小节检测反馈一起传递,压缩相同模式问题。
    返回空串表示无需反馈。
    """
    all_parts: list[str] = []

    # 1. 硬门槛 issues
    hard_parts: list[str] = []
    for issue in format_metrics.get("issues", []):
        if issue.startswith("素材外词"):
            words = issue.split(":", 1)[1]
            hard_parts.append(f"素材外词:「{words}」严禁编造使用")
        elif issue.startswith("加戏词") or issue.startswith("杂质词"):
            words = issue.split(":", 1)[1]
            hard_parts.append(f"禁用词:「{words}」必须剔除")
        elif issue == "首行非标题":
            hard_parts.append("首行必须是 Markdown 一级标题")
        elif issue == "末行为空":
            hard_parts.append("末行必须是结语正文最后一句")
        elif issue.startswith("最长段"):
            n = issue.replace("最长段", "").replace("字", "")
            hard_parts.append(f"最长段 {n} 字,超 160 字必须拆段")
        else:
            hard_parts.append(f"硬门槛:「{issue}」")

    # 2. judge 反馈
    judge_parts: list[str] = []
    if judge_result and not judge_result.get("pass", False):
        judge_parts = _judge_feedback_parts(judge_result)

    # 3. 小节检测反馈(压缩相同模式)
    section_parts: list[str] = []
    if section_judge_result and not section_judge_result.get("pass", True):
        section_parts = _section_feedback_parts_compressed(section_judge_result)

    # 4. 删除反馈
    delete_parts: list[str] = []
    if judge_result:
        relevance_dim = judge_result.get("dimensions", {}).get("relevance", {})
        if relevance_dim.get("score", 5) <= 2:
            delete_parts = _relevance_feedback_parts(judge_result)

    # 5. content 反馈
    content_parts: list[str] = []
    if content_metrics and content_metrics["content_score"] < 2:
        content_parts = _content_feedback_parts(content_metrics)

    # 6. 形式最短板
    form_parts: list[str] = []
    if not hard_parts and not judge_parts and not section_parts:
        form_parts = _form_gap_parts(format_metrics)

    # 合并所有反馈
    all_parts = (
        hard_parts
        + judge_parts
        + section_parts
        + delete_parts
        + content_parts
        + form_parts
    )

    if not all_parts:
        return ""

    # 构建反馈标题
    title_parts = []
    if hard_parts:
        title_parts.append("硬门槛")
    if judge_parts:
        title_parts.append("Judge")
    if section_parts:
        title_parts.append("小节检测")
    if delete_parts:
        title_parts.append("删除")
    if content_parts:
        title_parts.append("内容")
    if form_parts:
        title_parts.append("形式")

    title = "+".join(title_parts) + "(本轮必须修正)"

    return _wrap_feedback(title, all_parts)


def _judge_feedback_parts(judge_result: dict) -> list[str]:
    dim_labels = {
        "hook": "开头吸引力",
        "abstraction": "抽象落地",
        "depth": "思考深度",
        "coherence": "叙事连贯",
        "outsider": "读者可理解",
        "format": "格式运用",
    }
    parts = []
    for dim_name, dim in (judge_result.get("dimensions") or {}).items():
        if isinstance(dim, dict) and dim.get("score", 3) <= 2:
            label = dim_labels.get(dim_name, dim_name)
            parts.append(f"{label}({dim.get('score')}/5):{dim.get('reason','')}")
    for s in (judge_result.get("suggestions") or [])[:3]:
        parts.append(f"改进建议:{s}")
    return parts


def _section_feedback_parts(section_judge_result: dict) -> list[str]:
    """小节检测反馈：提取所有小节的问题，输出结构化修改指令。"""
    parts = []
    issues = section_judge_result.get("all_issues", [])[:10]  # 最多 10 条
    if issues:
        parts.append("以下小节问题必须修正：")
    for issue in issues:
        if isinstance(issue, dict):
            section = issue.get("section", "")
            sentence = issue.get("sentence", "")
            problem = issue.get("problem", "")
            suggestion = issue.get("suggestion", "")
            if suggestion:
                parts.append(f"-「{section}」{sentence} → {suggestion}")
            else:
                parts.append(f"-「{section}」{sentence}（{problem}）")
        else:
            parts.append(f"- {issue}")
    return parts


def _section_feedback_parts_compressed(section_judge_result: dict) -> list[str]:
    """小节检测反馈(压缩模式)：合并相同模式的问题，只传递模式与位置。"""
    issues = section_judge_result.get("all_issues", [])
    if not issues:
        return []

    # 定义模式识别规则
    patterns = {
        "术语未解释": ["未解释", "未定义", "首次出现未", "裸写", "未说明"],
        "括号注释式": ["括号注释", "（", "）"],
        "流水账叙事": ["流水账", "时间线", "后来", "然后"],
        "AI腔调": ["有意思", "酷", "很酷", "听起来"],
        "内部文件名": [".py", ".md", ".json", ".swift"],
        "统计数据缺上下文": ["次", "个", "KB", "MB"],
    }

    # 分类问题
    categorized: dict[str, list[str]] = {k: [] for k in patterns}
    uncategorized: list[str] = []

    for issue in issues:
        if not isinstance(issue, dict):
            uncategorized.append(str(issue))
            continue

        problem = issue.get("problem", "") + issue.get("suggestion", "")
        section = issue.get("section", "")
        matched = False

        for pattern_name, keywords in patterns.items():
            if any(kw in problem for kw in keywords):
                categorized[pattern_name].append(section)
                matched = True
                break

        if not matched:
            uncategorized.append(f"「{section}」{issue.get('problem', '')}")

    # 构建压缩反馈
    parts = []
    for pattern_name, sections in categorized.items():
        if sections:
            # 去重并统计
            unique_sections = list(dict.fromkeys(sections))  # 保持顺序去重
            count = len(sections)
            if count > 2:
                parts.append(
                    f"- {pattern_name}模式(出现{count}次): {unique_sections[0]}等小节"
                )
            else:
                parts.append(f"- {pattern_name}模式: {', '.join(unique_sections)}")

    # 未分类的问题只保留前3条
    for prob in uncategorized[:3]:
        parts.append(f"- {prob}")

    return parts


def _relevance_feedback_parts(judge_result: dict) -> list[str]:
    """删除反馈：提取需要删除的内容。"""
    parts = []
    relevance_dim = judge_result.get("dimensions", {}).get("relevance", {})
    reason = relevance_dim.get("reason", "")
    if reason:
        parts.append(f"需要删除：{reason}")
    # 从 suggestions 中提取删除建议
    for s in (judge_result.get("suggestions") or [])[:3]:
        if "删除" in s or "去掉" in s or "移除" in s:
            parts.append(f"删除建议：{s}")
    return parts


def _content_feedback_parts(content_metrics: dict) -> list[str]:
    issues = []
    if not content_metrics["has_process"]:
        issues.append(
            "文章缺少排查/调试/实验过程——至少一个小节要写「我试了什么→观察到什么→为什么不对→怎么发现正确的」"
        )
    if not content_metrics["has_tradeoff"]:
        issues.append("文章缺少设计取舍——至少一处要写「选了A没选B,因为…代价是…」")
    if not content_metrics["has_surprise"]:
        issues.append(
            "文章缺少意外发现或错误假设——至少一处写「我本来以为是X,结果是Y」(必须基于素材真实事实)"
        )
    if not content_metrics["not_all_conclusions"]:
        issues.append("文章太多结论性小节(教训是/结论是/最终),减少到最多 2 处")
    return issues


def _form_gap_parts(format_metrics: dict) -> list[str]:
    """形式维度优秀线缺口最大的两个维度反馈。"""

    def _gap(name: str, cur: int, target: int) -> float:
        if name in ("max_para", "bj"):
            return max(0.0, (cur - target) / target)
        return max(0.0, (target - cur) / target)

    hints = {
        "lst": "两个及以上并列的信息点/清单/步骤,必须用列表呈现;在语义合理前提下全篇列表密度目标 6 行以上(不要为凑数硬堆)",
        "bold": "关键结论、术语、概念用 **粗体** 标出;在语义合理前提下全篇粗体密度目标 10 处以上(不要为凑数硬堆)",
        "quote": "每个机制小节里的坑/教训,提炼成一句用块引用(>)单独收尾,全文至少 3 处",
        "max_para": "正文段落尽量 90 字内,超过 160 字必须拆段,一段只讲一件事",
        "bj": "正文标点一律用全角逗号,禁止半角逗号混入正文(代码块、行内代码内除外)",
    }
    dims = []
    for name, target in FORM_TARGETS.items():
        cur = format_metrics.get(name, 0)
        dims.append((_gap(name, cur, target), hints[name]))
    dims.sort(key=lambda x: -x[0])
    return [h for d, h in dims if d > 0.05][:2]


def _wrap_feedback(title: str, parts: list[str]) -> str:
    return (
        f"\n\n====== {title} ======\n"
        "上一版以下问题不达标,本轮针对性地修正,其余要求不变:\n- "
        + "\n- ".join(parts)
        + "\n\n**保留指导**:当前文章结构和大部分内容质量良好,请保留文章整体框架和已通过检测的部分,只修正反馈指出的具体问题。"
    )


# ===== 报告: 追加到文章内部,不单独建 .report.md =====
def build_round_report(meta: dict, round_info: dict, feedback: str = "") -> str:
    """单轮检测报告段(追加到本轮文章末尾,供排查修复用,不属于文章正文)。"""
    m = round_info["metrics"]
    lines = [
        "---",
        "",
        "## 质量检测报告",
        "",
        "> 说明:以下为生成/检测管线自动追加的检测结果,供排查修复用,不属于文章正文。",
        "",
        f"- 生成轮次: {round_info['attempt']}/{meta.get('retries', '-')}",
        f"- 目标主题: {meta.get('topic', '-')}",
        f"- 硬门槛: {'通过' if round_info['hard'] else '未过:' + '/'.join(m['issues'])}",
        f"- 软得分: {m['score']}",
        f"- 格式指标: 段{m['max_para']}字 列表{m['lst']} 引用{m['quote']} "
        f"粗体{m['bold']} 图{m['mermaid']} 代码块{m['code']} 表格{m['tables']} "
        f"半角逗号{m['bj']}",
    ]
    c = round_info.get("content_metrics")
    if c:
        lines.append(
            f"- 内容指标: 排查={c['has_process']} 取舍={c['has_tradeoff']} "
            f"意外={c['has_surprise']} 非全结论={c['not_all_conclusions']} "
            f"(score {c['content_score']}/4)"
        )
    j = round_info.get("judge_result")
    if j:
        dims = " ".join(
            f"{k}={v['score']}/5"
            for k, v in (j.get("dimensions") or {}).items()
            if isinstance(v, dict)
        )
        lines.append(
            f"- Judge: 总分 {j.get('total_score', 0):.0f}/100 "
            f"pass={j.get('pass', False)}  {dims}"
        )
    # 小节检测结果
    sj = round_info.get("section_judge_result")
    if sj:
        lines.append(
            f"- 小节检测: 总分 {sj.get('total_score', 0):.0f}/100 "
            f"pass={sj.get('pass', False)}"
        )
        for issue in sj.get("all_issues", []):
            lines.append(f"  - {issue}")
    # 追加具体反馈（问题描述、改进建议）
    if feedback:
        lines.extend(
            [
                "",
                "### 具体反馈",
                "",
                feedback,
            ]
        )
    return "\n".join(lines)


def build_final_report(meta: dict, rounds: list[dict], final_attempt: int) -> str:
    """最终汇总检测报告段(追加到选中文章末尾,含所有轮次检测结果,排查修复用)。"""
    lines = [
        "---",
        "",
        "## 质量检测报告(汇总)",
        "",
        "> 说明:以下为生成/检测管线自动追加的检测结果,供排查修复用,不属于文章正文。",
        "",
        f"- 目标主题: {meta.get('topic', '-')}",
        f"- 素材: {meta.get('src_path', '-')}",
        f"- 采纳轮次: {final_attempt}",
        f"- 重试上限: {meta.get('retries', '-')}",
        "",
        "### 每轮检测",
        "",
    ]
    for r in rounds:
        m = r["metrics"]
        lines.append(f"#### 轮次 {r['attempt']}")
        lines.append("")
        lines.append(
            f"- 硬门槛: {'通过' if r['hard'] else '未过:' + '/'.join(m['issues'])}"
        )
        lines.append(f"- 软得分: {m['score']}")
        lines.append(
            f"- 格式指标: 段{m['max_para']}字 列表{m['lst']} 引用{m['quote']} "
            f"粗体{m['bold']} 图{m['mermaid']} 代码块{m['code']} 表格{m['tables']} "
            f"半角逗号{m['bj']}"
        )
        c = r.get("content_metrics")
        if c:
            lines.append(
                f"- 内容指标: 排查/取舍/意外/非全结论 (score {c['content_score']}/4)"
            )
        j = r.get("judge_result")
        if j:
            dims = " ".join(
                f"{k}={v['score']}/5"
                for k, v in (j.get("dimensions") or {}).items()
                if isinstance(v, dict)
            )
            lines.append(
                f"- Judge: 总分 {j.get('total_score', 0):.0f}/100 "
                f"pass={j.get('pass', False)}  {dims}"
            )
        if r.get("path"):
            lines.append(f"- 版本文件: {r['path']}")
        lines.append("")
    return "\n".join(lines)
