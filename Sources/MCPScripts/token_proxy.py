"""Token proxy monitoring service.

Intercepts Claude Code → API requests and records token usage and request context.

Refactor (2026-08-30, stage 2): protocol conversion/injection → proxy_protocol.py;
usage recording → proxy_usage.py; this entry point keeps providers routing + HTTP
endpoints + service startup.
"""

import asyncio
from dataclasses import dataclass
import json
import os
import sys
import time

import aiohttp
import llm_client
from aiohttp import web
from config import ui_language
from db import conn as dbconn
from log_utils import setup_logging
from proxy_client import load_client_accel, matches_accel_client
from proxy_output_filter import OUTPUT_FILTER_ENV_KEY, filter_tool_outputs
from proxy_protocol import (
    OpenAIToAnthropicStream,
    ProtocolConverter,
    _detect_api_format,
    _extract_output_from_sse,
    _extract_tool_name_from_sse,
    _extract_usage_from_sse,
    _inject_classifier_disabled,
    _inject_system_prompt,
    _is_classifier_candidate,
)
from proxy_provider import api_format_of, api_key_of, missing_keys
from proxy_response_note import (
    RESPONSE_NOTE_ENV_KEY,
    NoteBodyBuffer,
    SSENoteInjector,
    strip_notes_from_messages,
)
from proxy_skill_dedup import dedup_tool_results
from proxy_usage import (
    DB_PATH,
    TOOL_OUTPUT_DB_PATH,
    extract_tool_outputs,
    init_db,
    init_tool_output_db,
    record_gateway_log,
    record_usage,
)

# ---------------------------------------------------------------------------
# Configuration (dedicated env; common config in config.py, protocol/usage config in their own submodules)
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("MODEL_PROXY_PORT", "8080"))
UPSTREAM_URL = os.environ.get(
    "MODEL_PROXY_URL", ""
)  # compatibility: single upstream when providers is empty
# providers routing table (JSON env, serialized on the Swift side from config.yaml):
#   [{"name","url","apiFormat":"anthropic|openai","apiKey","models":[".."]}, ...]
# Routing rule: body.model exactly matches some provider.models → that provider (upstream
# model uses the original value); no match → providers[0] as fallback, upstream model uses
# its models[0].
PROVIDERS_JSON = os.environ.get("MODEL_PROXY_PROVIDERS", "")
# classifier acceleration's client allowlist (JSON env, serialized on the Swift side from
# config.yaml modelProxy.clientAccel; empty string by default → proxy_client uses the
# built-in default allowlist, i.e. historical behavior)
CLIENT_ACCEL_JSON = os.environ.get("MODEL_PROXY_CLIENT_ACCEL", "")
# skill full-text dedup switch (config.yaml modelProxy.skillDedupEnabled → env). On by
# default: when the same skill is called repeatedly, the whole SKILL.md is re-injected each
# time, pure waste.
SKILL_DEDUP_ENABLED = os.environ.get("MODEL_PROXY_SKILL_DEDUP", "1") != "0"
# Tool-output slimming config (config.yaml modelProxy.outputFilter → env, JSON string).
# Empty string by default means the Python-side built-in default (on, max_bytes 8000),
# isomorphic with skill dedup.
OUTPUT_FILTER_JSON = os.environ.get(OUTPUT_FILTER_ENV_KEY, "")
# Response-side append of "what was rewritten this turn" (config.yaml modelProxy.responseAnnotation → env).
RESPONSE_NOTE_ENABLED = os.environ.get(RESPONSE_NOTE_ENV_KEY, "1") != "0"

