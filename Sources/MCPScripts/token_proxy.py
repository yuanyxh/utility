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

import llm_client
from log_utils import setup_logging
from proxy_protocol import (
    ProtocolConverter,
    OpenAIToAnthropicStream,
    _detect_api_format,
    _extract_usage_from_sse,
    _extract_output_from_sse,
    _extract_tool_name_from_sse,
    _is_classifier_candidate,
    _inject_classifier_disabled,
    _inject_system_prompt,
)
from proxy_client import load_client_accel, matches_accel_client
from proxy_provider import api_format_of, api_key_of, missing_keys
from proxy_usage import (
    DB_PATH,
    TOOL_OUTPUT_DB_PATH,
    init_db,
    init_tool_output_db,
    record_gateway_log,
    record_usage,
    extract_tool_outputs,
)
from db import conn as dbconn
from config import ui_language
from proxy_skill_dedup import dedup_tool_results
from proxy_output_filter import OUTPUT_FILTER_ENV_KEY, filter_tool_outputs

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
# classifier 加速的客户端白名单（JSON env，Swift 侧从 config.yaml modelProxy.clientAccel
# 序列化；缺省为空串 → proxy_client 用内置默认白名单，即历史行为）
CLIENT_ACCEL_JSON = os.environ.get("MODEL_PROXY_CLIENT_ACCEL", "")
# skill 全文去重开关（config.yaml modelProxy.skillDedupEnabled → env）。缺省开：
# 同一 skill 被反复调用时每次都把整份 SKILL.md 重复注入，纯浪费。
SKILL_DEDUP_ENABLED = os.environ.get("MODEL_PROXY_SKILL_DEDUP", "1") != "0"
# 工具输出瘦身配置（config.yaml modelProxy.outputFilter → env，JSON 串）。
# 缺省空串即用 Python 侧内置默认（开，max_bytes 8000），与 skill dedup 同构。
OUTPUT_FILTER_JSON = os.environ.get(OUTPUT_FILTER_ENV_KEY, "")

logger = setup_logging("token_proxy", json_format=True)

#: 后台任务的强引用池。asyncio 的事件循环对 create_task 只持**弱引用**，
#: fire-and-forget 用法下任务可能在跑完前就被 GC 回收，表现为用量记录随机
#: 丢失（官方文档明确要求保存引用）。完成回调负责及时释放。
_BACKGROUND_TASKS: set = set()


def _load_providers() -> list[dict]:
    if not PROVIDERS_JSON:
        return []
    try:
        parsed = json.loads(PROVIDERS_JSON)
    except json.JSONDecodeError:
        logger.warning(
            json.dumps({"msg": "providers_json_invalid", "error": "bad JSON"})
        )
        return []

    # 缺键的 provider 无法路由到预期模型。不在装载时报出来，它就只表现为
    # 「请求被静默转发到 providers[0]」——看起来像路由逻辑出错，实际是配置面断裂。
    out: list[dict] = []
    for p in parsed:
        if not isinstance(p, dict) or not p.get("url"):
            continue
        absent = missing_keys(p)
        if absent:
            logger.warning(
                json.dumps(
                    {
                        "msg": "provider_config_missing",
                        "provider": p.get("name", ""),
                        "keys": absent,
                        "effect": "该 provider 可能无法路由到预期模型",
                    }
                )
            )
        out.append(p)
    return out


PROVIDERS = _load_providers()

#: classifier 加速白名单（客户端身份的唯一来源；判据来自可配置白名单而非写死的客户端指纹）
CLIENT_ACCEL = load_client_accel(CLIENT_ACCEL_JSON)


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


_logged_first_body: bool = False


#: 入口路径 → 协议格式的映射前缀（在 `_upstream_path` 归一化之后比较）。
#: **入口路径是协议的权威声明**，比从请求体推测可靠：启发式在「无 system、无 tools
#: 的单轮请求」上必然落到兜底分支（见 `_detect_api_format`），会把 OpenAI 协议请求
#: 误判成 anthropic 并做错误转换。
ANTHROPIC_PATH_PREFIXES: tuple[str, ...] = ("v1/messages",)
OPENAI_PATH_PREFIXES: tuple[str, ...] = ("v1/chat/completions", "v1/completions")


