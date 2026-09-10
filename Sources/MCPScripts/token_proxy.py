"""Token 代理监控服务。

拦截 Claude Code → API 的请求，记录 token 用量和请求上下文。

重构（2026-08-30，阶段2）：协议转换/注入 → proxy_protocol.py；
usage 记录 → proxy_usage.py；本入口保留 providers 路由 + HTTP 端点 + 服务启动。
"""

import asyncio
import json
import os
import sys
import time

import aiohttp
from aiohttp import web

from log_utils import setup_logging
from proxy_protocol import (
    ProtocolConverter,
    OpenAIToAnthropicStream,
    _detect_api_format,
    _extract_usage_from_sse,
    _extract_output_from_sse,
    _extract_tool_name_from_sse,
    _is_claude_code,
    _is_classifier_candidate,
    _inject_classifier_disabled,
    _inject_system_prompt,
)
from proxy_usage import DB_PATH, init_db, record_gateway_log, record_usage
from db import conn as dbconn

# ---------------------------------------------------------------------------
# 配置（专属 env；公共配置在 config.py，协议/usage 配置在各自子模块）
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("MODEL_PROXY_PORT", "8080"))
UPSTREAM_URL = os.environ.get("MODEL_PROXY_URL", "")  # 兼容：providers 为空时的单一上游
# providers 路由表（JSON env，Swift 侧从 config.yaml 序列化）：
#   [{"name","url","apiFormat":"anthropic|openai","apiKey","models":[".."]}, ...]
# 路由规则：body.model 精确匹配某 provider.models → 该 provider（上游 model 用原值）；
# 未匹配 → providers[0] 兜底，上游 model 用其 models[0]。
PROVIDERS_JSON = os.environ.get("MODEL_PROXY_PROVIDERS", "")
ROUTER_JSON = os.environ.get("MODEL_PROXY_ROUTER", "")  # 智能路由配置（JSON env）

logger = setup_logging("token_proxy", json_format=True)


def _load_providers() -> list[dict]:
    if not PROVIDERS_JSON:
        return []
    try:
        parsed = json.loads(PROVIDERS_JSON)
        return [p for p in parsed if isinstance(p, dict) and p.get("url")]
    except json.JSONDecodeError:
        logger.warning(
            json.dumps({"msg": "providers_json_invalid", "error": "bad JSON"})
        )
        return []


PROVIDERS = _load_providers()


def _load_router() -> dict:
    """加载智能路由配置。"""
    if not ROUTER_JSON:
        return {}
    try:
        return json.loads(ROUTER_JSON)
    except json.JSONDecodeError:
        logger.warning(json.dumps({"msg": "router_json_invalid", "error": "bad JSON"}))
        return {}


ROUTER = _load_router()
# tier 名 → 模型名映射（从 ROUTER.tiers 读取，配置在 config.yaml modelProxy.router.tiers）
TIERS = ROUTER.get("tiers", {})

CLASSIFY_PROMPT_TEMPLATE = """根据以下用户消息，判断任务类型。只输出 `strong` | `weak`，禁止任何偏好，禁止输出其他内容，否则退回重走。

## 分类标准
- strong：需要深度推理、多步分析、复杂调试、架构设计、创造性写作
- weak：日常编码、简单问答、工具执行、文件操作、格式化、重复性任务

## 用户消息
{last_user_message}
"""


def _resolve_provider(model: str) -> tuple[dict, str]:
    """按 body.model 路由 provider，返回 (provider, 上游模型名)。

    - model 匹配某 provider.models → 该 provider，上游 model 用原值
    - 未匹配 → providers[0] 兜底，上游 model 用其 models[0]
    - providers 为空 → 兼容旧单上游（url + 透传 key）
    """
    for p in PROVIDERS:
        if model in p.get("models", []):
            return p, model
    if PROVIDERS:
        default = PROVIDERS[0]
        models = default.get("models") or ["unknown"]
        return default, models[0]
    return {
        "name": "legacy",
        "url": UPSTREAM_URL,
        "apiFormat": "anthropic",
        "apiKey": "",
    }, model


# ---------------------------------------------------------------------------
# 智能路由：weak 模型分类 → 两级 tier 路由
# ---------------------------------------------------------------------------


