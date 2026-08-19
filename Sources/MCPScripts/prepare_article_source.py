#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
素材自动化脚本：从主题(topic.md)出发，调用 agent CLI 深挖记忆库，组织成五要素素材文件。

用法:
    python3 prepare_article_source.py \
        --topic <topic.md> \
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
1. **主动调用 MCP 工具深挖记忆库与项目上下文**（最高优先级，不要只调一次就写）：
   - recall：检索与该主题相关的历史记忆、架构设计、用户决策、真实踩坑经历——素材里几乎每个概念背后都有对应记忆
   - project_notes：查项目本地记录
   - project_search：查主题涉及的组件、模块、符号、API 的定义与真实上下文
2. 对素材里每一个「项目内部概念」，通过 MCP 查清：它是什么、在什么场景解决什么问题、为什么这么设计。
3. 从「可信来源」核验每一条事实：记忆库记录、CLAUDE.md 架构描述、源码、git 提交历史，四者至少其一可证。

====== 素材组织要求（输出必须符合）======
按**五要素**组织素材（缺的要素省略，不硬凑）：
- **场景**：这个东西是干什么的（背景上下文）
- **目标**：解决什么问题
- **矛盾**：难点 / 坑 / 为什么这么设计
- **决策**：怎么做 / 怎么选的
- **演进**：当前状态 / 后续变化

每条记忆/事实一个小节，标注其要素类型。首次出现的项目内部概念（组件/API/路径/内部缩写）用一句话说清「它是什么、干什么用的」。

文件末尾附「## 避坑边界」段：标注不可写的失真/虚构项（泛化设计、虚构机制、无记忆支撑的验证数字、未落地方案），作为写作时的排除清单。

====== 事实纪律（违反即废稿）======
- 只保留 **可证实** 的事实；多版本堆砌类历史中未落地的声明一律排除
- 记忆库记录里标注「后续优化」「计划中」的内容是未完成状态，不得写成已完成
- 禁止编造记忆库不支持的验证数字、性能指标、时间线；拿不准就不写
- 第一人称只写素材里真实发生的决策/踩坑，禁止编造「我一开始以为…」这类心理活动

====== 输出纪律 ======
只输出素材文件正文（Markdown），第一行是一级标题（主题名）。禁止前置汇报（「已核实/已查证/素材已核对」）与收尾客套。"""
    return system, user


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--topic", required=True, help="主题文件路径(topic.md)")
    ap.add_argument("--out", required=True, help="素材输出路径(topic_facts.md)")
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

    system, user = build_prompt(topic_text)
    logger.info("主题: %s", topic_text[:80].replace("\n", " "))
    print(f"[prepare] 主题: {topic_text.splitlines()[0]}", file=sys.stderr)

    material = call_agent(args.agent, system, user)
    logger.info("素材已生成, %d 字符", len(material))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(material)
    logger.info("已写入 %s", args.out)
    print(f"[prepare] 素材已写入 {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