def _upstream_path(request_path: str) -> str:
    """客户端请求路径 → 上游相对路径（provider.url 之后的部分）。

    `/open/v1/messages` → `v1/messages`；`/v1/messages` → `v1/messages`。
    `/open` 是历史兼容入口（用户已配 `ANTHROPIC_BASE_URL=.../open/v1`），
    `/v1` 是协议原生入口；两者在此归一，后续逻辑只面对一种形态。
    """
    if request_path.startswith("/open/"):
        return request_path[len("/open/") :]
    return request_path.lstrip("/")


def _api_format_from_path(upstream_path: str) -> str | None:
    """按入口路径判定协议格式；路径不表明协议时返回 None（交由启发式兜底）。"""
    for prefix in ANTHROPIC_PATH_PREFIXES:
        if upstream_path.startswith(prefix):
            return "anthropic"
    for prefix in OPENAI_PATH_PREFIXES:
        if upstream_path.startswith(prefix):
            return "openai"
    return None


async def handle_proxy(request: web.Request) -> web.StreamResponse:
    """转发请求到上游 API，流式返回响应。"""
    if not UPSTREAM_URL and not PROVIDERS:
        return web.json_response(
            {"error": "MODEL_PROXY_URL / MODEL_PROXY_PROVIDERS not configured"},
            status=503,
        )

    # 上游相对路径：/open 兼容入口与 /v1 原生入口在此归一
    path = _upstream_path(request.path)

    # 网关模型发现：GET /v1/models（或 /open/v1/models）→ 返回 providers 全部模型，
    # 供客户端模型选择器列出路由。响应 schema 按协议选择，见 _models_schema_for。
    if request.method == "GET" and path == "v1/models":
        return await _handle_models(request)

    # 读取请求 body
    body_bytes = await request.read()
    request_body = {}
    try:
        request_body = json.loads(body_bytes) if body_bytes else {}
    except json.JSONDecodeError:
        pass

    # 客户端 API 格式：**入口路径优先**（协议声明），路径不表明协议时才回退请求体启发式。
    # 两者不一致时记 format_mismatch 而**不静默采信**——不一致本身是信号（客户端用了
    # 非规范路径，或启发式误判），静默会让错误转换无从归因。
    api_format = _api_format_from_path(path)
    if api_format is None:
        api_format = _detect_api_format(request_body)
    else:
        by_body = _detect_api_format(request_body)
        if by_body != api_format:
            logger.warning(
                json.dumps(
                    {
                        "msg": "format_mismatch",
                        "path": request.path,
                        "by_path": api_format,
                        "by_body": by_body,
                        "effect": "采用路径判据",
                    }
                )
            )

    provider, upstream_model = _resolve_provider(request_body.get("model", ""))
    request_body["model"] = upstream_model

    provider_format = api_format_of(provider)
    body_bytes = json.dumps(request_body).encode()

    # 构建上游 URL（两种入口形态已在 path 归一）
    # 例: /v1/messages 或 /open/v1/messages → path="v1/messages" → provider.url/v1/messages
    upstream = f"{provider['url']}/{path}"
    if request.query_string:
        upstream += f"?{request.query_string}"

    # 安全分类请求（classifier）关闭 thinking，加速响应。
    # 结构判据（_is_classifier_candidate）与客户端无关；**是否启用由可配置客户端
    # 白名单决定**（config.yaml modelProxy.clientAccel）——客户端身份不是协议事实，
    # 写死单一客户端会让其他客户端在同一结构的请求下拿不到加速、撞上游超时。
    # 关键路径日志按三类返回点区分：命中白名单且为 candidate 记 info；命中白名单但
    # 非 candidate 记 debug（观测形态变化）；未命中白名单记 debug（含 UA 摘要，
    # 便于发现需要登记的新客户端）。
    accel_client = matches_accel_client(request.headers, CLIENT_ACCEL)
    if accel_client:
        if _is_classifier_candidate(request_body):
            _inject_classifier_disabled(request_body, api_format)
            body_bytes = json.dumps(request_body).encode()
            logger.info(
                json.dumps(
                    {
                        "msg": "classifier_thinking_disabled",
                        "client": accel_client,
                        "model": request_body.get("model", ""),
                        "messages": len(request_body.get("messages", [])),
                        "api_format": api_format,
                    }
                )
            )
        else:
            logger.info(
                json.dumps(
                    {
                        "msg": "classifier_check_skip",
                        "client": accel_client,
                        "model": request_body.get("model", ""),
                        "stream": request_body.get("stream"),
                        "tools": len(request_body.get("tools", [])),
                        "messages": len(request_body.get("messages", [])),
                    }
                )
            )
    else:
        logger.info(
            json.dumps(
                {
                    "msg": "classifier_client_not_allowed",
                    # UA 截断：仅用于发现需要登记的新客户端，不整串落盘
                    "user_agent": request.headers.get("user-agent", "")[:80],
                    "api_format": api_format,
                }
            )
        )

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

    # skill 全文去重：第二份起换成短提示（判据是内容逐字节相同，代理拿不到
    # skill 名单）。必须在 record 之后——记录层要留原样，否则度量标尺被自己毁掉。
    if SKILL_DEDUP_ENABLED:
        deduped = dedup_tool_results(request_body, api_format, ui_language())
        if deduped:
            body_bytes = json.dumps(request_body).encode()
            logger.info(
                json.dumps(
                    {
                        "msg": "skill_dedup",
                        "replaced": deduped,
                        "api_format": api_format,
                    }
                )
            )

    # 工具输出瘦身：超长砍头尾 + JSON 无损 minify，只对 shell 类工具（Read 等
    # 是模型点名要的文件内容，截断等于损坏）。同样必须在 record 之后。
    filtered = filter_tool_outputs(
        request_body,
        api_format,
        OUTPUT_FILTER_JSON,
        ui_language(),
    )
    if filtered:
        if filtered.get("saved_bytes"):
            body_bytes = json.dumps(request_body).encode()
        logger.info(
            json.dumps({"msg": "output_filter", "api_format": api_format, **filtered})
        )

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
    api_key = api_key_of(provider)
    if api_key:
        headers.pop("x-api-key", None)
        headers.pop("authorization", None)
        if provider_format == "openai":
            headers["Authorization"] = f"Bearer {api_key}"
        else:
            headers["x-api-key"] = api_key

    start_time = time.monotonic()

    # 503 瞬时重试：上游（deepseek 等 provider）偶发返回 503（"temporarily unavailable"）。
    # 命中 agent 客户端的安全分类调用时会导致其关键操作被拦（故障与客户端无关，
    # 早期观测来自 Claude Code）。
    # 策略值取自 llm_client（**单一权威**）：同一类故障在「主转发」与「LLM 调用」两处
    # 都要处理，就地各写一份必然漂移；换值时要能一处改全局生效。
    retry_max = llm_client.DEFAULT_RETRY_503_MAX
    retry_delay = llm_client.DEFAULT_RETRY_503_DELAY
    for attempt in range(retry_max + 1):
        # 诊断(临时)：记录异常发生的阶段，用于定位流中断的第一现场。
        # 必须在 try 内、循环体首句赋值，这样外层 proxy_error 一定能读到。
        diag_stage = "connect"
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
                    if upstream_resp.status == 503 and attempt < retry_max:
                        logger.warning(
                            json.dumps(
                                {
                                    "msg": "proxy_retry",
                                    "path": request.path,
                                    "attempt": attempt + 1,
                                    "latency_ms": latency_ms,
                                    "model": request_body.get("model", ""),
                                }
                            )
                        )
                        await asyncio.sleep(retry_delay)
                        continue

                    # 流式转发响应
                    #
                    # content-encoding 与 content-length 必须**一起**剔除，二者是一对：
                    # aiohttp 客户端默认 auto_decompress，转发出去的 body 已经不是上游
                    # 声明的那份字节了。只剔 content-encoding 而不剔 content-length，
                    # 等于把压缩前的长度谎报给客户端——要么按旧长度截断，要么协议错误。
                    #
                    # 模型名注入会额外加长响应体，是同一类问题的第二个来源：上游若带
                    # content-length，照抄会按旧长度截断、把注入的尾段整段吃掉。
                    #
                    # 剔除后交由 aiohttp 重新分帧（HTTP/1.1 走 chunked）。
                    forward_headers = {
                        k: v
                        for k, v in upstream_resp.headers.items()
                        if k.lower()
                        not in {
                            "transfer-encoding",
                            "content-encoding",
                            "content-length",
                        }
                    }
                    response = web.StreamResponse(
                        status=upstream_resp.status, headers=forward_headers
                    )
                    diag_stage = "prepare"
                    await response.prepare(request)
                    diag_stage = "stream"

                    # 收集 SSE chunks 以提取 usage
                    collected_body = bytearray()
                    is_sse = "text/event-stream" in upstream_resp.headers.get(
                        "content-type", ""
                    )
                    # 流中断时的异常信息，供 record_usage 记录
                    stream_error = ""
                    # 诊断(临时)：最后一次从上游收到数据的时间。用于区分
                    # 「上游停顿时被客户端放弃」与「连接被直接重置」——
                    # 前者 since_last_chunk_ms 大，后者接近于 0。
                    last_chunk_at = time.monotonic()

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
                                last_chunk_at = time.monotonic()
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
                                    raw = "".join(parts).encode()
                                    # collected_body 收未注入的原始流：usage / 输出
                                    # 预览的提取口径不被注入内容影响
                                    collected_body.extend(raw)
                                    await response.write(
                                        tagger.feed(raw) if tagger else raw
                                    )
                            # 收尾：content_block_stop / message_delta / message_stop
                            if not stream_error:
                                tail = converter.finish()
                                if tail:
                                    raw = "".join(tail).encode()
                                    collected_body.extend(raw)
                                    await response.write(
                                        tagger.feed(raw) if tagger else raw
                                    )
                        elif convert_resp and not is_sse:
                            # 非流式转换：先收完整 JSON body 再整体转换
                            raw_body = bytearray()
                            async for chunk in upstream_resp.content.iter_any():
                                last_chunk_at = time.monotonic()
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
                                last_chunk_at = time.monotonic()
                                # 收集 SSE chunks 以提取 usage；400 等错误响应为非 SSE JSON，
                                # 也收集以记录响应体定位错误（临时增强）
                                if is_sse or upstream_resp.status >= 400:
                                    collected_body.extend(chunk)
                                await response.write(chunk)

                    except (
                        ConnectionResetError,
                        BrokenPipeError,
                        RuntimeError,
                        asyncio.CancelledError,
                    ) as e:
                        # 客户端已断开连接或 transport 关闭，停止转发
                        stream_error = f"{type(e).__name__}: {e}"
                        # 诊断(临时)：这里才是流中断的第一现场，但它此前只被存进
                        # stream_error 而不落日志；若随后 write_eof 再抛，外层
                        # proxy_error 记下的将是**第二个**异常，第一现场永久丢失。
                        # error_type 本身即带方向：Client* 系 → 写客户端失败，
                        # ClientPayloadError/ServerDisconnectedError → 读上游失败。
                        logger.warning(
                            json.dumps(
                                {
                                    "msg": "stream_interrupted",
                                    "stage": diag_stage,
                                    "error_type": type(e).__name__,
                                    "error": str(e),
                                    "received": len(collected_body),
                                    # 绝对时间：与客户端 debug 日志对照用
                                    "ts": int(time.time()),
                                    # 请求总时长（对比 API_TIMEOUT_MS=300000）
                                    "elapsed_ms": int(
                                        (time.monotonic() - start_time) * 1000
                                    ),
                                    # 距最后一次收到上游数据的间隔
                                    "since_last_chunk_ms": int(
                                        (time.monotonic() - last_chunk_at) * 1000
                                    ),
                                }
                            )
                        )

                    # 诊断(临时)：write_eof 在内层 try 之外，连接已断时会**再抛一次**
                    # ClientConnectionResetError，冒泡到外层 proxy_error 并覆盖第一现场；
                    # 同时跳过其后的 record_usage，使中断在数据库侧也不留痕。
                    # 此处吞掉并单独记日志，让第一现场得以保留、record_usage 得以执行。
                    try:
                        await response.write_eof()
                    except Exception as e:
                        logger.warning(
                            json.dumps(
                                {
                                    "msg": "write_eof_failed",
                                    "error_type": type(e).__name__,
                                    "error": str(e),
                                    "stream_error": stream_error,
                                    "received": len(collected_body),
                                }
                            )
                        )
                    diag_stage = "done"

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
                        # 工具输出（最新一轮 tool_result）随 usage 一并入库。
                        # 两表分属不同库文件，只有在这里才能拿到 api_usage 自增 id，
                        # 分开写会让 api_usage_id 恒为 NULL，成本归因分析断链。
                        # 覆盖范围与 api_usage 完全一致（usage 解析失败/非 200 时两表
                        # 都不记），故 JOIN 不会有孤立行——这是有意对齐，不是遗漏。
                        tool_outputs = extract_tool_outputs(
                            record_request_body, api_format=api_format
                        )
                        task = asyncio.create_task(
                            record_usage(
                                record_request_body,
                                usage_data,
                                upstream_resp.status,
                                latency_ms,
                                output_preview,
                                error_message,
                                tool_name_override=tool_name,
                                api_format=api_format,
                                tool_outputs=tool_outputs,
                            )
                        )
                        _BACKGROUND_TASKS.add(task)
                        task.add_done_callback(_BACKGROUND_TASKS.discard)

                    logger.info(
                        json.dumps(
                            {
                                "msg": "proxy_request",
                                "method": request.method,
                                "path": request.path,
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
                        "path": request.path,
                        "error": str(e),
                        # 诊断(临时)：异常类型 + 发生阶段。此前只记 str(e)，而
                        # "Cannot write to closing transport" 在 prepare / 写客户端 /
                        # write_eof 三处都会抛出，仅凭消息无法区分是哪一个。
                        "error_type": type(e).__name__,
                        "stage": diag_stage,
                        "latency_ms": latency_ms,
                    }
                )
            )
            return web.json_response(
                {"error": f"upstream_error: {e}"},
                status=502,
            )