def _find_provider_by_name(name: str) -> dict | None:
    """按 name 查找 provider（用于分类器配置引用 providers 中的某个）。"""
    for p in PROVIDERS:
        if p.get("name") == name:
            return p
    return None


def _extract_last_user_message(messages: list) -> str:
    """提取最后一条 user 消息内容（截断 500 字），跳过 tool_result。"""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            content = msg.get("content", "")
            if isinstance(content, list):
                texts = [b.get("text", "") for b in content if b.get("type") == "text"]
                content = " ".join(texts)
            return str(content)[:500]
    return ""


def _is_tool_result_only(messages: list) -> bool:
    """判断最后一条 user 消息是否为纯 tool_result 回传（无文本内容）。

    Claude Code 工具执行后发 tool_result 块回传结果，模型此时在做机械性信息消化，
    不需要深度推理，直接走 weak 模型。
    """
    for msg in reversed(messages):
        if msg.get("role") == "user":
            content = msg.get("content", "")
            if isinstance(content, list):
                # 所有块都是 tool_result → 纯工具回传
                return all(b.get("type") == "tool_result" for b in content)
            # 字符串内容 → 不是纯 tool_result
            return False
    return False


async def _classify_anthropic(prompt: str, provider: dict, timeout_ms: int) -> str:
    """Anthropic 格式分类请求。"""
    url = f"{provider['url']}/messages"
    headers = {"content-type": "application/json", "anthropic-version": "2023-06-01"}
    api_key = provider.get("apiKey", "")
    if api_key:
        headers["x-api-key"] = api_key
    body = {
        "model": provider["models"][0],
        "max_tokens": 10,
        "thinking": {"type": "disabled"},  # 禁用 thinking，加速分类响应
        "messages": [{"role": "user", "content": prompt}],
    }
    timeout = aiohttp.ClientTimeout(total=timeout_ms / 1000)
    async with aiohttp.ClientSession() as session:
        async with session.post(url, json=body, headers=headers, timeout=timeout) as resp:
            data = await resp.json()
            status = resp.status
            content = data.get("content", [{}])
            result = content[0].get("text", "").strip().lower() if content else ""
            logger.info(json.dumps({
                "msg": "classify_response",
                "format": "anthropic",
                "url": url,
                "status": status,
                "result": result,
                "raw_preview": str(data)[:300],
            }))
            if result in ("strong", "weak"):
                return result
            raise ValueError(f"classify_invalid_response: status={status} result={result}")


async def _classify_openai(prompt: str, provider: dict, timeout_ms: int) -> str:
    """OpenAI 格式分类请求。"""
    url = f"{provider['url']}/chat/completions"
    headers = {"content-type": "application/json"}
    api_key = provider.get("apiKey", "")
    if api_key:
        headers["authorization"] = f"Bearer {api_key}"
    body = {
        "model": provider["models"][0],
        "max_tokens": 10,
        "messages": [{"role": "user", "content": prompt}],
    }
    timeout = aiohttp.ClientTimeout(total=timeout_ms / 1000)
    async with aiohttp.ClientSession() as session:
        async with session.post(url, json=body, headers=headers, timeout=timeout) as resp:
            data = await resp.json()
            status = resp.status
            choices = data.get("choices", [])
            result = choices[0].get("message", {}).get("content", "").strip().lower() if choices else ""
            logger.info(json.dumps({
                "msg": "classify_response",
                "format": "openai",
                "url": url,
                "status": status,
                "result": result,
                "raw_preview": str(data)[:300],
            }))
            if result in ("strong", "weak"):
                return result
            raise ValueError(f"classify_invalid_response: status={status} result={result}")


