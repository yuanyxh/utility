#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
基于 SOUL.md 风格规范 + 知识库素材，调用 agent CLI 生成分享文章。
通用版：主题从素材自拟，不绑定任何特定项目/模块（区别于 gen_article.py）。

用法:
    python3 gen_article_generic.py \
        --soul  <SOUL.md 路径> \
        --src   <知识库素材路径> \
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
from log_utils import setup_logging

logger = setup_logging("gen_article_generic")


QUALITY_PROMPT = """====== 文章质量要求(必须满足)======
以下各项是「文章质量」维度的硬要求，逐条自查仍不合格不算完成:

1. **主题锚定**：文章只能围绕 user 明确指定的主题展开。素材里其他真实内容只能作为支撑小节，绝不能喧宾夺主变成文章主题。
2. **事实纪律**：只写有依据的真实内容。标注「虚构/失真/未并入/未经统一验证/仅供参考」的内容一律不采用；不确定的事实不编造，宁可如实说「这个没做严格验证」。
3. **结构**：开篇自然切入(从具体问题/现象/背景/版本号起手)，结尾「## 结语」收束；正文结构由内容形态决定，小标题按需用、不固定模板。
4. **具体化**：涉及时间、规模、成本、性能给具体数字或区间；没有确切数字就诚实说明，不编造精确值。
5. **信息密度**：每段都有实质信息(做法/原因/坑/效果)，删掉凑数的套话空话。
6. **技术准确**：原理、术语、因果链讲对，不确定的技术细节不硬写。
7. **探索感**：禁止罗列实现细节、不编造心理，以「素材里真实存在的矛盾/疑问」为行文线索展开——完整要求以四条最高优先级硬规则第 3 条为准，此处不重复。
===================================="""


