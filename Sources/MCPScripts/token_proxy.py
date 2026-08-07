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
NOTES_DIR = os.environ.get(
    "NOTES_DIR", os.path.expanduser("~/Documents/selfdata/notes")
)
SYSTEM_PROMPTS_FILE = os.path.join(NOTES_DIR, "MCP", "System_Prompts.md")

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

    # 迁移：移除已废弃的三字段（session_id/project_path/estimated_cost_usd）
    # 先 DROP 引用列的索引，再 DROP COLUMN（SQLite 约束）
    if "session_id" in columns:
        conn.execute("DROP INDEX IF EXISTS idx_api_usage_session")
        conn.execute("ALTER TABLE api_usage DROP COLUMN session_id")
    if "project_path" in columns:
        conn.execute("DROP INDEX IF EXISTS idx_api_usage_project")
        conn.execute("ALTER TABLE api_usage DROP COLUMN project_path")
    if "estimated_cost_usd" in columns:
        conn.execute("ALTER TABLE api_usage DROP COLUMN estimated_cost_usd")
    conn.commit()

    # 修正历史：首日中断（stop_reason 为空串 ''）被默认回填为 core，修正归入 process
    # 当前写入逻辑对 stop_reason 空归 process，新数据不会产生该组合，幂等无害
    conn.execute(
        "UPDATE api_usage SET request_level = 'process' "
        "WHERE request_level = 'core' AND (stop_reason IS NULL OR stop_reason = '')"
    )
    conn.commit()

    # 三个月自动清理
    conn.execute("DELETE FROM api_usage WHERE timestamp < datetime('now', '-3 months')")
    conn.commit()
    conn.close()


# ---------------------------------------------------------------------------
# UsageFieldResolver — 智能 usage 字段路径解析
# ---------------------------------------------------------------------------


