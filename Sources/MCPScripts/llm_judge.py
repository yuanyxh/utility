"""LLM-as-Judge 文章质量评估器。

用独立的 LLM 调用对生成文章进行多维度评分，替代不可靠的正则匹配。
基于 G-Eval 方法论（CoT + Form-Filling），但简化为单轮评估。

用法:
    from llm_judge import judge_article
    result = judge_article(article, src_text, agent_template)

返回:
    {
        "total_score": float,      # 0-100 加权总分
        "pass": bool,              # 是否达标（total_score >= threshold）
        "dimensions": {
            "factual": {"score": 1-5, "reason": "..."},
            "coherence": {"score": 1-5, "reason": "..."},
            "depth": {"score": 1-5, "reason": "..."},
            "abstraction": {"score": 1-5, "reason": "..."},
            "readability": {"score": 1-5, "reason": "..."},
        },
        "suggestions": ["...", "..."],  # 具体改进建议
    }

参考:
    - G-Eval (Microsoft, ACL 2023): CoT + Softmax 概率归一化
    - FActScore (ACL 2023): 原子事实验证
    - DeepEval: 开源 LLM 评估框架（G-Eval/Hallucination/Coherence/Faithfulness）
"""

from __future__ import annotations

import json
import re
from agent_call import call_agent
from log_utils import setup_logging

logger = setup_logging("llm_judge")

# 评估维度定义：名称 → (权重, 检查项列表)
# 每个检查项有明确判定标准，避免主观模糊。
DIMENSIONS = {
    "hook": (
        0.18,
        [
            "开头第一段是否回答了「这是什么、跟我有什么关系」？",
            "是否从具体问题/现象切入，而不是从项目历史/版本号/技术栈切入？",
            "读者看完开头后是否有「哦，原来是解决这个问题的」的感觉？",
        ],
    ),
    "abstraction": (
        0.25,
        [
            "技术概念是否用读者能懂的语言解释了「它解决了什么问题」，而不只是「它是什么」？",
            "是否把「做了什么」翻译成了「为什么这么做」？",
        ],
    ),
    "depth": (
        0.25,
        [
            "是否有至少一个完整的「排查/调试/设计决策」过程（不是一句话带过）？",
            "是否展示了「我以为X→但其实是Y→所以改了Z」的思考链？",
            "设计取舍是否写了「选了A没选B，因为…代价是…」？",
            "还是只罗列了结论没有过程？",
        ],
    ),
    "coherence": (
        0.17,
        [
            "段落之间是否有自然过渡（承接上文的结论/问题/发现）？",
            "是否存在「像独立文档拼在一起」的碎片感？",
            "小节之间是否有因果/递进关系（交换顺序后逻辑是否仍然成立）？",
        ],
    ),
    "outsider": (
        0.10,
        [
            "一个完全不了解这个项目的读者，能否不查资料就理解文章在讲什么？",
            "内部概念（模块名/组件名/API名）是否都用日常语言解释了？",
            "是否有备忘录级别的内容（只有内部人懂的细节）原样搬入？",
        ],
    ),
    "format": (
        0.15,
        [
            "是否有可以用 Markdown 格式（如表格、列表、代码块、引用块）更清晰表达的内容，但用了纯文本？",
            "是否有流程、步骤、比较、分类等内容适合用表格呈现，但用了散文？",
            "是否有架构、流程、状态转换、数据流等内容适合用 Mermaid 图呈现，但用了纯文字描述？",
            "是否滥用列表（把本应是一段话的内容拆成无意义的列表）？",
        ],
    ),
    "relevance": (
        0.10,
        [
            "是否有不合理、不重要、突兀的内容需要删除？",
            "是否有与主题不直接相关的内容？",
            "是否有冗余的解释或重复的内容？",
        ],
    ),
}

SCORE_THRESHOLD = 80  # 总分 >= 80 为达标