#: The response compression encoding whitelist **declared by ourselves** when forwarding to
#: the upstream (not passing through the client's Accept-Encoding).
#:
#: The upstream picks the compression method by this header — measured on deepseek: declare
#: zstd and it returns zstd, declare br and it returns br, and it **compresses even a 200 SSE
#: stream**, not just error responses. Yet this proxy must read and rewrite the response body
#: (SSE usage extraction, model-name injection, skill dedup, output filtering), so being
#: unable to decode means discarding the whole response **along with the upstream's real
#: status code**: when aiohttp's decoder is unavailable it raises `ContentEncodingError`
#: (inheriting `PayloadEncodingError` → `BadHttpMessage`, **code always 400**), which in
#: `ClientResponse.start()` is wrapped into `ClientResponseError(status=400, message='Can not
#: decode content-encoding: …')` and turned into a 502 by the except below — the `400` in the
#: error text is **not the upstream status code**; the client only sees an unexplained 502 and
#: retries repeatedly (the 2026-10-12 user report had exactly this shape).
#:
#: Only declare encodings aiohttp can actually decode in this venv: gzip/deflate go through
#: the stdlib zlib, br needs Brotli, zstd needs backports.zstd (aiohttp 3.14 only then
#: supports zstd, and only installs it via the speedups extra) — both are installed and
#: written into requirements.txt. Contract group 7 asserts "every declared encoding is
#: decodable by this process", so **writing one in on a machine without the library turns it
#: red** (that is exactly what it is meant to catch: declaring an undecodable encoding
#: amounts to discarding the whole response together with the real status code). Install the
#: library before adding a new encoding.
UPSTREAM_ACCEPT_ENCODING = "gzip, deflate, br, zstd"

logger = setup_logging("token_proxy", json_format=True)

#: Strong-reference pool for background tasks. asyncio's event loop holds only **weak
#: references** to create_task; under fire-and-forget usage a task may be garbage-collected
#: before it finishes, manifesting as randomly lost usage records (the official docs
#: explicitly require saving the reference). A completion callback releases it in time.
_BACKGROUND_TASKS: set = set()

#: Process-wide upstream connection pool: a per-request ClientSession discards the TCP/TLS
#: connection, paying a full handshake before the first token on every request.
_SESSION: aiohttp.ClientSession | None = None


def _get_session() -> aiohttp.ClientSession:
    global _SESSION
    if _SESSION is None or _SESSION.closed:
        _SESSION = aiohttp.ClientSession(
            connector=aiohttp.TCPConnector(limit=64, ttl_dns_cache=300)
        )
    return _SESSION


class _SharedSession:
    """Async context manager yielding the shared session, **closing nothing** on exit.

    It exists only so the forwarding body keeps its indentation — that line used to be
    `async with aiohttp.ClientSession() as session:`, building and tearing down a pool per
    request. Reading the global needs no lock: `_get_session` never awaits.
    """

    async def __aenter__(self) -> aiohttp.ClientSession:
        return _get_session()

    async def __aexit__(self, *_exc) -> bool:
        return False


async def _close_session(_app: web.Application) -> None:
    global _SESSION
    session, _SESSION = _SESSION, None
    if session is not None and not session.closed:
        await session.close()


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

    # A provider missing keys cannot be routed to the expected model. If it is not reported
    # at load time, it only manifests as "the request is silently forwarded to providers[0]"
    # — which looks like a routing logic error but is actually a broken config surface.
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
                        "effect": "this provider may not route to the expected model",
                    }
                )
            )
        out.append(p)
    return out


PROVIDERS = _load_providers()

#: classifier acceleration allowlist (the sole source of client identity; the criterion comes from a configurable allowlist rather than a hard-coded client fingerprint)
CLIENT_ACCEL = load_client_accel(CLIENT_ACCEL_JSON)


