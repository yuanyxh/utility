"""token_proxy 的请求归一化层。

把 Anthropic Messages API 与 OpenAI Chat Completions 两种请求体归一为统一的
`NormalizedTurn` 序列，供路由策略层（proxy_router.py）求值。

设计约束（勿回退）：本模块只允许依赖两种 API 的**协议定义**，禁止依赖任何
客户端的产品实现细节——不得匹配工具名（Read/Grep/Glob…）、不得匹配工具输出
文本（BUILD SUCCEEDED/Traceback/exit code…）、不得匹配客户端注入标记
（<system-reminder>、"This session is being continued"…）。这些都会随客户端
版本、语言、工具集变化而失效，且让代理绑死在单一客户端上。

唯一安全的结构假设：无状态 API 每轮重发全量消息（协议必然结果）。
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from typing import Any

# ---------------------------------------------------------------------------
# 归一化后的内部表示（与两端协议字段名解耦）
# ---------------------------------------------------------------------------

KIND_TEXT = "text"
KIND_TOOL_CALL = "tool_call"
KIND_TOOL_RESULT = "tool_result"

ROLE_USER = "user"
ROLE_ASSISTANT = "assistant"
ROLE_TOOL = "tool"
ROLE_SYSTEM = "system"

API_ANTHROPIC = "anthropic"
API_OPENAI = "openai"


@dataclass
class NormalizedBlock:
    """归一化内容块。

    `is_error` 是三态：True=失败 / False=确认成功 / None=协议未提供。

    Anthropic 的 tool_result 有 `is_error` 字段（SDK 中为 NotRequired），
    OpenAI 的 tool 消息没有对应字段。**None 必须与 False 分开对待**——
    把「不知道」当成「没出错」会让降档在缺少失败信号时静默发生，是本层
    最容易写错、后果最严重的一处。
    """

    kind: str
    text: str = ""
    tool_name: str = ""
    tool_call_id: str = ""
    #: 工具入参的**原始值**（dict 或 JSON 字符串），不做预计算。
    #: 归一化跑在每个请求的关键路径上，而历史里的工具入参常包含整份文件内容；
    #: 逐条 json.dumps 会让长会话每请求多付数十毫秒纯 CPU。只有打转检测真正
    #: 需要时才按需取签名，且只针对尾部有限条数。
    tool_input_raw: Any = None
    is_error: bool | None = None

    def input_signature(self) -> str:
        """工具入参的规范签名（按需计算，超长截断防大载荷）。"""
        return _canonical_input(self.tool_input_raw)


@dataclass
class NormalizedTurn:
    """归一化的一轮消息。"""

    role: str
    blocks: list[NormalizedBlock] = field(default_factory=list)

    @property
    def is_real_user_turn(self) -> bool:
        """真实用户轮——纯结构判定，零内容匹配。

        Anthropic 侧工具回传以 `type=="tool_result"` 的内容块承载；OpenAI 侧
        以 `role=="tool"` 承载（归一化为 ROLE_TOOL）。两种协议下都无需读取
        任何文本内容即可判定。

        这也修正了旧实现 `_is_tool_result_only` 的缺陷：那个实现要求「所有块
        都是 tool_result」，遇到 tool_result+text 混合块就判定失败、回落 LLM
        分类，是会话中段模型反复翻转的成因。
        """
        return self.role == ROLE_USER and not self.tool_results

    @property
    def text(self) -> str:
        return " ".join(
            b.text for b in self.blocks if b.kind == KIND_TEXT and b.text
        ).strip()

    @property
    def tool_calls(self) -> list[NormalizedBlock]:
        return [b for b in self.blocks if b.kind == KIND_TOOL_CALL]

    @property
    def tool_results(self) -> list[NormalizedBlock]:
        return [b for b in self.blocks if b.kind == KIND_TOOL_RESULT]


# ---------------------------------------------------------------------------
# 归一化
# ---------------------------------------------------------------------------


def system_to_text(system) -> str:
    """Anthropic system（string 或 text block 数组）→ 纯文本。

    本函数是「如何读 system 字段」的**单一权威实现**——`proxy_protocol.py`
    的规则注入与指纹计算都必须复用它，避免同一事实两处推导。
    """
    if isinstance(system, str):
        return system
    if isinstance(system, list):
        return "\n".join(
            b.get("text", "")
            for b in system
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def _result_text(content) -> str:
    """tool_result / tool 消息的内容 → 纯文本（str 或 block 数组）。"""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


#: 工具入参签名的字节上限。工具入参常含整份文件内容，签名只用于「两次调用
#: 是否相同」的比较，截断不影响判别力，却能挡住长会话的 CPU 放大。
INPUT_SIGNATURE_LIMIT = 4096


def _canonical_input(raw) -> str:
    """工具入参归一为可比较的规范字符串（用于打转检测），超长截断。"""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            return raw[:INPUT_SIGNATURE_LIMIT]
    try:
        text = json.dumps(raw, sort_keys=True, ensure_ascii=False)
    except (TypeError, ValueError):
        text = str(raw)
    return text[:INPUT_SIGNATURE_LIMIT]


def _normalize_anthropic(body: dict) -> list[NormalizedTurn]:
    turns: list[NormalizedTurn] = []

    system = body.get("system")
    if system:
        turns.append(
            NormalizedTurn(
                ROLE_SYSTEM, [NormalizedBlock(KIND_TEXT, text=system_to_text(system))]
            )
        )

    for m in body.get("messages", []):
        if not isinstance(m, dict):
            continue
        role = m.get("role", "")
        content = m.get("content")
        blocks: list[NormalizedBlock] = []

        if isinstance(content, str):
            blocks.append(NormalizedBlock(KIND_TEXT, text=content))
        elif isinstance(content, list):
            for b in content:
                if not isinstance(b, dict):
                    continue
                bt = b.get("type")
                if bt == "text":
                    blocks.append(NormalizedBlock(KIND_TEXT, text=b.get("text", "")))
                elif bt == "tool_use":
                    blocks.append(
                        NormalizedBlock(
                            KIND_TOOL_CALL,
                            tool_name=b.get("name", ""),
                            tool_call_id=b.get("id", ""),
                            tool_input_raw=b.get("input", {}),
                        )
                    )
                elif bt == "tool_result":
                    is_err = b.get("is_error")
                    blocks.append(
                        NormalizedBlock(
                            KIND_TOOL_RESULT,
                            text=_result_text(b.get("content", "")),
                            tool_call_id=b.get("tool_use_id", ""),
                            # 非 bool（含缺失）一律记为 None=协议未提供
                            is_error=is_err if isinstance(is_err, bool) else None,
                        )
                    )

        turns.append(NormalizedTurn(role, blocks))

    return turns


def _normalize_openai(body: dict) -> list[NormalizedTurn]:
    turns: list[NormalizedTurn] = []

    for m in body.get("messages", []):
        if not isinstance(m, dict):
            continue
        role = m.get("role", "")
        content = m.get("content")

        # OpenAI 工具回传是独立 role="tool" 消息，且**没有** is_error 等价字段
        if role == "tool":
            turns.append(
                NormalizedTurn(
                    ROLE_TOOL,
                    [
                        NormalizedBlock(
                            KIND_TOOL_RESULT,
                            text=_result_text(content),
                            tool_call_id=m.get("tool_call_id", ""),
                            is_error=None,
                        )
                    ],
                )
            )
            continue

        blocks: list[NormalizedBlock] = []
        if isinstance(content, str) and content:
            blocks.append(NormalizedBlock(KIND_TEXT, text=content))
        elif isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "text":
                    blocks.append(NormalizedBlock(KIND_TEXT, text=b.get("text", "")))

        if role == ROLE_ASSISTANT:
            for tc in m.get("tool_calls") or []:
                if not isinstance(tc, dict):
                    continue
                fn = tc.get("function") or {}
                blocks.append(
                    NormalizedBlock(
                        KIND_TOOL_CALL,
                        tool_name=fn.get("name", ""),
                        tool_call_id=tc.get("id", ""),
                        tool_input_raw=fn.get("arguments", ""),
                    )
                )

        turns.append(NormalizedTurn(role, blocks))

    return turns


def normalize_turns(body: dict, api_format: str) -> list[NormalizedTurn]:
    """请求体 → 归一化轮次序列。"""
    if api_format == API_OPENAI:
        return _normalize_openai(body)
    return _normalize_anthropic(body)


# ---------------------------------------------------------------------------
# 查询辅助
# ---------------------------------------------------------------------------


def real_user_texts(turns: list[NormalizedTurn]) -> list[str]:
    """全部真实用户轮的文本（结构判定，不含工具回传）。"""
    return [t.text for t in turns if t.is_real_user_turn and t.text]


def first_real_user_text(turns: list[NormalizedTurn]) -> str:
    """首条真实用户消息文本。正序短路返回，不物化全量列表。"""
    for t in turns:
        if t.is_real_user_turn and t.text:
            return t.text
    return ""


def last_real_user_text(turns: list[NormalizedTurn]) -> str:
    """最近一条真实用户消息文本。倒序短路返回，不物化全量列表。

    注意语义：在 agent loop 中，工具回传轮不是真实用户轮，因此本函数在整个
    loop 内恒定返回最初那条指令；用户中途发出新指令时才会变化——这正是
    `latest_user` 键分量「loop 内稳定、新指令自动分界」的实现基础。
    """
    for t in reversed(turns):
        if t.is_real_user_turn and t.text:
            return t.text
    return ""


def turn_index(turns: list[NormalizedTurn]) -> int:
    """已完成轮数 = 含工具调用的 assistant 轮数（协议字段计数，与客户端无关）。"""
    return sum(1 for t in turns if t.tool_calls)


def last_tool_call(turns: list[NormalizedTurn]) -> NormalizedBlock | None:
    for t in reversed(turns):
        calls = t.tool_calls
        if calls:
            return calls[-1]
    return None


def latest_tool_results(turns: list[NormalizedTurn]) -> list[NormalizedBlock]:
    """最近一次工具回传的全部结果块。"""
    for t in reversed(turns):
        results = t.tool_results
        if results:
            return results
    return []


#: 打转检测的尾部回看上限。只比较最近这些工具调用，避免长会话每次请求
#: 都对全量历史重算入参签名（工具入参常含整份文件内容）。
STREAK_SCAN_LIMIT = 16


def tool_call_streak(turns: list[NormalizedTurn]) -> int:
    """末尾连续同名同参工具调用次数（打转检测，纯协议字段）。

    只回看尾部 `STREAK_SCAN_LIMIT` 条调用，且先比工具名、同名才计算入参签名
    （签名为按需惰性计算）。返回值为「至少」语义，调用方用阈值比较即可。
    """
    calls = [b for t in turns for b in t.tool_calls]
    if not calls:
        return 0
    tail = calls[-STREAK_SCAN_LIMIT:]
    last = tail[-1]
    last_sig = last.input_signature()
    streak = 0
    for b in reversed(tail):
        if b.tool_name != last.tool_name or b.input_signature() != last_sig:
            break
        streak += 1
    return streak


def check_tool_pairing(turns: list[NormalizedTurn]) -> tuple[bool, str]:
    """工具调用与回传的配对完整性检查。

    中途切换模型时，若历史里存在无配对 tool_result 的 tool_use（客户端解析
    失败、流中断、provider 返回非协议格式等），严格校验的上游会直接 400。
    这是已知故障模式（2026-09-10 排查），因此切换前必须做协议级配对检查。

    返回 (是否配对完整, 原因)。
    """
    calls: set[str] = set()
    results: list[str] = []
    for t in turns:
        for b in t.tool_calls:
            if b.tool_call_id:
                calls.add(b.tool_call_id)
        for b in t.tool_results:
            results.append(b.tool_call_id)

    orphan_results = [rid for rid in results if rid and rid not in calls]
    if orphan_results:
        return False, "orphan_tool_result"

    # 豁免面必须收窄：只允许**最后一条消息本身是 assistant 轮**时，其内的
    # tool_use 尚无回传（客户端正在请求继续）。早先按 `turns[-2:]` 豁免会把
    # 「assistant 发出 tool_use → 用户直接发文本（打断/截断）」这一**正是要拦
    # 的形态**一并放过，使这道门在最需要它的场景失效。
    exempt: set[str] = set()
    if turns and turns[-1].role == ROLE_ASSISTANT:
        exempt = {b.tool_call_id for b in turns[-1].tool_calls if b.tool_call_id}

    paired = {rid for rid in results if rid}
    unpaired = [cid for cid in calls if cid not in paired and cid not in exempt]
    if unpaired:
        return False, "unpaired_tool_use"

    return True, "ok"


# ---------------------------------------------------------------------------
# 指纹（会话身份 / agent 类型身份）
# ---------------------------------------------------------------------------


def _digest(*parts: str) -> str:
    h = hashlib.sha256()
    for p in parts:
        h.update(p.encode("utf-8", errors="replace"))
        h.update(b"\x00")
    return h.hexdigest()[:16]


SYSTEM_PREFIX_LIMIT = 4096


def system_fingerprint(turns: list[NormalizedTurn]) -> str:
    """system 内容的指纹。

    直接按块累加到上限即停，不走 `NormalizedTurn.text`——后者会把整个
    system（可为数万字符）先拼成一个字符串再截断，在每请求的关键路径上
    白付一次全量拼接。
    """
    buf: list[str] = []
    size = 0
    for t in turns:
        if t.role != ROLE_SYSTEM:
            continue
        for b in t.blocks:
            if b.kind != KIND_TEXT or not b.text:
                continue
            remain = SYSTEM_PREFIX_LIMIT - size
            if remain <= 0:
                return _digest("".join(buf))
            chunk = b.text[:remain]
            buf.append(chunk)
            size += len(chunk)
        break
    return _digest("".join(buf))


def tools_fingerprint(body: dict) -> str:
    """工具名集合的指纹（协议字段：Anthropic `tools[].name`，OpenAI
    `tools[].function.name`）。顺序无关，用排序消除客户端排序差异。"""
    names: list[str] = []
    for t in body.get("tools") or []:
        if not isinstance(t, dict):
            continue
        fn = t.get("function")
        if isinstance(fn, dict):
            names.append(fn.get("name", ""))
        else:
            names.append(t.get("name", ""))
    return _digest("\x01".join(sorted(n for n in names if n)), str(len(names)))


#: task_key 支持的键分量。取值必须来自本集合。
KEY_PART_NAMES = ("system", "tools", "first_user", "latest_user", "profile")

#: 缺省键分量：`latest_user` 保证 loop 内稳定（工具回传轮不是真实用户轮），
#: 同时用户发出新指令即自动分界、升档锁定随之解除。
DEFAULT_KEY_PARTS = ("system", "tools", "latest_user")


def build_fingerprints(
    turns: list[NormalizedTurn], body: dict, key_parts: list[str]
) -> tuple[str, str, list[str]]:
    """按配置的分量构造 (task_key, profile_key, 未知分量列表)。

    - profile_key = system + tools → 一类 agent（主 agent / 各子 agent 天然分离）
    - task_key    = profile_key + 配置指定的分量

    `first_user` 与 `latest_user` 的取舍：
      - `latest_user`（默认）：loop 内稳定（工具回传轮不算真实用户轮），
        用户发出新指令时变化 → 新指令自动分界、锁定随之解除。
      - `first_user`：更抗客户端注入的中间用户轮，但用户在同一对话里追加
        指令**不会**开新会话，升档后的锁定会一直保持到会话结束。

    未知分量不参与构造，并在返回值中列出供调用方告警。
    """
    unknown = [p for p in key_parts if p not in KEY_PART_NAMES]
    parts = {
        "system": system_fingerprint(turns),
        "tools": tools_fingerprint(body),
        "first_user": _digest(first_real_user_text(turns)),
        "latest_user": _digest(last_real_user_text(turns)),
    }
    profile_key = _digest(parts["system"], parts["tools"])
    parts["profile"] = profile_key

    # 有未知分量时**整组退回缺省**，而不是只剔除它：只剔除会让本应「按用户指令
    # 分界」的键退化成「每个 profile 一个常量键」——所有会话共用一个 SessionState，
    # 分类只做一次、轮次跨无关任务累积、检查点变成全局计数。宁可回到已知良好的
    # 缺省组合，也不接受一个语义已经变质的键。
    effective = [
        p
        for p in (key_parts if not unknown else DEFAULT_KEY_PARTS)
        if p in KEY_PART_NAMES
    ] or ["profile"]
    ordered = [parts[p] for p in effective]
    return _digest(*ordered), profile_key, unknown
