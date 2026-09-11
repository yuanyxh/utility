"""token_proxy 的模型分级路由策略层。

从 token_proxy.py 的 `_route_by_tier` 演化而来（2026-09-11）。核心变化：

1. **判据全部来自协议契约**——工具失败走 `tool_result.is_error`、打转走
   `tool_use.name`+入参、循环位置走消息结构。零内容匹配，可服务任意 agent。
2. **决策粒度从「轮」改为「会话 + 段」**——每次切档都会让上游前缀缓存失效，
   要以整个上下文重付一次 prefill。逐轮切档省下的模型差价抵不过缓存损失。
3. **会话内 tier 单调不降**——降档只有一条通道且只做一次；升档由终止性信号
   触发并锁定到用户下条消息。不可逆的风险（缓存全灭 + 上下文被弱模型污染）
   由单调性消掉，降档的收益不抵这个风险。
4. **一切可配置**——tier 数量/命名/描述、轮数阈值、正则、只读工具名、缓存
   折扣全部来自 config，本模块不含任何字面量判据。

成本模型的推导（勿凭直觉改阈值）：

    设 Ps/Pw 为两档输入未命中价，c 为缓存折扣（命中价/未命中价），C 为上下文。
    双向切档（strong 段中插 weak 段再切回）的回本轮数：
        M* = 2 + [Pw + Ps(1-2c)] / [c(Ps - Pw)]
    单向降档（降下去不再切回）：
        M* ≈ 1 + (1-c)Pw / [c(Ps - Pw)]

    结论：C 被约掉，回本线与上下文规模无关；M* 对价差极不敏感，对缓存折扣
    极敏感（c=0.10 时 M*≈12，c=0.26 时 M*≈4.5）。单向降档仅需 2-3 轮，
    双向需 12-15 轮。这是「单调不降」定式的由来。
"""

from __future__ import annotations

import asyncio
import json
import re
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timezone

import aiohttp

from db import conn as dbconn
from log_utils import setup_logging
from proxy_protocol import _is_classifier_candidate
from proxy_normalize import (
    API_OPENAI,
    DEFAULT_KEY_PARTS,
    KEY_PART_NAMES,
    NormalizedTurn,
    build_fingerprints,
    check_tool_pairing,
    last_tool_call,
    latest_tool_results,
    last_real_user_text,
    normalize_turns,
    tool_call_streak,
    turn_index,
)

logger = setup_logging("token_proxy", json_format=True)

# ---------------------------------------------------------------------------
# 缺字段兜底（**不是默认值**）
#
# 分级路由配置的业务默认值唯一权威在 Swift `ConfigTypes.swift` 与用户可见的
# `default-config.yaml`：`MODEL_PROXY_ROUTER` 只由 Swift `routerJSON()` 生成，
# 本模块这些常量在正常链路上**永远不可达**，只在「手写 env 调试」或「Swift 侧
# 漏了字段」时生效。缺字段一律记 `router_config_missing` 告警，让漂移可观测，
# 而不是静默生效——同一语义有两个权威源且其中一个长期不被执行，漂移就不会被发现。
#
# 取值一律偏保守：宁可少切档，不可乱切档。
# ---------------------------------------------------------------------------

#: 分类 prompt 模板。**本模板的权威副本在这里**（Swift 侧只存用户覆盖值，
#: 留空即用本模板）。{tier_lines} 由 tiers 的 name+description 动态拼装，
#: 加档无需改代码；{last_user_message} 为末条真实用户消息。
DEFAULT_CLASSIFY_PROMPT_TEMPLATE = """根据以下用户消息归类。可选类别：
{tier_lines}

只输出类别名，禁止输出其他任何内容，否则退回重走。

## 用户消息
{last_user_message}
"""

# 键分量的权威定义在归一化层（proxy_normalize），此处只做引用避免两处推导。
# `latest_user` → loop 内稳定、新指令自动分界；`first_user` → 更抗客户端注入的
# 中间用户轮，但同一对话里追加指令不再开新会话（升档锁定会保持到会话结束）。



#: 双向切档回本轮数兜底值。实际应按 provider 缓存折扣反推（见模块 docstring）。
FALLBACK_SWITCH_COST_TURNS = 12

#: 末尾连续同名同参工具调用达到此数即判定打转。
FALLBACK_LOOP_STREAK = 3

#: 连续多少轮工具失败才升档。1 = 单次失败即升档（不推荐：`is_error` 由客户端按
#: 「非零退出」判定，grep 无匹配 / diff 有差异 / test 失败都会被标为 true）。
FALLBACK_ESCALATE_ERROR_STREAK = 2

#: 每 N 轮强制升档一次（is_error 不可用时的主力兜底），0=禁用。
#: 注意：**它必须 ≤ switch_cost_turns 才可能与降档共存**——若检查点比回本线还密，
#: 弱档段永远撑不到回本就被强制升回，降档在任何轮次都必然亏本。故对已降档的会话，
#: 实际间隔取 max(checkpoint_interval, switch_cost_turns)（见 _check_escalation）。
FALLBACK_CHECKPOINT_INTERVAL = 8

#: 分类器**总**时间预算（毫秒）。单次超时 × 重试次数会在转发前的关键链路上叠加，
#: 必须有一个总闸：预算耗尽即放弃分类走兜底档，绝不把 3×timeout 全压在请求上。
FALLBACK_CLASSIFIER_TOTAL_BUDGET_MS = 3000

FALLBACK_MAX_SESSIONS = 512
FALLBACK_TTL_SECONDS = 7200
FALLBACK_PROFILE_MIN_SAMPLES = 5
FALLBACK_PROFILE_WINDOW = 50
FALLBACK_PROFILE_UPGRADE_THRESHOLD = 0.1
#: `_profiles` 字典的容量上限。与 `_sessions` 一样必须有界——否则本机任意进程
#: 用互不相同的 system/tools 发请求就能让它无界增长。
FALLBACK_MAX_PROFILES = 256

#: 内容层正则的被匹配文本上限（防灾难性回溯卡死事件循环）。
PATTERN_MATCH_LIMIT = 4096

#: 协议层定义的正常终止原因（Anthropic stop_reason 枚举；OpenAI 侧已由
#: _extract_usage_from_sse 映射为同一套值）。其余视为异常 → 升档。
NORMAL_STOP_REASONS = frozenset({"end_turn", "tool_use", "stop_sequence"})

