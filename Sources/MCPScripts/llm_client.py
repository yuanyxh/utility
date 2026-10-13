"""The single LLM exit point on the Python side.

Before the migration, three call sites each wrote their own "read config ->
assemble body/headers -> POST -> extract content -> swallow exceptions":
`summary_llm._llm_chat` (sync httpx), `server._check_contradiction` (async
httpx), `proxy_usage.UsageFieldResolver._ask_model` (async aiohttp). The
differences were all incidental; the cost was: changing auth/timeout/thinking
injection required touching three places, and missing one silently degraded;
failure log names differed across sites, preventing unified observability; and
response-body parsing was written once per site too (`content[0].text` vs
`choices[0].message.content`).

This module unifies **config parsing, request construction, auth headers,
protocol differences, timeout defaults, thinking injection, response
extraction, error logging, and the 503 retry policy**; it does **not** unify
the calling style -- summarize is a synchronous call chain (`chat`), while
server/proxy are in asyncio (`achat`). Forcing everything synchronous would
deadlock the event loop, and forcing everything async would require changing
summarize's entire call chain; neither yields any benefit.

The sole source of config is `config.py` (env is injected by Swift); this
module does not read env directly and holds no defaults.
Scope is LLM-only: `summary_llm._HTTP` (the local memory service's generic
httpx client) is not in this list and stays as-is.
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

# Dedicated log file (~/.cache/utility/llm_client.log): the single cross-process
# observability surface for LLM failures, distinguishing call sites by `label`.
# `json_format=True` because this module outputs only JSON structures.
logger = setup_logging("llm_client", json_format=True)

#: Protocol identifiers. Consistent with `proxy_provider`'s values (that is the authority for the provider config surface).
API_OPENAI = "openai"
API_ANTHROPIC = "anthropic"

#: Anthropic protocol version header (single source: shared by the classifier and any anthropic target)
ANTHROPIC_VERSION = "2023-06-01"

#: Default timeout for the synchronous path (seconds). **Single authority =
#: `config.llm_timeout()`** (env `AI_LLM_TIMEOUT` <- `config.yaml ai.llmTimeout`).
#: The three summarize-side call sites originally hardcoded 90 / 120 / 120:
#: scattered values mean "switching to a slower model" requires editing three
#: places, and missing one times out on long context, with nobody knowing which
#: value is actually in effect. When the caller passes `timeout=` explicitly,
#: the caller wins (e.g. the classifier passes remaining time per its own total
#: budget, resolver uses a shorter probe timeout).
DEFAULT_SYNC_TIMEOUT = llm_timeout()
#: Default timeout for the async path (= `proxy_usage`'s 15s before the migration)
DEFAULT_ASYNC_TIMEOUT = 15.0

#: 503 transient retry policy -- **single authority**. The proxy's main
#: forwarding path (`token_proxy.py`) imports these two values as well: the same
#: class of failure (occasional upstream 503) must be handled in both forwarding
#: and LLM calls, and writing the values separately is bound to drift.
#:
#: The default `retry_503=0` means no retry -- most call sites had no retry
#: before the migration, preserving zero behavior change.
#: **Callers that already have their own retry loop must keep it 0** (the
#: classifier retries per `classifier.maxRetries` + total budget): stacking two
#: retry layers amplifies a "bounce-type" upstream into N×M calls and distorts
#: the budget accounting.
DEFAULT_RETRY_503_MAX = 2
DEFAULT_RETRY_503_DELAY = 0.5


@dataclass(frozen=True)
class LLMTarget:
    """The target of one LLM call (endpoint/model/key/protocol).

    The reason the target can be specified explicitly: the classifier hits
    **a particular provider from the providers table**, not the main model in
    the `config.yaml ai` section. When no target is specified,
    `default_target()` (the main model) is used.
    """

    endpoint: str
    model: str
    api_key: str = ""
    api_format: str = API_OPENAI

    @property
    def ready(self) -> bool:
        """Endpoint and model both present = request can be issued.

        **An empty api_key is legal**: a provider config with an empty `apiKey`
        means "pass through the client key", and this target must still be able
        to issue a request (without an auth header). Folding it into the
        can-issue-check would directly break classification for every
        "passthrough key" provider.
        """
        return bool(self.endpoint and self.model)

    @property
    def configured(self) -> bool:
        """Full criterion for the main-model path (including key).

        The main model is a call the proxy issues itself, with no client key to
        pass through; a missing key is necessarily a 401, so callers use this to
        skip early the "construct a prompt only to fail" path.
        """
        return self.ready and bool(self.api_key)


def default_target() -> LLMTarget:
    """Main-model target (`config.yaml ai` section -> env injected by Swift).

    The endpoint's `/chat/completions` is concatenated only here: before the
    migration, three call sites each concatenated the same string, and one
    missing/wrong character meant a 404, which in the old implementation also
    showed only as "returns None" -- a silent failure.
    """
    base = summary_api_url()
    return LLMTarget(
        endpoint=f"{base}/chat/completions" if base else "",
        model=summary_model(),
        api_key=ai_api_key(),
        api_format=API_OPENAI,
    )


def is_configured(target: LLMTarget | None = None) -> bool:
    """Whether the target can be used for a main-model call (including the key criterion)."""
    return (target or default_target()).configured


# ---------------------------------------------------------------------------
# Request construction
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
        # Disabling thinking is a **protocol difference**: Anthropic has a
        # thinking block; the OpenAI protocol has no standard field, so the
        # known reasoning params (reasoning_effort / output_config) are removed.
        if target.api_format == API_ANTHROPIC:
            body["thinking"] = {"type": "disabled"}
        body.pop("reasoning_effort", None)
        body.pop("output_config", None)

    if extra_body:
        # The **sole entry point** for provider-private extensions (e.g. deepseek's
        # OpenAI-compatible endpoint accepts thinking). Such fields are not a
        # protocol fact; putting them in the common layer would make other openai
        # providers receive an unknown field and 400, so the caller must pass
        # them explicitly and explicitly accept the provider binding.
        body.update(extra_body)
    return body


def _extract_text(data: dict, api_format: str) -> str | None:
    """Extract text from the response body, following each protocol's path.

    Return-value semantics align item-by-item with the old implementation:
    - anthropic: a missing `content` is treated as an **empty answer**, not a
      failure (the classifier's existing semantics, returns "");
    - openai: a missing `choices` is treated as a **failure** (the old
      implementation raised KeyError/IndexError here -> returned None).
    Treating the latter as an empty string would hand the caller what looks like
    a successful answer with no content at all.
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
    """Unified failure log.

    `label` preserves each call site's original decision semantics (e.g.
    `usage_resolver_ask_failed`), so "unifying the log name" does not come at
    the cost of losing attributability -- grepping by the old name still works.
    """
    logger.warning(
        json.dumps({"msg": "llm_call_failed", "label": label, "error": error, **extra})
    )


# ---------------------------------------------------------------------------
# Calls
# ---------------------------------------------------------------------------

#: Shared client for the synchronous path (connection reuse; the async side creates one per call -- see the `achat` docstring)
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
    """Synchronous LLM call (httpx). Returns None on failure/unconfigured; does not raise."""
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
    """Asynchronous LLM call (httpx.AsyncClient, created per call).

    Created per call rather than shared at module level: an `AsyncClient`'s
    connection pool binds to the event loop in use at first access, and this
    module is imported by two different processes (MCP server / token proxy) and
    their respective test scripts; a shared instance would fall into the class of
    intermittent failures known as "cross-loop reuse". The old implementation
    (aiohttp creating a session per call) behaved the same way, so this is
    unchanged.
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
# JSON parsing (migrated from summary_llm, logic preserved verbatim)
# ---------------------------------------------------------------------------


def parse_json(raw: str | None) -> dict | None:
    """Extract a JSON object from LLM output. Best-effort: fenced code blocks / surrounding chatter / trailing commas / unescaped quotes."""
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
            # When the LLM copies source text it may bring literal ASCII double quotes into a string value unescaped -> escape and retry
            quoted = _escape_inline_quotes(fixed)
            try:
                return json.loads(quoted, strict=False)
            except json.decoder.JSONDecodeError:
                return None


def _escape_inline_quotes(s: str) -> str:
    """Escape unescaped bare quotes inside string values as \\" (key-ending/value-ending quotes are unaffected)."""
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