async def _classify_task(request_body: dict) -> str | None:
    """用 weak 模型分类任务。返回 'strong'/'weak'，失败返回 None。"""
    classifier_cfg = ROUTER.get("classifier", {})
    provider_name = classifier_cfg.get("provider", "")
    provider = _find_provider_by_name(provider_name)
    if not provider:
        logger.warning(json.dumps({"msg": "classify_provider_not_found", "provider": provider_name}))
        return None

    messages = request_body.get("messages", [])
    last_msg = _extract_last_user_message(messages)
    if not last_msg:
        return "weak"  # 无用户消息，直接走弱模型

    prompt = CLASSIFY_PROMPT_TEMPLATE.format(last_user_message=last_msg)
    api_format = provider.get("apiFormat", "anthropic")
    timeout_ms = classifier_cfg.get("timeout_ms", 10000)
    max_retries = classifier_cfg.get("max_retries", 3)
    retry_delay = classifier_cfg.get("retry_delay_ms", 500) / 1000
    provider_url = provider.get("url", "")
    provider_model = provider.get("models", ["unknown"])[0]

    logger.info(json.dumps({
        "msg": "classify_request",
        "provider": provider_name,
        "url": f"{provider_url}/messages",
        "model": provider_model,
        "api_format": api_format,
        "prompt_preview": prompt[:200],
        "timeout_ms": timeout_ms,
    }))

    for attempt in range(max_retries):
        t0 = time.monotonic()
        try:
            if api_format == "openai":
                result = await _classify_openai(prompt, provider, timeout_ms)
            else:
                result = await _classify_anthropic(prompt, provider, timeout_ms)
            latency_ms = int((time.monotonic() - t0) * 1000)
            logger.info(json.dumps({
                "msg": "classify_result",
                "provider": provider_name,
                "result": result,
                "latency_ms": latency_ms,
                "attempt": attempt + 1,
            }))
            return result
        except Exception as e:
            latency_ms = int((time.monotonic() - t0) * 1000)
            logger.warning(json.dumps({
                "msg": "classify_retry",
                "provider": provider_name,
                "attempt": attempt + 1,
                "latency_ms": latency_ms,
                "error": str(e),
            }))
            if attempt < max_retries - 1:
                await asyncio.sleep(retry_delay)
    logger.warning(json.dumps({
        "msg": "classify_failed",
        "provider": provider_name,
        "max_retries": max_retries,
    }))
    return None  # 全部失败，fallback weak


async def _route_by_tier(request_body: dict) -> tuple[dict, str] | None:
    """智能路由入口。返回 (provider, model_name) 或 None（使用原始 _resolve_provider）。"""
    if not ROUTER.get("enabled"):
        return None

    # 0. Classifier 候选直接走 weak（与 _is_classifier_candidate 同一逻辑源，消除 Two derivations）
    if _is_classifier_candidate(request_body):
        tier = ROUTER.get("default_tier", "weak")
        model_name = TIERS.get(tier)
        if model_name:
            provider = _find_provider_for_model(model_name)
            if provider:
                return provider, model_name

    # 0.5. 纯 tool_result 回传直接走 weak（机械性信息消化，不需要深度推理）
    if _is_tool_result_only(request_body.get("messages", [])):
        tier = ROUTER.get("default_tier", "weak")
        model_name = TIERS.get(tier)
        if model_name:
            provider = _find_provider_for_model(model_name)
            if provider:
                return provider, model_name

    # 1. LLM 分类
    tier = await _classify_task(request_body)

    # 2. 分类失败 fallback
    if tier is None:
        default_tier = ROUTER.get("default_tier", "weak")
        logger.warning(json.dumps({"msg": "classify_fallback", "tier": default_tier}))
        tier = default_tier

    model_name = TIERS.get(tier)
    if model_name:
        provider = _find_provider_for_model(model_name)
        if provider:
            return provider, model_name
    return None


def _find_provider_for_model(model_name: str) -> dict | None:
    """按模型名查找所属 provider。"""
    for p in PROVIDERS:
        if model_name in p.get("models", []):
            return p
    return None


_logged_first_body: bool = False