def _resolve_provider(model: str) -> tuple[dict, str]:
    """Route a provider by body.model, returning (provider, upstream model name).

    - model matches some provider.models → that provider, upstream model uses the original value
    - no match → providers[0] as fallback, upstream model uses its models[0]
    - providers empty → compatible with the legacy single upstream (url + passed-through key)
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


#: Mapping prefixes of entry path → protocol format (compared after `_upstream_path`
#: normalization). **The entry path is the authoritative declaration of the protocol**, more
#: reliable than guessing from the request body: the heuristic necessarily falls to the
#: fallback branch on a "single-turn request with no system and no tools" (see
#: `_detect_api_format`), misjudging an OpenAI-protocol request as anthropic and performing a
#: wrong conversion.
ANTHROPIC_PATH_PREFIXES: tuple[str, ...] = ("v1/messages",)
OPENAI_PATH_PREFIXES: tuple[str, ...] = ("v1/chat/completions", "v1/completions")


def _upstream_path(request_path: str) -> str:
    """Client request path → upstream relative path (the part after provider.url).

    `/open/v1/messages` → `v1/messages`; `/v1/messages` → `v1/messages`.
    `/open` is the legacy compatibility entry (users who configured
    `ANTHROPIC_BASE_URL=.../open/v1`), `/v1` is the protocol-native entry; the two are
    normalized here and the subsequent logic faces only one form.
    """
    if request_path.startswith("/open/"):
        return request_path[len("/open/") :]
    return request_path.lstrip("/")


def _api_format_from_path(upstream_path: str) -> str | None:
    """Determine the protocol format by the entry path; returns None when the path does not indicate the protocol (falls back to the heuristic)."""
    for prefix in ANTHROPIC_PATH_PREFIXES:
        if upstream_path.startswith(prefix):
            return "anthropic"
    for prefix in OPENAI_PATH_PREFIXES:
        if upstream_path.startswith(prefix):
            return "openai"
    return None


@dataclass
class _ProxyState:
    """Everything the forwarding stages share; filled in by `_prepare_request`."""

    request: web.Request
    path: str
    api_format: str
    provider: dict
    provider_format: str
    request_body: dict
    body_bytes: bytes
    record_request_body: dict
    note_parts: list[str]
    upstream: str


async def handle_proxy(request: web.Request) -> web.StreamResponse:
    """Forward the request to the upstream API, returning the response in a streaming manner."""
    if not UPSTREAM_URL and not PROVIDERS:
        return web.json_response(
            {"error": "MODEL_PROXY_URL / MODEL_PROXY_PROVIDERS not configured"},
            status=503,
        )

    # Upstream relative path: the /open compatibility entry and the /v1 native entry are normalized here
    path = _upstream_path(request.path)

    # Gateway model discovery: GET /v1/models (or /open/v1/models) → return all provider
    # models, for the client model selector to list routes. The response schema is chosen by
    # protocol, see _models_schema_for.
    if request.method == "GET" and path == "v1/models":
        return await _handle_models(request)
    state = await _prepare_request(request, path)
    _apply_rewrites(state)
    return await _forward(state)


async def _prepare_request(request: web.Request, path: str) -> _ProxyState:
    """Read the body, resolve the protocol/provider, inject rules, and capture the record copy."""
    # Read the request body
    body_bytes = await request.read()
    request_body = {}
    try:
        request_body = json.loads(body_bytes) if body_bytes else {}
    except json.JSONDecodeError:
        pass

    # Client API format: **entry path takes priority** (protocol declaration); only when the
    # path does not indicate the protocol does it fall back to the request-body heuristic.
    # When the two disagree, log format_mismatch and **do not silently trust either** — the
    # disagreement itself is a signal (the client used a non-standard path, or the heuristic
    # misjudged), and silence would make the wrong conversion unattributable.
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
                        "effect": "use the path criterion",
                    }
                )
            )

    provider, upstream_model = _resolve_provider(request_body.get("model", ""))
    request_body["model"] = upstream_model

    provider_format = api_format_of(provider)
    body_bytes = json.dumps(request_body).encode()

    # Build the upstream URL (the two entry forms are already normalized in path)
    # e.g. /v1/messages or /open/v1/messages → path="v1/messages" → provider.url/v1/messages
    upstream = f"{provider['url']}/{path}"
    if request.query_string:
        upstream += f"?{request.query_string}"

    # Safety classification request (classifier) disables thinking to speed up the response.
    # The structural criterion (_is_classifier_candidate) is client-independent; **whether it
    # is enabled is decided by the configurable client allowlist** (config.yaml
    # modelProxy.clientAccel) — client identity is not a protocol fact, and hard-coding a
    # single client would leave other clients unable to get acceleration for requests of the
    # same structure, hitting the upstream timeout.
    # The critical-path log distinguishes three return points: matched allowlist and is a
    # candidate logs info; matched allowlist but not a candidate logs debug (to observe shape
    # changes); not matched logs debug (with a UA summary, to help discover new clients that
    # need registering).
    accel_client = matches_accel_client(request.headers, CLIENT_ACCEL)
    if accel_client:
        if _is_classifier_candidate(request_body):
            _inject_classifier_disabled(request_body, api_format)
            body_bytes = json.dumps(request_body).encode()
            logger.debug(
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
            logger.debug(
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
                    # UA truncation: only for discovering new clients that need registering, not persisting the whole string
                    "user_agent": request.headers.get("user-agent", "")[:80],
                    "api_format": api_format,
                }
            )
        )

    # System prompt injection: read the rules from System_Prompts.md and inject them into every real user input
    injected, rule_injected = _inject_system_prompt(request_body)
    if injected is not None:
        body_bytes = injected

    # First-request log: output the full body after injection, to verify the system prompt takes effect
    global _logged_first_body
    if not _logged_first_body:
        _logged_first_body = True
        try:
            parsed = json.loads(body_bytes)
            # Output only the system field, the injected rule count, and model, to avoid flooding
            log_body = {
                "model": parsed.get("model", ""),
                "rule_injected": rule_injected,
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
        except Exception as e:  # noqa: BLE001
            logger.warning(
                json.dumps({"msg": "first_body_log_failed", "error": str(e)})
            )

    # Record the original (post-injection) request body before conversion, for record_usage
    # context extraction (the structure is the client format)
    record_request_body = json.loads(body_bytes) if body_bytes else {}

    # The list of rewrites triggered this turn, for the response-side "applied: …" append
    note_parts: list[str] = []
    return _ProxyState(
        request=request,
        path=path,
        api_format=api_format,
        provider=provider,
        provider_format=provider_format,
        request_body=request_body,
        body_bytes=body_bytes,
        record_request_body=record_request_body,
        note_parts=note_parts,
        upstream=upstream,
    )


def _apply_rewrites(state: _ProxyState) -> None:
    """Client-format rewrites before forwarding; the record copy stays untouched."""
    # skill full-text dedup: from the second copy onward replace with a short note (the
    # criterion is byte-identical content; the proxy cannot see the skill list). Must be
    # after record — the record layer must keep the original, otherwise the measurement
    # yardstick destroys itself.
    if SKILL_DEDUP_ENABLED:
        deduped = dedup_tool_results(
            state.request_body, state.api_format, ui_language()
        )
        if deduped:
            state.note_parts.append("skillDedup")
            state.body_bytes = json.dumps(state.request_body).encode()
            logger.info(
                json.dumps(
                    {
                        "msg": "skill_dedup",
                        "replaced": deduped,
                        "api_format": state.api_format,
                    }
                )
            )

    # Tool-output slimming: over-long head/tail trim + lossless JSON minify, only for
    # shell-like tools (Read etc. are file contents the model explicitly asked for;
    # truncating is corruption). Likewise must be after record.
    filtered = filter_tool_outputs(
        state.request_body,
        state.api_format,
        OUTPUT_FILTER_JSON,
        ui_language(),
    )
    if filtered:
        if filtered.get("saved_bytes"):
            state.note_parts.append("outputFilter")
            state.body_bytes = json.dumps(state.request_body).encode()
        logger.info(
            json.dumps(
                {"msg": "output_filter", "api_format": state.api_format, **filtered}
            )
        )

    # Strip the note lines the model echoed back from earlier turns: the note is injected into
    # the assistant's text block, so it enters the history and the model reproduces that line
    # on its own. Removing it here keeps it out of the upstream context.
    if RESPONSE_NOTE_ENABLED:
        stripped = strip_notes_from_messages(state.request_body.get("messages") or [])
        if stripped:
            state.body_bytes = json.dumps(state.request_body).encode()
            logger.info(
                json.dumps(
                    {
                        "msg": "note_strip",
                        "removed": stripped,
                        "api_format": state.api_format,
                    }
                )
            )

    # Request protocol conversion: client anthropic ↔ provider openai (standard gateway mapping)
    if state.api_format == "anthropic" and state.provider_format == "openai":
        state.request_body = json.loads(state.body_bytes)
        state.request_body = ProtocolConverter.request_anthropic_to_openai(
            state.request_body
        )
        state.body_bytes = json.dumps(state.request_body).encode()
        logger.debug(
            json.dumps(
                {
                    "msg": "request_converted",
                    "direction": "anthropic_to_openai",
                    "provider": state.provider.get("name", ""),
                }
            )
        )
    elif state.api_format == "openai" and state.provider_format == "anthropic":
        state.request_body = json.loads(state.body_bytes)
        state.request_body = ProtocolConverter.request_openai_to_anthropic(
            state.request_body
        )
        state.body_bytes = json.dumps(state.request_body).encode()
        logger.debug(
            json.dumps(
                {
                    "msg": "request_converted",
                    "direction": "openai_to_anthropic",
                    "provider": state.provider.get("name", ""),
                }
            )
        )


async def _forward(state: _ProxyState) -> web.StreamResponse:
    """Send the prepared request upstream, stream the response back, and record usage."""
    # Forward headers (pass through, but replace the auth key by provider)
    #
    # accept-encoding is the **exception**: the client's value is not passed through (Claude
    # Code declares `gzip, deflate, br, zstd`); instead this process declares the whitelist it
    # can decode — see the comment on UPSTREAM_ACCEPT_ENCODING. Skip it and then assign it
    # explicitly, both needed: assigning without skipping leaves both `accept-encoding` (the
    # client's original) and `Accept-Encoding` (the whitelist) keys in the dict, and both
    # headers get sent.
    headers = {}
    skip_headers = {
        "host",
        "content-length",
        "transfer-encoding",
        "accept-encoding",
    }
    for k, v in state.request.headers.items():
        if k.lower() not in skip_headers:
            headers[k] = v
    headers["Accept-Encoding"] = UPSTREAM_ACCEPT_ENCODING
    api_key = api_key_of(state.provider)
    if api_key:
        headers.pop("x-api-key", None)
        headers.pop("authorization", None)
        if state.provider_format == "openai":
            headers["Authorization"] = f"Bearer {api_key}"
        else:
            headers["x-api-key"] = api_key

    start_time = time.monotonic()

    # 503 transient retry: the upstream (deepseek etc. providers) occasionally returns 503
    # ("temporarily unavailable"). When it hits an agent client's safety classification call
    # it causes that client's key operations to be blocked (the failure is client-independent;
    # the early observations came from Claude Code).
    # The policy values come from llm_client (**single authority**): the same class of failure
    # must be handled in both "main forwarding" and "LLM calls", and writing a copy in each
    # place inevitably drifts; a change must take effect globally from one place.
    retry_max = llm_client.DEFAULT_RETRY_503_MAX
    retry_delay = llm_client.DEFAULT_RETRY_503_DELAY
    for attempt in range(retry_max + 1):
        # Diagnostic (temporary): record the stage where the exception occurs, to locate the
        # first scene of a stream interruption. Must be assigned inside try, at the first
        # statement of the loop body, so the outer proxy_error can always read it.
        diag_stage = "connect"
        try:
            # Not merged: combining would reindent the 365-line response block below.
            # The two forms are equivalent: _SharedSession closes nothing on exit.
            async with _SharedSession() as session:  # noqa: SIM117
                async with session.request(
                    method=state.request.method,
                    url=state.upstream,
                    headers=headers,
                    data=state.body_bytes,
                    timeout=aiohttp.ClientTimeout(
                        total=300,
                        sock_connect=10,
                        sock_read=120,
                    ),
                ) as upstream_resp:
                    latency_ms = int((time.monotonic() - start_time) * 1000)

                    # Upstream transient 503: abandon this connection, wait and retry
                    if upstream_resp.status == 503 and attempt < retry_max:
                        logger.warning(
                            json.dumps(
                                {
                                    "msg": "proxy_retry",
                                    "path": state.request.path,
                                    "attempt": attempt + 1,
                                    "latency_ms": latency_ms,
                                    "model": state.request_body.get("model", ""),
                                }
                            )
                        )
                        await asyncio.sleep(retry_delay)
                        continue

                    # Stream the forward response
                    #
                    # content-encoding and content-length must be removed **together**; they
                    # are a pair: the aiohttp client auto-decompresses by default, so the
                    # forwarded body is no longer the bytes the upstream declared. Removing
                    # only content-encoding without content-length is equivalent to lying to
                    # the client with the pre-compression length — either truncating by the
                    # old length or a protocol error.
                    #
                    # Model-name injection additionally lengthens the response body, a second
                    # source of the same problem: if the upstream carries content-length,
                    # copying it truncates by the old length and eats the entire injected tail.
                    #
                    # After removal, aiohttp re-frames it (HTTP/1.1 uses chunked).
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
                    await response.prepare(state.request)
                    diag_stage = "stream"

                    # Collect SSE chunks to extract usage
                    collected_body = bytearray()
                    is_sse = "text/event-stream" in upstream_resp.headers.get(
                        "content-type", ""
                    )
                    # Exception info on stream interruption, for record_usage to record
                    stream_error = ""
                    # Diagnostic (temporary): the time of the last data received from the
                    # upstream. Used to distinguish "the client gave up while the upstream
                    # stalled" from "the connection was directly reset" — the former has a
                    # large since_last_chunk_ms, the latter near 0.
                    last_chunk_at = time.monotonic()

                    # Upstream openai → client anthropic: the response needs conversion (Claude Code scenario)
                    convert_resp = (
                        state.provider_format == "openai"
                        and state.api_format == "anthropic"
                    )
                    converter = (
                        OpenAIToAnthropicStream() if (convert_resp and is_sse) else None
                    )

                    try:
                        if converter is not None:
                            # Streaming conversion: buffer openai SSE line by line → anthropic SSE events
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
                                    # collected_body collects the un-injected raw stream:
                                    # the extraction yardstick for usage / output preview
                                    # is not affected by injected content
                                    collected_body.extend(raw)
                                    # The response-side note is not wired into this branch yet (no
                                    # rewrite stats are collected for the converted format).
                                    await response.write(raw)
                            # Wrap up: content_block_stop / message_delta / message_stop
                            if not stream_error:
                                tail = converter.finish()
                                if tail:
                                    raw = "".join(tail).encode()
                                    collected_body.extend(raw)
                                    await response.write(raw)
                        elif convert_resp and not is_sse:
                            # Non-streaming conversion: collect the full JSON body first, then convert as a whole
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
                            except Exception as e:  # noqa: BLE001
                                stream_error = f"convert_error: {e}"
                                payload = bytes(raw_body)
                            await response.write(payload)
                            collected_body.extend(payload)
                        else:
                            # Pass-through (same format). The response-side append is only
                            # enabled when there really is a rewrite to report; otherwise it
                            # stays a pure pass-through — no parsing means zero overhead and
                            # no new failure path.
                            note_sink = None
                            if RESPONSE_NOTE_ENABLED:
                                if is_sse:
                                    note_sink = SSENoteInjector(
                                        state.note_parts, ui_language()
                                    )
                                elif upstream_resp.status < 400:
                                    note_sink = NoteBodyBuffer(
                                        state.note_parts, ui_language()
                                    )
                            async for chunk in upstream_resp.content.iter_any():
                                last_chunk_at = time.monotonic()
                                # Collect SSE chunks to extract usage; error responses such
                                # as 400 are non-SSE JSON, also collected to record the
                                # response body for locating the error (temporary enhancement)
                                if is_sse or upstream_resp.status >= 400:
                                    collected_body.extend(chunk)
                                if note_sink is not None:
                                    out = note_sink.feed(chunk)
                                    if out:
                                        await response.write(out)
                                else:
                                    await response.write(chunk)
                            if note_sink is not None:
                                tail = note_sink.finish()
                                if tail:
                                    await response.write(tail)
                                if getattr(note_sink, "message_starts", 0) > 1:
                                    logger.warning(
                                        json.dumps(
                                            {
                                                "msg": "stream_multiple_message_start",
                                                "count": note_sink.message_starts,
                                                "model": state.request_body.get(
                                                    "model", ""
                                                ),
                                                "path": state.request.path,
                                            }
                                        )
                                    )

                    except (
                        ConnectionResetError,
                        BrokenPipeError,
                        RuntimeError,
                        asyncio.CancelledError,
                    ) as e:
                        # The client has disconnected or the transport is closed; stop forwarding
                        stream_error = f"{type(e).__name__}: {e}"
                        # Diagnostic (temporary): this is the real first scene of the stream
                        # interruption, but previously it was only stored in stream_error and
                        # never logged; if a subsequent write_eof throws again, the outer
                        # proxy_error would record the **second** exception and the first scene
                        # would be lost forever. error_type itself carries direction: Client*
                        # family → writing to the client failed;
                        # ClientPayloadError/ServerDisconnectedError → reading the upstream failed.
                        logger.warning(
                            json.dumps(
                                {
                                    "msg": "stream_interrupted",
                                    "stage": diag_stage,
                                    "error_type": type(e).__name__,
                                    "error": str(e),
                                    "received": len(collected_body),
                                    # absolute time: for comparison with the client's debug logs
                                    "ts": int(time.time()),
                                    # total request duration (compare API_TIMEOUT_MS=300000)
                                    "elapsed_ms": int(
                                        (time.monotonic() - start_time) * 1000
                                    ),
                                    # interval since the last data received from the upstream
                                    "since_last_chunk_ms": int(
                                        (time.monotonic() - last_chunk_at) * 1000
                                    ),
                                }
                            )
                        )

                    # Diagnostic (temporary): write_eof is outside the inner try; when the
                    # connection is already broken it throws **again**
                    # (ClientConnectionResetError), bubbling to the outer proxy_error and
                    # overwriting the first scene; it also skips the subsequent record_usage,
                    # leaving the interruption untraced on the database side too. Swallow it
                    # here and log separately, so the first scene is preserved and
                    # record_usage runs.
                    try:
                        await response.write_eof()
                    except Exception as e:  # noqa: BLE001
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

                    # Extract usage / output preview / tool name
                    sse_bytes = bytes(collected_body) if collected_body else b""
                    if converter is not None:
                        # the converter has already normalized usage (including input/output tokens)
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
                            _extract_usage_from_sse(
                                sse_bytes, api_format=state.api_format
                            )
                            if is_sse and sse_bytes
                            else None
                        )
                        out_format = state.api_format

                    if usage_data:
                        # Supplement model: some APIs' SSE responses lack a model field
                        if not usage_data.get("model"):
                            usage_data["model"] = state.request_body.get(
                                "model", "unknown"
                            )
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
                        # Extract error info (stream-interruption exception first, then the upstream error body)
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
                        # Tool outputs (the latest round of tool_result) are persisted
                        # together with usage. The two tables belong to different DB files, and
                        # only here can the api_usage auto-increment id be obtained; writing
                        # them separately would leave api_usage_id always NULL, breaking the
                        # cost-attribution chain. The coverage is exactly the same as api_usage
                        # (neither table records when usage resolution fails or the status is
                        # non-200), so a JOIN has no orphan rows — this is deliberate
                        # alignment, not an omission.
                        tool_outputs = extract_tool_outputs(
                            state.record_request_body, api_format=state.api_format
                        )
                        task = asyncio.create_task(
                            record_usage(
                                state.record_request_body,
                                usage_data,
                                upstream_resp.status,
                                latency_ms,
                                output_preview,
                                error_message,
                                tool_name_override=tool_name,
                                api_format=state.api_format,
                                tool_outputs=tool_outputs,
                            )
                        )
                        _BACKGROUND_TASKS.add(task)
                        task.add_done_callback(_BACKGROUND_TASKS.discard)

                    logger.info(
                        json.dumps(
                            {
                                "msg": "proxy_request",
                                "method": state.request.method,
                                "path": state.request.path,
                                "status": upstream_resp.status,
                                "latency_ms": latency_ms,
                                "model": state.request_body.get("model", ""),
                            }
                        )
                    )

                    # Temporary enhancement: record the >=400 error response body, to locate the specific error of deepseek's context over-limit 400
                    if upstream_resp.status >= 400 and sse_bytes:
                        logger.warning(
                            json.dumps(
                                {
                                    "msg": "proxy_http_error_body",
                                    "model": state.request_body.get("model", ""),
                                    "status": upstream_resp.status,
                                    "latency_ms": latency_ms,
                                    "body": sse_bytes.decode("utf-8", errors="replace")[
                                        :500
                                    ],
                                }
                            )
                        )

                    return response

        except (TimeoutError, aiohttp.ClientError) as e:
            latency_ms = int((time.monotonic() - start_time) * 1000)
            # Connect-stage failures never reached the upstream and wrote nothing to the
            # client, so replaying is safe; from "prepare" on a retry would double the response.
            if (
                attempt < retry_max
                and diag_stage == "connect"
                and isinstance(e, (aiohttp.ClientConnectionError, asyncio.TimeoutError))
            ):
                logger.warning(
                    json.dumps(
                        {
                            "msg": "proxy_retry",
                            "reason": "connection",
                            "path": state.request.path,
                            "attempt": attempt + 1,
                            "error_type": type(e).__name__,
                            "latency_ms": latency_ms,
                        }
                    )
                )
                await asyncio.sleep(retry_delay)
                continue
            logger.error(
                json.dumps(
                    {
                        "msg": "proxy_error",
                        "path": state.request.path,
                        "error": str(e),
                        # Diagnostic (temporary): exception type + stage. Previously only
                        # str(e) was logged, but "Cannot write to closing transport" is thrown
                        # in all three of prepare / writing to the client / write_eof, and the
                        # message alone cannot tell which one it was.
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


#: The value of `created` in the OpenAI-compatible schema (the epoch of 2026-01-01T00:00:00Z).
#: Use a fixed constant rather than the current time: the `created` of the same model list
#: must be stable across responses, otherwise clients caching by that field would
#: continually invalidate.
_MODEL_CREATED_EPOCH = 1767225600


def _models_schema_for(request: web.Request) -> str:
    """The protocol format of the model-discovery response. The criterion is taken from
    **protocol-level request headers**, not the UA:

    - carries `anthropic-version` (the Anthropic SDK / Claude Code sends it on every request) → anthropic
    - carries `Authorization: Bearer ...` (the OpenAI SDK's auth method) → openai
    - neither → falls back to anthropic for the `/open/*` compatibility entry, and logs info

    The UA is a client product fingerprint, unrelated to the protocol; using it to judge the
    protocol is exactly the kind of approach this stage aims to eliminate.
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
    """GET /v1/models (or /open/v1/models): return all provider models.

    The same endpoint must serve clients of both protocols, and the response schema differs:
    - Anthropic (Claude Code's /model selector): `{data:[{type,id,display_name,
      created_at}], has_more, first_id, last_id}`
    - OpenAI (SDK `models.list()`): `{object:"list", data:[{id,object:"model",
      created, owned_by}]}`

    Providing only one would make the other protocol's SDK fail to parse.
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
    """Health check endpoint."""
    return web.json_response({"status": "ok"})


async def handle_usage_summary(request: web.Request) -> web.Response:
    """Today's usage summary (for Swift to query)."""
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
    except Exception as e:  # noqa: BLE001
        return web.json_response({"error": str(e)}, status=500)


async def handle_usage_layers(request: web.Request) -> web.Response:
    """Layered query: core exchange (end_turn) + process records (tool_use)."""
    try:
        level = request.query.get("level", "core")
        limit = int(request.query.get("limit", "50"))
        offset = int(request.query.get("offset", "0"))

        with dbconn(DB_PATH) as conn:
            if level == "core":
                # query only end_turn (core exchange)
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
                            ],  # actual_user_input first, fallback to input_preview
                            "output": r[4],
                            "input_tokens": r[5],
                            "output_tokens": r[6],
                            "stop_reason": r[7],
                            "latency_ms": r[8],
                            "model": r[9],
                        }
                    )
            elif level == "process":
                # query tool_use process records
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
                # query all
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
    except Exception as e:  # noqa: BLE001
        return web.json_response({"error": str(e)}, status=500)


