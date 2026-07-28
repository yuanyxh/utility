"""Token 代理监控服务。

拦截 Claude Code → API 的请求，记录 token 用量和请求上下文。
"""

import asyncio
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import aiohttp
from aiohttp import web

from log_utils import setup_logging

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("MODEL_PROXY_PORT", "8080"))
UPSTREAM_URL = os.environ.get("MODEL_PROXY_URL", "")  # 为空则拒绝请求
DB_DIR = os.environ.get("UTILITY_DATA_DIR", os.path.expanduser("~/.config/utility"))
DB_PATH = os.path.join(DB_DIR, "token_usage.sqlite")
LLM_API_URL = os.environ.get("SUMMARY_API_URL", "")
LLM_API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
LLM_MODEL = os.environ.get("SUMMARY_MODEL", "")

logger = setup_logging("token_proxy", json_format=True)

# ---------------------------------------------------------------------------
# SQLite 初始化
# ---------------------------------------------------------------------------


def init_db():
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS api_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            session_id TEXT,
            project_path TEXT,
            request_type TEXT,
            context_summary TEXT,
            input_preview TEXT,
            input_message_count INTEGER,
            has_tool_result INTEGER DEFAULT 0,
            output_preview TEXT,
            output_type TEXT,
            stop_reason TEXT,
            response_valid INTEGER DEFAULT 1,
            model TEXT,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            estimated_cost_usd REAL DEFAULT 0,
            latency_ms INTEGER DEFAULT 0,
            api_format TEXT,
            request_level TEXT DEFAULT 'core',
            tool_name TEXT,
            parent_id INTEGER,
            actual_user_input TEXT,
            error_message TEXT
        );
        CREATE TABLE IF NOT EXISTS usage_field_cache (
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            input_path TEXT,
            output_path TEXT,
            cache_read_path TEXT,
            cache_write_path TEXT,
            updated_at TEXT,
            PRIMARY KEY (provider, model)
        );
        CREATE INDEX IF NOT EXISTS idx_api_usage_timestamp ON api_usage(timestamp);
        CREATE INDEX IF NOT EXISTS idx_api_usage_session ON api_usage(session_id);
        CREATE INDEX IF NOT EXISTS idx_api_usage_project ON api_usage(project_path);
        CREATE INDEX IF NOT EXISTS idx_api_usage_level ON api_usage(request_level);
    """)

    # 迁移：为旧表添加新列（如果不存在）
    cursor = conn.execute("PRAGMA table_info(api_usage)")
    columns = [row[1] for row in cursor.fetchall()]
    if "request_level" not in columns:
        conn.execute(
            "ALTER TABLE api_usage ADD COLUMN request_level TEXT DEFAULT 'core'"
        )
        conn.execute("ALTER TABLE api_usage ADD COLUMN tool_name TEXT")
        conn.execute("ALTER TABLE api_usage ADD COLUMN parent_id INTEGER")
        conn.execute("ALTER TABLE api_usage ADD COLUMN actual_user_input TEXT")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_api_usage_level ON api_usage(request_level)"
        )
        # 根据 stop_reason 回填 request_level
        conn.execute(
            "UPDATE api_usage SET request_level = 'process' WHERE stop_reason = 'tool_use'"
        )
        conn.commit()
    if "error_message" not in columns:
        conn.execute("ALTER TABLE api_usage ADD COLUMN error_message TEXT")
        conn.commit()

    # 三个月自动清理
    conn.execute("DELETE FROM api_usage WHERE timestamp < datetime('now', '-3 months')")
    conn.commit()
    conn.close()


# ---------------------------------------------------------------------------
# UsageFieldResolver — 智能 usage 字段路径解析
# ---------------------------------------------------------------------------


class UsageFieldResolver:
    """根据 provider/model 智能定位 usage 字段路径。"""

    def __init__(self):
        self._cache: dict[tuple[str, str], dict] = {}

    def _load_from_db(self, provider: str, model: str) -> dict | None:
        try:
            conn = sqlite3.connect(DB_PATH)
            row = conn.execute(
                "SELECT input_path, output_path, cache_read_path, cache_write_path "
                "FROM usage_field_cache WHERE provider=? AND model=?",
                (provider, model),
            ).fetchone()
            conn.close()
            if row:
                return {
                    "input_path": row[0],
                    "output_path": row[1],
                    "cache_read_path": row[2],
                    "cache_write_path": row[3],
                }
        except Exception:
            pass
        return None

    def _save_to_db(self, provider: str, model: str, paths: dict):
        try:
            conn = sqlite3.connect(DB_PATH)
            conn.execute(
                "INSERT OR REPLACE INTO usage_field_cache "
                "(provider, model, input_path, output_path, cache_read_path, cache_write_path, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    provider,
                    model,
                    paths.get("input_path", ""),
                    paths.get("output_path", ""),
                    paths.get("cache_read_path", ""),
                    paths.get("cache_write_path", ""),
                    datetime.now(timezone.utc).isoformat(),
                ),
            )
            conn.commit()
            conn.close()
        except Exception:
            pass

    async def _ask_model(self, sample_response: dict) -> dict | None:
        """调用主模型识别 usage 字段路径。"""
        if not LLM_API_URL or not LLM_API_KEY:
            return None

        prompt = (
            "Analyze this API response JSON and identify the exact field paths for token usage. "
            "Return ONLY a JSON object with these keys: "
            "input_path, output_path, cache_read_path, cache_write_path. "
            "Each value is a dot-separated path like 'usage.input_tokens'. "
            "If a field doesn't exist, use empty string.\n\n"
            "Note: streaming SSE responses may nest usage under 'delta', "
            "e.g. delta.usage.input_tokens. Use the ACTUAL structure in the sample.\n\n"
            f"Response sample:\n{json.dumps(sample_response, indent=2)[:2000]}"
        )

        payload = {
            "model": LLM_MODEL,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0,
            "max_tokens": 300,
        }
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {LLM_API_KEY}",
        }

        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{LLM_API_URL}/chat/completions",
                    json=payload,
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=15),
                ) as resp:
                    if resp.status != 200:
                        return None
                    data = await resp.json()
                    content = data["choices"][0]["message"]["content"]
                    # 提取 JSON
                    start = content.index("{")
                    end = content.rindex("}") + 1
                    return json.loads(content[start:end])
        except Exception as e:
            logger.warning(
                json.dumps({"msg": "usage_resolver_ask_failed", "error": str(e)})
            )
            return None

    def _get_by_path(self, obj: dict, path: str):
        """按 dot-separated path 取值。"""
        if not path:
            return None
        parts = path.split(".")
        cur = obj
        for p in parts:
            if isinstance(cur, dict) and p in cur:
                cur = cur[p]
            else:
                return None
        return cur

    async def resolve(self, response_body: dict, provider: str = "default") -> dict:
        """解析 usage 字段，返回 {input_tokens, output_tokens, cache_read_tokens, cache_write_tokens}。"""
        model = response_body.get("model", "unknown")
        key = (provider, model)

        paths = self._cache.get(key) or self._load_from_db(provider, model)

        if not paths:
            # 首次遇到此 model，调用模型识别
            paths = await self._ask_model(response_body)
            if paths:
                self._cache[key] = paths
                self._save_to_db(provider, model, paths)
                logger.info(
                    json.dumps(
                        {
                            "msg": "usage_resolver_new_model",
                            "model": model,
                            "paths": paths,
                        }
                    )
                )
            else:
                # 无法识别，返回零值
                return self._zero_usage()

        # 用缓存路径取值
        usage = {
            "input_tokens": self._safe_int(
                self._get_by_path(response_body, paths.get("input_path", ""))
            ),
            "output_tokens": self._safe_int(
                self._get_by_path(response_body, paths.get("output_path", ""))
            ),
            "cache_read_tokens": self._safe_int(
                self._get_by_path(response_body, paths.get("cache_read_path", ""))
            ),
            "cache_write_tokens": self._safe_int(
                self._get_by_path(response_body, paths.get("cache_write_path", ""))
            ),
        }

        # 如果取到的值全为 0，可能是路径失效，刷新一次
        if all(v == 0 for v in usage.values()):
            refreshed_paths = await self._ask_model(response_body)
            if refreshed_paths and refreshed_paths != paths:
                self._cache[key] = refreshed_paths
                self._save_to_db(provider, model, refreshed_paths)
                usage = {
                    "input_tokens": self._safe_int(
                        self._get_by_path(
                            response_body, refreshed_paths.get("input_path", "")
                        )
                    ),
                    "output_tokens": self._safe_int(
                        self._get_by_path(
                            response_body, refreshed_paths.get("output_path", "")
                        )
                    ),
                    "cache_read_tokens": self._safe_int(
                        self._get_by_path(
                            response_body, refreshed_paths.get("cache_read_path", "")
                        )
                    ),
                    "cache_write_tokens": self._safe_int(
                        self._get_by_path(
                            response_body, refreshed_paths.get("cache_write_path", "")
                        )
                    ),
                }
                logger.info(
                    json.dumps(
                        {
                            "msg": "usage_resolver_refreshed",
                            "model": model,
                            "new_paths": refreshed_paths,
                        }
                    )
                )

        return usage

    @staticmethod
    def _safe_int(val) -> int:
        if val is None:
            return 0
        try:
            return int(val)
        except (ValueError, TypeError):
            return 0

    @staticmethod
    def _zero_usage() -> dict:
        return {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
        }


# ---------------------------------------------------------------------------
# TokenRecorder — 数据记录
# ---------------------------------------------------------------------------

resolver = UsageFieldResolver()


def _extract_user_text(content) -> str:
    """从消息内容中提取纯文本，跳过 system-reminder。"""
    if isinstance(content, list):
        text_parts = [
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        content = " ".join(text_parts)
    content_str = str(content)
    # 跳过 system-reminder
    if "<system-reminder>" in content_str:
        end_tag = "</system-reminder>"
        end_idx = content_str.find(end_tag)
        if end_idx != -1:
            content_str = content_str[end_idx + len(end_tag) :].strip()
    return content_str


# 续接提示词前缀，用于识别 Claude Code 注入的会话续接
CONTINUATION_PREFIX = "This session is being continued from a previous conversation"


def extract_request_context(body: dict) -> dict:
    """从 Claude Code 请求 body 提取上下文信息。"""
    ctx = {
        "request_type": "conversation",
        "context_summary": "",
        "input_preview": "",
        "actual_user_input": "",
        "input_message_count": 0,
        "has_tool_result": 0,
    }

    messages = body.get("messages", [])
    ctx["input_message_count"] = len(messages)

    if body.get("tools"):
        ctx["request_type"] = "tool_use"

    # 检查是否有 tool_result
    for msg in messages:
        if isinstance(msg.get("content"), list):
            for block in msg["content"]:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    ctx["has_tool_result"] = 1
                    ctx["request_type"] = "tool_result"
                    break

    # 提取最后一条 user message 作为 context_summary
    for msg in reversed(messages):
        if msg.get("role") == "user":
            content_str = _extract_user_text(msg.get("content", ""))
            ctx["context_summary"] = content_str[:100]
            break

    # input_preview: 所有 user messages 前 200 字拼接，跳过续接提示词
    user_texts = []
    for msg in messages:
        if msg.get("role") == "user":
            content_str = _extract_user_text(msg.get("content", ""))
            # 跳过续接提示词
            if content_str.startswith(CONTINUATION_PREFIX):
                continue
            # 跳过纯摘要内容
            if content_str.strip().startswith("Summary:"):
                continue
            user_texts.append(content_str[:200])
    ctx["input_preview"] = " | ".join(user_texts)[:200]

    # actual_user_input: 提取用户实际输入，跳过续接提示词和 system-reminder
    actual_parts = []
    for msg in messages:
        if msg.get("role") == "user":
            content_str = _extract_user_text(msg.get("content", ""))
            # 跳过续接提示词
            if content_str.startswith(CONTINUATION_PREFIX):
                # 续接提示词后可能有实际用户输入，用 "Summary:" 分隔
                summary_idx = content_str.find("Summary:")
                if summary_idx != -1:
                    # 续接提示词结束，后面是摘要
                    continue
                continue
            # 跳过纯摘要内容（以 "Summary:" 开头）
            if content_str.strip().startswith("Summary:"):
                continue
            if content_str.strip():
                actual_parts.append(content_str[:500])
    ctx["actual_user_input"] = " | ".join(actual_parts)[:500] if actual_parts else ""

    return ctx


def extract_response_context(usage_data: dict) -> dict:
    """从 usage 数据提取响应上下文。"""
    stop_reason = (
        usage_data.get("stop_reason")
        or (usage_data.get("delta") or {}).get("stop_reason")
        or ""
    )
    # 只有 error 和空响应算无效，max_tokens/end_turn/stop_sequence 都是正常
    response_valid = 0 if stop_reason == "error" else 1

    # 提取错误信息
    error_message = ""
    if stop_reason == "error":
        error_data = usage_data.get("error", {})
        if isinstance(error_data, dict):
            error_message = error_data.get("message", str(error_data))
        elif isinstance(error_data, str):
            error_message = error_data
    elif usage_data.get("error"):
        error_data = usage_data.get("error", {})
        if isinstance(error_data, dict):
            error_message = error_data.get("message", str(error_data))
        elif isinstance(error_data, str):
            error_message = error_data

    return {
        "output_type": "text",
        "stop_reason": stop_reason,
        "response_valid": response_valid,
        "error_message": error_message,
    }


async def record_usage(
    request_body: dict,
    response_body: dict,
    status: int,
    latency_ms: int,
    output_preview: str = "",
    error_message: str = "",
):
    """记录一次 API 调用的 token 用量。"""
    if status != 200:
        return

    # 解析 usage
    usage = await resolver.resolve(response_body)

    # 提取上下文
    req_ctx = extract_request_context(request_body)
    resp_ctx = extract_response_context(response_body)

    model = response_body.get("model", "unknown")
    stop_reason = resp_ctx["stop_reason"]

    # 使用 resp_ctx 中的 error_message（如果未提供）
    if not error_message:
        error_message = resp_ctx.get("error_message", "")

    # 确定 request_level
    request_level = "core" if stop_reason == "end_turn" else "process"

    # 提取 tool_name（如果有的话）
    tool_name = ""
    if request_body.get("tools") and stop_reason == "tool_use":
        # 从请求中提取工具名称
        messages = request_body.get("messages", [])
        for msg in reversed(messages):
            if msg.get("role") == "assistant":
                content = msg.get("content", [])
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tool_name = block.get("name", "")
                            break
                if tool_name:
                    break

    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "session_id": request_body.get("metadata", {}).get("session_id", ""),
        "project_path": _detect_project(request_body),
        "request_type": req_ctx["request_type"],
        "context_summary": req_ctx["context_summary"],
        "input_preview": req_ctx["input_preview"],
        "actual_user_input": req_ctx["actual_user_input"],
        "input_message_count": req_ctx["input_message_count"],
        "has_tool_result": req_ctx["has_tool_result"],
        "output_preview": output_preview,
        "output_type": resp_ctx["output_type"],
        "stop_reason": stop_reason,
        "response_valid": resp_ctx["response_valid"],
        "model": model,
        "input_tokens": usage["input_tokens"],
        "output_tokens": usage["output_tokens"],
        "cache_read_tokens": usage["cache_read_tokens"],
        "cache_write_tokens": usage["cache_write_tokens"],
        "estimated_cost_usd": 0,
        "latency_ms": latency_ms,
        "api_format": "anthropic",
        "request_level": request_level,
        "tool_name": tool_name,
        "parent_id": None,
        "error_message": error_message,
    }

    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.execute(
            "INSERT INTO api_usage "
            "(timestamp, session_id, project_path, request_type, context_summary, "
            "input_preview, actual_user_input, input_message_count, has_tool_result, output_preview, "
            "output_type, stop_reason, response_valid, model, input_tokens, "
            "output_tokens, cache_read_tokens, cache_write_tokens, "
            "estimated_cost_usd, latency_ms, api_format, request_level, tool_name, parent_id, error_message) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                record["timestamp"],
                record["session_id"],
                record["project_path"],
                record["request_type"],
                record["context_summary"],
                record["input_preview"],
                record["actual_user_input"],
                record["input_message_count"],
                record["has_tool_result"],
                record["output_preview"],
                record["output_type"],
                record["stop_reason"],
                record["response_valid"],
                record["model"],
                record["input_tokens"],
                record["output_tokens"],
                record["cache_read_tokens"],
                record["cache_write_tokens"],
                record["estimated_cost_usd"],
                record["latency_ms"],
                record["api_format"],
                record["request_level"],
                record["tool_name"],
                record["parent_id"],
                record["error_message"],
            ),
        )
        record_id = cursor.lastrowid
        conn.commit()
        conn.close()
        logger.info(
            json.dumps(
                {
                    "msg": "usage_recorded",
                    "model": model,
                    "input_tokens": usage["input_tokens"],
                    "output_tokens": usage["output_tokens"],
                    "latency_ms": latency_ms,
                    "request_level": request_level,
                    "tool_name": tool_name,
                }
            )
        )
    except Exception as e:
        logger.error(json.dumps({"msg": "usage_record_failed", "error": str(e)}))


def _detect_project(body: dict) -> str:
    """尝试从请求中检测项目路径。"""
    metadata = body.get("metadata", {})
    return metadata.get("project_path", "")


# ---------------------------------------------------------------------------
# ProxyServer — aiohttp 反向代理
# ---------------------------------------------------------------------------


async def handle_proxy(request: web.Request) -> web.StreamResponse:
    """转发请求到上游 API，流式返回响应。"""
    if not UPSTREAM_URL:
        return web.json_response(
            {"error": "MODEL_PROXY_URL not configured"},
            status=503,
        )

    # 构建上游 URL
    # Claude Code 发送 ANTHROPIC_BASE_URL + "/messages"
    # 代理监听 /open，捕获 path，原样转发到上游
    # 例: /open/v1/messages → path="v1/messages" → UPSTREAM_URL/v1/messages
    path = request.match_info.get("path", "")
    upstream = f"{UPSTREAM_URL}/{path}"
    if request.query_string:
        upstream += f"?{request.query_string}"

    # 读取请求 body
    body_bytes = await request.read()
    request_body = {}
    try:
        request_body = json.loads(body_bytes) if body_bytes else {}
    except json.JSONDecodeError:
        pass

    # 转发 headers（透传 API Key 等）
    headers = {}
    skip_headers = {"host", "content-length", "transfer-encoding"}
    for k, v in request.headers.items():
        if k.lower() not in skip_headers:
            headers[k] = v

    start_time = time.monotonic()

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

                # 流式转发响应
                response = web.StreamResponse(
                    status=upstream_resp.status,
                    headers={
                        k: v
                        for k, v in upstream_resp.headers.items()
                        if k.lower() not in {"transfer-encoding", "content-encoding"}
                    },
                )
                await response.prepare(request)

                # 收集 SSE chunks 以提取 usage
                collected_body = bytearray()
                is_sse = "text/event-stream" in upstream_resp.headers.get(
                    "content-type", ""
                )

                try:
                    async for chunk in upstream_resp.content.iter_any():
                        await response.write(chunk)
                        if is_sse:
                            collected_body.extend(chunk)
                except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
                    # 客户端已断开连接，停止转发
                    pass

                await response.write_eof()

                # 从 SSE 流中提取最后一个 chunk 的 usage 和输出内容
                if is_sse and collected_body:
                    sse_bytes = bytes(collected_body)
                    usage_data = _extract_usage_from_sse(sse_bytes)
                    output_preview = _extract_output_from_sse(sse_bytes)
                    if usage_data:
                        # 补充 model：部分 API 的 SSE 响应不含 model 字段
                        if not usage_data.get("model"):
                            usage_data["model"] = request_body.get("model", "unknown")
                        # 提取错误信息（如果有的话）
                        error_message = ""
                        if upstream_resp.status >= 400:
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
                                request_body,
                                usage_data,
                                upstream_resp.status,
                                latency_ms,
                                output_preview,
                                error_message,
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


def _extract_usage_from_sse(sse_data: bytes) -> dict | None:
    """从 SSE 流中提取最后一个包含 usage 的 chunk。"""
    last_usage = None
    detected_model = ""
    detected_stop_reason = ""
    for line in sse_data.decode("utf-8", errors="replace").split("\n"):
        if not line.startswith("data: "):
            continue
        data_str = line[6:].strip()
        if data_str == "[DONE]":
            break
        try:
            chunk = json.loads(data_str)
            # model 在首批 chunk 中出现，需单独跟踪
            if "model" in chunk:
                detected_model = chunk["model"]
            sr = chunk.get("stop_reason") or (chunk.get("delta") or {}).get(
                "stop_reason"
            )
            if sr:
                detected_stop_reason = sr
            if "usage" in chunk:
                last_usage = chunk
        except json.JSONDecodeError:
            continue

    if last_usage:
        if detected_model:
            last_usage["model"] = detected_model
        if detected_stop_reason:
            last_usage["stop_reason"] = detected_stop_reason

    return last_usage


def _extract_output_from_sse(sse_data: bytes) -> str:
    """从 SSE 流中提取输出文本内容（取前 2000 字符）。"""
    output_text = []
    for line in sse_data.decode("utf-8", errors="replace").split("\n"):
        if not line.startswith("data: "):
            continue
        data_str = line[6:].strip()
        if data_str == "[DONE]":
            break
        try:
            chunk = json.loads(data_str)
            # 提取 content_delta 中的文本
            delta = chunk.get("delta", {})
            if "text" in delta:
                output_text.append(delta["text"])
            # 提取 content 数组中的文本
            content = chunk.get("content", [])
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        output_text.append(block.get("text", ""))
        except json.JSONDecodeError:
            continue
    # 截取前 2000 字符
    full_text = "".join(output_text)
    return full_text[:2000] if full_text else ""


async def handle_health(request: web.Request) -> web.Response:
    """健康检查端点。"""
    return web.json_response({"status": "ok"})


async def handle_usage_summary(request: web.Request) -> web.Response:
    """今日用量摘要（供 Swift 查询）。"""
    try:
        conn = sqlite3.connect(DB_PATH)
        row = conn.execute("""
            SELECT
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(cache_read_tokens), 0),
                COALESCE(SUM(estimated_cost_usd), 0),
                COUNT(*),
                SUM(CASE WHEN response_valid = 0 THEN 1 ELSE 0 END)
            FROM api_usage
            WHERE timestamp >= date('now', 'start of day')
        """).fetchone()
        conn.close()

        return web.json_response(
            {
                "input_tokens": row[0],
                "output_tokens": row[1],
                "cache_read_tokens": row[2],
                "estimated_cost_usd": row[3],
                "total_requests": row[4],
                "invalid_requests": row[5] or 0,
            }
        )
    except Exception as e:
        return web.json_response({"error": str(e)}, status=500)


async def handle_cost_by_project(request: web.Request) -> web.Response:
    """按项目分组的费用统计。"""
    try:
        conn = sqlite3.connect(DB_PATH)
        rows = conn.execute("""
            SELECT COALESCE(project_path, 'unknown') as project,
                   COALESCE(SUM(estimated_cost_usd), 0) as cost
            FROM api_usage
            WHERE timestamp >= date('now', 'start of day')
            GROUP BY project
            ORDER BY cost DESC
            LIMIT 10
        """).fetchall()
        conn.close()

        return web.json_response([{"project": r[0], "cost": r[1]} for r in rows])
    except Exception as e:
        return web.json_response({"error": str(e)}, status=500)


async def handle_usage_layers(request: web.Request) -> web.Response:
    """分层查询：核心交换（end_turn）+ 过程记录（tool_use）。"""
    try:
        level = request.query.get("level", "core")
        limit = int(request.query.get("limit", "50"))
        offset = int(request.query.get("offset", "0"))

        conn = sqlite3.connect(DB_PATH)
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

        conn.close()
        return web.json_response(result)
    except Exception as e:
        return web.json_response({"error": str(e)}, status=500)


# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------


def create_app() -> web.Application:
    app = web.Application()
    app.router.add_route("*", "/health", handle_health)
    app.router.add_route("GET", "/usage/summary", handle_usage_summary)
    app.router.add_route("GET", "/usage/by_project", handle_cost_by_project)
    app.router.add_route("GET", "/usage/layers", handle_usage_layers)
    app.router.add_route("*", "/open/{path:.*}", handle_proxy)
    return app


def main():
    if not UPSTREAM_URL:
        logger.error(
            json.dumps({"msg": "startup_failed", "error": "MODEL_PROXY_URL not set"})
        )
        sys.exit(1)

    init_db()
    logger.info(
        json.dumps(
            {
                "msg": "startup",
                "port": PORT,
                "upstream": UPSTREAM_URL,
                "db": DB_PATH,
            }
        )
    )

    app = create_app()
    web.run_app(app, host="127.0.0.1", port=PORT, print=None)


if __name__ == "__main__":
    main()