def judge_article(
    article: str,
    src_text: str,
    agent_template: str,
    cwd: str | None = None,
    format_result: dict | None = None,
    content_result: dict | None = None,
) -> dict:
    """用 LLM 评估文章质量，返回结构化评分结果。

    Args:
        article: 生成的文章正文
        src_text: 素材原文（用于事实一致性对比）
        agent_template: agent CLI 命令模板
        cwd: agent 工作目录
        format_result: 程序化格式检测结果（管道式二次检测：作为 judge 上下文注入）
        content_result: 程序化内容检测结果（同上）
    """
    # 构造评估 prompt
    system = _build_judge_system()
    user = _build_judge_user(
        article, src_text, format_result=format_result, content_result=content_result
    )

    try:
        raw = call_agent(agent_template, system, user, cwd=cwd)
        result = _parse_judge_response(raw)
    except (SystemExit, Exception) as e:
        logger.warning("LLM judge 调用失败: %s，回退到空评估", e)
        result = _empty_result()

    return result


def _build_judge_system() -> str:
    """构造 judge 的 system prompt。"""
    return """你是一位严格的技术文章评审专家。你的任务是评估一篇技术分享文章的质量。

评估原则：
1. 以「第一次接触这个项目的第三方读者」视角评估——假设读者完全不了解这个项目
2. 严格区分「事实」和「编造」——素材里没写的不能算文章的功劳
3. 关注思考过程而非结论——读者要看的是「怎么想的」，不是「做了什么」
4. 评语要具体，指出具体哪个段落有问题，给出可操作的改进建议

5 个评估维度及检查项（每项独立判断）：

【开头吸引力】检查项：
- 开头第一段是否回答了「这是什么、跟我有什么关系」？
- 是否从具体问题/现象切入，而不是从项目历史/版本号/技术栈切入？
- 读者看完开头后是否有「哦，原来是解决这个问题的」的感觉？

【抽象落地】检查项：
- 技术概念是否用读者能懂的语言解释了「它解决了什么问题」，而不只是「它是什么」？
- 是否把「做了什么」翻译成了「为什么这么做」？

【思考深度】检查项：
- 是否有至少一个完整的「排查/调试/设计决策」过程（不是一句话带过）？
- 是否展示了「我以为X→但其实是Y→所以改了Z」的思考链？
- 设计取舍是否写了「选了A没选B，因为…代价是…」？

【叙事连贯】检查项：
- 段落之间是否有自然过渡（承接上文的结论/问题/发现）？
- 是否存在「像独立文档拼在一起」的碎片感？
- 小节之间是否有因果/递进关系？

【读者可理解】检查项：
- 一个完全不了解这个项目的读者，能否不查资料就理解文章在讲什么？
- 内部概念是否都用日常语言解释了？
- 是否有备忘录级别的内容原样搬入？

【格式运用】检查项：
- 是否有可以用 Markdown 格式（如表格、列表、代码块、引用块）更清晰表达的内容，但用了纯文本？
- 是否有流程、步骤、比较、分类等内容适合用表格呈现，但用了散文？
- 是否有架构、流程、状态转换、数据流等内容适合用 Mermaid 图呈现，但用了纯文字描述？
- 是否滥用列表（把本应是一段话的内容拆成无意义的列表）？

【内容相关性】检查项：
- 是否有不合理、不重要、突兀的内容需要删除？
- 是否有与主题不直接相关的内容？
- 是否有冗余的解释或重复的内容？

输出格式要求（严格遵守）：
请输出一个 JSON 对象，包含以下字段：

{
  "hook": {"score": 1-5, "reason": "具体评语，指出哪个段落有问题"},
  "abstraction": {"score": 1-5, "reason": "具体评语，列出裸写的术语"},
  "depth": {"score": 1-5, "reason": "具体评语，指出哪里缺过程"},
  "coherence": {"score": 1-5, "reason": "具体评语，指出碎片感的位置"},
  "outsider": {"score": 1-5, "reason": "具体评语，指出读者看不懂的地方"},
  "format": {"score": 1-5, "reason": "具体评语，指出哪些内容可以用更好的格式呈现"},
  "relevance": {"score": 1-5, "reason": "具体评语，指出需要删除的内容"},
  "suggestions": ["改进建议1（具体到段落）", "改进建议2"]
}

评分标准（每维度 1-5 分）：
- 5 分：优秀，无可挑剔
- 4 分：良好，有小瑕疵
- 3 分：及格，有明显问题但不影响阅读
- 2 分：不及格，问题严重
- 1 分：很差，基本不可读

只输出 JSON，不要输出其他内容。"""