def build_prompt(
    soul_text: str, src_text: str, facts_text: str = ""
) -> tuple[str, str]:
    """构造 system + user prompt。soul=风格规范，facts=权威事实，src=素材。"""
    system = f"""你是一位技术分享博主。你的写作风格由下面的规范文件严格定义，请逐节通读，记住语气、句式、用词、结构习惯，然后严格按照该风格写作。

====== 四条最高优先级硬规则(违反任何一条即废稿，先记住这四条再读后面的规范)======
1. **标点**：正文中句号、逗号、顿号一律用中文全角(，。、)，正文全角标点占比必须 ≥90%，半角逗号/半角句号基本不出现(个别代码片段内嵌除外)。全角标点紧贴汉字，不加空格。正文出现英文标点时前后必须预留空格：冒号「:」后跟一个空格，左引号「"」前跟一个空格、右引号「"」后跟一个空格，半角标点不紧贴汉字。全角正文标点示范(只看标点形态，内容与素材无关、不要模仿其叙事)：「先是把日志打全，再对着每一条看断在哪一步，定位到漏了边界条件才修好，这个过程并不复杂，难的是坚持走完。」
2. **第一人称**：「我」/「我们」是全篇骨架，每个小节至少 1 处「我」的观察或亲历，禁止无人称客观转述；但所有「我」的经历必须来自素材里的真实事实，禁止编造素材里没有的经历。密度贴近 6.6 次/千字基准(1800~3000 字对应全篇约 12~20 处「我」)，每个小节至多 2 处，禁止每段都塞「我」凑密度。**全文人称主语统一「我」，禁止出现第三人称「用户」二字**——素材里标注「用户偏好/用户观察/用户反馈/用户要求」的内容，其叙述主体即作者本人，统一用「我」承接；动作归属仍须准确：作者亲历的动作(排查/取舍/统计)写「我…」，作者未亲历的动作(如「消耗 60 元」)不写成「我做」，用中性表述承接(如「排查时发现一笔查无出处的异常消耗」)。
3. **探索感(禁止罗列实现细节、不编造心理)**：禁止罗列具体类名、符号清单、正则写法、具体参数这些没人看的细节；**讲机制/逻辑时只讲逻辑本身(因果/决策/取舍)，它们只在讲代码/源码流程时以真实代码或伪代码出现**。以「素材里真实存在的矛盾/疑问」为行文线索：先摆问题(这里为什么这么设计/坑在哪/取舍的代价)，再一步步分析素材里实际给出的解答，最后落到结论，让读者跟着思考走。第一人称只写素材里真实发生的事(真实的决策、真实的踩坑、真实的取舍)；禁止编造素材里没有的「我一开始以为…」「试了才发现…」这类心理活动——没有素材依据的内心戏就是 AI 文，素材里有什么就写什么，没有的过程不补全。架构/机制分析保留，但要由素材内容驱动、自然涌现，不是拿通用词硬套。禁止写成「SwiftExtractor 管 class/struct/enum/…」这种清单。
4. **正文严谨硬朗**：正文核心小节一律严谨陈述，像工程师记架构笔记，禁止吊儿郎当、口语吐槽、玩梗。自嘲/口语最多出现在前言和结语各一句；正文里的「我」用克制的观察和推理（「这里我理解成…」「这个权衡当时是这么考虑的」），但**只写素材里有依据的真实经历**，不写「准确率感人」「够喝一壶的」这类。
====================================

====== 写作风格规范(必须遵守)======
{soul_text}
====================================

写作硬性禁令(违反即不合格)：
- 禁止「首先/其次/最后」「总而言之/综上所述」这类排比总结
- 禁止空泛形容词堆砌(高效、强大、优雅、无缝)
- 禁止「在这个快节奏的时代」「值得注意」「不难发现」这类套话
- 禁止开头寒暄式(「在当今…背景下」)，开篇直接进主题、不设模板(禁止「前一段时间我在做…」复述全文式开头)
- 禁止四平八稳、每段对仗工整的完美文章感
- 禁止给知名三方工具/产品加括号补注(如「Claude Code(Anthropic 的命令行工具)」)：专有名词的三方工具/产品首次出现直接用 markdown 链接标注 [Claude Code](官方地址)，不确定官方地址就只写名称、不编造链接；不用括号解释它是什么
- 论述连贯：一个论点展开时支撑理由要连贯排列，禁止中途插入与当前论证无关的背景/术语定义再跳回(如讲「用量是黑洞」时突然插入「token 是最小计量单位」的词典式定义)；术语含义放到真正用到它的语境，或直接省去
- **禁止「A(评)、B(评)、C(评)」括号堆叠式并列**：两个及以上方案/要素及其各自评价(如「对比四条路：查仪表盘(可控性差)、解析转录(不精确)、依赖/cost(无法长期追踪)、自建代理」)，一律拆成列表或表格、方案与评价分行呈现，禁止压进一句+连续括号；整段只表达单个孤立概念时才允许用括号带一句
- 禁止废话铺垫(「这篇文章就来聊聊」「折腾了大半个月」「绕了不少弯路」这类直接删)，前言直接进主题、不复述全文

分层要求(规范第一节 1.0 场景分档，必须执行):
- **不允许整篇一个调**：通篇吊儿郎当(全口语)和通篇教科书(全严谨)都算不合格。但当前最常见的问题是正文过度口语化——默认先写严谨硬朗，需要时才口语，别反过来(默认档位与自嘲边界以四条硬规则第 4 条为准)。
- **严谨档≠无人称**：第一人称「我」的观察、推理、亲历是所有段落的骨架，严谨段也必须保留，但**只写素材里有依据的真实经历**。分层只压口语，不删「我」，也不虚构「我」。

{QUALITY_PROMPT}

{FORMAT_READABILITY}"""

    facts_section = ""
    if facts_text.strip():
        facts_section = f"""====== 项目真实架构(权威事实，与素材冲突时以此为准)======
{facts_text}
====================================

"""

    user = f"""请基于下面的知识库素材，写一篇技术分享文章。

写作要求(标点、第一人称、探索感、论述连贯、括号堆叠、图表规范等写作硬规则一律以 system 为准，不在此重复，均须遵守)：
1. 主题：从素材核心内容自动确定——围绕素材最核心的一件事定主题，标题自拟；素材里标注「虚构/失真」的内容作为避坑边界，不作为主题。
2. 素材中如含真实落地案例/真实实现细节，可作为支撑小节；但整体主题必须聚焦素材核心内容，不写跑题。
3. 素材中标注「虚构/失真/未并入/未经统一验证/仅供参考/设计稿/泛化方案/历史方案」的内容一律不采用，不要用泛化设计冒充真实落地；不确定的事实不编造，宁可如实说「这个没做严格验证」。
4. 篇幅 1800~3000 字(短而精，禁废话)，中文为主，术语保留英文+反引号。

{facts_section}====== 素材全文 ======
{src_text}
======================"""
    return system, user