async def handle_proxy(request: web.Request) -> web.StreamResponse:
    """转发请求到上游 API，流式返回响应。"""
    if not UPSTREAM_URL and not PROVIDERS:
        return web.json_response(
            {"error": "MODEL_PROXY_URL / MODEL_PROXY_PROVIDERS not configured"},
            status=503,
        )

    # 网关模型发现：GET /open/v1/models → 返回 providers 全部模型。
    # 配合 CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1，/model 选择器列出路由。
    path = request.match_info.get("path", "")
    if request.method == "GET" and path == "v1/models":
        return await _handle_models()

    # 读取请求 body
    body_bytes = await request.read()
    request_body = {}
    try:
        request_body = json.loads(body_bytes) if body_bytes else {}
    except json.JSONDecodeError:
        pass

    # 检测客户端 API 格式（anthropic / openai）
    api_format = _detect_api_format(request_body)

    # 智能路由：weak 模型分类 → 自动选择 strong/weak 模型
    original_model = request_body.get("model", "")
    tier_result = await _route_by_tier(request_body)
    if tier_result:
        # router 返回了 (provider, model_name) — 直接使用，跳过 _resolve_provider
        provider, upstream_model = tier_result
        request_body["model"] = upstream_model
        logger.info(json.dumps({
            "msg": "tier_classify",
            "original_model": original_model,
            "routed_model": upstream_model,
            "provider": provider.get("name", ""),
            "signals": {
                "message_count": len(request_body.get("messages", [])),
                "tool_count": len(request_body.get("tools", [])),
                "has_thinking": "thinking" in request_body or "reasoning_effort" in request_body,
            },
        }))
    else:
        # router 未命中（disabled / 用户手动 /model）→ 走原有 _resolve_provider
        provider, upstream_model = _resolve_provider(request_body.get("model", ""))
        request_body["model"] = upstream_model

    provider_format = provider.get("apiFormat", "anthropic")
    body_bytes = json.dumps(request_body).encode()

    # 构建上游 URL
    # 例: /open/v1/messages → path="v1/messages" → provider.url/v1/messages
    upstream = f"{provider['url']}/{path}"
    if request.query_string:
        upstream += f"?{request.query_string}"

    # 安全分类请求（classifier）关闭 thinking，加速响应。
    # 仅对 Claude Code 来源生效（_is_claude_code 校验请求头），结构启发式识别。
    # 关键路径日志：命中记 info；Claude Code 来源但非 candidate 记 debug，
    # 用于观测形态变化（防静默失效）；非 Claude Code 来源记 debug。
    if _is_claude_code(request.headers):
        if _is_classifier_candidate(request_body):
            _inject_classifier_disabled(request_body, api_format)
            body_bytes = json.dumps(request_body).encode()
            logger.info(
                json.dumps(
                    {
                        "msg": "classifier_thinking_disabled",
                        "model": request_body.get("model", ""),
                        "messages": len(request_body.get("messages", [])),
                        "api_format": api_format,
                    }
                )
            )
        else:
            logger.debug(
                json.dumps(
                    {
                        "msg": "classifier_check_skip",
                        "model": request_body.get("model", ""),
                        "stream": request_body.get("stream"),
                        "tools": len(request_body.get("tools", [])),
                        "messages": len(request_body.get("messages", [])),
                    }
                )
            )
    else:
        logger.debug("classifier_source_not_claude")

    # System prompt 注入：从 System_Prompts.md 读取规则，注入到最后一条真实用户输入前
    injected, rule_target = _inject_system_prompt(request_body)
    if injected is not None:
        body_bytes = injected

    # 首次请求日志：输出注入后的完整 body，用于验证系统提示词生效
    global _logged_first_body
    if not _logged_first_body:
        _logged_first_body = True
        try:
            parsed = json.loads(body_bytes)
            # 只输出 system 字段、rule 注入命中和 model，避免刷屏
            log_body = {
                "model": parsed.get("model", ""),
                "rule_target": rule_target,
                "system": (
                    parsed.get("system")
                    if api_format == "anthropic"
                    else parsed.get("messages", [{}])[0]
                ),
            }
            logger.info(
                json.dumps(
                    {
                        "msg": "first_request_body",
                        "api_format": api_format,
                        "body_debug": log_body,
                    }
                )
            )
        except Exception as e:
            logger.warning(
                json.dumps({"msg": "first_body_log_failed", "error": str(e)})
            )

    # 记录转换前的原始（注入后）请求体，供 record_usage 上下文提取（结构是客户端格式）
    record_request_body = json.loads(body_bytes) if body_bytes else {}

    # 请求协议转换：客户端 anthropic ↔ provider openai（网关标准映射）
    if api_format == "anthropic" and provider_format == "openai":
        request_body = json.loads(body_bytes)
        request_body = ProtocolConverter.request_anthropic_to_openai(request_body)
        body_bytes = json.dumps(request_body).encode()
        logger.debug(
            json.dumps(
                {
                    "msg": "request_converted",
                    "direction": "anthropic_to_openai",
                    "provider": provider.get("name", ""),
                }
            )
        )
    elif api_format == "openai" and provider_format == "anthropic":
        request_body = json.loads(body_bytes)
        request_body = ProtocolConverter.request_openai_to_anthropic(request_body)
        body_bytes = json.dumps(request_body).encode()
        logger.debug(
            json.dumps(
                {
                    "msg": "request_converted",
                    "direction": "openai_to_anthropic",
                    "provider": provider.get("name", ""),
                }
            )
        )

    # 转发 headers（透传，但按 provider 替换鉴权 key）
    headers = {}
    skip_headers = {"host", "content-length", "transfer-encoding"}
    for k, v in request.headers.items():
        if k.lower() not in skip_headers:
            headers[k] = v
    api_key = provider.get("apiKey", "")
    if api_key:
        headers.pop("x-api-key", None)
        headers.pop("authorization", None)
        if provider_format == "openai":
            headers["Authorization"] = f"Bearer {api_key}"
        else:
            headers["x-api-key"] = api_key

    start_time = time.monotonic()

    # 503 瞬时重试：上游（deepseek 等 provider）偶发返回 503（"temporarily unavailable"），
    # 命中 Claude Code 的 classifier 调用时会导致 Bash 被拦截。等待后重试，最多 3 次。
    RETRY_MAX = 2  # 额外重试次数
    RETRY_DELAY = 0.5  # 重试间隔（秒）
    for attempt in range(RETRY_MAX + 1):
        try:
            async with aiohttp.ClientSession() as session:
                async with session.request(
                    method=request.method,
                    url=upstream,
                    headers=headers,
                    data=body_bytes,
                    timeout=aiohttp.ClientTimeout(
                        total=300,
                        sock_connect=10,
                        sock_read=120,
                    ),
                ) as upstream_resp:
                    latency_ms = int((time.monotonic() - start_time) * 1000)

                    # 上游瞬时 503：放弃本次连接，等待后重试
                    if upstream_resp.status == 503 and attempt < RETRY_MAX:
                        logger.warning(
                            json.dumps(
                                {
                                    "msg": "proxy_retry",
                                    "path": f"/open/{path}",
                                    "attempt": attempt + 1,
                                    "latency_ms": latency_ms,
                                    "model": request_body.get("model", ""),
                                }
                            )
                        )
                        await asyncio.sleep(RETRY_DELAY)
                        continue

                    # 流式转发响应
                    response = web.StreamResponse(
                        status=upstream_resp.status,
                        headers={
                            k: v
                            for k, v in upstream_resp.headers.items()
                            if k.lower()
                            not in {"transfer-encoding", "content-encoding"}
                        },
                    )
                    await response.prepare(request)

                    # 收集 SSE chunks 以提取 usage
                    collected_body = bytearray()
                    is_sse = "text/event-stream" in upstream_resp.headers.get(
                        "content-type", ""
                    )
                    # 流中断时的异常信息，供 record_usage 记录
                    stream_error = ""

                    # 上游 openai → 客户端 anthropic：响应需转换（Claude Code 场景）
                    convert_resp = (
                        provider_format == "openai" and api_format == "anthropic"
                    )
                    converter = (
                        OpenAIToAnthropicStream() if (convert_resp and is_sse) else None
                    )

                    try:
                        if converter is not None:
                            # 流式转换：逐行缓冲 openai SSE → anthropic SSE 事件
                            line_buffer = ""
                            async for chunk in upstream_resp.content.iter_any():
                                line_buffer += chunk.decode("utf-8", errors="replace")
                                lines = line_buffer.split("\n")
                                line_buffer = lines.pop()
                                parts: list[str] = []
                                for line in lines:
                                    line = line.strip()
                                    if not line.startswith("data: "):
                                        continue
                                    data_str = line[6:].strip()
                                    if data_str == "[DONE]":
                                        continue
                                    try:
                                        oc = json.loads(data_str)
                                    except json.JSONDecodeError:
                                        continue
                                    parts.extend(converter.feed(oc))
                                if parts:
                                    payload = "".join(parts).encode()
                                    await response.write(payload)
                                    collected_body.extend(payload)
                            # 收尾：content_block_stop / message_delta / message_stop
                            if not stream_error:
                                tail = converter.finish()
                                if tail:
                                    payload = "".join(tail).encode()
                                    await response.write(payload)
                                    collected_body.extend(payload)
                        elif convert_resp and not is_sse:
                            # 非流式转换：先收完整 JSON body 再整体转换
                            raw_body = bytearray()
                            async for chunk in upstream_resp.content.iter_any():
                                raw_body.extend(chunk)
                            try:
                                resp_json = json.loads(bytes(raw_body))
                                converted = (
                                    ProtocolConverter.response_openai_to_anthropic(
                                        resp_json
                                    )
                                )
                                payload = json.dumps(converted).encode()
                            except Exception as e:
                                stream_error = f"convert_error: {e}"
                                payload = bytes(raw_body)
                            await response.write(payload)
                            collected_body.extend(payload)
                        else:
                            # 直通（同格式）
                            async for chunk in upstream_resp.content.iter_any():
                                await response.write(chunk)
                                # 收集 SSE chunks 以提取 usage；400 等错误响应为非 SSE JSON，
                                # 也收集以记录响应体定位错误（临时增强）
                                if is_sse or upstream_resp.status >= 400:
                                    collected_body.extend(chunk)
                    except (
                        ConnectionResetError,
                        BrokenPipeError,
                        RuntimeError,
                        asyncio.CancelledError,
                    ) as e:
                        # 客户端已断开连接或 transport 关闭，停止转发
                        stream_error = f"{type(e).__name__}: {e}"

                    await response.write_eof()

                    # 提取 usage / 输出预览 / 工具名
                    sse_bytes = bytes(collected_body) if collected_body else b""
                    if converter is not None:
                        # 转换器已归一化 usage（含 input/output tokens）
                        usage_data = dict(converter.usage)
                        out_format = "anthropic"
                    elif convert_resp and not is_sse:
                        converted_usage = {}
                        try:
                            parsed = json.loads(
                                sse_bytes.decode("utf-8", errors="replace")
                            )
                            converted_usage = (
                                parsed.get("usage", {})
                                if isinstance(parsed, dict)
                                else {}
                            )
                        except (json.JSONDecodeError, UnicodeDecodeError):
                            pass
                        usage_data = {
                            "input_tokens": converted_usage.get("input_tokens", 0),
                            "output_tokens": converted_usage.get("output_tokens", 0),
                        }
                        out_format = "anthropic"
                    else:
                        usage_data = (
                            _extract_usage_from_sse(sse_bytes, api_format=api_format)
                            if is_sse and sse_bytes
                            else None
                        )
                        out_format = api_format

                    if usage_data:
                        # 补充 model：部分 API 的 SSE 响应不含 model 字段
                        if not usage_data.get("model"):
                            usage_data["model"] = request_body.get("model", "unknown")
                        output_preview = (
                            _extract_output_from_sse(sse_bytes, api_format=out_format)
                            if sse_bytes
                            else ""
                        )
                        tool_name = (
                            _extract_tool_name_from_sse(
                                sse_bytes, api_format=out_format
                            )
                            if sse_bytes
                            else ""
                        )
                        # 提取错误信息（优先流中断异常，其次上游 error body）
                        error_message = stream_error
                        if not error_message and upstream_resp.status >= 400:
                            try:
                                error_body = json.loads(
                                    sse_bytes.decode("utf-8", errors="replace")
                                )
                                if "error" in error_body:
                                    error_data = error_body["error"]
                                    if isinstance(error_data, dict):
                                        error_message = error_data.get(
                                            "message", str(error_data)
                                        )
                                    else:
                                        error_message = str(error_data)
                            except (json.JSONDecodeError, UnicodeDecodeError):
                                pass
                        asyncio.create_task(
                            record_usage(
                                record_request_body,
                                usage_data,
                                upstream_resp.status,
                                latency_ms,
                                output_preview,
                                error_message,
                                tool_name_override=tool_name,
                                api_format=api_format,
                            )
                        )

                    logger.info(
                        json.dumps(
                            {
                                "msg": "proxy_request",
                                "method": request.method,
                                "path": f"/open/{path}",
                                "status": upstream_resp.status,
                                "latency_ms": latency_ms,
                                "model": request_body.get("model", ""),
                            }
                        )
                    )

                    # 临时增强：记录 >=400 错误响应体，定位 deepseek 上下文超限 400 的具体错误
                    if upstream_resp.status >= 400 and sse_bytes:
                        logger.warning(
                            json.dumps(
                                {
                                    "msg": "proxy_http_error_body",
                                    "model": request_body.get("model", ""),
                                    "status": upstream_resp.status,
                                    "latency_ms": latency_ms,
                                    "body": sse_bytes.decode("utf-8", errors="replace")[
                                        :500
                                    ],
                                }
                            )
                        )

                    return response

        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            latency_ms = int((time.monotonic() - start_time) * 1000)
            logger.error(
                json.dumps(
                    {
                        "msg": "proxy_error",
                        "path": f"/open/{path}",
                        "error": str(e),
                        "latency_ms": latency_ms,
                    }
                )
            )
            return web.json_response(
                {"error": f"upstream_error: {e}"},
                status=502,
            )