# ---------------------------------------------------------------------------
# Gateway-layer log: middleware uniformly records rejected/failed/oversized requests,
# covering api_usage's troubleshooting blind spot. The recording implementation
# (record_gateway_log + constants + gateway_log table) is consolidated into proxy_usage.py;
# this entry point only keeps the middleware that catches exceptions and calls it, no longer
# maintaining the connection boilerplate separately.
# ---------------------------------------------------------------------------


@web.middleware
async def gateway_log_middleware(request, handler):
    """Wrap all routes: catch exceptions (including aiohttp 413 over-limit) and record the gateway log, without changing the original behavior."""
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
    # aiohttp's default client_max_size is only 1MB; once a Claude Code request body
    # (including CLAUDE.md/skills/MCP tool definitions) exceeds it, it directly returns
    # 413 "Maximum request body size exceeded" and never reaches the upstream.
    # Set 64MB for headroom, with the client's 32MB check as a fallback; the proxy is no
    # longer the bottleneck.
    app = web.Application(client_max_size=64 * 1024 * 1024)
    app.middlewares.append(gateway_log_middleware)
    # The upstream pool is process-wide, so it is closed once here, not per request.
    app.on_cleanup.append(_close_session)
    app.router.add_route("*", "/health", handle_health)
    app.router.add_route("GET", "/usage/summary", handle_usage_summary)
    app.router.add_route("GET", "/usage/layers", handle_usage_layers)
    # Two entries coexist: `/v1/*` is the protocol-native entry (the client need not configure
    # base_url to an unconventional prefix), `/open/*` is the legacy compatibility alias (users
    # who already configured ANTHROPIC_BASE_URL=.../open/v1 are unaffected). Registered after
    # /usage/* and /health so they are not shadowed; the two routes share the same handler and
    # the path is normalized in _upstream_path.
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