def call_agent_cli(
    agent_template: str, system: str, user: str, cwd: str | None = None
) -> str:
    """调用 agent CLI 生成文章（由 agent 模板完全决定，零参数假设）。

    相比直连 API,agent CLI 能加载用户级 MCP 工具(如 mino-brain),写作时可
    通过 recall / project_notes 等检索记忆库与项目上下文——弥补「只见素材、
    不见上下文」的盲区，让模型真正理解素材背后的项目背景、历史决策与术语含义。
    """
    return call_agent(agent_template, system, user, cwd=cwd)


# 形式可读性规范(泛化,2026-08-17 用户观察抽象):
# 底层原则——技术文章读者以「扫读」为主(扫标题/列表/表格/代码,跳读正文),
# 信息呈现要为扫读服务:信息粒度小 + 表达原语匹配信息类型。
FORMAT_READABILITY = """

====== 形式可读性：信息粒度与表达原语匹配扫读路径 ======
底层原则:技术文章的读者大多在「扫读」——扫标题、扫列表、扫表格、扫代码,再回头跳读正文,不是逐字读。因此信息呈现要为扫读服务:让每一眼都能抓到「一类信息」,而不是在一大段文字里翻找。

1. **段落即信息单元**：一个段落只承载一个信息点/一个论证步骤。正文段落多数应 ≤ 100 字(约 3 行)；超过 120 字必须拆分，或改用列表/表格/图承载(内容天然连贯拆不动时，优先换承载形式，而不是留长段)。禁止用分号长句罗列多个并列项——那正是该用列表的信号。宁可多分段，不让大段文字堆成视觉上的「墙」。注意这与「长句」不冲突：句子可以长(逗号串联)，但一个段落的信息点必须单一。写完一段自问一句「这段讲了几件事」，超过一件就拆；这里说的「段落」仅指连续正文文字，列表、图、表格、块引用、代码块都不算段落，不受此约束。
2. **表达原语匹配信息类型**(信息是什么形态，就用什么元素承载；下面几项是硬要求，不是可选):
   - 两个及以上**并列**的信息点、顺序步骤、清单 → **必须用列表**(有序/无序)，禁止分号长句罗列；嵌套层级用缩进
   - 对比/映射/字段对应 → markdown 表格
   - 流程/架构/调用链 → mermaid 图
   - 术语/关键概念/结论 → 粗体或行内反引号标出，便于扫读命中
   - 示例/配置/代码 → 代码块，块前后有引导句和解释句
   - **提示/要点/注意事项/教训** → 用块引用(>)单独呈现，不混在正文段里
   - 结构层级 → ## 大节、### 小节,层级分明
3. **视觉节奏**：全文由短段落、标题、列表、表格、图、代码块、块引用交错组成；禁止连续几大段纯文字没有停顿。重要结论和关键术语用粗体，让扫读一眼命中。
4. **缩进规范**：列表嵌套、块引用、代码块的缩进要正确，markdown 渲染后层级不乱。"""