#: OpenAI 兼容 schema 中 `created` 的取值（2026-01-01T00:00:00Z 的 epoch）。
#: 用固定常量而非当前时间：同一份模型列表每次响应的 `created` 必须稳定，
#: 否则按该字段做缓存的客户端会反复失效。
_MODEL_CREATED_EPOCH = 1767225600


def _models_schema_for(request: web.Request) -> str:
    """模型发现响应的协议格式。判据取自**协议级请求头**，不用 UA：

    - 带 `anthropic-version`（Anthropic SDK / Claude Code 每条请求都带）→ anthropic
    - 带 `Authorization: Bearer ...`（OpenAI SDK 的鉴权方式）→ openai
    - 两者都无 → 按 `/open/*` 兼容入口兜底为 anthropic，并记 info 日志

    UA 是客户端产品指纹、与协议无关，拿它判协议正是本阶段要消除的那类写法。
    """
    if request.headers.get("anthropic-version"):
        return "anthropic"
    if request.headers.get("authorization", "").lower().startswith("bearer"):
        return "openai"
    logger.info(
        json.dumps(
            {
                "msg": "models_schema_fallback",
                "path": request.path,
                "schema": "anthropic",
            }
        )
    )
    return "anthropic"


async def _handle_models(request: web.Request) -> web.Response:
    """GET /v1/models（或 /open/v1/models）：返回 providers 全部模型。

    同一端点要服务两种协议客户端，响应 schema 不同：
    - Anthropic（Claude Code 的 /model 选择器）：`{data:[{type,id,display_name,
      created_at}], has_more, first_id, last_id}`
    - OpenAI（SDK `models.list()`）：`{object:"list", data:[{id,object:"model",
      created, owned_by}]}`

    只提供一种会让另一种协议的 SDK 解析失败。
    """
    entries: list[tuple[str, str]] = [
        (p.get("name", ""), m) for p in PROVIDERS for m in p.get("models", [])
    ]

    if _models_schema_for(request) == "openai":
        data = [
            {
                "id": m,
                "object": "model",
                "created": _MODEL_CREATED_EPOCH,
                "owned_by": pname,
            }
            for pname, m in entries
        ] or [
            {
                "id": "unknown",
                "object": "model",
                "created": _MODEL_CREATED_EPOCH,
                "owned_by": "",
            }
        ]
        return web.json_response({"object": "list", "data": data})

    data = [
        {
            "type": "model",
            "id": m,
            "display_name": f"{pname} · {m}",
            "created_at": "2026-01-01T00:00:00Z",
        }
        for pname, m in entries
    ]
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
                            or r[
                                3
                            ],  # actual_user_input 优先，fallback 到 input_preview
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
    # 两种入口并存：`/v1/*` 是协议原生入口（客户端无需把 base_url 配成非常规前缀），
    # `/open/*` 是历史兼容别名（已配 ANTHROPIC_BASE_URL=.../open/v1 的用户不受影响）。
    # 注册在 /usage/* 与 /health 之后，不会遮蔽它们；两条路由共用同一 handler，
    # 路径在 _upstream_path 归一。
    app.router.add_route("*", "/open/{path:.*}", handle_proxy)
    app.router.add_route("*", "/v1/{path:.*}", handle_proxy)
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
    init_tool_output_db()
    logger.info(
        json.dumps(
            {
                "msg": "startup",
                "port": PORT,
                "upstream": UPSTREAM_URL,
                "providers": [p.get("name", "") for p in PROVIDERS],
                "db": DB_PATH,
                "tool_output_db": TOOL_OUTPUT_DB_PATH,
            }
        )
    )

    app = create_app()
    web.run_app(app, host="127.0.0.1", port=PORT, print=None)


if __name__ == "__main__":
    main()
