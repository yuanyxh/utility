#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
基于 SOUL.md 风格规范 + 知识库素材，调用 agent CLI 生成分享文章。
通用版：主题由 --topic 显式指定，素材为唯一事实源。

生成/检测抽离架构（2026-09-01 重构）：
    生成器（本文件）：只负责生成——SOUL 语气 + 内容边界 + 输出纪律。
    检测管道（article_pipeline.py + llm_judge.py）：只负责检测与反馈——
        素材强校验(material_check + judge_material) → 生成循环(每轮 format_check →
        content_check → judge 管道式二次检测 → build_feedback) →
        所有轮次文章写入 --out 位置，检测报告追加到文章内部(不单独建 .report.md)。

用法:
    python3 gen_article_generic.py \
        --soul  <SOUL.md 路径> \
        --src   <知识库素材路径> \
        --topic <目标主题> \
        --out   <输出路径或目录，默认 stdout>

agent CLI 由 --agent 模板完全决定（占位符见 agent_call.call_agent），脚本不做
任何 agent 参数假设。agent CLI 需具备 MCP 工具以深度挖掘记忆库与项目上下文。
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import date

from agent_call import call_agent
from article_pipeline import (
    material_check,
    format_check,
    content_check,
    build_feedback,
    build_round_report,
    build_final_report,
)
from log_utils import setup_logging
from llm_judge import judge_article, judge_material, judge_article_by_sections

logger = setup_logging("gen_article_generic")


def check_correction(previous_feedback: str, current_article: str) -> str:
    """检查上一轮反馈的问题是否被改正"""
    corrections = []

    # 检查硬门槛 issues
    if "首行非标题" in previous_feedback and current_article.strip().startswith("# "):
        corrections.append("首行非标题 ✓")

    if "末行为空" in previous_feedback and not current_article.strip().endswith(""):
        corrections.append("末行为空 ✓")

    # 检查禁用词
    if "禁用词" in previous_feedback:
        # 提取禁用词列表
        import re

        pattern = r"禁用词:「([^」]+)」"
        matches = re.findall(pattern, previous_feedback)
        for word in matches:
            if word not in current_article:
                corrections.append(f"禁用词「{word}」已删除 ✓")

    # 检查素材外词
    if "素材外词" in previous_feedback:
        import re

        pattern = r"素材外词:「([^」]+)」"
        matches = re.findall(pattern, previous_feedback)
        for word in matches:
            if word not in current_article:
                corrections.append(f"素材外词「{word}」已删除 ✓")

    # 检查格式问题
    if "最长段" in previous_feedback:
        corrections.append("最长段问题（需人工检查）")

    if not corrections:
        return "未检测到明确改正"

    return "; ".join(corrections)


def build_prompt(soul_text: str, src_text: str, topic: str) -> tuple[str, str]:
    """构造 system + user prompt。生成侧只保留：语气(SOUL) + 内容边界 + 输出纪律。"""
    system = f"""你是一位技术分享博主。你的写作风格由下面的规范文件严格定义，请逐节通读，记住语气、句式、用词、结构习惯，然后严格按照该风格写作。

====== 写作风格规范(必须遵守)======
{soul_text}
====================================

====== 内容边界(违反即废稿)======
1. **主题锚定**：文章只围绕目标主题展开。素材里其他真实内容只能作为支撑小节，绝不能喧宾夺主变成文章主题。
2. **事实纪律**：只写素材里有依据的真实内容。素材标注「虚构/失真/未并入/未经统一验证/仅供参考/设计稿/泛化方案/历史方案」的内容一律不采用；不确定的事实不编造，宁可如实说「这个没做严格验证」。
3. **第三视角**：读者是第一次听说这个项目/领域。每个内部术语、符号、模块名第一次出现，必须先用日常语言说清「它是干什么的」再给术语名；禁止裸写读者看不懂的项目内部符号与内部编号。
4. **输出纪律**：只输出文章正文本身，从标题开始到「## 结语」小节结束。第一行必须是 Markdown 一级标题(# 开头)；最后一行必须是结语正文最后一句。禁止正文之外的任何内容(已核实汇报/自查清单/对规范的复述/提问/客套)。**禁止写文件、禁止调用 Write 工具、禁止创建临时文件**。
5. **结构自由**：不预设骨架、不规定小节数量。用什么结构、先讲什么后讲什么，由素材内容形态自然决定；禁止模板痕迹与硬塞分类标签。"""
    user = f"""请基于下面的知识库素材，围绕目标主题写一篇技术分享文章。

目标主题：{topic}

====== 素材全文(唯一事实源，正文事实只能来自这里)======
{src_text}
======================"""
    return system, user