# 方案 generic 结构(泛化,2026-08-18 多 agent 并行验证后用户选定回填):
# 解决同质化:不写死骨架,主线由素材形态决定;禁止模板痕迹与硬塞分类标签。
# 验证结果:Panel/Stage/OCR 三篇结构完全不同(事件机制拆解/共同地基/交互链路时序)。
SCHEME_GENERIC = """

====== 方案要求：结构自由,主线由素材形态决定 ======
本文**不预设骨架**——不规定小节数量，不规定开头结尾的章节格式(只保留两条输出纪律：第一行是标题、结尾以「## 结语」收束)。你只有一个任务：把素材讲成一个真人技术作者会写的样子。用什么结构、几个小节、先讲什么后讲什么，由素材本身的内容形态决定，不是由某个模板决定。

====== 第一步：识别素材形态,选定主线 ======
动笔前先判断素材属于哪种形态，再选匹配的主线组织方式。这是本文结构唯一的合法依据——禁止不判断形态就套用一种结构。

1. **架构 / 机制类**(讲组件怎么协同、分层、解耦、协议)：主线按「机制解决什么问题 → 每个机制内部的矛盾与决策 → 机制之间的配合与边界」推进。
2. **交互 / 系统 API 类**(讲事件、坐标系、线程、回调、系统行为)：主线按「一次完整操作走一遍的时序 → 链路每个环节的坑 → 每个坑的修法与代价」推进，或按「交互链路逐环节展开」。
3. **流程 / 演进类**(讲一个东西怎么从 A 变到 B、多阶段推进)：主线按「阶段演进 → 每阶段的触发因素与取舍 → 演进结果」推进。
4. **问题排查 / 事故类**(讲一个 bug 怎么定位修复)：主线按「现象 → 排查路径 → 根因 → 修法与验证」推进。

素材同时含多种形态时，选「读者理解这件事最需要的那条主线」，其余作为支撑小节插入主线，不喧宾夺主。**判断错了主线没关系，但必须做这个判断**——这是本文区别于模板文章的地方。

====== 第二步：按主线组织,让标题和段落从内容里长出来 ======
- **小节标题承载信息**：禁止「一、二、三」「1. 2. 3.」「第一节/第二部分」这类序号式无信息量标题，也禁止「复盘起点」「核心决策」「总体介绍」这类通用腔标题——标题要让人不看正文就知道这节解决什么。
- **禁止自报门式句子**：全文禁止出现「本文是一篇技术复盘」「这篇文章按…组织」「下面按链路顺序展开」「最后给读者一句可迁移的教训」这类声明/预告结构的话——结构要让读者自己感受到，不是作者说出来。
- **段落与列表**：一段讲一件事；两个及以上并列的信息点用列表，禁止分号长句罗列。
- **每条机制/决策，至少写清「矛盾(为什么这样)→ 决策(怎么选)→ 代价(放弃了什么/代价是什么)」三要素中的两个**：素材里有代价或坑就写，素材里没有的不硬凑、不编造。

====== 第三步：可视化按需，与内容匹配(不凑数，也不限固定数量) ======
判断标准：没有这个图/表/代码块，读者会少理解一层；否则就不放。形式与内容匹配:
- **多步决策/分层探测/处理流程(如「先查缓存→按规则匹配→自动判断→兜底识别→回写缓存」这类带顺序与分支的逻辑)→ 必须用 mermaid 流程图呈现，禁止只用一段纯文字描述流程顺序**——文字只做图的引导和补充说明
- 有「几条路径分流 / 一个决策分支 / 循环」→ mermaid 流程图
- 有「多层组件 / 调用链 / 数据流 / 状态流转」→ mermaid 架构图
- 有「两类以上东西的对比 / 指标 / 清单」→ markdown 表格
- 有「关键代码 / 配置片段,不展示读者就看不懂机制」→ 代码块
整篇至少 1 个可视化(真人技术博客的常态)，至多 3 个——多了就是为形式塞图。每个图/表/代码块前后必须有引导句和解释句，禁止光秃秃扔出来。

====== 写作纪律(违反即废稿)======
- **禁止给素材硬塞分类标签**：素材里没有的归类、总结、结论(例如「主动设计 / 被踩坑逼出来」这类二分，或任何素材未出现的框架词)，文章里一律不出现。素材是什么样，文章就写什么样。
- **禁止模板痕迹**：不套「复盘起点 → 第一层取舍 → 核心决策 → 代价与边界 → 结论」这类固定骨架；不使用「这节回答…」「这就是我后面所有机制的地基」「回头看，哪些决策现在看是对的」这类在多个主题间重复出现的衔接话术。
- **每个结论必须能在素材里找到出处**：素材没写的不写，宁可少写不编造。素材标注「虚构/失真/泛化设计」的内容一律不采用。

====== 术语嵌中文(正文半角逗号的主要来源)======
正文逗号一律中文全角「，」；英文术语、代码标识(如 `changeCount`、`NSPasteboard`、`.drag`)尽量作为独立元素排版，不要硬嵌进中文短语里凑成复合词(英文标点空格细则见四条硬规则第 1 条)。

====== 风格基调 ======
像工程师把亲手做过的系统讲给同行听——克制、具体、有取舍有代价、信息密度高。不追求教科书般的完整，追求读者看完真的懂了这件事为什么这么设计。开头直接进主题(从具体问题/现象/矛盾起手)，禁止「本文介绍…」「本文将分析…」「近年来…」这类前言；结语一句话收束，不排比升华。"""