class UsageFieldResolver:
    """根据 provider/model 智能定位 usage 字段路径。

    已知 provider 路径映射（避免 LLM 回调）：
      - Anthropic/DeepSeek：usage.input_tokens / usage.output_tokens
      - OpenAI：usage.prompt_tokens / usage.completion_tokens
    """

    # 已知字段路径（model name 前缀匹配 → paths dict）
    _KNOWN_PATTERNS: list[tuple[str, dict]] = [
        (
            "anthropic",
            {
                "input_path": "usage.input_tokens",
                "output_path": "usage.output_tokens",
                "cache_read_path": "usage.cache_read_input_tokens",
                "cache_write_path": "usage.cache_creation_input_tokens",
            },
        ),
        (
            "claude",
            {
                "input_path": "usage.input_tokens",
                "output_path": "usage.output_tokens",
                "cache_read_path": "usage.cache_read_input_tokens",
                "cache_write_path": "usage.cache_creation_input_tokens",
            },
        ),
        (
            "deepseek",
            {
                "input_path": "usage.input_tokens",
                "output_path": "usage.output_tokens",
                "cache_read_path": "usage.cache_read_input_tokens",
                "cache_write_path": "usage.cache_creation_input_tokens",
            },
        ),
        (
            "gpt",
            {
                "input_path": "usage.prompt_tokens",
                "output_path": "usage.completion_tokens",
                "cache_read_path": "usage.prompt_tokens_details.cached_tokens",
                "cache_write_path": "",
            },
        ),
        (
            "o1",
            {
                "input_path": "usage.prompt_tokens",
                "output_path": "usage.completion_tokens",
                "cache_read_path": "",
                "cache_write_path": "",
            },
        ),
        (
            "o3",
            {
                "input_path": "usage.prompt_tokens",
                "output_path": "usage.completion_tokens",
                "cache_read_path": "",
                "cache_write_path": "",
            },
        ),
    ]

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
            # 尝试已知 pattern 匹配
            for prefix, known_paths in self._KNOWN_PATTERNS:
                if model.lower().startswith(prefix):
                    paths = known_paths
                    self._cache[key] = paths
                    self._save_to_db(provider, model, paths)
                    break

        if not paths:
            # 从 response body 的 usage 字段名自动探测
            usage_data = response_body.get("usage", {})
            if isinstance(usage_data, dict):
                if "input_tokens" in usage_data:
                    paths = {
                        "input_path": "usage.input_tokens",
                        "output_path": "usage.output_tokens",
                        "cache_read_path": "usage.cache_read_input_tokens",
                        "cache_write_path": "usage.cache_creation_input_tokens",
                    }
                elif "prompt_tokens" in usage_data:
                    paths = {
                        "input_path": "usage.prompt_tokens",
                        "output_path": "usage.completion_tokens",
                        "cache_read_path": "usage.prompt_tokens_details.cached_tokens",
                        "cache_write_path": "",
                    }
            if paths:
                self._cache[key] = paths
                self._save_to_db(provider, model, paths)

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
    """从消息内容中提取纯文本，跳过各种 system-reminder 标签。

    兼容 Anthropic（content list of blocks）和 OpenAI（content string）格式。
    """
    if content is None:
        return ""
    if isinstance(content, list):
        text_parts = [
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        content = " ".join(text_parts) if text_parts else ""
    content_str = str(content)
    # 跳过所有 system-reminder 类型的标签（包括 <system-reminder> 和 <local-command-caveat> 等）
    while True:
        start = content_str.find("<")
        if start == -1:
            break
        end = content_str.find(">", start)
        if end == -1:
            break
        tag = content_str[start : end + 1]
        # 关闭标签
        close_tag = f"</{tag[1:]}"
        close_start = content_str.find(close_tag)
        if close_start != -1:
            close_end = close_start + len(close_tag)
            content_str = content_str[:start] + content_str[close_end:].strip()
        else:
            content_str = content_str[:start] + content_str[end + 1 :].strip()
    return content_str.strip()


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

    # 检查是否有 tool_result（兼容两种格式）
    for msg in messages:
        if msg.get("role") == "tool":
            ctx["has_tool_result"] = 1
            ctx["request_type"] = "tool_result"
            break
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
            if content_str.strip():
                user_texts.append(content_str[:200])
    ctx["input_preview"] = " | ".join(user_texts)

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
    ctx["actual_user_input"] = " | ".join(actual_parts) if actual_parts else ""

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
    tool_name_override: str = "",
    api_format: str = "anthropic",
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

    # 提取 tool_name：SSE 流提取优先 > 请求体 assistant 消息兜底
    tool_name = tool_name_override
    if not tool_name and stop_reason == "tool_use":
        # 从请求中提取工具名称（兜底）
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
        "latency_ms": latency_ms,
        "api_format": api_format,
        "request_level": request_level,
        "tool_name": tool_name,
        "parent_id": None,
        "error_message": error_message,
    }

    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.execute(
            "INSERT INTO api_usage "
            "(timestamp, request_type, context_summary, "
            "input_preview, actual_user_input, input_message_count, has_tool_result, output_preview, "
            "output_type, stop_reason, response_valid, model, input_tokens, "
            "output_tokens, cache_read_tokens, cache_write_tokens, "
            "latency_ms, api_format, request_level, tool_name, parent_id, error_message) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                record["timestamp"],
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


# ---------------------------------------------------------------------------
# System Prompt 注入
# ---------------------------------------------------------------------------


def _detect_api_format(body: dict) -> str:
    """从请求体检测 API 格式：'anthropic' 或 'openai'。"""
    if "system" in body and isinstance(body.get("system"), list):
        return "anthropic"
    messages = body.get("messages", [])
    if messages and messages[0].get("role") == "system":
        return "openai"
    tools = body.get("tools", [])
    if tools:
        if "inputSchema" in tools[0]:
            return "anthropic"
        if isinstance(tools[0], dict) and tools[0].get("type") == "function":
            return "openai"
    return "anthropic"


def _is_claude_code(headers) -> bool:
    """判断请求是否来自 Claude Code（请求头特征，非内容匹配）。

    用协议级特征而非具体文案：x-anthropic-billing-header 是 Claude Code
    特有的请求头；User-Agent 兜底含 "claude"。其他客户端（codex/curl 等）
    不满足，不会触发 classifier 处理。
    """
    if headers.get("x-anthropic-billing-header"):
        return True
    return "claude" in headers.get("user-agent", "").lower()


def _is_classifier_candidate(body: dict) -> bool:
    """结构启发式判断是否 classifier 候选：stream != true + tools 空 + messages ≤ 2。

    不匹配任何硬编码签名（签名随 Claude Code 版本变化，泛化避免静默失效）。
    v2.1.160+ 的 classifier 请求带 assistant pre-fill，messages 为 2 条；
    真实对话几十到上百条。
    """
    if body.get("stream"):
        return False
    if body.get("tools"):
        return False
    return len(body.get("messages", [])) <= 2


def _inject_classifier_disabled(body: dict, api_format: str) -> None:
    """向请求体注入 thinking disabled（deepseek 兼容层），并移除旧版参数。"""
    if api_format == "anthropic":
        body["thinking"] = {"type": "disabled"}
        for k in ("reasoning_effort", "output_config"):
            body.pop(k, None)
    else:
        # openai 格式：无 thinking 参数，移除 reasoning_effort 即可
        body.pop("reasoning_effort", None)


# 缓存：文件内容 + mtime，mtime 未变时不重新读盘
_sys_prompt_content: str | None = None
_sys_prompt_mtime: float = 0

# 首次请求标志，用于调试日志
_logged_first_body: bool = False


def _inject_system_prompt(body: dict) -> bytes | None:
    """读取 System_Prompts.md 注入到请求体的 system 字段。

    返回修改后的 body_bytes，文件不存在或读取失败时返回 None。
    注入的提示词不设置 cache_control，保证每次请求都携带。
    文件 mtime 未变时跳过读盘，使用缓存的内容。
    """
    global _sys_prompt_content, _sys_prompt_mtime

    try:
        current_mtime = os.path.getmtime(SYSTEM_PROMPTS_FILE)
    except OSError:
        _sys_prompt_content = None
        return None

    if current_mtime != _sys_prompt_mtime:
        try:
            with open(SYSTEM_PROMPTS_FILE, "r", encoding="utf-8") as f:
                content = f.read().strip()
            _sys_prompt_content = content if content else None
            _sys_prompt_mtime = current_mtime
        except Exception as e:
            _sys_prompt_content = None
            logger.warning(
                json.dumps({"msg": "system_prompt_read_failed", "error": str(e)})
            )
            return None

    if _sys_prompt_content is None:
        return None

    fmt = _detect_api_format(body)
    if fmt == "anthropic":
        body.setdefault("system", [])
        body["system"].append(
            {
                "type": "text",
                "text": _sys_prompt_content,
            }
        )
    else:
        messages = body.setdefault("messages", [])
        if messages and isinstance(messages[0].get("content"), str):
            # 常见 case：system content 是字符串 → 转数组，原始内容设断点，注入内容在断点后
            messages[0]["content"] = [
                {
                    "type": "text",
                    "text": messages[0]["content"],
                    "prompt_cache_breakpoint": {"mode": "explicit"},
                },
                {"type": "text", "text": _sys_prompt_content},
            ]
        elif messages and isinstance(messages[0].get("content"), list):
            # system content 已是数组：最后一个 dict 块设断点，追加注入
            blocks = list(messages[0].get("content", []))
            for i in range(len(blocks) - 1, -1, -1):
                if (
                    isinstance(blocks[i], dict)
                    and "prompt_cache_breakpoint" not in blocks[i]
                ):
                    blocks[i] = {
                        **blocks[i],
                        "prompt_cache_breakpoint": {"mode": "explicit"},
                    }
                    break
            blocks.append({"type": "text", "text": _sys_prompt_content})
            messages[0]["content"] = blocks
        else:
            # 无 system 消息：插入，空块断点后接注入
            messages.insert(
                0,
                {
                    "role": "system",
                    "content": [
                        {
                            "type": "text",
                            "text": "",
                            "prompt_cache_breakpoint": {"mode": "explicit"},
                        },
                        {"type": "text", "text": _sys_prompt_content},
                    ],
                },
            )

    return json.dumps(body).encode()


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

    # 检测 API 格式（anthropic / openai）
    api_format = _detect_api_format(request_body)

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

    # System prompt 注入：从 System_Prompts.md 读取并追加（无缓存）
    injected = _inject_system_prompt(request_body)
    if injected is not None:
        body_bytes = injected

    # 首次请求日志：输出注入后的完整 body，用于验证系统提示词生效
    global _logged_first_body
    if not _logged_first_body:
        _logged_first_body = True
        try:
            parsed = json.loads(body_bytes)
            # 只输出 system 字段和 model，避免刷屏
            log_body = {
                "model": parsed.get("model", ""),
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

    # 转发 headers（透传 API Key 等）
    headers = {}
    skip_headers = {"host", "content-length", "transfer-encoding"}
    for k, v in request.headers.items():
        if k.lower() not in skip_headers:
            headers[k] = v

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
                        sock_read=30,
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

                    try:
                        async for chunk in upstream_resp.content.iter_any():
                            await response.write(chunk)
                            if is_sse:
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

                    # 从 SSE 流中提取最后一个 chunk 的 usage 和输出内容
                    if is_sse and collected_body:
                        sse_bytes = bytes(collected_body)
                        usage_data = _extract_usage_from_sse(
                            sse_bytes, api_format=api_format
                        )
                        output_preview = _extract_output_from_sse(
                            sse_bytes, api_format=api_format
                        )
                        tool_name = _extract_tool_name_from_sse(
                            sse_bytes, api_format=api_format
                        )
                        if usage_data:
                            # 补充 model：部分 API 的 SSE 响应不含 model 字段
                            if not usage_data.get("model"):
                                usage_data["model"] = request_body.get(
                                    "model", "unknown"
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
                                    request_body,
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


def _extract_usage_from_sse(
    sse_data: bytes, api_format: str = "anthropic"
) -> dict | None:
    """从 SSE 流中提取最后一个包含 usage 的 chunk。

    api_format="openai" 时：
      - usage 字段使用 prompt_tokens/completion_tokens
      - finish_reason 映射为 stop_reason
      - 归一化为 input_tokens/output_tokens/cache_read_input_tokens 字段名
    """
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

            if "model" in chunk:
                detected_model = chunk["model"]

            if api_format == "anthropic":
                sr = chunk.get("stop_reason") or (chunk.get("delta") or {}).get(
                    "stop_reason"
                )
                if sr:
                    detected_stop_reason = sr
            else:
                # OpenAI: finish_reason 在 choices[0]
                choices = chunk.get("choices", [])
                if choices:
                    fr = choices[0].get("finish_reason")
                    if fr:
                        # 映射 OpenAI finish_reason → 统一 stop_reason
                        _map = {
                            "stop": "end_turn",
                            "tool_calls": "tool_use",
                            "length": "max_tokens",
                            "content_filter": "content_filter",
                        }
                        detected_stop_reason = _map.get(fr, fr)

            if "usage" in chunk:
                last_usage = chunk
        except json.JSONDecodeError:
            continue

    if last_usage:
        if detected_model:
            last_usage["model"] = detected_model
        if detected_stop_reason:
            last_usage["stop_reason"] = detected_stop_reason

        if api_format == "openai":
            # 归一化 OpenAI usage 字段名到统一格式
            u = last_usage.get("usage", {})
            if "prompt_tokens" in u:
                u["input_tokens"] = u["prompt_tokens"]
            if "completion_tokens" in u:
                u["output_tokens"] = u["completion_tokens"]
            details = u.get("prompt_tokens_details", {})
            if isinstance(details, dict) and "cached_tokens" in details:
                u["cache_read_input_tokens"] = details["cached_tokens"]

    return last_usage


def _extract_output_from_sse(sse_data: bytes, api_format: str = "anthropic") -> str:
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

            if api_format == "anthropic":
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
            else:
                # OpenAI: choices[0].delta.content
                choices = chunk.get("choices", [])
                if choices:
                    delta = choices[0].get("delta", {})
                    content = delta.get("content")
                    if content is not None:
                        output_text.append(content)
        except json.JSONDecodeError:
            continue
    # 截取前 2000 字符
    full_text = "".join(output_text)
    return full_text[:2000] if full_text else ""


def _extract_tool_name_from_sse(sse_data: bytes, api_format: str = "anthropic") -> str:
    """从 SSE 流中提取 tool_use/tool_calls 的工具名。"""
    if api_format == "anthropic":
        # Anthropic: content_block_start → content_block.name
        for line in sse_data.decode("utf-8", errors="replace").split("\n"):
            if not line.startswith("data: "):
                continue
            data_str = line[6:].strip()
            if data_str == "[DONE]":
                break
            try:
                chunk = json.loads(data_str)
                if chunk.get("type") == "content_block_start":
                    block = chunk.get("content_block", {})
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        name = block.get("name", "")
                        if name:
                            return name
            except json.JSONDecodeError:
                continue
    else:
        # OpenAI: choices[0].delta.tool_calls[0].function.name
        for line in sse_data.decode("utf-8", errors="replace").split("\n"):
            if not line.startswith("data: "):
                continue
            data_str = line[6:].strip()
            if data_str == "[DONE]":
                break
            try:
                chunk = json.loads(data_str)
                choices = chunk.get("choices", [])
                if choices:
                    delta = choices[0].get("delta", {})
                    tool_calls = delta.get("tool_calls", [])
                    if tool_calls:
                        for tc in tool_calls:
                            fn = tc.get("function", {})
                            name = fn.get("name", "")
                            if name:
                                return name
            except json.JSONDecodeError:
                continue
    return ""


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
