#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
素材自动化脚本：从主题(topic.md)出发，调用 agent CLI 深挖记忆库，组织成五要素素材文件。

支持多素材合并：如果提供 --sources 参数，会将多个素材文件合并为一份。

用法:
    python3 prepare_article_source.py \
        --topic <topic.md> \
        --out <topic_facts.md> \
        --agent <agent CLI 命令模板>

    # 多素材合并模式
    python3 prepare_article_source.py \
        --topic <topic.md> \
        --sources <source1.md> <source2.md> ... \
        --out <topic_facts.md> \
        --agent <agent CLI 命令模板>

agent CLI 必须有 MCP 工具（如 mino-brain）可调用，才能 deep dive 记忆库与项目上下文。
命令模板占位符见 agent_call.call_agent，脚本不做任何 agent 参数假设。
"""

from __future__ import annotations

import argparse
import os
import sys

from agent_call import call_agent
from log_utils import setup_logging

logger = setup_logging("prepare_article_source")


def build_prompt(topic_text: str) -> tuple[str, str]:
    """构造 system + user prompt。主题取自 topic.md 全文。"""
    system = f"""你是一位记忆库分析师。你的职责是：围绕给定主题，从记忆库与项目上下文中提炼**可证实**的权威事实，组织成结构化素材文件，供后续文章生成使用。你运行在 Agent 环境中，具备 MCP 工具（服务名 mino-brain，提供记忆库与项目检索）。"""

    user = f"""请围绕下面的主题，从记忆库深度挖掘事实，组织成一份素材文件。

主题：
{topic_text}

====== 工作流程（动笔前必须完成）======
1. **全量记忆导出**：先用 recall 导出与主题相关的所有记忆，基于主题关键词过滤
2. **多次深挖**：基于第一轮结果，搜索关联内容（排查、取舍、意外、架构、设计、踩坑、优化等）
3. **代码上下文**：搜索项目结构、git log、模块依赖关系
4. **交叉验证**：验证数字与事实的准确性

====== 记忆搜索关键词 ======
- 核心关键词：{topic_text}
- 关联关键词：排查、取舍、意外、没想到、架构、设计、踩坑、优化、修复、重构、迁移、演进
- 用户相关：用户决策、用户偏好、用户反馈
- 项目相关：模块、组件、API、依赖、接口

====== 素材组织要求（输出必须符合）======

**主题相关性过滤**：每条素材必须与主题直接相关——这条素材去掉后，文章是否还能成立？如果答案是「能」，这条素材就不属于本次主题。

**素材排序**：最核心的素材排在最前面，次要的排在后面。

按**六要素**组织素材（缺的要素省略，不硬凑）：
- **场景**：这个东西是干什么的（背景上下文）
- **目标**：解决什么问题
- **矛盾**：难点 / 坑 / 为什么这么设计
- **决策**：怎么做 / 怎么选的
- **思考过程**：当时怎么想的 → 发现了什么 → 怎么转过来的
- **演进**：当前状态 / 后续变化

每条记忆/事实一个小节，标注其要素类型和时间戳。首次出现的项目内部概念用一句话说清「它是什么、干什么用的」。

**时间线标注**：素材末尾附「## 时间线」段，按时间顺序列出所有事件的日期和一句话描述。

**思考过程是素材的核心价值**——没有思考过程的素材只能生成「问题→方案→结论」的清单文章。

**抽象程度**：素材只记录「做了什么、为什么这么做、结果如何」，不记录实现细节（具体阈值、配置项精确值等）。

**读者视角表述**：素材中的技术概念必须用「读者能懂的话」写，不能只写内部术语。

文件末尾附「## 避坑边界」段：标注不可写的失真/虚构项，作为写作时的排除清单。

====== 事实纪律（违反即废稿）======
- 只保留 **可证实** 的事实；多版本堆砌类历史中未落地的声明一律排除
- 记忆库记录里标注「后续优化」「计划中」的内容是未完成状态，不得写成已完成
- 禁止编造记忆库不支持的验证数字、性能指标、时间线；拿不准就不写
- 思考过程只写记忆库里有依据的——「当时排查了两轮」可以写，「第一轮我判断是X因为Y」如果记忆库里没记录就不能编造
- 第一人称只写素材里真实发生的决策/踩坑，禁止编造「我一开始以为…」这类心理活动

====== 输出纪律 ======
只输出素材文件正文（Markdown），第一行是一级标题（主题名）。禁止前置汇报（「已核实/已查证/素材已核对」）与收尾客套。"""
    return system, user


def merge_materials_prompt(topic_text: str, sources_text: str) -> str:
    """构造多素材合并的 user prompt。"""
    return f"""请将下面的多份素材合并为一份，围绕主题组织成结构化素材。

主题：
{topic_text}

====== 素材列表 ======
{sources_text}
======================

====== 合并要求 ======
1. **去重**：相同事实只保留一份，保留信息更完整的版本
2. **去噪**：去除与主题不直接相关的内容（标注「⚠️与主题不直接相关」）
3. **去伪**：去除失真/虚构内容（标注「⚠️失真/虚构」）
4. **保留核心**：保留有思考过程、排查经历、设计取舍的内容
5. **按六要素组织**：场景、目标、矛盾、决策、思考过程、演进
6. **读者视角表述**：技术概念必须用读者能懂的话写，不能只写内部术语

====== 输出要求 ======
只输出合并后的素材文件正文（Markdown），第一行是一级标题（主题名）。
禁止前置汇报与收尾客套。"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--topic", required=True, help="主题文件路径(topic.md)")
    ap.add_argument("--out", required=True, help="素材输出路径(topic_facts.md)")
    ap.add_argument(
        "--sources",
        nargs="*",
        default=[],
        help="多个素材文件路径(可选，用于合并模式)",
    )
    ap.add_argument(
        "--agent",
        default="claude -p --output-format text --append-system-prompt-file {system_prompt_file}",
        help="agent CLI 命令模板(占位符 {system_prompt_file}/{prompt_file} 由脚本替换)",
    )
    args = ap.parse_args()

    if not os.path.exists(args.topic):
        raise SystemExit(
            f"[失败] 主题文件不存在: {args.topic}\n"
            "请先在 Gen_Articles/topic.md 里写入想生成的主题"
        )
    with open(args.topic, encoding="utf-8") as f:
        topic_text = f.read().strip()
    if not topic_text:
        raise SystemExit(f"[失败] 主题文件为空: {args.topic}")

    # 多素材合并模式
    if args.sources:
        sources_text = []
        for src_path in args.sources:
            if not os.path.exists(src_path):
                logger.warning("素材文件不存在，跳过: %s", src_path)
                continue
            with open(src_path, encoding="utf-8") as f:
                sources_text.append(f.read().strip())
        if not sources_text:
            raise SystemExit("[失败] 所有素材文件都不存在")
        user_prompt = merge_materials_prompt(topic_text, "\n\n".join(sources_text))
        system = "你是一位记忆库分析师。你的职责是：围绕给定主题，将多份素材合并为一份结构化的素材文件，去重、去噪、保留核心事实。"
    else:
        system, user_prompt = build_prompt(topic_text)

    logger.info("主题: %s", topic_text[:80].replace("\n", " "))
    print(f"[prepare] 主题: {topic_text.splitlines()[0]}", file=sys.stderr)

    material = call_agent(args.agent, system, user_prompt)
    logger.info("素材已生成, %d 字符", len(material))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(material)
    logger.info("已写入 %s", args.out)
    print(f"[prepare] 素材已写入 {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
