"""Python 侧唯一 LLM 出口。

迁移前四个调用点各写一份「读配置 → 拼 body/头 → POST → 取 content → 异常吞掉」：
`summary_llm._llm_chat`（同步 httpx）、`server._check_contradiction`（异步 httpx）、
`proxy_usage.UsageFieldResolver._ask_model`（异步 aiohttp）、
`proxy_router._classify_anthropic/_classify_openai`（异步 aiohttp）。差异都是偶然的，
代价是：改鉴权/超时/thinking 注入要动四处，漏一处即静默降级；各处的失败日志名不同，
无法统一观测；解析响应体的方式也各写一遍（`content[0].text` vs `choices[0].message.content`）。

本模块统一**配置解析、请求构造、鉴权头、协议差异、超时默认、thinking 注入、响应提取、
错误日志、503 重试策略**；**不统一调用风格**——summarize 是同步调用链（`chat`），
server/proxy 在 asyncio 里（`achat`）。强行同步化会卡死事件循环，强行异步化要改
summarize 的全部调用链，两者收益都为零。

配置唯一来源是 `config.py`（env 由 Swift 注入），本模块不直接读 env、不持默认值。
范围仅限 LLM：`summary_llm._HTTP`（本地记忆服务的通用 httpx 客户端）不属此列，保持原样。
"""

from __future__ import annotations

import asyncio
import json
import re
import time
from dataclasses import dataclass

import httpx

from config import ai_api_key, llm_timeout, summary_api_url, summary_model
from log_utils import setup_logging

# 独立日志文件（~/.cache/utility/llm_client.log）：跨进程的唯一 LLM 失败观测面，
# 按 `label` 区分调用点。`json_format=True` 是因为本模块输出全是 JSON 结构。
logger = setup_logging("llm_client", json_format=True)

#: 协议标识。与 `proxy_provider` 的取值一致（那里是 provider 配置面的权威）。
API_OPENAI = "openai"
API_ANTHROPIC = "anthropic"

#: Anthropic 协议的版本头（单一来源：分类器与任何 anthropic 目标共用）
ANTHROPIC_VERSION = "2023-06-01"

#: 同步链路默认超时（秒）。**单一权威 = `config.llm_timeout()`**（env `AI_LLM_TIMEOUT`
#: ← `config.yaml ai.llmTimeout`）。三处 summarize 侧调用点原先各自写死 90 / 120 / 120：
#: 值分散意味着「换个慢模型」要改三处、漏一处就在长上下文上超时失败，且没人知道
#: 到底哪个值在生效。调用方显式传 `timeout=` 时以调用方为准（如分类器按自己的总预算
#: 传剩余时间、resolver 用更短的探测超时）。
DEFAULT_SYNC_TIMEOUT = llm_timeout()
#: 异步链路默认超时（= 迁移前 `proxy_usage` 的 15s）
DEFAULT_ASYNC_TIMEOUT = 15.0

#: 503 瞬时重试策略——**单一权威**。代理主转发路径（`token_proxy.py`）也 import 这两个值：
#: 同一类故障（上游偶发 503）在转发与 LLM 调用两处都要处理，值分开写必然漂移。
#:
#: 缺省 `retry_503=0` 即不重试——迁移前多数调用点本就没有重试，保持零行为变化。
#: **已有自带重试环的调用方必须保持 0**（分类器按 `classifier.maxRetries` + 总预算重试）：
#: 两层重试叠加会把「打转型」上游放大成 N×M 次调用，且预算账目失真。
DEFAULT_RETRY_503_MAX = 2
DEFAULT_RETRY_503_DELAY = 0.5


@dataclass(frozen=True)
class LLMTarget:
    """一次 LLM 调用的目标（端点/模型/key/协议）。

    之所以能显式指定目标：分类器打的是 **providers 表里的某个 provider**，不是
    `config.yaml ai` 段的主模型。不指定目标时用 `default_target()`（主模型）。
    """

    endpoint: str
    model: str
    api_key: str = ""
    api_format: str = API_OPENAI

    @property
    def ready(self) -> bool:
        """端点与模型齐备 = 可发起请求。

        **api_key 为空是合法的**：provider 配置的 `apiKey` 留空表示「透传客户端 key」，
        这个目标仍然要能发出请求（不带鉴权头）。把它并进可发起判据会让所有
        「透传 key」的 provider 分类直接失效。
        """
        return bool(self.endpoint and self.model)

    @property
    def configured(self) -> bool:
        """主模型路径的完整判据（含 key）。

        主模型是代理自己发起的调用，没有客户端 key 可透传，缺 key 必然 401，
        故调用方用它提前跳过「注定失败还要构造 prompt」的路径。
        """
        return self.ready and bool(self.api_key)