# ===== 质量验证(2026-08-17 加入):生成后自动量化,不达标自动重跑取最优 =====
# 目的:claude -p 单次生成有随机性,不能依赖一次就跑出达标文章。
# 机制:硬门槛(不满足即废稿,必须重跑)+ 软得分(越高越好,重跑后保留最优)。
MIN_WORDS, MAX_WORDS = 1800, 3000  # 篇幅(汉字),硬门槛
MAX_PARA_WORDS = 120  # 硬门槛:最长正文段落(汉字),超出即废稿重跑
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


def quality_check(article: str, src_text: str = "") -> tuple[bool, float, dict]:
    """量化一篇文章:返回 (硬门槛是否通过, 软得分, 各维度指标)。"""
    import re as _re

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

    # 硬门槛:篇幅/首行末行/禁词/最长段落;半角逗号进软名单
    hard_issues, soft_issues = [], []
    if not (MIN_WORDS <= han <= MAX_WORDS):
        hard_issues.append(f"篇幅{han}")
    if max_para > MAX_PARA_WORDS:
        hard_issues.append(f"最长段{max_para}字")
    if bj_body > MAX_BODY_COMMA:
        soft_issues.append(f"正文半角逗号{bj_body}")
    if not first.startswith("#"):
        hard_issues.append("首行非标题")
    if not last:
        hard_issues.append("末行为空")
    for name, words in HARD_BLOCKERS.items():
        # 「素材外词」以写作依据为准:src/facts 里出现过的词不算素材外词。
        # 静态黑名单面向特定素材,换新素材会误拦素材真词(如 token_proxy 的「费用估算」),
        # 加戏词/杂质词与素材无关,保持静态。
        if name == "素材外词":
            words = [w for w in words if w not in src_text]
        hit = [w for w in words if w in t]
        if hit:
            hard_issues.append(f"{name}:{'/'.join(hit)}")

    hard_pass = not hard_issues
    score = (
        min(lst, 10) * 8  # 列表行:优秀密度 ~10 行,封顶拉高区分高质量与及格
        + min(quote, 5) * 8  # 块引用:优秀 ~5 处
        + min(bold, 14) * 5  # 粗体:优秀密度 ~14 处
        + max(0, MAX_PARA_WORDS - max_para) * 1.0  # 段落越短越好(120 字内连续加分)
        + min(mermaid, 3) * 6  # 图
        + min(code_blocks, 4) * 5  # 代码块
        + min(table_rows // 3, 3) * 5  # 表格(3 行折一张)
        + max(0, 5 - bj_body) * 2
        - max(0, bj_body - 5) * 1.0  # 半角逗号:≤5 奖励,超额每个扣 1 分(全角标点铁律)
    )
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
            "soft_issues": soft_issues,
            "score": round(score, 1),
        },
    )