def _build_judge_user(
    article: str,
    src_text: str,
    format_result: dict | None = None,
    content_result: dict | None = None,
) -> str:
    """构造 judge 的 user prompt。format/content 程序化检测结果注入为二次检测上下文。"""
    ctx = ""
    if format_result:
        issues = format_result.get("issues") or []
        m = format_result
        ctx += (
            f"\n====== 程序化格式检测结果(二次检测输入)======\n"
            f"硬门槛: {'通过' if not issues else '未过:' + '/'.join(issues)}\n"
            f"软得分: {m.get('score', 0)}\n"
            f"格式指标: 最长段{m.get('max_para', 0)}字/列表{m.get('lst', 0)}行/"
            f"引用{m.get('quote', 0)}处/粗体{m.get('bold', 0)}处/"
            f"半角逗号{m.get('bj', 0)}个\n"
            f"=============================\n"
        )
    if content_result:
        c = content_result
        ctx += (
            f"程序化内容检测: 排查={c.get('has_process')} "
            f"取舍={c.get('has_tradeoff')} 意外={c.get('has_surprise')} "
            f"非全结论={c.get('not_all_conclusions')} (score {c.get('content_score')}/4)\n"
        )
    return f"""请评估以下技术文章的质量。

====== 素材原文（用于对比事实一致性）======
{src_text[:5000]}
{"... (素材较长，已截断)" if len(src_text) > 5000 else ""}
=============================
{ctx}
====== 待评估文章 ======
{article}
=============================

请按照 system 中定义的评分标准，对文章的 5 个维度分别打分，并给出具体评语和改进建议。
程序化检测结果仅供你交叉参考——它指出的问题如果属实要纳入评分，程序化误判的部分可以忽略。
只输出 JSON，不要输出其他内容。"""


def _parse_judge_response(raw: str) -> dict:
    """解析 LLM judge 的 JSON 输出。"""
    # 尝试从回复中提取 JSON
    # 先找 ```json ... ``` 块
    json_match = re.search(r"```json\s*(.*?)\s*```", raw, re.S)
    if json_match:
        json_str = json_match.group(1)
    else:
        # 尝试直接解析整段
        json_str = raw.strip()

    try:
        data = json.loads(json_str)
    except json.JSONDecodeError:
        # 尝试修复常见问题：截断的 JSON
        # 找最后一个完整的 } 并截断
        last_brace = json_str.rfind("}")
        if last_brace > 0:
            try:
                data = json.loads(json_str[: last_brace + 1])
            except json.JSONDecodeError:
                # 尝试更激进的修复：添加缺失的闭合括号
                try:
                    # 统计未闭合的括号
                    open_braces = json_str.count("{") - json_str.count("}")
                    open_brackets = json_str.count("[") - json_str.count("]")
                    fixed_json = json_str + "}" * open_braces + "]" * open_brackets
                    data = json.loads(fixed_json)
                except json.JSONDecodeError:
                    logger.warning("无法解析 judge 输出: %s", raw[:200])
                    return _empty_result()
        else:
            # 尝试更激进的修复：添加缺失的闭合括号
            try:
                open_braces = json_str.count("{") - json_str.count("}")
                open_brackets = json_str.count("[") - json_str.count("]")
                fixed_json = json_str + "}" * open_braces + "]" * open_brackets
                data = json.loads(fixed_json)
            except json.JSONDecodeError:
                logger.warning("无法解析 judge 输出: %s", raw[:200])
                return _empty_result()

    # 验证结构
    dimensions = {}
    for dim_name, (weight, _) in DIMENSIONS.items():
        if dim_name in data and isinstance(data[dim_name], dict):
            score = data[dim_name].get("score", 3)
            reason = data[dim_name].get("reason", "")
            # 确保 score 在 1-5 范围
            score = max(1, min(5, int(score)))
            dimensions[dim_name] = {"score": score, "reason": reason}
        else:
            dimensions[dim_name] = {"score": 3, "reason": "未评估"}

    # 计算加权总分（0-100）
    total = 0.0
    for dim_name, (weight, _) in DIMENSIONS.items():
        total += dimensions[dim_name]["score"] * weight * 20  # 5分→100分

    suggestions = data.get("suggestions", [])
    if not isinstance(suggestions, list):
        suggestions = [str(suggestions)] if suggestions else []

    return {
        "total_score": round(total, 1),
        "pass": total >= SCORE_THRESHOLD,
        "dimensions": dimensions,
        "suggestions": suggestions,
    }