def default_target() -> LLMTarget:
    """主模型目标（`config.yaml ai` 段 → Swift 注入的 env）。

    endpoint 的 `/chat/completions` 只在这里拼一次：迁移前三个调用点各自拼同一字符串，
    少拼/拼错一个字符就是 404，而 404 在旧实现里同样只表现为「返回 None」——静默失败。
    """
    base = summary_api_url()
    return LLMTarget(
        endpoint=f"{base}/chat/completions" if base else "",
        model=summary_model(),
        api_key=ai_api_key(),
        api_format=API_OPENAI,
    )


def is_configured(target: LLMTarget | None = None) -> bool:
    """目标是否可用于主模型调用（含 key 判据）。"""
    return (target or default_target()).configured


# ---------------------------------------------------------------------------
# 请求构造
# ---------------------------------------------------------------------------


def _headers(target: LLMTarget) -> dict[str, str]:
    headers = {"content-type": "application/json"}
    if target.api_format == API_ANTHROPIC:
        headers["anthropic-version"] = ANTHROPIC_VERSION
        if target.api_key:
            headers["x-api-key"] = target.api_key
    elif target.api_key:
        headers["authorization"] = f"Bearer {target.api_key}"
    return headers


def _body(
    prompt: str,
    target: LLMTarget,
    *,
    system: str | None,
    temperature: float | None,
    max_tokens: int | None,
    disable_thinking: bool,
    extra_body: dict | None,
) -> dict:
    messages: list[dict] = [{"role": "user", "content": prompt}]
    if system:
        messages.insert(0, {"role": "system", "content": system})

    body: dict = {"model": target.model, "messages": messages}
    if temperature is not None:
        body["temperature"] = temperature
    if max_tokens:
        body["max_tokens"] = max_tokens

    if disable_thinking:
        # 关思考是**协议差异**：Anthropic 有 thinking 块；OpenAI 协议无标准字段，
        # 只能删掉已知的推理参数（reasoning_effort / output_config）。
        if target.api_format == API_ANTHROPIC:
            body["thinking"] = {"type": "disabled"}
        body.pop("reasoning_effort", None)
        body.pop("output_config", None)

    if extra_body:
        # provider 私有扩展的**唯一入口**（如 deepseek 的 OpenAI 兼容端点接受 thinking）。
        # 这类字段不是协议事实，写进公共层会让其他 openai provider 收到未知字段而 400，
        # 故只能由调用方显式传出、显式承担 provider 绑定。
        body.update(extra_body)
    return body


def _extract_text(data: dict, api_format: str) -> str | None:
    """从响应体取文本，按协议走各自的路径。

    返回值语义与旧实现逐条对齐：
    - anthropic：缺 `content` 视为**空答案**而非失败（分类器既有语义，返回 ""）；
    - openai：缺 `choices` 视为**失败**（旧实现这里会抛 KeyError/IndexError → 返回 None）。
    把后者也当成空字符串会让调用方拿到一个看似成功、实则没有任何内容的答案。
    """
    if api_format == API_ANTHROPIC:
        blocks = data.get("content") or []
        if blocks and isinstance(blocks[0], dict):
            return blocks[0].get("text") or ""
        return ""
    choices = data.get("choices") or []
    if not choices or not isinstance(choices[0], dict):
        return None
    return (choices[0].get("message") or {}).get("content")


def _log_failure(label: str, error: str, **extra) -> None:
    """统一的失败日志。

    `label` 保留各调用点原来的判定语义（如 `usage_resolver_ask_failed`），
    使「统一日志名」不以丢失可归因性为代价——按旧名 grep 仍能命中。
    """
    logger.warning(
        json.dumps({"msg": "llm_call_failed", "label": label, "error": error, **extra})
    )


# ---------------------------------------------------------------------------
# 调用
# ---------------------------------------------------------------------------

#: 同步链路共享客户端（连接复用；异步侧每次调用新建——见 `achat` 注释）
_SYNC_CLIENT = httpx.Client()


def chat(
    prompt: str,
    *,
    system: str | None = None,
    temperature: float | None = None,
    max_tokens: int | None = None,
    timeout: float | None = None,
    disable_thinking: bool = False,
    extra_body: dict | None = None,
    target: LLMTarget | None = None,
    label: str = "llm_chat",
    retry_503: int = 0,
    retry_delay: float = DEFAULT_RETRY_503_DELAY,
) -> str | None:
    """同步 LLM 调用（httpx）。失败/未配置返回 None，不抛异常。"""
    tgt = target or default_target()
    if not tgt.ready:
        logger.debug(json.dumps({"msg": "llm_not_configured", "label": label}))
        return None

    body = _body(
        prompt,
        tgt,
        system=system,
        temperature=temperature,
        max_tokens=max_tokens,
        disable_thinking=disable_thinking,
        extra_body=extra_body,
    )
    attempt_limit = max(0, retry_503) + 1
    for attempt in range(attempt_limit):
        try:
            resp = _SYNC_CLIENT.post(
                tgt.endpoint,
                json=body,
                headers=_headers(tgt),
                timeout=timeout or DEFAULT_SYNC_TIMEOUT,
            )
            if resp.status_code == 503 and attempt < attempt_limit - 1:
                logger.warning(
                    json.dumps(
                        {"msg": "llm_retry_503", "label": label, "attempt": attempt + 1}
                    )
                )
                time.sleep(retry_delay)
                continue
            if resp.status_code >= 400:
                _log_failure(label, f"HTTP {resp.status_code}", status=resp.status_code)
                return None
            return _extract_text(resp.json(), tgt.api_format)
        except Exception as e:
            _log_failure(label, f"{type(e).__name__}: {e}")
            return None
    return None