def _build_feedback(metrics: dict) -> str:
    """依据上一版指标,挑最薄弱的两个形式维度,生成补短板指令。

    claude 单次生成是「多目标权衡」:形式约束互相抢注意力,强化一条常丢别的。
    与其纯随机重试,不如把上一版最短板显式反馈给下一轮,让生成朝缺口收敛。
    反馈目标取「优秀线」而非「及格线」:达标后的轮次仍有提升方向,避免退化纯随机。
    返回空串表示无需反馈(四个维度均已达优秀线)。
    """
    parts = []

    # 硬门槛 issues 优先:被废稿的形式短板,下一轮先解决它,否则再好的形式分也白搭。
    # 命中「素材外词/加戏词/杂质词」时把具体词与达标指令都写进反馈,让模型不再盲改。
    for issue in metrics.get("issues", []):
        if issue.startswith("素材外词"):
            words = issue.split(":", 1)[1]
            parts.append(
                f"素材外词:「{words}」在素材里不存在，严禁编造使用;"
                "如需表达类似含义，改用素材里出现的原词(严格引用素材原文措辞)"
            )
        elif issue.startswith("加戏词") or issue.startswith("杂质词"):
            words = issue.split(":", 1)[1]
            parts.append(
                f"禁用词:「{words}」属 AI 腔/废稿词，全文必须剔除，用事实陈述代替"
            )
        elif issue.startswith("篇幅"):
            n = issue.split("篇幅")[1]
            parts.append(f"篇幅不达标：当前{n}字，必须扩写/压缩到 1800-3000 汉字")
        elif issue == "首行非标题":
            parts.append("首行必须是 Markdown 一级标题(# 开头)，不许空行或正文开头")
        elif issue == "末行为空":
            parts.append("末行必须是结语正文的最后一句，禁止空行/客套收尾")
        elif issue.startswith("最长段"):
            n = issue.replace("最长段", "").replace("字", "")
            parts.append(
                f"最长正文段落 {n} 字，超 120 字必须拆段：一段只承载一个信息点，"
                "并列信息改用列表/表格，拆完后最长段必须在 120 字内"
            )
        else:
            parts.append(f"硬门槛不通过：「{issue}」")

    def _gap(name: str, cur: int, target: int, hint: str) -> tuple[float, str]:
        # max_para / bj 越小越好,其余越大越好;归一化为 [0, 1] 的缺口
        d = (
            max(0.0, (cur - target) / target)
            if name in ("max_para", "bj")
            else max(0.0, (target - cur) / target)
        )
        return d, hint

    # 反馈目标取固定优秀线(与固定得分公式同源):lst 6/bold 10/quote 3。
    # max_para/bj 与内容长短无关,固定。
    dims = [
        _gap(
            "lst",
            metrics["lst"],
            6,
            "两个及以上并列的信息点/清单/步骤，必须用列表呈现；"
            "在语义合理前提下全篇列表密度目标 6 行以上"
            "(不要为凑数硬堆)",
        ),
        _gap(
            "bold",
            metrics["bold"],
            10,
            "关键结论、术语、概念用 **粗体** 标出；"
            "在语义合理前提下全篇粗体密度目标 10 处以上"
            "(不要为凑数硬堆)",
        ),
        _gap(
            "quote",
            metrics["quote"],
            3,
            "每个机制小节里的坑/教训，提炼成一句用块引用(>)单独收尾，" "全文至少 3 处",
        ),
        _gap(
            "max_para",
            metrics["max_para"],
            90,
            "正文段落尽量 90 字内，超过 120 字必须拆段，一段只讲一件事",
        ),
        _gap(
            "bj",
            metrics["bj"],
            3,
            "正文标点一律用全角逗号，禁止半角逗号混入正文(代码块、行内代码内除外)",
        ),
    ]
    dims.sort(key=lambda x: -x[0])
    worst = [h for d, h in dims if d > 0.05][: max(0, 2 - len(parts))]
    if not worst and not parts:
        return ""
    return (
        "\n\n====== 上一版自查反馈(本轮必须修正，最高优先级) ======\n"
        "上一版以下问题不达标，本轮针对性地修正，其余要求不变:\n- "
        + "\n- ".join(parts + worst)
    )


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
    """从文章正文提取 Markdown 一级标题(# ...)，清理为合法文件名片段。

    返回空串表示未找到标题(无一级标题行或标题为空)。仅认一级标题，
    避免误取正文里的 ## 子标题。
    """
    for line in article.splitlines():
        line = line.strip()
        if line.startswith("# "):
            title = line[2:].strip()
            if not title:
                return ""
            # 清理文件名非法字符(/ \ : * ? " < > |)，空格直接去除
            title = re.sub(r'[\\/:*?"<>|]', "_", title)
            title = re.sub(r"\s+", "", title).strip()
            return title[:MAX_TITLE_LEN]
    return ""


def resolve_out(out_arg: str, src_path: str, article: str = "") -> str:
    """解析 --out：以 .md 结尾视为文件路径直接用；否则视为目录，按年/季度划分。

    目录模式：<outDir>/<年>/<季度>/<标题>_<YYYYMMDD>.md
    标题优先取文章正文第一行 Markdown 一级标题(clean 后)，素材文件名去 _facts
    后缀兜底(如 topic_facts.md → topic)。约定：文章输出恒为 .md，
    故以 .md 结尾区分文件/目录两种形态。
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--soul", required=True, help="SOUL.md 风格规范路径")
    ap.add_argument(
        "--src", required=True, help="知识库素材路径(文件或目录，目录取最新 *.md)"
    )
    ap.add_argument("--facts", help="权威事实文件路径(可选，用于锚定主题)")
    ap.add_argument(
        "--out", help="输出文件路径或目录(目录按年/季度划分，缺省输出到 stdout)"
    )
    ap.add_argument(
        "--retries",
        type=int,
        default=3,
        help="生成后自动验证，硬门槛不满足自动重跑次数(默认 3，取硬门槛通过且得分最高的一版)",
    )
    ap.add_argument(
        "--agent",
        default="claude -p --output-format text --append-system-prompt-file {system_prompt_file}",
        help="agent CLI 命令模板(占位符 {system_prompt_file}/{prompt_file} 由脚本替换，最终命令完全由配置决定)",
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

    system, user = build_prompt(soul, src, facts_text)

    # MCP 深度上下文挖掘 + 第三视角(读者可读)指令:
    # 让 claude 动笔前尽量深挖记忆库与项目上下文,并牢牢记住
    # 「文章是写给第三方读者看的」——内部黑话必须翻译,禁止备忘录式写法
    mcp_note = """\n\n====== 写作前必做：深度挖掘上下文(最高优先级，动笔前必须完成) ======