def _empty_result() -> dict:
    """judge 失败时的回退结果。"""
    return {
        "total_score": 0,
        "pass": False,
        "dimensions": {
            name: {"score": 3, "reason": "评估失败，默认中性"} for name in DIMENSIONS
        },
        "suggestions": ["LLM judge 调用失败，请人工检查"],
    }


def build_judge_feedback(result: dict, section_result: dict | None = None) -> str:
    """根据 judge 评估结果生成注入下一轮 prompt 的反馈。"""
    parts = []

    # 只反馈评分 <= 2 的维度（不及格）
    dim_labels = {
        "hook": "开头吸引力",
        "abstraction": "抽象落地",
        "depth": "思考深度",
        "coherence": "叙事连贯",
        "outsider": "读者可理解",
        "format": "格式运用",
        "relevance": "内容相关性",
    }
    for dim_name, (weight, _) in DIMENSIONS.items():
        dim = result["dimensions"].get(dim_name, {})
        score = dim.get("score", 3)
        reason = dim.get("reason", "")
        if score <= 2:
            label = dim_labels.get(dim_name, dim_name)
            parts.append(f"{label}({score}/5)：{reason}")

    # 追加 suggestions
    for s in result.get("suggestions", [])[:3]:  # 最多 3 条
        parts.append(f"改进建议：{s}")

    # 追加小节检测结果
    if section_result and not section_result.get("pass", True):
        for issue in section_result.get("all_issues", [])[:5]:  # 最多 5 条
            parts.append(f"小节问题：{issue}")

    if not parts:
        return ""

    return (
        "\n\n====== LLM 评审反馈(本轮必须修正) ======\n"
        "独立评审专家发现以下问题:\n- " + "\n- ".join(parts)
    )


def judge_material(
    src_text: str,
    topic: str,
    agent_template: str,
    cwd: str | None = None,
) -> dict:
    """素材 LLM 校验:主题一致性 + 表述达标 + 可生成性。

    生成前对素材做强校验(管道式:程序化 material_check 打底,LLM 二次判定)。
    返回 {"pass": bool | None, "issues": [...], "summary": str}。
    pass=None 表示 LLM 调用失败未判定(不阻塞,由程序化结果决定)。
    """
    system = (
        "你是一位严格的素材评审专家,任务是在文章生成前评估一份素材是否足够支撑一篇技术分享文章。\n"
        "评估三个维度:\n"
        "1. 主题一致性:素材内容是否围绕目标主题展开、是否聚焦(不散乱、不跑题)\n"
        "2. 表述达标:素材是否有具体的事实/事件/决策过程,而不是空泛描述或残缺碎片\n"
        "3. 可生成性:素材是否足以支撑 1800 字以上的完整文章(有矛盾/取舍/坑/排查过程)\n"
        "输出格式(严格遵守):\n"
        '{"pass": true/false, "issues": ["具体问题1", "..."], "summary": "一句话结论"}\n'
        "只输出 JSON,不要输出其他内容。"
    )
    user = f"""====== 目标主题 ======
{topic}
=============================

====== 素材全文 ======
{src_text[:6000]}
{"... (素材较长，已截断)" if len(src_text) > 6000 else ""}
=============================

请评估这份素材的主题一致性、表述达标、可生成性,输出 JSON。"""
    try:
        raw = call_agent(agent_template, system, user, cwd=cwd)
        return _parse_material_json(raw)
    except Exception as e:
        logger.warning("LLM 素材校验调用失败: %s, 回退程序化结果", e)
        return {"pass": None, "issues": [], "summary": "LLM 素材校验调用失败，未判定"}


def _parse_material_json(raw: str) -> dict:
    """解析素材校验 JSON 输出。容错处理截断/格式问题。"""
    m = re.search(r"```json\s*(.*?)\s*```", raw, re.S)
    json_str = m.group(1) if m else raw.strip()
    try:
        data = json.loads(json_str)
    except json.JSONDecodeError:
        last = json_str.rfind("}")
        if last > 0:
            try:
                data = json.loads(json_str[: last + 1])
            except json.JSONDecodeError:
                return {"issues": ["解析失败"], "score": 3}
        else:
            return {"issues": ["解析失败"], "score": 3}
    return {
        "pass": bool(data.get("pass", False)),
        "issues": (
            data.get("issues", []) if isinstance(data.get("issues"), list) else []
        ),
        "summary": str(data.get("summary", "")),
    }