def call_agent_cli(
    agent_template: str, system: str, user: str, cwd: str | None = None
) -> str:
    """调用 agent CLI 生成文章（由 agent 模板完全决定，零参数假设）。"""
    return call_agent(agent_template, system, user, cwd=cwd)


def resolve_src(src_arg: str) -> tuple[str, str]:
    """解析 --src：文件直接用；目录则取最新 *.md（排除 *_facts.md），返回 (素材路径, 素材文本)。"""
    if os.path.isdir(src_arg):
        candidates = sorted(
            (
                os.path.join(src_arg, n)
                for n in os.listdir(src_arg)
                if n.endswith(".md") and not n.endswith("_facts.md")
            ),
            key=lambda p: os.path.getmtime(p),
            reverse=True,
        )
        if not candidates:
            raise SystemExit(f"[失败] 素材目录无 .md 文件：{src_arg}")
        src_path = candidates[0]
    else:
        src_path = src_arg
    with open(src_path, encoding="utf-8") as f:
        return src_path, f.read()


MAX_TITLE_LEN = 60  # 文章标题用于文件名时截断上限(避免超长路径)


def extract_title(article: str) -> str:
    """从文章正文提取 Markdown 一级标题(# ...)，清理为合法文件名片段。"""
    for line in article.splitlines():
        line = line.strip()
        if line.startswith("# "):
            title = line[2:].strip()
            if not title:
                return ""
            title = re.sub(r'[\\/:*?"<>|]', "_", title)
            title = re.sub(r"\s+", "", title).strip()
            return title[:MAX_TITLE_LEN]
    return ""