你运行在 Claude Code 环境中，具备 MCP 工具(服务名 mino-brain，提供记忆库与项目检索)。这篇文章是写给不了解这个项目的第三方读者看的——不是你的备忘录，不是内部变更记录。动笔前，你必须调用 MCP 工具深挖记忆与项目上下文，把素材里「只有作者懂、读者会莫名其妙」的内容，全部补成读者能懂的背景。

必须主动、尽量多地调用 MCP 工具(不要只调一次就动笔):
- recall / project_notes：检索与素材主题相关的历史记忆、架构设计、用户决策、真实踩坑经历——素材里几乎每个概念背后都有对应的记忆，挖到才算数
- project_search / project_exports：查素材里提到的组件、模块、符号、API 的定义与真实上下文(它是什么、干什么用、被谁用)
- project_structure / project_packages：查项目结构与依赖，理清素材里概念之间的真实关系

对素材里每一个「项目内部概念」(术语、符号、模块名、字段名、接口、版本号、内部时间线)，都要通过 MCP 查清四件事:
1. 它是什么(一句话，不依赖项目内部定义)
2. 它在什么场景解决什么问题
3. 为什么这么设计(取舍/踩了什么坑)
4. 它属于哪个系统、面向谁

挖到的信息只用于两件事：①帮你理解素材里每个概念到底是什么；②向读者解释清楚。它不能成为文章的新事实点——文章的全部事实只能来自源素材。严禁编造素材与查证之外的事实。MCP 工具不可用时，基于素材 + 常识写作,不要中断。

====== 第三视角铁律：读者永远看不懂你的内部黑话(违反即废稿) ======
牢牢记住这句话：这篇文章是给别人看的。写作时始终站在「第一次接触这个项目、这个概念」的第三方读者视角，逐句审视——这句话读者看得懂吗？这个词读者知道是什么意思吗？读者知道这跟他有什么关系吗？
- 正文里每个出现的内部术语/符号/黑话，必须用读者能懂的话解释清楚(它是什么、为什么出现、意味着什么)，禁止裸写读者无法理解的项目内部符号，宁可多解释一句也不能让读者莫名其妙
- 禁止原样照抄素材里的内部细节(精确到内部字段名、内部日期、内部数字，如「121 条」「7/27」「8/3」)，除非它们对读者有真实意义；读者需要的是「这个坑的教训」，不是「这个坑的内部编号」
- 素材里只有作者自己懂的「备忘录级」内容，要么翻译成读者能理解的说法，要么删掉，禁止原样写进文章
- 你是一个讲亲身经历给「第一次听的人」听的作者，不是内部系统给内部用户看的变更记录

====== 事实边界铁律：文章的事实只能来自源素材(违反即废稿) ======
MCP 挖到的一切记忆/项目信息，都只是「帮你读懂素材」的参考——不是让你往文章里加素材之外的新事实。写作时牢牢守住这条边界:
- 素材之外的查证信息(即便真实存在)只用于解释概念，不作为文章的叙事事实点；拿不准就不写，宁可少写也不能失真
- 禁止从素材「合理推断」出素材没有的细节(如从「日报汇总」脑补出「最烧钱的项目、缓存命中率」)——素材没写的功能、数据维度、场景、结果，一律不写，宁缺毋假
- 「我」的经历、决策、踩坑只能写源素材里明确标注的事实，素材没写的「我」的经历与心理活动一律不编(见四条硬规则第 3 条)；写完后自查：文中每一句事实都必须在源素材里找得到出处，找不到的删掉