async def achat(
    prompt: str,
    *,
    system: str | None = None,
    temperature: float | None = None,
    max_tokens: int | None = None,
    timeout: float | None = None,
    disable_thinking: bool = False,
    extra_body: dict | None = None,
    target: LLMTarget | None = None,
    label: str = "llm_achat",
    retry_503: int = 0,
    retry_delay: float = DEFAULT_RETRY_503_DELAY,
) -> str | None:
    """异步 LLM 调用（httpx.AsyncClient，每次调用新建）。

    每次新建而非共享模块级客户端：`AsyncClient` 的连接池绑定首次使用时的 event loop，
    而本模块被两个不同进程（MCP server / token proxy）与各自的测试脚本导入，
    共享实例会落在「跨 loop 复用」这一类偶发故障上。旧实现（aiohttp 每次建 session）
    也是这个行为，故不改。
    """
    tgt = target or default_target()
    if not tgt.ready:
        logger.debug(json.dumps({"msg": "llm_not_configured", "label": label}))
        return None

    body = _body(
        prompt,
        tgt,
        system=system,
        temperature=temperature,
        max_tokens=max_tokens,
        disable_thinking=disable_thinking,
        extra_body=extra_body,
    )
    attempt_limit = max(0, retry_503) + 1
    for attempt in range(attempt_limit):
        try:
            async with httpx.AsyncClient() as client:
                resp = await client.post(
                    tgt.endpoint,
                    json=body,
                    headers=_headers(tgt),
                    timeout=timeout or DEFAULT_ASYNC_TIMEOUT,
                )
            if resp.status_code == 503 and attempt < attempt_limit - 1:
                logger.warning(
                    json.dumps(
                        {"msg": "llm_retry_503", "label": label, "attempt": attempt + 1}
                    )
                )
                await asyncio.sleep(retry_delay)
                continue
            if resp.status_code >= 400:
                _log_failure(label, f"HTTP {resp.status_code}", status=resp.status_code)
                return None
            return _extract_text(resp.json(), tgt.api_format)
        except Exception as e:
            _log_failure(label, f"{type(e).__name__}: {e}")
            return None
    return None


# ---------------------------------------------------------------------------
# JSON 解析（自 summary_llm 迁移，逐字保留逻辑）
# ---------------------------------------------------------------------------


def parse_json(raw: str | None) -> dict | None:
    """从 LLM 输出里抠出 JSON 对象。尽力而为：围栏代码块 / 前后废话 / 尾逗号 / 裸引号。"""
    if not raw:
        return None
    raw = raw.strip()
    m = re.search(r"```json\s*\n(.+?)\n\s*```", raw, re.DOTALL)
    if not m:
        m = re.search(r"```\s*\n(.+?)\n\s*```", raw, re.DOTALL)
    if not m:
        m = re.search(r"\{.*\}", raw, re.DOTALL)
    json_str = m.group(1) if m and m.lastindex else (m.group(0) if m else raw)
    start, end = json_str.find("{"), json_str.rfind("}")
    if start != -1 and end != -1:
        json_str = json_str[start : end + 1]
    try:
        return json.loads(json_str, strict=False)
    except json.decoder.JSONDecodeError:
        fixed = re.sub(r",\s*([}\]])", r"\1", json_str)
        try:
            return json.loads(fixed, strict=False)
        except json.decoder.JSONDecodeError:
            # LLM 复制原文时可能把英文双引号原样带进字符串值且未转义 → 转义后重试
            quoted = _escape_inline_quotes(fixed)
            try:
                return json.loads(quoted, strict=False)
            except json.decoder.JSONDecodeError:
                return None


def _escape_inline_quotes(s: str) -> str:
    """把字符串值内未转义的裸引号转义为 \\"（键结束/值结束引号不受影响）。"""
    out = []
    in_str = False
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if in_str:
            if c == "\\":
                out.append(c)
                if i + 1 < n:
                    out.append(s[i + 1])
                    i += 2
                    continue
            elif c == '"':
                j = i + 1
                while j < n and s[j] in " \t":
                    j += 1
                if j < n and s[j] in ",}]:":
                    in_str = False
                    out.append(c)
                else:
                    out.append('\\"')
            else:
                out.append(c)
        else:
            if c == '"':
                in_str = True
            out.append(c)
        i += 1
    return "".join(out)
