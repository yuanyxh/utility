#!/usr/bin/env python3
"""知识面板的补货入口：把卡片补进池子。

由 Swift 的 `KnowledgeService` 按间隔起子进程调用（**不是 TaskScheduler** ——
它的 handleMissed 以「今天第一个 cron 点」为基准，任何 sub-daily 的 cron 都会
静默退化成每天一次）。池子够了就直接退出，所以调用方可以放心按固定节拍唤醒。

退出码恒为 0，结果以 JSON 打印到 stdout；真正的问题写 `~/.cache/utility/knowledge_refill.log`。
不走 TaskScheduler 的通知路径 —— 每 30 分钟弹一条系统通知会疯掉。
"""

import json
import sys

import config
import knowledge_engine as engine
import knowledge_pool as pool
from log_utils import setup_logging

logger = setup_logging("knowledge_refill")


def _refill_fragments(budget: int) -> tuple[int, int, list]:
    """碎片：高频、短。额度与主题各算各的（共用计数会让先跑的碎片把主题饿死）。"""
    results = []
    added = 0
    target = config.knowledge_fragment_target()
    while added < engine.CARDS_PER_KIND_PER_RUN and budget >= 3:
        if pool.pool_count(pool.KIND_FRAGMENT) >= target:
            break
        dom = pool.pick_fragment_domain()
        if dom is None:
            logger.warning("碎片领域池为空,跳过碎片补货")
            break
        done = "\n".join(pool.recent_titles(pool.KIND_FRAGMENT, dom["domain"], 12))
        r = engine.advance(
            dom["domain"], done, pool.KIND_FRAGMENT, topic_kind=dom["kind"]
        )
        budget -= r["calls"]
        if r["code"] == engine.OK:
            pool.commit_card(
                kind=pool.KIND_FRAGMENT,
                theme=dom["domain"],
                title=r["concept"],
                body=r["body"],
                topic_kind=dom["kind"],
                evidence=r["evidence"],
                evidence_urls=r["urls"],
                why_now=r["why_now"],
            )
            pool.bump_fragment_used(dom["id"])
            added += 1
            logger.info("碎片入池: %s / %s", dom["domain"], r["concept"])
        elif r["code"] in (engine.EXPAND_FAIL, engine.CARD_UNAVAILABLE):
            logger.warning(
                "上游不可用,本轮停止碎片补货: %s (%s)", dom["domain"], r["code"]
            )
            break
        else:
            logger.warning("碎片未产出: domain=%s code=%s", dom["domain"], r["code"])
        results.append(
            {
                "kind": "fragment",
                "theme": dom["domain"],
                "code": r["code"],
                "concept": r["concept"],
                "calls": r["calls"],
            }
        )
    return budget, added, results


def _refill_topics(budget: int) -> tuple[int, int, list]:
    """主题化：沿主线按序推进。额度与碎片各算各的。"""
    results = []
    added = 0
    max_streak = config.knowledge_max_fail_streak()
    target = config.knowledge_topic_target()
    while added < engine.CARDS_PER_KIND_PER_RUN and budget >= 3:
        if pool.pool_count(pool.KIND_TOPIC) >= target:
            break
        topic = pool.next_topic()
        if topic is None:
            logger.warning("没有 active 主题,跳过主题化补货")
            break
        done = "\n".join(
            f"{c['seq'] + 1}. {c['name']}" for c in pool.concepts_of(topic["id"])
        )
        r = engine.advance(
            topic["name"], done, pool.KIND_TOPIC, topic_kind=topic["kind"]
        )
        budget -= r["calls"]
        code = r["code"]

        if code == engine.OK:
            pool.commit_card(
                kind=pool.KIND_TOPIC,
                theme=topic["name"],
                title=r["concept"],
                body=r["body"],
                topic_kind=topic["kind"],
                evidence=r["evidence"],
                evidence_urls=r["urls"],
                topic_id=topic["id"],
                why_now=r["why_now"],
            )
            pool.reset_topic_fail(topic["id"])
            added += 1
            logger.info("主题入池: %s / %s", topic["name"], r["concept"])
        elif code == engine.EXHAUSTED:
            pool.mark_topic_done(topic["id"])
            logger.info("主题已讲完,标记 done: %s", topic["name"])
        elif code in (engine.EXPAND_FAIL, engine.CARD_UNAVAILABLE):
            # 这两种都是**上游不可用**(LLM 返回空/断连/超时,llm_client.log 可证),不是内容问题:
            # 既不计入 fail_streak、也不在本轮继续硬撞 —— 否则一次网络抖动就能把主题永久标成
            # done(实测踩到:调用失败直接把两个主题烧成 done)。
            logger.warning("上游不可用,本轮停止主题补货: %s (%s)", topic["name"], code)
            break
        else:
            # 概念已消费(哪怕卡片没生成)也要落一行,否则下一轮会把同一个概念重问一遍,
            # 而 expand 拿到的 {done} 会原地打转。落库的 status 区分失败原因。
            status = engine.CONCEPT_STATUS.get(code)
            if status and r["concept"]:
                pool.insert_concept(
                    topic["id"],
                    r["concept"],
                    r["why_now"],
                    pool.next_concept_seq(topic["id"]),
                    status,
                )
            streak = pool.bump_topic_fail(topic["id"], max_streak)
            logger.warning(
                "主题未产出: %s code=%s fail_streak=%d", topic["name"], code, streak
            )
        results.append(
            {
                "kind": "topic",
                "theme": topic["name"],
                "code": code,
                "concept": r["concept"],
                "calls": r["calls"],
            }
        )
    return budget, added, results


def main() -> int:
    path = pool.init_db()
    added_domains, added_topics = pool.seed_from_config()
    logger.info(
        "补货开始: db=%s 新增种子 domains=%d topics=%d",
        path,
        added_domains,
        added_topics,
    )

    budget = engine.MAX_LLM_CALLS_PER_RUN
    results: list = []
    # 两类各算各的额度:共享计数时先跑的碎片会把主题饿死(碎片池长期不满时)
    budget, frag_made, r1 = _refill_fragments(budget)
    budget, topic_made, r2 = _refill_topics(budget)
    results += r1 + r2
    made = frag_made + topic_made

    summary = {
        "made": made,
        "calls_used": engine.MAX_LLM_CALLS_PER_RUN - budget,
        "pool_topic": pool.pool_count(pool.KIND_TOPIC),
        "pool_fragment": pool.pool_count(pool.KIND_FRAGMENT),
        "results": results,
    }
    logger.info("补货结束: made=%d calls_used=%d", made, summary["calls_used"])
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