async def _handle_models() -> web.Response:
    """GET /v1/models：返回 providers 全部模型（Anthropic models API 格式）。

    配合 Claude Code 的 CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1，
    /model 选择器直接列出代理路由的模型。
    """
    data = []
    for p in PROVIDERS:
        pname = p.get("name", "")
        for m in p.get("models", []):
            data.append(
                {
                    "type": "model",
                    "id": m,
                    "display_name": f"{pname} · {m}",
                    "created_at": "2026-01-01T00:00:00Z",
                }
            )
    if not data:
        data.append(
            {
                "type": "model",
                "id": "unknown",
                "display_name": "unknown",
                "created_at": "2026-01-01T00:00:00Z",
            }
        )
    return web.json_response(
        {
            "data": data,
            "has_more": False,
            "first_id": data[0]["id"],
            "last_id": data[-1]["id"],
        }
    )


async def handle_health(request: web.Request) -> web.Response:
    """健康检查端点。"""
    return web.json_response({"status": "ok"})


async def handle_usage_summary(request: web.Request) -> web.Response:
    """今日用量摘要（供 Swift 查询）。"""
    try:
        with dbconn(DB_PATH) as conn:
            row = conn.execute("""
                SELECT
                    COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(output_tokens), 0),
                    COALESCE(SUM(cache_read_tokens), 0),
                    COUNT(*),
                    SUM(CASE WHEN response_valid = 0 THEN 1 ELSE 0 END)
                FROM api_usage
                WHERE timestamp >= date('now', 'start of day')
            """).fetchone()

        return web.json_response(
            {
                "input_tokens": row[0],
                "output_tokens": row[1],
                "cache_read_tokens": row[2],
                "total_requests": row[3],
                "invalid_requests": row[4] or 0,
            }
        )
    except Exception as e:
        return web.json_response({"error": str(e)}, status=500)