def resolve_out(out_arg: str, src_path: str, article: str = "") -> str:
    """解析 --out：以 .md 结尾视为文件路径直接用；否则视为目录，按年/季度划分。

    目录模式：<outDir>/<年>/<季度>/<标题>_<YYYYMMDD>.md
    """
    if out_arg.endswith(".md"):
        return out_arg

    today = date.today()
    season = ["一季度", "二季度", "三季度", "四季度"][(today.month - 1) // 3]
    base = extract_title(article)
    if not base:
        base = os.path.splitext(os.path.basename(src_path))[0]
        if base.endswith("_facts"):
            base = base[: -len("_facts")]
        base = re.sub(r"[^\w一-鿿]", "_", base).strip("_") or "article"
    out_dir = os.path.join(out_arg, str(today.year), season)
    os.makedirs(out_dir, exist_ok=True)
    return os.path.join(out_dir, f"{base}_{today.strftime('%Y%m%d')}.md")


def resolve_version_path(
    out_arg: str, src_path: str, article: str, attempt: int
) -> str:
    """目录模式下每轮版本的正文路径：<最终基名>_v<轮次>.md"""
    final = resolve_out(out_arg, src_path, article)
    return os.path.splitext(final)[0] + f"_v{attempt}.md"


def material_pipeline(
    src_text: str, topic: str, args
) -> tuple[bool, dict, dict | None, str]:
    """素材强校验管道：程序化 material_check 打底 + LLM judge_material 二次判定 + 去噪。

    返回 (是否通过, material_metrics, material_judge, 去噪后的素材)。
    不通过时调用方需输出素材问题报告并跳过生成。
    """
    metrics = material_check(src_text, topic)
    judge = None
    cleaned_src = src_text  # 去噪后的素材
    if args.judge:
        try:
            judge = judge_material(
                src_text,
                topic,
                args.agent,
                cwd=os.path.dirname(os.path.abspath(__file__)),
            )
        except Exception as e:
            logger.warning("素材 LLM 校验失败: %s", e)
            judge = {"pass": None, "issues": [], "summary": "素材 LLM 校验调用失败"}

    # 程序化达标线:允许 2 个维度不达标(topic 提供时 6 维需过 4,否则 5 维需过 3)
    passed = sum(metrics.values())
    threshold = len(metrics) - 2

    # LLM 明确判定不合格 → 强阻塞
    if judge and judge.get("pass") is False:
        return False, metrics, judge, cleaned_src

    # 素材去噪：去除不重要内容
    if args.judge and passed >= threshold:
        try:
            cleaned_src = _clean_material(src_text, topic, args.agent)
        except Exception as e:
            logger.warning("素材去噪失败: %s，使用原始素材", e)

    return passed >= threshold, metrics, judge, cleaned_src


def _clean_material(src_text: str, topic: str, agent_template: str) -> str:
    """素材去噪：去除不重要内容，保留核心事实。"""
    system = """你是一位素材编辑专家。你的任务是去除素材中的不重要内容，保留核心事实。

去除标准：
1. 与主题不直接相关的内容（标注「⚠️与主题不直接相关」）
2. 失真/虚构内容（标注「⚠️失真/虚构」）
3. 过于细节的实现数字（具体阈值、保留天数、清理频率等）
4. 缺少思考过程的内容（只有「做了X」没有「为什么做X」）

保留标准：
1. 有思考过程的内容（排查经历、设计取舍、意外发现）
2. 与主题直接相关的核心事实
3. 读者能理解的表述

输出格式：
只输出去噪后的素材正文（Markdown），保持原有结构。"""

    user = f"""请对以下素材进行去噪处理，去除不重要内容，保留核心事实。

主题：{topic}

====== 原始素材 ======
{src_text}
======================

请输出去噪后的素材正文。"""

    try:
        cleaned = call_agent(agent_template, system, user)
        return cleaned
    except Exception as e:
        logger.warning("素材去噪调用失败: %s", e)
        return src_text


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--soul", required=True, help="SOUL.md 风格规范路径")
    ap.add_argument(
        "--src", required=True, help="知识库素材路径(文件或目录，目录取最新 *.md)"
    )
    ap.add_argument(
        "--topic", default="", help="目标主题(显式指定，素材校验与主题锚定的依据)"
    )
    ap.add_argument("--facts", help="权威事实文件路径(可选，用于素材校验参照)")
    ap.add_argument(
        "--out", help="输出文件路径或目录(目录按年/季度划分，缺省输出到 stdout)"
    )
    ap.add_argument(
        "--retries",
        type=int,
        default=3,
        help="生成后自动验证，不达标自动重跑次数(默认 3，取达标且综合得分最高的一版)",
    )
    ap.add_argument(
        "--judge",
        action="store_true",
        default=True,
        help="启用 LLM-as-Judge 管道式评估(素材校验 + 文章二次检测，默认开启)",
    )
    ap.add_argument(
        "--judge-threshold",
        type=float,
        default=60,
        help="LLM judge 达标分数线(默认 60，满分 100)",
    )
    ap.add_argument(
        "--agent",
        default="claude -p --output-format text --append-system-prompt-file {system_prompt_file}",
        help="agent CLI 命令模板(占位符 {system_prompt_file}/{prompt_file} 由脚本替换)",
    )
    args = ap.parse_args()

    if not os.path.exists(args.soul):
        raise SystemExit(
            f"[失败] SOUL.md 不存在: {args.soul}\n请确认 Gen_Articles/SOUL.md 已就位"
        )
    with open(args.soul, encoding="utf-8") as f:
        soul = f.read()

    src_path, src = resolve_src(args.src)
    facts_text = ""
    if args.facts:
        with open(args.facts, encoding="utf-8") as f:
            facts_text = f.read()
    logger.info("素材: %s", src_path)

    src_all = src + "\n" + facts_text

    # ===== 素材强校验管道 =====
    passed, mat_metrics, mat_judge, cleaned_src = material_pipeline(
        src_all, args.topic, args
    )
    missing = [k for k, v in mat_metrics.items() if not v]
    if not passed:
        reason = []
        if missing:
            reason.append(f"程序化校验缺失: {missing}")
        if mat_judge and mat_judge.get("pass") is False:
            reason.append(f"LLM 校验: {mat_judge.get('summary','')}")
            reason += [f"  - {i}" for i in (mat_judge.get("issues") or [])]
        msg = f"[跳过] 素材不达标: {'; '.join(reason)}"
        print(msg, file=sys.stderr)
        logger.warning("素材不达标跳过生成: %s", msg)
        # 素材检测结果记录(无文章可追加，写独立记录文件，命名避开 report)
        if args.out:
            out_dir = os.path.join(args.out, str(date.today().year))
            os.makedirs(out_dir, exist_ok=True)
            rep = os.path.join(
                out_dir, f"material_check_{date.today().strftime('%Y%m%d')}.md"
            )
            with open(rep, "w", encoding="utf-8") as f:
                f.write(
                    f"# 素材检测记录\n\n- 素材: {src_path}\n- 目标主题: {args.topic}\n"
                    f"- 结论: 不达标，未生成\n- 缺失维度: {missing}\n"
                    f"- LLM 校验: {mat_judge.get('summary','-') if mat_judge else '-'}\n"
                )
                issues = (mat_judge.get("issues") or []) if mat_judge else []
                for i in issues:
                    f.write(f"- {i}\n")
            print(f"素材检测记录: {rep}", file=sys.stderr)
        return 0

    if args.topic.strip():
        print(
            f"[素材] 校验通过 (缺失: {missing or '无'})"
            f"{(' LLM:' + mat_judge['summary']) if mat_judge and mat_judge.get('summary') else ''}",
            file=sys.stderr,
        )

    # ===== 生成 + 检测管道 + 反馈迭代 =====
    system, user = build_prompt(soul, cleaned_src, args.topic)
    # 生成前深挖上下文(理解素材用，agent CLI 具备 MCP 能力)
    user += (
        "\n\n====== 写作前必做：深度挖掘上下文 ======\n"
        "你运行在 Claude Code 环境中，具备 MCP 工具(服务名 mino-brain)。动笔前调用 MCP 工具"
        "(recall/project_notes/project_search/project_exports/project_structure/project_packages)"
        "深挖素材里每个项目内部概念的背景——它是什么/解决什么问题/为什么这么设计——"
        "目的是让你理解素材、并能向第三方读者解释清楚。挖到的信息只用于理解与解释，"
        "不能成为文章的新事实点；文章全部事实只能来自源素材。MCP 不可用时基于素材+常识写作，不中断。"
    )
    # 全局理解约束：不要写流水账，要从"为什么这样做"的角度写
    user += (
        "\n\n====== 写作要求 ======\n"
        "请从全局理解的角度写文章，不要写流水账（8/14 做了什么，8/15 做了什么）。"
        "读者关心的是为什么这样做，不是什么时候做了什么。"
        "每个技术名词第一次出现时，必须先用一句话说清楚它是干什么的，再给出名字。"
        "禁止项目内部文件名/脚本名直接出现（如 gen_article_material.py、notes/Extracts），"
        "要一句话说清楚它是干什么的，比如素材聚合脚本（在主生成前跑一轮，把零散记忆拼成完整素材）。"
    )

    cwd = os.path.dirname(os.path.abspath(__file__))
    feedback = ""
    rounds: list[dict] = []
    candidate = ""  # 上一轮生成的文章内容
    best_score = 0  # 上一轮的分数，用于安全阀判断
    meta = {
        "src_path": src_path,
        "topic": args.topic,
        "soul": args.soul,
        "retries": args.retries,
        "judge_threshold": args.judge_threshold,
    }

    for attempt in range(1, args.retries + 1):
        # 混合方案：第一轮基于素材生成，后续轮次基于上篇内容+反馈渐进修改
        if attempt == 1 or (best_score > 0 and score < best_score - 15):
            # 第一轮或质量下降超过 15 分，基于素材重新生成（不加反馈）
            user_run = user
            logger.info("轮次 %d: 基于素材生成 (attempt=1 或质量下降)", attempt)
            try:
                candidate = call_agent_cli(args.agent, system, user_run, cwd=cwd)
            except SystemExit as e:
                print(f"[尝试 {attempt}] 生成失败,跳过重试：{e}", file=sys.stderr)
                logger.error("生成失败: %s", e)
                continue
        else:
            # 渐进修改：反馈在前（强化理解），上篇内容在后，不需要 SOUL.md 等系统提示
            feedback_system = f"""你是技术文章修改助手。根据反馈修改文章，保留好的部分，修正问题部分。

修改原则：
1. 只修正反馈指出的问题，保留文章整体框架
2. 保持原文风格和语气
3. 只输出修改后的完整文章正文，从 # 一级标题开始，到结语正文最后一句结束
4. 禁止输出任何正文之外的内容：禁止核对/确认说明、禁止改动清单、禁止计划、禁止提问、禁止写文件

素材位置：{src_path}
如需参考素材以确认事实准确性，可调用 MCP 工具获取外部资料。"""
            user_run = f"""{feedback}

====== 当前文章(请基于反馈修改以下内容) ======
{candidate}
======================

请输出修改后的完整文章正文。第一行必须是 Markdown 一级标题(# 开头)，直接输出正文，不要输出任何说明文字。"""
            logger.info("轮次 %d: 基于上篇内容渐进修改", attempt)
            print(
                f"[尝试 {attempt}/{args.retries}] agent CLI system={len(feedback_system)}ch user={len(user_run)}ch",
                file=sys.stderr,
            )
            logger.info(
                "尝试 %d/%d: system=%d字符, user=%d字符",
                attempt,
                args.retries,
                len(feedback_system),
                len(user_run),
            )
            try:
                candidate = call_agent_cli(
                    args.agent, feedback_system, user_run, cwd=cwd
                )
            except SystemExit as e:
                print(f"[尝试 {attempt}] 生成失败,跳过重试：{e}", file=sys.stderr)
                logger.error("生成失败: %s", e)
                continue

        # 检测管道:①格式检测 → ②内容检测 → ③judge 二次检测(接收①②结果)
        hard, score, metrics = format_check(candidate, src_all)
        content_m = content_check(candidate)
        judge_result = None
        section_judge_result = None
        if args.judge:
            try:
                # 全局检测：judge_article
                judge_result = judge_article(
                    candidate,
                    src_all,
                    args.agent,
                    cwd=cwd,
                    format_result=metrics,
                    content_result=content_m,
                )
                # 非全局检测：judge_article_by_sections
                section_judge_result = judge_article_by_sections(
                    candidate,
                    src_all,
                    args.agent,
                    cwd=cwd,
                )
            except Exception as e:
                logger.warning("LLM judge 失败: %s", e)

        # 版本保留:所有轮次文章写到 --out 位置 + 单轮检测报告追加到文章内部
        v_path = None
        if args.out:
            v_path = resolve_version_path(args.out, src_path, candidate, attempt)
            round_rep = build_round_report(
                meta,
                {
                    "attempt": attempt,
                    "hard": hard,
                    "metrics": metrics,
                    "content_metrics": content_m,
                    "judge_result": judge_result,
                    "section_judge_result": section_judge_result,
                },
                feedback=feedback,
            )
            with open(v_path, "w", encoding="utf-8") as f:
                f.write(candidate + "\n\n" + round_rep)
            print(f"[版本] v{attempt} 已写入: {v_path}", file=sys.stderr)

        # 计算综合分数（judge 总分 * 0.7 + 小节检测分数 * 0.3）
        composite_score = score
        if judge_result and section_judge_result:
            composite_score = (
                judge_result["total_score"] * 0.7
                + section_judge_result["total_score"] * 0.3
            )

        tag = "通过" if hard else "未过"
        judge_info = ""
        section_info = ""
        if judge_result:
            judge_info = f" 评审{judge_result['total_score']:.0f}/100"
        if section_judge_result:
            section_info = f" 小节{section_judge_result['total_score']:.0f}/100"
        print(
            f"[检查 {attempt}] 硬门槛{tag} 综合{composite_score:.0f}{judge_info}{section_info} "
            f"段{metrics['max_para']}字 列表{metrics['lst']} 引用{metrics['quote']} "
            f"粗体{metrics['bold']} 半角逗号{metrics['bj']} "
            f"内容分{content_m['content_score']}/4 issues={metrics['issues']}",
            file=sys.stderr,
        )
        logger.info(
            "检查 %d: 硬门槛%s 得分%.0f 内容分%d issues=%s",
            attempt,
            tag,
            score,
            content_m["content_score"],
            metrics["issues"],
        )

        rounds.append(
            {
                "attempt": attempt,
                "hard": hard,
                "metrics": metrics,
                "content_metrics": content_m,
                "judge_result": judge_result,
                "path": v_path,
            }
        )

        # 更新 best_score 用于安全阀判断
        best_score = score

        # 反馈:综合 format/content/judge/section_judge(硬门槛 issues 优先)
        feedback = build_feedback(
            metrics, content_m, judge_result, section_judge_result
        )

        # 调试日志：记录反馈内容和改正情况
        if feedback:
            logger.info("轮次 %d 反馈内容: %s", attempt, feedback[:500])
        if rounds:
            previous_feedback = rounds[-1].get("feedback", "")
            if previous_feedback:
                correction = check_correction(previous_feedback, candidate)
                logger.info("轮次 %d 改正情况: %s", attempt, correction)

    # 每轮次已独立输出，无需最终版本逻辑
    if not rounds:
        raise SystemExit("[失败] 所有尝试均生成失败")

    # 输出最终统计信息
    passed_count = sum(1 for r in rounds if r["hard"])
    print(
        f"[完成] 共 {len(rounds)} 轮，硬门槛通过 {passed_count} 轮",
        file=sys.stderr,
    )
    logger.info("完成: 共 %d 轮，硬门槛通过 %d 轮", len(rounds), passed_count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
