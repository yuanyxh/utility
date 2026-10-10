"""客户端特征层：身份白名单 + 客户端注入文案/标签表。

代理面向**通用 agent**，不预设任何单一客户端。本模块是「这个请求来自哪个客户端、
带哪些客户端注入物」的唯一入口：

- **身份白名单**：客户端身份不是协议事实，不能写死在代理逻辑里。历史上
  `proxy_protocol._is_claude_code` 用 UA 子串 / 私有 header 硬编码 Claude Code，
  导致其他客户端在**同一结构**的请求（stream=false + tools 空 + messages ≤ 2）
  下拿不到 classifier 加速——上游为默认 thinking 的模型时响应 28-32s，撞客户端
  超时，agent 的关键操作被拦。现改为可配置白名单，默认含 claude-code。
- **客户端注入文案/标签**：续接提示词、摘要前缀、客户端标签随客户端版本变化且
  各家取值不同，只能作为**可配置表**存在；未命中时保留观测（`client_text_miss`），
  避免新客户端文案悄悄污染 `actual_user_input` 与会话标识锚点。

配置由 Swift 从 config.yaml 序列化后经 env 传入（JSON 侧统一 snake_case）：

- `MODEL_PROXY_CLIENT_ACCEL`：`{"enabled": bool, "clients": [{"name",
  "user_agent_contains": [...], "header_present": [...]}]}`
- `MODEL_PROXY_CLIENT_TEXT`：`{"continuation_prefixes": [...],
  "summary_prefixes": [...], "injected_tags": [...]}`

两者缺省（未注入）时使用内置默认，默认值 = 历史行为，故为**零行为变化**。

配置是**增量补充**而非覆盖：内置默认始终是基线，配置项追加（同名客户端覆盖同名默认项）。
理由：覆盖语义下只写一个字段会把其余默认值静默清空（只加续接前缀 → 标签清理与摘要前缀
双双失效，摘要文本随即混进 `actual_user_input`）——正是本层要消灭的那类静默失效。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

from log_utils import setup_logging

logger = setup_logging("token_proxy", json_format=True)

# ---------------------------------------------------------------------------
# 契约面：与 Swift `TokenProxyManager.clientAccelJSON()/clientTextJSON()` 的字段约定
#
# 启动时对照实际 payload 报出缺失键（`client_config_missing` 告警），
# 并由契约脚本断言 Swift 序列化字段 ⊇ 本集合。
# ---------------------------------------------------------------------------

ACCEL_CONTRACT_KEYS: tuple[str, ...] = ("enabled", "clients")
ACCEL_CLIENT_KEYS: tuple[str, ...] = ("name", "user_agent_contains", "header_present")
CLIENT_TEXT_CONTRACT_KEYS: tuple[str, ...] = (
    "continuation_prefixes",
    "summary_prefixes",
    "injected_tags",
)

# ---------------------------------------------------------------------------
# 内置默认（= 引入配置面之前的行为，逐字等价）
# ---------------------------------------------------------------------------

DEFAULT_ACCEL_CLIENTS: tuple[dict, ...] = (
    # Claude Code 的两个来源信号。**历史实现是 OR**（`x-anthropic-billing-header`
    # 存在，或 UA 含 "claude"，任一即视为 Claude Code）——拆成两条而不是一条的两个
    # 条件：匹配器内部是 AND，OR 由多条表达；写成一条会让只带单一信号的客户端
    # （如裁剪了 billing header 的版本、claude-agent-sdk）静默失去加速。
    # 名字带来源，日志里能分辨是哪条命中。
    {
        "name": "claude-code:billing-header",
        "header_present": ["x-anthropic-billing-header"],
    },
    {"name": "claude-code:user-agent", "user_agent_contains": ["claude"]},
)

DEFAULT_CONTINUATION_PREFIXES: tuple[str, ...] = (
    "This session is being continued from a previous conversation",
)
DEFAULT_SUMMARY_PREFIXES: tuple[str, ...] = ("Summary:",)
DEFAULT_INJECTED_TAGS: tuple[str, ...] = (
    "system-reminder",
    "local-command-caveat",
    "local-command-stdout",
    "command-name",
    "command-message",
    "command-args",
)


@dataclass(frozen=True)
class ClientMatcher:
    """单个客户端的匹配条件。

    语义：`user_agent_contains` 任一命中、`header_present` 全部存在；
    两类都声明时取 **AND**；两类都为空则**不命中**（防误配置把全部流量纳入白名单）。
    """

    name: str = ""
    user_agent_contains: tuple[str, ...] = field(default_factory=tuple)
    header_present: tuple[str, ...] = field(default_factory=tuple)


@dataclass(frozen=True)
class ClientAccel:
    """classifier 加速的客户端白名单。`enabled=False` 时全部不加速。"""

    enabled: bool = True
    clients: tuple[ClientMatcher, ...] = field(default_factory=tuple)


@dataclass(frozen=True)
class ClientText:
    """各客户端的注入文案与前缀/标签表。"""

    continuation_prefixes: tuple[str, ...] = DEFAULT_CONTINUATION_PREFIXES
    summary_prefixes: tuple[str, ...] = DEFAULT_SUMMARY_PREFIXES
    injected_tags: tuple[str, ...] = DEFAULT_INJECTED_TAGS


# ---------------------------------------------------------------------------
# 加载
# ---------------------------------------------------------------------------


def _merge(defaults: tuple[str, ...], configured: tuple[str, ...]) -> tuple[str, ...]:
    """默认在前、配置在后，去重保序（增量补充语义，见模块 docstring）。"""
    out = list(defaults)
    seen = set(defaults)
    for item in configured:
        if item and item not in seen:
            seen.add(item)
            out.append(item)
    return tuple(out)


def _warn_missing(payload: dict, contract: tuple[str, ...], scope: str) -> None:
    missing = [k for k in contract if k not in payload]
    if missing:
        logger.warning(
            json.dumps(
                {
                    "msg": "client_config_missing",
                    "scope": scope,
                    "keys": missing,
                    "effect": "缺失键回退内置默认",
                }
            )
        )


def load_client_accel(raw: str) -> ClientAccel:
    """解析 MODEL_PROXY_CLIENT_ACCEL；缺失/非法 JSON 时回退内置默认白名单。"""
    if not raw:
        return ClientAccel(enabled=True, clients=_builtin_matchers())
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        logger.warning(
            json.dumps({"msg": "client_accel_json_invalid", "effect": "回退内置默认"})
        )
        return ClientAccel(enabled=True, clients=_builtin_matchers())
    if not isinstance(parsed, dict):
        logger.warning(
            json.dumps({"msg": "client_accel_not_object", "effect": "回退内置默认"})
        )
        return ClientAccel(enabled=True, clients=_builtin_matchers())

    _warn_missing(parsed, ACCEL_CONTRACT_KEYS, "clientAccel")

    # 内置默认是基线；配置项同名覆盖、异名追加（见模块 docstring 的增量补充语义）
    matchers: list[ClientMatcher] = list(_builtin_matchers())
    for item in parsed.get("clients") or []:
        if not isinstance(item, dict):
            continue
        _warn_missing(item, ACCEL_CLIENT_KEYS, "clientAccel.clients")
        matcher = _to_matcher(item)
        for i, existing in enumerate(matchers):
            if matcher.name and existing.name == matcher.name:
                matchers[i] = matcher
                break
        else:
            matchers.append(matcher)
    # 唯一的关闭开关是 enabled；clients 只增不减，故不存在「误清空白名单」的路径
    return ClientAccel(
        enabled=bool(parsed.get("enabled", True)), clients=tuple(matchers)
    )


def load_client_text(raw: str) -> ClientText:
    """解析 MODEL_PROXY_CLIENT_TEXT；缺失/非法 JSON 时回退内置默认表。"""
    if not raw:
        return ClientText()
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        logger.warning(
            json.dumps({"msg": "client_text_json_invalid", "effect": "回退内置默认"})
        )
        return ClientText()
    if not isinstance(parsed, dict):
        logger.warning(
            json.dumps({"msg": "client_text_not_object", "effect": "回退内置默认"})
        )
        return ClientText()

    _warn_missing(parsed, CLIENT_TEXT_CONTRACT_KEYS, "clientText")

    def _strs(key: str, fallback: tuple[str, ...]) -> tuple[str, ...]:
        value = parsed.get(key)
        if not isinstance(value, list):
            return fallback
        return _merge(fallback, tuple(str(v) for v in value if str(v)))

    return ClientText(
        continuation_prefixes=_strs(
            "continuation_prefixes", DEFAULT_CONTINUATION_PREFIXES
        ),
        summary_prefixes=_strs("summary_prefixes", DEFAULT_SUMMARY_PREFIXES),
        injected_tags=_strs("injected_tags", DEFAULT_INJECTED_TAGS),
    )


def _builtin_matchers() -> tuple[ClientMatcher, ...]:
    return tuple(_to_matcher(item) for item in DEFAULT_ACCEL_CLIENTS)


def _to_matcher(item: dict) -> ClientMatcher:
    def _tuple_of(key: str) -> tuple[str, ...]:
        value = item.get(key)
        if not isinstance(value, list):
            return ()
        return tuple(str(v).strip() for v in value if str(v).strip())

    return ClientMatcher(
        name=str(item.get("name", "")),
        user_agent_contains=tuple(s.lower() for s in _tuple_of("user_agent_contains")),
        header_present=tuple(s.lower() for s in _tuple_of("header_present")),
    )


# ---------------------------------------------------------------------------
# 匹配
# ---------------------------------------------------------------------------


def _header(headers, name: str) -> str:
    """大小写不敏感地取请求头（aiohttp 的 CIMultiDict 与普通 dict 都支持）。"""
    try:
        value = headers.get(name)
    except Exception:
        value = None
    if value is not None:
        return str(value)
    try:
        for key in headers.keys():
            if isinstance(key, str) and key.lower() == name.lower():
                return str(headers[key])
    except Exception:
        pass
    return ""


def matches_accel_client(headers, accel: ClientAccel) -> str | None:
    """命中的客户端名；未命中或未启用返回 None。

    返回名字而非布尔值——日志要能区分「命中哪个客户端」，否则排查时只能看到
    「没加速」而无法判断是白名单没配还是条件写错。
    """
    if not accel.enabled:
        return None
    ua = _header(headers, "user-agent").lower()
    for matcher in accel.clients:
        if not matcher.user_agent_contains and not matcher.header_present:
            continue
        if matcher.user_agent_contains and not any(
            s in ua for s in matcher.user_agent_contains
        ):
            continue
        if matcher.header_present and not all(
            _header(headers, h) for h in matcher.header_present
        ):
            continue
        return matcher.name or "unnamed"
    return None