#: 本模块从 MODEL_PROXY_ROUTER 读取的**全部**键，按 JSON 分组。
#:
#: 这是与 Swift `TokenProxyManager.routerJSON()` 之间的契约面，同时支撑两件事：
#:   1. 启动时对照实际 payload 报出缺失键（`router_config_missing` 告警）
#:   2. `scripts/check-router-config-contract.py` 断言 Swift 侧序列化字段 ⊇ 本集合，
#:      让「Swift 加了字段忘了同步」在提交前就红灯，而不是靠运行期发现
CONTRACT_KEYS: dict[str, tuple[str, ...]] = {
    "root": ("enabled", "tiers", "default_tier"),
    "classifier": (
        "provider",
        "prompt_template",
        "max_retries",
        "retry_delay_ms",
        "timeout_ms",
        "total_budget_ms",
    ),
    "policy": (
        "classifier_fast_path",
        "switch_cost_turns",
        "loop_streak",
        "escalate_error_streak",
        "checkpoint_interval",
        "escalate_patterns",
        "readonly_tools",
        "normal_stop_reasons",
        "require_paired_history",
    ),
    "conversation": ("key_parts", "max_sessions", "ttl_seconds"),
    "profile": (
        "enabled",
        "min_samples",
        "window",
        "upgrade_rate_threshold",
        "prior_tier",
        "max_profiles",
    ),
}


class Reason:
    """结构化决策原因——供日志归因，禁止用裸字符串散落各处。"""

    ROUTER_DISABLED = "router_disabled"
    ROUTER_ERROR = "router_error"
    TIER_UNRESOLVED = "tier_unresolved"

    #: 结构判定的非 agent 请求（如 Claude Code safety classifier）直通兜底档，
    #: 不建会话、不调分类器
    FASTPATH_CLASSIFIER = "fastpath_classifier"

    SESSION_NEW_CLASSIFIED = "session_new_classified"
    SESSION_NEW_PROFILE_PRIOR = "session_new_profile_prior"
    SESSION_NEW_FALLBACK = "session_new_fallback"

    ESCALATE_TOOL_ERROR = "escalate_tool_error"
    ESCALATE_LOOP = "escalate_loop"
    ESCALATE_STOP_REASON = "escalate_stop_reason"
    ESCALATE_CHECKPOINT = "escalate_checkpoint"
    ESCALATE_PATTERN = "escalate_pattern"

    DOWNGRADE_READONLY = "downgrade_readonly"

    HOLD = "hold"
    HOLD_LOCKED = "hold_locked"
    #: 并发请求撞上同 task_key 的会话创建，直接并入既有会话（单飞）
    HOLD_CONCURRENT_JOIN = "hold_concurrent_join"
    HOLD_ALREADY_WEAKEST = "hold_already_weakest"
    HOLD_ALREADY_DOWNGRADED = "hold_already_downgraded"
    HOLD_NOT_READONLY = "hold_not_readonly"
    HOLD_NO_EXPECTED_TURNS = "hold_no_expected_turns"
    HOLD_INSUFFICIENT_REMAINING = "hold_insufficient_remaining"
    HOLD_SWITCH_UNSAFE = "hold_switch_unsafe"
    HOLD_ERROR_UNKNOWN = "hold_error_unknown"


# ---------------------------------------------------------------------------
# 配置模型
# ---------------------------------------------------------------------------


@dataclass
class TierDef:
    name: str
    model: str
    description: str = ""


@dataclass
class RouteDecision:
    """一次路由决策的结果。

    tier 为 None 表示本模块未接管（禁用 / 出错），调用方回落到按 body.model
    选 provider 的原路径。
    """

    tier: str | None
    reason: str
    model: str = ""
    provider: dict | None = None
    task_key: str = ""
    profile_key: str = ""
    turn_index: int = 0
    detail: dict = field(default_factory=dict)


def _compile_patterns(raw) -> list[re.Pattern]:
    out: list[re.Pattern] = []
    for p in raw or []:
        try:
            out.append(re.compile(p))
        except (re.error, TypeError) as e:
            logger.warning(
                json.dumps({"msg": "router_pattern_invalid", "pattern": str(p), "error": str(e)})
            )
    return out