def judge_article_by_sections(
    article: str,
    src_text: str,
    agent_template: str,
    cwd: str | None = None,
) -> dict:
    """按二级标题拆分文章，对每个小节单独检测，汇总结果。

    返回各小节的检测结果 + 汇总统计。
    """
    # 按二级标题拆分文章
    sections = re.split(r"\n## ", article)
    section_results = []

    for i, section in enumerate(sections):
        if not section.strip():
            continue

        # 构造小节检测 prompt
        system = """你是一位严格的技术文章评审专家。你的任务是评估一个技术文章小节的质量，并输出具体的修改指令。

评估原则：
1. 以「第一次接触这个项目的第三方读者」视角评估
2. 检查是否有函数名、配置值、内部字段名裸写（如 'FSEventStream 实现'、'client_max_size'、'@web.middleware'）
3. 检查是否有内部术语（模块名/组件名/API名）未解释就出现（如 `ProjectScanner`、`tool_resource`、`NSPasteboard`）
4. 检查是否有括号注释式术语解释（如「热层（mem0）」「冷层（summarize.py 聚合版）」）
5. 检查是否有项目内部文件名/脚本名直接出现（如 `gen_article_material.py`、`notes/Extracts`）
6. 检查是否只是流水账标注日期，没有从全局理解的角度写

输出格式（严格遵守，最多输出 2 条问题）：
{"issues": [{"sentence": "需要修改的原句", "problem": "问题描述", "suggestion": "修改建议"}], "score": 1-5}
只输出 JSON，不要输出其他内容。"""

        user = f"""请评估以下技术文章小节的质量，并输出具体的修改指令（最多 3 条）：

{section}

请检查是否有函数名裸写、内部术语未解释、括号注释式术语解释、项目内部文件名直接出现、流水账标注日期等问题，输出 JSON。"""

        try:
            raw = call_agent(agent_template, system, user, cwd=cwd)
            result = _parse_section_json(raw)
            # JSON 解析失败时跳过这个小节，不添加到反馈中
            if result is None:
                logger.warning("小节 %d JSON 解析失败，跳过", i)
                continue
            section_results.append(
                {
                    "section_index": i,
                    "section_title": (
                        section.split("\n")[0].strip()
                        if "\n" in section
                        else f"Section {i}"
                    ),
                    "result": result,
                }
            )
        except Exception as e:
            logger.warning("小节检测失败: %s", e)
            section_results.append(
                {
                    "section_index": i,
                    "section_title": (
                        section.split("\n")[0].strip()
                        if "\n" in section
                        else f"Section {i}"
                    ),
                    "result": {"issues": ["检测失败"], "score": 3},
                }
            )

    # 汇总统计
    total_score = sum(r["result"].get("score", 3) for r in section_results) / max(
        len(section_results), 1
    )
    all_issues = []
    for r in section_results:
        issues = r["result"].get("issues", [])
        if issues:
            for issue in issues:
                if isinstance(issue, dict):
                    all_issues.append(
                        {
                            "section": r["section_title"],
                            "sentence": issue.get("sentence", ""),
                            "problem": issue.get("problem", ""),
                            "suggestion": issue.get("suggestion", ""),
                        }
                    )
                else:
                    all_issues.append(
                        {
                            "section": r["section_title"],
                            "sentence": str(issue),
                            "problem": str(issue),
                            "suggestion": "",
                        }
                    )

    return {
        "total_score": round(total_score * 20, 1),  # 1-5 分转为 0-100 分
        "pass": total_score >= 4.0,
        "section_results": section_results,
        "all_issues": all_issues,
    }