async def handle_usage_layers(request: web.Request) -> web.Response:
    """分层查询：核心交换（end_turn）+ 过程记录（tool_use）。"""
    try:
        level = request.query.get("level", "core")
        limit = int(request.query.get("limit", "50"))
        offset = int(request.query.get("offset", "0"))

        with dbconn(DB_PATH) as conn:
            if level == "core":
                # 只查询 end_turn（核心交换）
                rows = conn.execute(
                    """
                    SELECT id, timestamp, actual_user_input, input_preview, output_preview,
                           input_tokens, output_tokens, stop_reason, latency_ms, model
                    FROM api_usage
                    WHERE stop_reason = 'end_turn'
                    ORDER BY timestamp DESC
                    LIMIT ? OFFSET ?
                """,
                    (limit, offset),
                ).fetchall()

                result = []
                for r in rows:
                    result.append(
                        {
                            "id": r[0],
                            "timestamp": r[1],
                            "user_input": r[2]
                            or r[3],  # actual_user_input 优先，fallback 到 input_preview
                            "output": r[4],
                            "input_tokens": r[5],
                            "output_tokens": r[6],
                            "stop_reason": r[7],
                            "latency_ms": r[8],
                            "model": r[9],
                        }
                    )
            elif level == "process":
                # 查询 tool_use 过程记录
                rows = conn.execute(
                    """
                    SELECT id, timestamp, tool_name, input_tokens, output_tokens,
                           latency_ms, parent_id
                    FROM api_usage
                    WHERE stop_reason = 'tool_use'
                    ORDER BY timestamp DESC
                    LIMIT ? OFFSET ?
                """,
                    (limit, offset),
                ).fetchall()

                result = []
                for r in rows:
                    result.append(
                        {
                            "id": r[0],
                            "timestamp": r[1],
                            "tool_name": r[2],
                            "input_tokens": r[3],
                            "output_tokens": r[4],
                            "latency_ms": r[5],
                            "parent_id": r[6],
                        }
                    )
            else:
                # 查询所有
                rows = conn.execute(
                    """
                    SELECT id, timestamp, request_level, input_preview, output_preview,
                           input_tokens, output_tokens, stop_reason, latency_ms, tool_name
                    FROM api_usage
                    ORDER BY timestamp DESC
                    LIMIT ? OFFSET ?
                """,
                    (limit, offset),
                ).fetchall()

                result = []
                for r in rows:
                    result.append(
                        {
                            "id": r[0],
                            "timestamp": r[1],
                            "level": r[2],
                            "input": r[3],
                            "output": r[4],
                            "input_tokens": r[5],
                            "output_tokens": r[6],
                            "stop_reason": r[7],
                            "latency_ms": r[8],
                            "tool_name": r[9],
                        }
                    )

        return web.json_response(result)
    except Exception as e:
        return web.json_response({"error": str(e)}, status=500)