class RouterConfig:
    """从 MODEL_PROXY_ROUTER JSON 构造的策略配置。

    tiers 为**数组**而非字典：Swift 的 Dictionary 编码不保证顺序，而档位强度
    顺序（索引 0 = 最强）是策略语义的一部分，必须显式保序。
    """

    def __init__(self, cfg: dict):
        self.enabled = bool(cfg.get("enabled"))

        self.tiers: list[TierDef] = []
        for item in cfg.get("tiers") or []:
            if not isinstance(item, dict):
                continue
            name = item.get("name", "")
            if not name:
                continue
            self.tiers.append(
                TierDef(name, item.get("model", ""), item.get("description", ""))
            )
        self.tier_names = [t.name for t in self.tiers]
        # 档位名大小写不敏感：分类器输出统一 .lower()，若这里按原样建索引，
        # 配置写 `Medium` 的档位将永远无法命中，每次分类都失败。
        # 键用小写，值仍为配置里的原始名（对外输出保持原样）。
        self.tier_rank = {t.name.lower(): i for i, t in enumerate(self.tiers)}

        self.default_tier = self.canonical_tier(cfg.get("default_tier", "")) or self.weakest

        clf = cfg.get("classifier") or {}
        self.classifier_provider = clf.get("provider", "")
        self.classifier_prompt_template = clf.get("prompt_template", "")
        self.classifier_max_retries = int(clf.get("max_retries", 3))
        self.classifier_retry_delay_ms = int(clf.get("retry_delay_ms", 500))
        self.classifier_timeout_ms = int(clf.get("timeout_ms", 10000))
        self.classifier_total_budget_ms = int(
            clf.get("total_budget_ms", FALLBACK_CLASSIFIER_TOTAL_BUDGET_MS)
        )

        pol = cfg.get("policy") or {}
        self.classifier_fast_path = bool(pol.get("classifier_fast_path", True))
        self.switch_cost_turns = int(pol.get("switch_cost_turns", FALLBACK_SWITCH_COST_TURNS))
        self.loop_streak = int(pol.get("loop_streak", FALLBACK_LOOP_STREAK))
        self.escalate_error_streak = max(
            1, int(pol.get("escalate_error_streak", FALLBACK_ESCALATE_ERROR_STREAK))
        )
        self.checkpoint_interval = int(pol.get("checkpoint_interval", FALLBACK_CHECKPOINT_INTERVAL))
        self.escalate_patterns = _compile_patterns(pol.get("escalate_patterns"))
        self.readonly_tools = {t for t in (pol.get("readonly_tools") or []) if t}
        normal = pol.get("normal_stop_reasons")
        self.normal_stop_reasons = (
            frozenset(normal) if normal else NORMAL_STOP_REASONS
        )
        self.require_paired_history = bool(pol.get("require_paired_history", True))

        conv = cfg.get("conversation") or {}
        self.key_parts = [p for p in (conv.get("key_parts") or DEFAULT_KEY_PARTS) if p]
        self.max_sessions = int(conv.get("max_sessions", FALLBACK_MAX_SESSIONS))
        self.ttl_seconds = float(conv.get("ttl_seconds", FALLBACK_TTL_SECONDS))

        prof = cfg.get("profile") or {}
        self.profile_enabled = bool(prof.get("enabled", True))
        self.profile_min_samples = int(prof.get("min_samples", FALLBACK_PROFILE_MIN_SAMPLES))
        self.profile_window = max(1, int(prof.get("window", FALLBACK_PROFILE_WINDOW)))
        self.profile_upgrade_threshold = float(
            prof.get("upgrade_rate_threshold", FALLBACK_PROFILE_UPGRADE_THRESHOLD)
        )
        self.profile_prior_tier = (
            self.canonical_tier(prof.get("prior_tier", "")) or self.weakest
        )
        self.max_profiles = max(1, int(prof.get("max_profiles", FALLBACK_MAX_PROFILES)))

        self._warn_missing(cfg)
        self._warn_inconsistent()

    def _warn_missing(self, cfg: dict) -> None:
        """按契约面报出缺失键——兜底值是兜底，不是默认值，缺失必须可观测。"""
        missing: list[str] = []
        for group, keys in CONTRACT_KEYS.items():
            src = cfg if group == "root" else (cfg.get(group) or {})
            if not isinstance(src, dict):
                missing.extend(f"{group}.{k}" for k in keys)
                continue
            missing.extend(f"{group}.{k}" for k in keys if k not in src)
        if missing:
            logger.warning(
                json.dumps(
                    {
                        "msg": "router_config_missing",
                        "keys": missing,
                        "effect": "已用兜底值（非默认值）；业务默认值唯一权威在 "
                        "ConfigTypes.swift 与 default-config.yaml",
                    }
                )
            )

    def canonical_tier(self, name: str) -> str:
        """档位名归一为配置里的原始拼写（大小写、空值均容错）。返回 "" 表示未知。"""
        if not name:
            return ""
        rank = self.tier_rank.get(str(name).strip().lower())
        return self.tier_names[rank] if rank is not None else ""

    def _warn_inconsistent(self) -> None:
        """把配置层面的自相矛盾在加载时显式暴露，而不是留到运行时静默生效。"""
        if (
            self.checkpoint_interval > 0
            and self.checkpoint_interval < self.switch_cost_turns
        ):
            logger.warning(
                json.dumps(
                    {
                        "msg": "router_config_checkpoint_below_payback",
                        "checkpoint_interval": self.checkpoint_interval,
                        "switch_cost_turns": self.switch_cost_turns,
                        "effect": "已降档会话的实际检查点间隔将抬到 switch_cost_turns，"
                        "保证弱档段至少跑满回本线",
                    }
                )
            )
        if self.max_sessions == 0:
            logger.warning(
                json.dumps(
                    {
                        "msg": "router_config_max_sessions_zero",
                        "effect": "0 = 不限制会话数（与 ttlSeconds=0 表示不过期一致）",
                    }
                )
            )

    @property
    def strongest(self) -> str:
        return self.tier_names[0] if self.tier_names else ""

    @property
    def weakest(self) -> str:
        return self.tier_names[-1] if self.tier_names else ""

    def model_of(self, tier: str) -> str:
        rank = self.tier_rank.get(str(tier).strip().lower())
        return self.tiers[rank].model if rank is not None else ""

    def checkpoint_interval_for(self, downgraded: bool) -> int:
        """检查点间隔。已降档的会话必须把间隔抬到回本线，否则弱档段永远撑不到
        回本就被强制升回——降档在任何轮次都必然亏本（成本模型见模块 docstring）。"""
        if self.checkpoint_interval <= 0:
            return 0
        if downgraded:
            return max(self.checkpoint_interval, self.switch_cost_turns)
        return self.checkpoint_interval


# ---------------------------------------------------------------------------
# 会话与 profile 状态
# ---------------------------------------------------------------------------


@dataclass
class SessionState:
    tier: str
    profile_key: str
    origin: str
    #: **会话内**已完成的工具轮数（= 全局 turn_index - start_turn）。
    #: 必须与 start_turn 配对使用：Claude Code 每轮重发全量历史，`turn_index(turns)`
    #: 数的是**整段对话**的工具轮数，一段长对话里新开一个会话，它的值一上来就是
    #: 几百——直接拿来当「会话内轮数」会让所有按轮数的判据（检查点、降档回本线）
    #: 在会话第一个请求就满足。曾因此导致分级形同虚设：每个会话第 2 个请求即被
    #: 检查点强制升档并锁死。
    turns: int = 0
    #: 会话诞生时的全局 turn_index，用于把全局轮数折算为会话内轮数。
    start_turn: int = 0
    downgraded: bool = False
    locked: bool = False
    escalated: bool = False
    #: 上一次检查点升档时的**会话内**轮次。检查点按「距上次检查点的轮数」触发，
    #: 而不是 `turn % interval == 0`——后者会漏触发，也会在降档后立刻再触发。
    last_checkpoint_turn: int = 0
    #: 连续出现工具失败的轮数（本轮无失败即归零）。单次失败不足以升档：
    #: `is_error` 由客户端设置，Bash 的常规非零退出（grep 无匹配、diff 有差异、
    #: test 失败）同样被标为 True，一次就把会话永久锁到强档属于成本放大。
    consecutive_errors: int = 0
    last_stop_reason: str = ""
    created_at: float = 0.0
    touched_at: float = 0.0

    def snapshot(self) -> dict:
        return {
            "tier": self.tier,
            "origin": self.origin,
            "turns": self.turns,
            "downgraded": self.downgraded,
            "locked": self.locked,
            "escalated": self.escalated,
        }