def _parse_section_json(raw: str) -> dict:
    """解析小节检测 JSON 输出。增强容错逻辑。"""
    m = re.search(r"```json\s*(.*?)\s*```", raw, re.S)
    json_str = m.group(1) if m else raw.strip()

    # 尝试直接解析
    try:
        data = json.loads(json_str)
    except json.JSONDecodeError:
        # 策略1：找最后一个完整的 } 并截断
        last = json_str.rfind("}")
        if last > 0:
            try:
                data = json.loads(json_str[: last + 1])
            except json.JSONDecodeError:
                # 策略2：智能修复 - 找到最后一个完整的 key-value 对
                last_comma = json_str.rfind(",")
                if last_comma > 0:
                    truncated = json_str[:last_comma]
                    open_braces = truncated.count("{") - truncated.count("}")
                    open_brackets = truncated.count("[") - truncated.count("]")
                    try:
                        data = json.loads(
                            truncated + "}" * open_braces + "]" * open_brackets
                        )
                    except json.JSONDecodeError:
                        # 策略3：添加缺失的闭合括号
                        open_braces = json_str.count("{") - json_str.count("}")
                        open_brackets = json_str.count("[") - json_str.count("]")
                        if open_braces > 0 or open_brackets > 0:
                            try:
                                data = json.loads(
                                    json_str + "}" * open_braces + "]" * open_brackets
                                )
                            except json.JSONDecodeError:
                                # JSON 解析失败：跳过不写入，记录日志
                                logger.warning(
                                    "judge_article_by_sections JSON 解析失败: %s",
                                    json_str[:200],
                                )
                                return None
                        else:
                            # JSON 解析失败：跳过不写入，记录日志
                            logger.warning(
                                "judge_article_by_sections JSON 解析失败: %s",
                                json_str[:200],
                            )
                            return None
                else:
                    # 策略3：添加缺失的闭合括号
                    open_braces = json_str.count("{") - json_str.count("}")
                    open_brackets = json_str.count("[") - json_str.count("]")
                    if open_braces > 0 or open_brackets > 0:
                        try:
                            data = json.loads(
                                json_str + "}" * open_braces + "]" * open_brackets
                            )
                        except json.JSONDecodeError:
                            # JSON 解析失败：跳过不写入，记录日志
                            logger.warning(
                                "judge_article_by_sections JSON 解析失败: %s",
                                json_str[:200],
                            )
                            return None
                    else:
                        # JSON 解析失败：跳过不写入，记录日志
                        logger.warning(
                            "judge_article_by_sections JSON 解析失败: %s",
                            json_str[:200],
                        )
                        return None
        else:
            # 策略2：智能修复 - 找到最后一个完整的 key-value 对
            last_comma = json_str.rfind(",")
            if last_comma > 0:
                truncated = json_str[:last_comma]
                open_braces = truncated.count("{") - truncated.count("}")
                open_brackets = truncated.count("[") - truncated.count("]")
                try:
                    data = json.loads(
                        truncated + "}" * open_braces + "]" * open_brackets
                    )
                except json.JSONDecodeError:
                    # 策略3：添加缺失的闭合括号
                    open_braces = json_str.count("{") - json_str.count("}")
                    open_brackets = json_str.count("[") - json_str.count("]")
                    if open_braces > 0 or open_brackets > 0:
                        try:
                            data = json.loads(
                                json_str + "}" * open_braces + "]" * open_brackets
                            )
                        except json.JSONDecodeError:
                            # JSON 解析失败：跳过不写入，记录日志
                            logger.warning(
                                "judge_article_by_sections JSON 解析失败: %s",
                                json_str[:200],
                            )
                            return None
                    else:
                        # JSON 解析失败：跳过不写入，记录日志
                        logger.warning(
                            "judge_article_by_sections JSON 解析失败: %s",
                            json_str[:200],
                        )
                        return None
            else:
                # 策略3：添加缺失的闭合括号
                open_braces = json_str.count("{") - json_str.count("}")
                open_brackets = json_str.count("[") - json_str.count("]")
                if open_braces > 0 or open_brackets > 0:
                    try:
                        data = json.loads(
                            json_str + "}" * open_braces + "]" * open_brackets
                        )
                    except json.JSONDecodeError:
                        # JSON 解析失败：跳过不写入，记录日志
                        logger.warning(
                            "judge_article_by_sections JSON 解析失败: %s",
                            json_str[:200],
                        )
                        return None
                else:
                    # JSON 解析失败：跳过不写入，记录日志
                    logger.warning(
                        "judge_article_by_sections JSON 解析失败: %s", json_str[:200]
                    )
                    return None
    # 兼容旧格式（字符串列表）和新格式（对象列表）
    issues = data.get("issues", [])
    if issues and isinstance(issues[0], str):
        # 旧格式：字符串列表转为对象列表
        issues = [
            {"sentence": issue, "problem": issue, "suggestion": ""} for issue in issues
        ]
    return {
        "issues": issues,
        "score": max(1, min(5, int(data.get("score", 3)))),
    }