# ---------------------------------------------------------------------------
# 网关层日志：middleware 统一记录被拒/失败/超大请求，补 api_usage 的排查盲区。
# 记录实现（record_gateway_log + 常量 + gateway_log 表）已归口 proxy_usage.py，
# 本入口只保留 middleware 捕获异常并调用，不再重复维护连接样板。
# ---------------------------------------------------------------------------

@web.middleware
async def gateway_log_middleware(request, handler):
    """包裹所有路由：捕获异常（含 aiohttp 413 超限）并记录网关日志，不改变原有行为。"""
    start = time.monotonic()
    method = request.method
    path = request.path
    content_length = request.content_length or 0
    status_code = 0
    error_type = error_message = None
    try:
        resp = await handler(request)
        status_code = resp.status
    except web.HTTPException as e:
        status_code = e.status
        error_type = type(e).__name__
        error_message = e.text
        raise
    except Exception as e:
        status_code = 500
        error_type = type(e).__name__
        error_message = str(e)
        raise
    finally:
        latency_ms = int((time.monotonic() - start) * 1000)
        record_gateway_log(
            method,
            path,
            content_length,
            status_code,
            error_type,
            error_message,
            latency_ms,
        )
    return resp


def create_app() -> web.Application:
    # aiohttp 默认 client_max_size 仅 1MB，Claude Code 请求体（含 CLAUDE.md/skills/MCP 工具定义）
    # 超过后直接 413 "Maximum request body size exceeded"，转发到不了上游。
    # 设 64MB 留余量，由客户端 32MB 检查兜底，代理不再成为瓶颈。
    app = web.Application(client_max_size=64 * 1024 * 1024)
    app.middlewares.append(gateway_log_middleware)
    app.router.add_route("*", "/health", handle_health)
    app.router.add_route("GET", "/usage/summary", handle_usage_summary)
    app.router.add_route("GET", "/usage/layers", handle_usage_layers)
    app.router.add_route("*", "/open/{path:.*}", handle_proxy)
    return app


def main():
    if not UPSTREAM_URL and not PROVIDERS:
        logger.error(
            json.dumps(
                {
                    "msg": "startup_failed",
                    "error": "MODEL_PROXY_URL / MODEL_PROXY_PROVIDERS not set",
                }
            )
        )
        sys.exit(1)

    init_db()
    logger.info(
        json.dumps(
            {
                "msg": "startup",
                "port": PORT,
                "upstream": UPSTREAM_URL,
                "providers": [p.get("name", "") for p in PROVIDERS],
                "db": DB_PATH,
            }
        )
    )

    app = create_app()
    web.run_app(app, host="127.0.0.1", port=PORT, print=None)


if __name__ == "__main__":
    main()