@dataclass
class ProfileStats:
    """一类 agent（system+tools 指纹）的滑动行为统计。

    同时承担两个职责：
      1. 先验档——窗口内升级率低的 profile 直接免检走低档（重复劳动任务）
      2. 预期轮数——为降档的「预期收益」判断提供依据

    **所有派生值都取自同一个窗口内的样本**（`history` 是有 maxlen 的 deque），
    而不是「全生命周期比率 + 最近 N 条中位数」这种两个口径混用——那会让同一份
    配置在重启前后给出相反的结论。`window` 是真实的滑动窗口，不是只影响加载。
    """

    window: int = FALLBACK_PROFILE_WINDOW
    #: 窗口内每个已结束会话的 (轮数, 是否升过档)
    history: deque = field(default_factory=deque)

    def __post_init__(self) -> None:
        # deque 的 maxlen 只能在构造时设定；dataclass 默认工厂拿不到 window
        if self.history.maxlen != self.window:
            self.history = deque(self.history, maxlen=self.window)

    def record(self, state: SessionState) -> None:
        # 不计空会话（turns=0）：客户端探测、被中断的首个请求都会产生空会话，
        # 让它们进入统计只会稀释中位数、拉低升级率。
        if state.turns <= 0:
            return
        self.history.append((state.turns, bool(state.escalated)))

    @property
    def sessions(self) -> int:
        return len(self.history)

    @property
    def escalated_sessions(self) -> int:
        return sum(1 for _, esc in self.history if esc)

    @property
    def upgrade_rate(self) -> float:
        # 无样本时返回 1.0：视为「未知/风险高」，先验档不予启用（保守）
        return self.escalated_sessions / self.sessions if self.history else 1.0

    def expected_turns(self) -> float | None:
        if not self.history:
            return None
        ordered = sorted(t for t, _ in self.history)
        return float(ordered[len(ordered) // 2])

    def snapshot(self) -> dict:
        return {
            "sessions": self.sessions,
            "upgrade_rate": round(self.upgrade_rate, 3),
            "expected_turns": self.expected_turns(),
            "window": self.window,
        }


# ---------------------------------------------------------------------------
# 路由主体
# ---------------------------------------------------------------------------


class ProfileStore:
    """agent 类型统计的持久化。

    profile 统计只在会话淘汰时回填，而代理进程会因配置重载 / 应用重启而重建。
    不持久化的话学习成果每次归零，`min_samples` 判定与降档所需的 `expected_turns`
    会长期拿不到样本——降档通道事实上永不开启。故用独立小表持久化。

    表结构与 `api_usage` 解耦：本表是策略状态，不是用量记录，可安全清空重建。
    """

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._ready = False

    def _ensure(self) -> None:
        if self._ready or not self._db_path:
            return
        try:
            with dbconn(self._db_path) as c:
                existing = {
                    r[1] for r in c.execute("PRAGMA table_info(router_profile)").fetchall()
                }
                # 本表由同一次改动引入、从未随版本发布，且只存可重建的策略状态，
                # 因此旧形态直接重建即可，不做迁移脚手架；重建行为显式记日志。
                if existing and "history" not in existing:
                    logger.warning(
                        json.dumps(
                            {
                                "msg": "router_profile_schema_reset",
                                "old_columns": sorted(existing),
                                "reason": "策略状态表结构升级（窗口统计改为单一口径）",
                            }
                        )
                    )
                    c.execute("DROP TABLE router_profile")
                c.execute(
                    """CREATE TABLE IF NOT EXISTS router_profile (
                        profile_hash TEXT PRIMARY KEY,
                        history TEXT,
                        updated_at TEXT
                    )"""
                )
            self._ready = True
        except Exception as e:
            logger.warning(
                json.dumps({"msg": "router_profile_init_failed", "error": str(e)})
            )
            self._db_path = ""  # 持久化不可用 → 退化为纯内存，不阻断路由

    def load_all(self, window: int) -> dict[str, ProfileStats]:
        self._ensure()
        out: dict[str, ProfileStats] = {}
        if not self._db_path:
            return out
        try:
            with dbconn(self._db_path) as c:
                rows = c.execute(
                    "SELECT profile_hash, history FROM router_profile"
                ).fetchall()
            for key, raw in rows:
                stats = ProfileStats(window=window)
                try:
                    for item in json.loads(raw) or []:
                        turns, escalated = int(item[0]), bool(item[1])
                        if turns > 0:
                            stats.history.append((turns, escalated))
                except (json.JSONDecodeError, TypeError, ValueError, IndexError):
                    pass
                out[key] = stats
        except Exception as e:
            logger.warning(json.dumps({"msg": "router_profile_load_failed", "error": str(e)}))
        return out

    def save_many(self, items: list[tuple[str, ProfileStats]]) -> None:
        """批量落库。调用方负责放到线程里执行——这是阻塞式 SQLite 写，
        直接跑在事件循环上会冻结所有在途请求（含 SSE 转发）。"""
        self._ensure()
        if not self._db_path or not items:
            return
        try:
            now = datetime.now(timezone.utc).isoformat()
            with dbconn(self._db_path) as c:
                c.executemany(
                    "INSERT INTO router_profile (profile_hash, history, updated_at) "
                    "VALUES (?,?,?) "
                    "ON CONFLICT(profile_hash) DO UPDATE SET "
                    "history=excluded.history, updated_at=excluded.updated_at",
                    [
                        (key, json.dumps([list(x) for x in stats.history]), now)
                        for key, stats in items
                    ],
                )
        except Exception as e:
            logger.warning(json.dumps({"msg": "router_profile_save_failed", "error": str(e)}))


class Router:
    """分级路由状态机。

    依赖注入 provider 查找函数与统计存储，避免与 token_proxy.py 形成循环 import。
    """

    def __init__(
        self,
        cfg: dict,
        find_provider_by_name,
        find_provider_for_model,
        store: ProfileStore | None = None,
    ):
        self.config = RouterConfig(cfg)
        self._find_provider_by_name = find_provider_by_name
        self._find_provider_for_model = find_provider_for_model
        self._store = store
        self._sessions: dict[str, SessionState] = {}
        self._profiles: dict[str, ProfileStats] = (
            store.load_all(self.config.profile_window) if store else {}
        )
        # 同一 task_key 的并发开工锁：分类是一次网络调用（可达数秒），期间会话
        # 尚未写入 _sessions，没有锁的话并发请求会各发一次分类并互相覆盖状态。
        self._open_locks: dict[str, asyncio.Lock] = {}

    @property
    def enabled(self) -> bool:
        return self.config.enabled and bool(self.config.tiers)

    # -- 生命周期 ---------------------------------------------------------

    def finalize_all(self) -> None:
        """把在途会话回填 profile 统计并落库（进程退出 / 配置重载时调用）。

        没有这一步，能在单进程生命周期内被统计的只有「TTL 到期或容量溢出」的
        会话，最近在用的会话随进程消失——`min_samples` 与降档所需的
        `expected_turns` 因此长期缺样本。
        """
        items = self._drain_all()
        if items and self._store:
            self._store.save_many(items)

    def _profile_of(self, key: str) -> ProfileStats:
        stats = self._profiles.get(key)
        if stats is None:
            self._evict_profiles()
            stats = ProfileStats(window=self.config.profile_window)
            self._profiles[key] = stats
        else:
            # 触碰顺序用于 LRU 淘汰
            self._profiles[key] = self._profiles.pop(key)
        return stats

    def _evict_profiles(self) -> None:
        """`_profiles` 必须与 `_sessions` 一样有界——本机任意进程用互不相同的
        system/tools 发请求即可驱动它无界增长。"""
        overflow = len(self._profiles) - self.config.max_profiles
        if overflow > 0:
            for key in list(self._profiles.keys())[:overflow]:
                self._profiles.pop(key, None)

    def _record(self, state: SessionState) -> str:
        """会话结束时回填统计。只改内存；落库由调用方批量 offload 到线程。"""
        stats = self._profile_of(state.profile_key)
        stats.record(state)
        return state.profile_key

    def _evict(self, now: float) -> list[tuple[str, ProfileStats]]:
        """淘汰过期/超量会话，返回需要落库的 (profile_key, stats) 列表。"""
        touched: list[str] = []
        ttl = self.config.ttl_seconds
        if ttl > 0:
            expired = [k for k, s in self._sessions.items() if now - s.touched_at > ttl]
            for k in expired:
                touched.append(self._record(self._sessions.pop(k)))
        if self.config.max_sessions > 0:
            overflow = len(self._sessions) - self.config.max_sessions
            if overflow > 0:
                oldest = sorted(self._sessions.items(), key=lambda kv: kv[1].touched_at)
                for k, state in oldest[:overflow]:
                    self._sessions.pop(k, None)
                    touched.append(self._record(state))
        return self._pending_items(touched)

    def _drain_all(self) -> list[tuple[str, ProfileStats]]:
        touched = [self._record(s) for s in list(self._sessions.values())]
        self._sessions.clear()
        return self._pending_items(touched)

    def _pending_items(self, keys: list[str]) -> list[tuple[str, ProfileStats]]:
        seen: dict[str, ProfileStats] = {}
        for k in keys:
            stats = self._profiles.get(k)
            if stats is not None:
                seen[k] = stats
        return list(seen.items())

    async def _flush(self, items: list[tuple[str, ProfileStats]]) -> None:
        """把 SQLite 写移出事件循环。同步 write 会冻结所有在途请求（含 SSE 转发）。"""
        if not items or not self._store:
            return
        try:
            await asyncio.to_thread(self._store.save_many, items)
        except Exception as e:
            logger.warning(
                json.dumps({"msg": "router_profile_flush_failed", "error": str(e)})
            )

    # -- 决策入口 ---------------------------------------------------------

    async def decide(self, body: dict, api_format: str) -> RouteDecision:
        """产出本次请求的档位决策。

        归一化、快速路径判定、状态机全部在同一个 try 内——本方法承诺
        「任何内部异常都降级为不接管，绝不抛出」，因此**不能**把其中任何
        一步放在 try 之外（畸形请求体会让代理吐 500 且不转发）。
        """
        if not self.enabled:
            return RouteDecision(None, Reason.ROUTER_DISABLED)
        try:
            turns = normalize_turns(body, api_format)
            if self.config.classifier_fast_path and _is_classifier_candidate(body):
                # 结构判定的非 agent 请求直接走兜底档，**不建会话、不进 profile**：
                # 这类请求 tools 为空且消息各异，指纹必然互不相同，走正常流程会为
                # 每一条都额外发一次 LLM 分类调用，而它在工具调用批准的关键路径上。
                # 判定复用 proxy_protocol._is_classifier_candidate（单一事实源，
                # 勿在此重新推导一套结构条件）。
                tier = self.config.default_tier or self.config.weakest
                model = self.config.model_of(tier)
                provider = self._find_provider_for_model(model) if model else None
                if provider is not None:
                    return RouteDecision(
                        tier=tier,
                        reason=Reason.FASTPATH_CLASSIFIER,
                        model=model,
                        provider=provider,
                    )
            return await self._decide(turns, body, api_format)
        except Exception as e:  # 代理主链路不可被路由缺陷打断
            logger.warning(
                json.dumps({"msg": "router_exception", "error": f"{type(e).__name__}: {e}"})
            )
            return RouteDecision(None, Reason.ROUTER_ERROR)

    async def _decide(
        self, turns: list[NormalizedTurn], body: dict, api_format: str
    ) -> RouteDecision:
        cfg = self.config
        now = time.monotonic()
        pending = self._evict(now)

        task_key, profile_key, unknown = build_fingerprints(turns, body, cfg.key_parts)
        if unknown:
            logger.warning(
                json.dumps(
                    {
                        "msg": "router_key_parts_unknown",
                        "unknown": unknown,
                        "valid": list(KEY_PART_NAMES),
                        "effect": "未知分量已剔除；若因此变空则退回会话级粘性",
                    }
                )
            )
        idx = turn_index(turns)

        state = self._sessions.get(task_key)
        if state is None:
            decision = await self._open_session(task_key, profile_key, turns, idx, now)
            await self._flush(pending)
            return decision
        await self._flush(pending)

        state.touched_at = now
        # 全局轮数 → 会话内轮数。所有按轮数的判据都只认这个值。
        session_turns = idx - state.start_turn
        state.turns = session_turns

        # 连续工具失败计数须在升级判定**之前**更新：判定读的是「含本轮在内的连续次数」。
        results = latest_tool_results(turns)
        if any(r.is_error is True for r in results):
            state.consecutive_errors += 1
        else:
            state.consecutive_errors = 0

        # 1) 升级判定（终止性，命中即锁定到用户下条消息）
        escalated = self._check_escalation(state, turns)
        if escalated is not None:
            reason, detail = escalated
            if state.locked:
                # 已在高档锁定：信号保留在 detail 里可观测，但不再重复记升档——
                # 否则「已锁定」的每一轮都会报 escalate_*，升档计数虚高、归因失真。
                return self._emit(
                    state, task_key, idx, Reason.HOLD_LOCKED, {"signal": reason, **detail}
                )
            target = cfg.strongest
            changes_tier = (
                target and cfg.tier_rank.get(target.lower(), 99) < cfg.tier_rank.get(state.tier.lower(), 99)
            )
            if changes_tier:
                # 升档同样要换 provider/格式，与降档共享同一道前置检查：
                # 历史里存在无配对 tool_use 时切档会被严格上游 400（已知故障模式）。
                if cfg.require_paired_history:
                    ok, why = check_tool_pairing(turns)
                    if not ok:
                        logger.warning(
                            json.dumps(
                                {
                                    "msg": "route_switch_blocked",
                                    "reason": why,
                                    "direction": "escalate",
                                    "signal": reason,
                                }
                            )
                        )
                        return self._emit(
                            state,
                            task_key,
                            idx,
                            Reason.HOLD_SWITCH_UNSAFE,
                            {"pairing": why, "signal": reason, **detail},
                        )
                state.tier = target
            state.locked = True
            state.escalated = True
            return self._emit(state, task_key, idx, reason, detail)

        # 2) 降档判定（唯一通道，会话内至多一次）
        if state.locked:
            return self._emit(state, task_key, idx, Reason.HOLD_LOCKED)
        if state.downgraded:
            return self._emit(state, task_key, idx, Reason.HOLD_ALREADY_DOWNGRADED)
        if state.tier == cfg.weakest:
            return self._emit(state, task_key, idx, Reason.HOLD_ALREADY_WEAKEST)

        approved, reason, detail = self._check_downgrade(
            state, turns, session_turns, profile_key
        )
        if not approved:
            return self._emit(state, task_key, idx, reason, detail)
        state.tier = cfg.weakest
        state.downgraded = True
        # 降档即重置检查点基准，使弱档段至少跑满回本线才可能被强制升回
        state.last_checkpoint_turn = state.turns
        return self._emit(state, task_key, idx, reason, detail)

    async def _open_session(
        self,
        task_key: str,
        profile_key: str,
        turns: list[NormalizedTurn],
        idx: int,
        now: float,
    ) -> RouteDecision:
        # 单飞：分类是网络调用（可达数秒），期间会话尚未登记。同一 task_key 的
        # 并发请求（客户端重发、同 prompt 的并行子 agent）若各发一次分类，既多付
        # 延迟与 token，后写者还会覆盖前者的 locked/escalated/downgraded。
        lock = self._open_locks.get(task_key)
        if lock is None:
            self._evict_open_locks()
            lock = self._open_locks.setdefault(task_key, asyncio.Lock())
        async with lock:
            existing = self._sessions.get(task_key)
            if existing is not None:
                existing.touched_at = now
                existing.turns = idx
                # 会话已就绪，创建窗口结束，锁条目可以回收（后续请求走 _decide
                # 的主路径，不会再取这把锁）
                self._open_locks.pop(task_key, None)
                return self._emit(
                    existing, task_key, idx, Reason.HOLD_CONCURRENT_JOIN, {"joined": True}
                )
            decision = await self._open_locked(task_key, profile_key, turns, idx, now)
            self._open_locks.pop(task_key, None)
            return decision

    def _evict_open_locks(self) -> None:
        """锁表必须有界：每个 task_key 一把锁，不设限会随会话数无界增长。"""
        overflow = len(self._open_locks) - self.config.max_sessions
        if self.config.max_sessions > 0 and overflow > 0:
            for key in list(self._open_locks.keys())[:overflow]:
                self._open_locks.pop(key, None)

    async def _open_locked(
        self,
        task_key: str,
        profile_key: str,
        turns: list[NormalizedTurn],
        idx: int,
        now: float,
    ) -> RouteDecision:
        cfg = self.config
        reason = Reason.SESSION_NEW_FALLBACK
        detail: dict = {}

        stats = self._profiles.get(profile_key)
        prior_ok = (
            cfg.profile_enabled
            and stats is not None
            and stats.sessions >= cfg.profile_min_samples
            and stats.upgrade_rate <= cfg.profile_upgrade_threshold
        )

        if prior_ok:
            tier = cfg.profile_prior_tier or cfg.default_tier
            reason = Reason.SESSION_NEW_PROFILE_PRIOR
            detail = {"profile_samples": stats.sessions, "upgrade_rate": round(stats.upgrade_rate, 3)}
        else:
            classified = await self._classify(turns)
            if classified:
                tier = classified
                reason = Reason.SESSION_NEW_CLASSIFIED
            else:
                tier = cfg.default_tier
                detail = {"fallback": True}

        state = SessionState(
            tier=tier,
            profile_key=profile_key,
            origin=reason,
            # 会话从 0 起算；start_turn 记下诞生时的全局轮数，供后续折算
            turns=0,
            start_turn=idx,
            created_at=now,
            touched_at=now,
        )
        self._sessions[task_key] = state
        return self._emit(state, task_key, idx, reason, detail)

    # -- 升级 / 降档判据 ---------------------------------------------------

    def _check_escalation(
        self, state: SessionState, turns: list[NormalizedTurn]
    ) -> tuple[str, dict] | None:
        cfg = self.config

        # 1. 工具失败——协议级字段，Anthropic 侧由 Claude Code 等客户端必填。
        #    **要求连续失败**：`is_error` 是客户端对「非零退出」的判定，Bash 的
        #    grep 无匹配 / diff 有差异 / test 失败都算，单次就升档会把会话永久
        #    锁到强档（成本放大）。连续 2 轮才升，是对「这个错误卡住了」更稳的
        #    近似——真卡住的错误会在下一轮重复出现，偶发噪声不会。
        results = latest_tool_results(turns)
        failed = [r for r in results if r.is_error is True]
        if failed and state.consecutive_errors >= cfg.escalate_error_streak:
            return Reason.ESCALATE_TOOL_ERROR, {
                "failed_count": len(failed),
                "consecutive": state.consecutive_errors,
                "tool_call_ids": [r.tool_call_id for r in failed][:5],
            }

        # 2. 打转——连续同名同参工具调用（弱模型卡住的典型特征）
        streak = tool_call_streak(turns)
        if cfg.loop_streak > 0 and streak >= cfg.loop_streak:
            call = last_tool_call(turns)
            return Reason.ESCALATE_LOOP, {
                "streak": streak,
                "tool_name": call.tool_name if call else "",
            }

        # 3. 上一轮响应终止原因异常（max_tokens 截断 / error 等）
        if state.last_stop_reason and state.last_stop_reason not in cfg.normal_stop_reasons:
            return Reason.ESCALATE_STOP_REASON, {"stop_reason": state.last_stop_reason}

        # 4. 内容层兜底正则：仅当 provider 不返回 is_error 时才有意义，默认空。
        #    被匹配文本按上限截断——正则由用户配置，文本来自客户端，长度不限时
        #    一个灾难性回溯的表达式会卡死整个事件循环。
        if cfg.escalate_patterns and results:
            for r in results:
                sample = (r.text or "")[:PATTERN_MATCH_LIMIT]
                for pat in cfg.escalate_patterns:
                    if pat.search(sample):
                        return Reason.ESCALATE_PATTERN, {"pattern": pat.pattern}

        # 5. 检查点——is_error 不可用时的主力兜底，故不可缺省。
        #    按「距上次检查点的轮数」触发（而非 turn % interval），既不会漏触发，
        #    也能配合降档：已降档的会话间隔被抬到回本线，保证弱档段撑得到回本。
        interval = cfg.checkpoint_interval_for(state.downgraded)
        if interval > 0 and state.turns > 0:
            since = state.turns - state.last_checkpoint_turn
            if since >= interval:
                state.last_checkpoint_turn = state.turns
                return Reason.ESCALATE_CHECKPOINT, {
                    "turn_index": state.turns,
                    "since_last": since,
                    "interval": interval,
                }

        return None

    def _check_downgrade(
        self,
        state: SessionState,
        turns: list[NormalizedTurn],
        session_turns: int,
        profile_key: str,
    ) -> tuple[bool, str, dict]:
        """降档条件——必须全部满足，任何一项缺失都保持原档。

        `session_turns` 是**会话内**轮数（非对话全局轮数），与 profile 记录的
        `expected_turns` 同口径，两者相减才有意义。

        返回 (是否放行, 原因, 明细)。原因同时用于日志归因与决策输出。
        """
        cfg = self.config

        # 前置安全：历史中工具调用配对不完整时切档会让严格上游 400（已知故障模式）
        if cfg.require_paired_history:
            ok, why = check_tool_pairing(turns)
            if not ok:
                logger.warning(
                    json.dumps(
                        {"msg": "route_switch_blocked", "reason": why, "direction": "downgrade"}
                    )
                )
                return False, Reason.HOLD_SWITCH_UNSAFE, {"pairing": why}

        # 只读工具白名单为空 = 永不允许降档（通用 agent 的最保守默认）
        if not cfg.readonly_tools:
            return False, Reason.HOLD_NOT_READONLY, {"readonly_tools": 0}
        calls = [b for t in turns for b in t.tool_calls]
        if not calls:
            return False, Reason.HOLD_NOT_READONLY, {"calls": 0}
        outside = sorted({b.tool_name for b in calls if b.tool_name not in cfg.readonly_tools})
        if outside:
            return False, Reason.HOLD_NOT_READONLY, {"outside": outside[:5]}

        # 失败信号必须全部为「确认成功」。is_error 为 None（协议未提供）属未知，
        # 不可当作成功——这是本模块最容易写错的一处。
        results = latest_tool_results(turns)
        if not results:
            return False, Reason.HOLD_ERROR_UNKNOWN, {"results": 0}
        unknown = sum(1 for r in results if r.is_error is not False)
        if unknown:
            return False, Reason.HOLD_ERROR_UNKNOWN, {"unconfirmed": unknown}

        # 预期收益：剩余轮数必须够回本。只用剩余轮数——切档成本只付一次，
        # 收益按后续每轮累积，已完成轮数不参与经济性判断。
        stats = self._profiles.get(profile_key)
        expected = stats.expected_turns() if stats else None
        if expected is None:
            return False, Reason.HOLD_NO_EXPECTED_TURNS, {"session_turns": session_turns}
        remaining = expected - session_turns
        if remaining < cfg.switch_cost_turns:
            return False, Reason.HOLD_INSUFFICIENT_REMAINING, {
                "expected_turns": expected,
                "session_turns": session_turns,
                "remaining": remaining,
                "threshold": cfg.switch_cost_turns,
            }

        return True, Reason.DOWNGRADE_READONLY, {
            "session_turns": session_turns,
            "expected_turns": expected,
            "readonly_tools": len(cfg.readonly_tools),
        }

    # -- 响应侧回填 --------------------------------------------------------

    def on_response(self, task_key: str, stop_reason: str) -> None:
        """回填上一轮响应信息。stop_reason 不在请求体里，必须由响应侧提供。"""
        state = self._sessions.get(task_key)
        if state is not None and stop_reason:
            state.last_stop_reason = stop_reason

    # -- 分类器 -----------------------------------------------------------

    def _build_classify_prompt(self, user_text: str) -> str:
        cfg = self.config
        tmpl = cfg.classifier_prompt_template or DEFAULT_CLASSIFY_PROMPT_TEMPLATE
        tier_lines = "\n".join(
            f"- {t.name}：{t.description}" if t.description else f"- {t.name}"
            for t in cfg.tiers
        )
        # 两种拼写都替换：模板由用户手写，占位符拼错时 replace 是空操作、
        # 分类 prompt 会静默丢掉用户消息（分类器只能瞎猜），代价远大于多一次替换。
        for name in ("{last_user_message}", "{lastUserMessage}"):
            tmpl = tmpl.replace(name, user_text)
        return tmpl.replace("{tier_lines}", tier_lines)

    async def _classify(self, turns: list[NormalizedTurn]) -> str | None:
        cfg = self.config
        user_text = last_real_user_text(turns)
        if not user_text:
            return None

        provider = self._find_provider_by_name(cfg.classifier_provider)
        if not provider:
            logger.warning(
                json.dumps(
                    {
                        "msg": "classify_provider_not_found",
                        "provider": cfg.classifier_provider,
                    }
                )
            )
            return None

        prompt = self._build_classify_prompt(user_text[:500])
        api_format = provider.get("apiFormat", "anthropic")
        # 总预算闸：单次超时 × 重试次数会全部叠加在转发前的关键链路上，
        # 必须有一个总上限。预算耗尽即放弃分类走兜底档，不把请求卡死。
        deadline = time.monotonic() + max(0, cfg.classifier_total_budget_ms) / 1000
        for attempt in range(max(1, cfg.classifier_max_retries)):
            remaining_ms = int((deadline - time.monotonic()) * 1000)
            if remaining_ms <= 0:
                break
            t0 = time.monotonic()
            attempt_timeout = min(cfg.classifier_timeout_ms, remaining_ms)
            try:
                if api_format == API_OPENAI:
                    result = await self._classify_openai(prompt, provider, attempt_timeout)
                else:
                    result = await self._classify_anthropic(prompt, provider, attempt_timeout)
                canonical = cfg.canonical_tier(result)
                if canonical:
                    logger.info(
                        json.dumps(
                            {
                                "msg": "classify_result",
                                "provider": cfg.classifier_provider,
                                "result": canonical,
                                "latency_ms": int((time.monotonic() - t0) * 1000),
                                "attempt": attempt + 1,
                            }
                        )
                    )
                    return canonical
                raise ValueError(f"classify_invalid_response: {result!r}")
            except Exception as e:
                logger.warning(
                    json.dumps(
                        {
                            "msg": "classify_retry",
                            "provider": cfg.classifier_provider,
                            "attempt": attempt + 1,
                            "latency_ms": int((time.monotonic() - t0) * 1000),
                            "error": f"{type(e).__name__}: {e}",
                        }
                    )
                )
                if attempt < cfg.classifier_max_retries - 1:
                    await asyncio.sleep(cfg.classifier_retry_delay_ms / 1000)

        logger.warning(
            json.dumps(
                {
                    "msg": "classify_failed",
                    "provider": cfg.classifier_provider,
                    "max_retries": cfg.classifier_max_retries,
                    "budget_ms": cfg.classifier_total_budget_ms,
                    "elapsed_ms": int((time.monotonic() - (deadline - cfg.classifier_total_budget_ms / 1000)) * 1000),
                }
            )
        )
        return None

    async def _classify_anthropic(
        self, prompt: str, provider: dict, timeout_ms: int
    ) -> str:
        url = f"{provider['url']}/messages"
        headers = {"content-type": "application/json", "anthropic-version": "2023-06-01"}
        if provider.get("apiKey"):
            headers["x-api-key"] = provider["apiKey"]
        body = {
            "model": provider["models"][0],
            "max_tokens": 10,
            "thinking": {"type": "disabled"},  # 分类任务不需要推理，禁用可显著降延迟
            "messages": [{"role": "user", "content": prompt}],
        }
        timeout = aiohttp.ClientTimeout(total=timeout_ms / 1000)
        async with aiohttp.ClientSession() as session:
            async with session.post(url, json=body, headers=headers, timeout=timeout) as resp:
                data = await resp.json()
                content = data.get("content") or [{}]
                return content[0].get("text", "").strip().lower()

    async def _classify_openai(
        self, prompt: str, provider: dict, timeout_ms: int
    ) -> str:
        cfg = self.config
        url = f"{provider['url']}/chat/completions"
        headers = {"content-type": "application/json"}
        if provider.get("apiKey"):
            headers["authorization"] = f"Bearer {provider['apiKey']}"
        body = {
            "model": provider["models"][0],
            "max_tokens": 10,
            "messages": [{"role": "user", "content": prompt}],
        }
        timeout = aiohttp.ClientTimeout(total=timeout_ms / 1000)
        async with aiohttp.ClientSession() as session:
            async with session.post(url, json=body, headers=headers, timeout=timeout) as resp:
                data = await resp.json()
                choices = data.get("choices") or []
                if not choices:
                    return ""
                return (choices[0].get("message") or {}).get("content", "").strip().lower()

    # -- 输出 -------------------------------------------------------------

    def _emit(
        self,
        state: SessionState,
        task_key: str,
        idx: int,
        reason: str,
        detail: dict | None = None,
    ) -> RouteDecision:
        cfg = self.config
        model = cfg.model_of(state.tier)
        provider = self._find_provider_for_model(model) if model else None
        if provider is None or not model:
            # 档位模型在 providers 中不存在——不接管，回落原路径（防静默改错模型）
            logger.warning(
                json.dumps({"msg": "route_model_unresolved", "tier": state.tier, "model": model})
            )
            return RouteDecision(None, Reason.TIER_UNRESOLVED, task_key=task_key)
        return RouteDecision(
            tier=state.tier,
            reason=reason,
            model=model,
            provider=provider,
            task_key=task_key,
            profile_key=state.profile_key,
            turn_index=idx,
            detail={**(detail or {}), "session": state.snapshot()},
        )

    def snapshot(self) -> dict:
        """诊断快照（菜单栏 / 日志用）。"""
        return {
            "sessions": len(self._sessions),
            "profiles": {k: v.snapshot() for k, v in self._profiles.items()},
        }


def build_router(
    cfg: dict,
    find_provider_by_name,
    find_provider_for_model,
    store: ProfileStore | None = None,
) -> Router | None:
    """按配置构造 Router；未启用时返回 None（调用方保持原路径）。"""
    if not cfg:
        return None
    router = Router(cfg, find_provider_by_name, find_provider_for_model, store=store)
    if not router.enabled:
        logger.info(json.dumps({"msg": "router_disabled"}))
        return None
    logger.info(
        json.dumps(
            {
                "msg": "router_ready",
                "tiers": router.config.tier_names,
                "default_tier": router.config.default_tier,
                "switch_cost_turns": router.config.switch_cost_turns,
                "checkpoint_interval": router.config.checkpoint_interval,
                "readonly_tools": sorted(router.config.readonly_tools),
                "profile_enabled": router.config.profile_enabled,
            }
        )
    )
    return router