====== 禁止加戏，但也不许偷工减料 ======
一方面，这是一篇技术事实的记录，不是抒情散文——删掉作者的自我评价、感悟、升华与铺垫(「这个坑让我明白…」「真正有意思的是…」「我意识到…」「用量终于有了账本」「用了一段时间才发现…」)；第一人称只记录「做了什么」，不抒发「感受到了什么」；结语一句话收束，不排比升华。

另一方面，别把砍废话砍成砍内容——素材里的每一条机制、每个坑、每个决策、每条因果，都必须写进文章，一个都不能省。技术描述要说透：这个机制怎么做的、为什么这么设计、坑在哪、效果如何，读者要能从文章里完整读懂，而不是一笔带过。比如「跨语言集成、健康检查、并发模型」这类素材里的真实内容，必须有对应小节，不能因为嫌啰嗦就删掉。

篇幅目标 1800~3000 字。写完后如果明显低于 1800，说明你砍掉了该有的技术描述，补回来。

====== 输出纪律 ======
只输出文章正文本身，从标题开始，到「## 结语」小节结束。
- 第一行必须是文章标题，标题之前禁止出现任何文字——「已核实/已查证」「素材已核对」「可以动笔」这类前置汇报一律禁止
- 最后一行必须是结语正文的最后一句话，禁止任何收尾客套(「内容有误请指正」「欢迎交流」「需要我调整吗」一律不要)
- 禁止正文之外的任何内容：开头的已核实式汇报、结尾的自查清单、对写作规范的复述、任何提问或客套。正文之外一个字都不要输出。"""
    user += mcp_note

    # 方案结构要求(泛化结构:主线由素材形态决定)
    user += SCHEME_GENERIC

    # 生成 + 带反馈迭代 + 保留全程最优:agent CLI 单次生成有随机性,
    # 且形式约束互相抢注意力(强化一条常丢别的)。因此硬门槛只管内容正确性,
    # 形式指标用软得分驱动;每轮把上一版最短板反馈给下一轮,朝缺口收敛。
    cwd = os.path.dirname(os.path.abspath(__file__))
    best = None  # (hard_pass, score, article, metrics)
    feedback = ""
    for attempt in range(1, args.retries + 1):
        user_run = user + feedback
        print(
            f"[尝试 {attempt}/{args.retries}] agent CLI system={len(system)}ch user={len(user_run)}ch",
            file=sys.stderr,
        )
        logger.info("尝试 %d/%d", attempt, args.retries)
        try:
            candidate = call_agent_cli(args.agent, system, user_run, cwd=cwd)
        except SystemExit as e:
            print(f"[尝试 {attempt}] 生成失败,跳过重试：{e}", file=sys.stderr)
            logger.error("生成失败: %s", e)
            continue
        hard, score, metrics = quality_check(candidate, src + "\n" + facts_text)
        tag = "通过" if hard else "未过"
        print(
            f"[检查 {attempt}] 硬门槛{tag} 得分{score:.0f} "
            f"段{metrics['max_para']}字 列表{metrics['lst']} 引用{metrics['quote']} "
            f"粗体{metrics['bold']} 半角逗号{metrics['bj']} "
            f"issues={metrics['issues']} soft={metrics['soft_issues']}",
            file=sys.stderr,
        )
        logger.info(
            "检查 %d: 硬门槛%s 得分%.0f issues=%s",
            attempt,
            tag,
            score,
            metrics["issues"],
        )
        if (
            best is None
            or (hard and not best[0])
            or (hard == best[0] and score > best[1])
        ):
            best = (hard, score, candidate, metrics)
        feedback = _build_feedback(metrics)

    if best is None:
        raise SystemExit("[失败] 所有尝试均生成失败")

    hard, score, article, metrics = best
    if args.out:
        out_path = resolve_out(args.out, src_path, article)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(article)
        if hard:
            print(
                f"[完成] 硬门槛通过，得分{score:.0f}，已写入 {out_path}",
                file=sys.stderr,
            )
        else:
            print(
                f"[警告] 重试{args.retries}次仍未过硬门槛(issues={metrics['issues']}),"
                f"保留得分最高的一版写入 {out_path}",
                file=sys.stderr,
            )
        logger.info(
            "完成: 硬门槛%s 得分%.0f 输出=%s",
            "通过" if hard else "未过",
            score,
            out_path,
        )
    else:
        print(article)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
