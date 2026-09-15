"""token_proxy 的 token 用量记录层。

从 token_proxy.py 拆分（2026-08-30，重构阶段2）：DB 初始化、usage 字段路径解析
（UsageFieldResolver）、请求/响应上下文提取、usage 落库。代码原样搬移不改逻辑。
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
from datetime import datetime, timedelta, timezone

import aiohttp

from config import data_dir, deepseek_api_key, summary_model, summary_api_url
from db import conn as dbconn
from log_utils import setup_logging
from proxy_normalize import _result_text as result_text
from proxy_protocol import strip_injected_rules

# ---------------------------------------------------------------------------
# 配置（与拆分前 token_proxy.py 一致）
# ---------------------------------------------------------------------------

DB_DIR = data_dir()
DB_PATH = os.path.join(DB_DIR, "token_usage.sqlite")
# tool_output_log 独立库（与 token_usage.sqlite 同目录、独立管理）
TOOL_OUTPUT_DB_PATH = os.path.join(DB_DIR, "tool_output.sqlite")
# api_usage 保留天数（约 3 个月），启动时清理超期记录
API_USAGE_RETENTION_DAYS = 90
# tool_output_log 保留天数（短期，用于形态分析）
TOOL_OUTPUT_RETENTION_DAYS = 5
# gateway_log 记录范围与保留期：非 2xx + 请求体 >=512KB 预警，保留 90 天
GATEWAY_LOG_SIZE_THRESHOLD = 512 * 1024
GATEWAY_LOG_RETENTION_DAYS = 90
# LLM 配置（usage 字段路径解析用，见 UsageFieldResolver._ask_model）。
# 默认空串做「未配置即禁用」守卫——不要用 config 的默认真实值（会带空 URL 发起调用）。
LLM_API_URL = summary_api_url(default="")
LLM_API_KEY = deepseek_api_key()
LLM_MODEL = summary_model(default="")

logger = setup_logging("token_proxy", json_format=True)


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
            error_message TEXT,
            route_tier TEXT,
            route_reason TEXT,
            profile_hash TEXT
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
        -- 网关层日志：记录非 2xx 响应与超大请求（middleware 写入）。
        -- 区分 api_usage：api_usage 记成功请求的 token 用量；gateway_log 记被拒/失败/预警请求，
        -- 解决 aiohttp 层 413 超限等 handler 不执行、无任何记录的排查盲区。
        CREATE TABLE IF NOT EXISTS gateway_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            method TEXT,
            path TEXT,
            content_length INTEGER,
            status_code INTEGER,
            error_type TEXT,
            error_message TEXT,
            latency_ms INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_gateway_log_timestamp ON gateway_log(timestamp);
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

    # 迁移：分级路由诊断列（route_tier 档位 / route_reason 决策原因 / profile_hash
    # 会话所属 agent 类型指纹）。是排查「为什么这轮走了这个模型」的唯一手段——
    # 路由决策日志在 token_proxy.log 中滚动丢弃，这两列是可回溯的历史。
    if "route_tier" not in columns:
        conn.execute("ALTER TABLE api_usage ADD COLUMN route_tier TEXT")
        conn.execute("ALTER TABLE api_usage ADD COLUMN route_reason TEXT")
        conn.execute("ALTER TABLE api_usage ADD COLUMN profile_hash TEXT")
        conn.commit()
    # 迁移：路由决策明细列。降档被拦时记 outside 工具列表；升档时记触发信号名。
    # 路由日志在 token_proxy.log 中滚动丢弃，detail 列是排查「为什么不降档」的
    # 唯一持久手段——没有它，3 个 hold_not_readonly 返回点无法从数据侧区分。
    if "route_detail" not in columns:
        conn.execute("ALTER TABLE api_usage ADD COLUMN route_detail TEXT")
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

    # 三个月自动清理：cutoff 用与 timestamp 一致的 ISO 格式，避免 datetime('now') 空格格式在边界当天漏删
    cutoff = (
        datetime.now(timezone.utc) - timedelta(days=API_USAGE_RETENTION_DAYS)
    ).isoformat()
    conn.execute("DELETE FROM api_usage WHERE timestamp < ?", (cutoff,))
    conn.commit()
    conn.close()


def init_tool_output_db():
    """初始化 tool_output_log 独立库（5 天保留）。"""
    os.makedirs(DB_DIR, exist_ok=True)
    conn = sqlite3.connect(TOOL_OUTPUT_DB_PATH)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS tool_output_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            api_usage_id INTEGER,
            timestamp TEXT NOT NULL,
            tool_name TEXT,
            tool_call_id TEXT,
            output_text TEXT,
            output_size INTEGER,
            output_lines INTEGER,
            is_error INTEGER,
            stop_reason TEXT,
            model TEXT,
            route_tier TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_tool_output_timestamp ON tool_output_log(timestamp);
        CREATE INDEX IF NOT EXISTS idx_tool_output_tool_name ON tool_output_log(tool_name);
    """)
    # 五天自动清理
    cutoff = (
        datetime.now(timezone.utc) - timedelta(days=TOOL_OUTPUT_RETENTION_DAYS)
    ).isoformat()
    conn.execute("DELETE FROM tool_output_log WHERE timestamp < ?", (cutoff,))
    conn.commit()
    conn.close()


# 网关层日志：middleware 统一记录被拒/失败/超大请求，补 api_usage 的排查盲区。
# api_usage 只记成功请求的 token 用量；aiohttp 层 413 超限等 handler 不执行时不落库。
_gateway_log_write_count = 0


def record_gateway_log(
    method, path, content_length, status_code, error_type, error_message, latency_ms
):
    """写入网关日志：非 2xx 响应 + 超大请求体。保留 90 天，每 200 次写入删一次过期数据。"""
    global _gateway_log_write_count
    if status_code < 400 and (content_length or 0) < GATEWAY_LOG_SIZE_THRESHOLD:
        return
    try:
        with dbconn(DB_PATH) as c:
            c.execute(
                "INSERT INTO gateway_log (timestamp, method, path, content_length, status_code, "
                "error_type, error_message, latency_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    datetime.now(timezone.utc).isoformat(),
                    method,
                    path,
                    content_length,
                    status_code,
                    error_type,
                    error_message,
                    latency_ms,
                ),
            )
            _gateway_log_write_count += 1
            if _gateway_log_write_count % 200 == 0:
                cutoff = (
                    datetime.now(timezone.utc)
                    - timedelta(days=GATEWAY_LOG_RETENTION_DAYS)
                ).isoformat()
                c.execute("DELETE FROM gateway_log WHERE timestamp < ?", (cutoff,))
    except Exception:
        # 网关日志失败不影响主流程
        pass


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
            with dbconn(DB_PATH) as conn:
                row = conn.execute(
                    "SELECT input_path, output_path, cache_read_path, cache_write_path "
                    "FROM usage_field_cache WHERE provider=? AND model=?",
                    (provider, model),
                ).fetchone()
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
            with dbconn(DB_PATH) as conn:
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


resolver = UsageFieldResolver()


#: 需要从用户文本中剔除的**已登记**客户端注入标签。
#:
#: 只按名剔除，不再把任意 `<...>` 当标签：用户输入里出现比较运算符（`if x < y
#: and y > z`）或 HTML 片段时，通用标签清理会把中间整段吃掉——实测
#: `'if x < y and y > z: pass'` 被清成 `'if x z: pass'`，日志字段严重失真。
CLIENT_INJECTED_TAGS = (
    "system-reminder",
    "local-command-caveat",
    "local-command-stdout",
    "command-name",
    "command-message",
    "command-args",
)

_TAG_RE = re.compile(
    r"</?(?:" + "|".join(re.escape(t) for t in CLIENT_INJECTED_TAGS) + r")\b[^>]*>",
    re.IGNORECASE,
)


def _extract_user_text(content) -> str:
    """从消息内容中提取纯文本，跳过已登记的客户端注入标签。

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
    # 先剥注入的规则块，**再**清标签：规则块在真实用户输入之前，若先跑标签清理，
    # 规则正文里的尖括号可能把 `---rule_end` 一并吃掉，导致剥离函数找不到结束标记
    # 而把块后面的真实用户输入一起丢弃。
    content_str = strip_injected_rules(str(content))
    # 仅剔除已登记标签（含开闭标签），其余文本原样保留
    return _TAG_RE.sub("", content_str).strip()


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
            # 跳过续接提示词（其正文是上一轮摘要，不是用户输入）
            if content_str.startswith(CONTINUATION_PREFIX):
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


def extract_tool_outputs(body: dict, api_format: str = "anthropic") -> list[dict]:
    """从请求体提取最新一轮 tool_result 的全部工具输出。

    只提取最近一轮 tool_result——历史 tool_result 已在前序请求中记录过，
    每次请求携带完整消息历史但旧 tool_result 不重复记录。

    输出文本用 `proxy_normalize._result_text` 提取（工具回传内容的权威实现），
    **不做任何清洗**——这是形态分析的数据源，注入规则剥离与客户端标签剔除都会
    让「文件里恰好含 `<system-reminder>`」这类内容失真。规则注入只作用于最后一条
    真实用户消息，不会落在 tool_result 块上，故此处本就不需要剥离。

    返回列表，每项包含：tool_name, tool_call_id, output_text, output_size,
    output_lines, is_error。
    """
    messages = body.get("messages", [])
    if not messages:
        return []

    tool_results = []

    if api_format == "openai":
        # OpenAI: role="tool" 是独立消息，从后往前找连续的 tool 消息
        for msg in reversed(messages):
            if msg.get("role") != "tool":
                break
            text = result_text(msg.get("content", ""))
            tool_results.append(
                {
                    "tool_name": _resolve_openai_tool_name(messages, msg),
                    "tool_call_id": msg.get("tool_call_id", ""),
                    "output_text": text,
                    "output_size": len(text.encode("utf-8")),
                    "output_lines": text.count("\n") + 1 if text else 0,
                    "is_error": None,  # OpenAI 无 is_error 字段
                }
            )
        tool_results.reverse()  # 恢复时间正序
    else:
        # Anthropic: role=user 消息内含 type=="tool_result" 内容块
        # 从后往前找最后一个含 tool_result 的 user 消息
        for msg in reversed(messages):
            if msg.get("role") != "user":
                continue
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            blocks = [
                b
                for b in content
                if isinstance(b, dict) and b.get("type") == "tool_result"
            ]
            if not blocks:
                continue
            # 向上找配对的 tool_use 获取工具名
            tool_names = _resolve_tool_names(messages, blocks)
            for b in blocks:
                text = result_text(b.get("content", ""))
                is_err = b.get("is_error")
                tool_results.append(
                    {
                        "tool_name": tool_names.get(b.get("tool_use_id", ""), ""),
                        "tool_call_id": b.get("tool_use_id", ""),
                        "output_text": text,
                        "output_size": len(text.encode("utf-8")),
                        "output_lines": text.count("\n") + 1 if text else 0,
                        # 三态：True=失败 / False=确认成功 / None=协议未提供
                        "is_error": (
                            1 if is_err is True else (0 if is_err is False else None)
                        ),
                    }
                )
            break  # 只处理最后一个含 tool_result 的 user 消息

    return tool_results


def _resolve_openai_tool_name(messages: list[dict], tool_msg: dict) -> str:
    """OpenAI tool 消息 → 配对的 tool_call 函数名。

    OpenAI 的 role="tool" 消息不带工具名，需按 tool_call_id 回查 assistant
    消息里的 tool_calls。
    """
    call_id = tool_msg.get("tool_call_id", "")
    if not call_id:
        return ""
    for msg in reversed(messages):
        for tc in msg.get("tool_calls") or []:
            if isinstance(tc, dict) and tc.get("id") == call_id:
                fn = tc.get("function") or {}
                return fn.get("name", "") if isinstance(fn, dict) else ""
    return ""


def _resolve_tool_names(
    messages: list[dict], tool_result_blocks: list[dict]
) -> dict[str, str]:
    """从消息历史中查找 tool_result 配对的 tool_use 工具名。

    返回 {tool_use_id: tool_name} 映射。
    """
    needed_ids = {
        b.get("tool_use_id", "") for b in tool_result_blocks if b.get("tool_use_id")
    }
    if not needed_ids:
        return {}

    names: dict[str, str] = {}
    for msg in reversed(messages):
        if len(names) == len(needed_ids):
            break
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use":
                continue
            bid = block.get("id", "")
            if bid in needed_ids and bid not in names:
                names[bid] = block.get("name", "")
    return names


def record_tool_outputs(
    tool_outputs: list[dict],
    api_usage_id: int | None = None,
    stop_reason: str = "",
    model: str = "",
    route_tier: str = "",
):
    """将工具输出写入 tool_output_log 独立库。

    与 api_usage 分属两个库文件，无法共用一个事务，故单独开连接写入。
    写入失败只记日志不影响主流程——工具输出是分析素材，不该拖垮用量记录。
    """
    if not tool_outputs:
        return

    now = datetime.now(timezone.utc).isoformat()
    try:
        with dbconn(TOOL_OUTPUT_DB_PATH) as c:
            c.executemany(
                "INSERT INTO tool_output_log "
                "(api_usage_id, timestamp, tool_name, tool_call_id, output_text, "
                "output_size, output_lines, is_error, stop_reason, model, route_tier) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                [
                    (
                        api_usage_id,
                        now,
                        t.get("tool_name", ""),
                        t.get("tool_call_id", ""),
                        t.get("output_text", ""),
                        t.get("output_size", 0),
                        t.get("output_lines", 0),
                        t.get("is_error"),
                        stop_reason,
                        model,
                        route_tier,
                    )
                    for t in tool_outputs
                ],
            )
    except Exception as e:
        logger.error(json.dumps({"msg": "tool_output_record_failed", "error": str(e)}))


async def record_usage(
    request_body: dict,
    response_body: dict,
    status: int,
    latency_ms: int,
    output_preview: str = "",
    error_message: str = "",
    tool_name_override: str = "",
    api_format: str = "anthropic",
    route_tier: str = "",
    route_reason: str = "",
    profile_hash: str = "",
    route_detail: dict | None = None,
    tool_outputs: list[dict] | None = None,
):
    """记录一次 API 调用的 token 用量。

    可选 `tool_outputs`（由 `extract_tool_outputs` 产出）一并写入 tool_output_log，
    并带上本行的 `api_usage_id`——两表分属不同库文件，只能在这里拿到自增 id，
    拆成两个后台任务写会让该列恒为 NULL，工具输出体积与 token 用量的关联分析就断了。
    """
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
        "route_tier": route_tier,
        "route_reason": route_reason,
        "profile_hash": profile_hash,
        "route_detail": json.dumps(route_detail) if route_detail else None,
    }

    try:
        with dbconn(DB_PATH) as conn:
            cursor = conn.execute(
                "INSERT INTO api_usage "
                "(timestamp, request_type, context_summary, "
                "input_preview, actual_user_input, input_message_count, has_tool_result, output_preview, "
                "output_type, stop_reason, response_valid, model, input_tokens, "
                "output_tokens, cache_read_tokens, cache_write_tokens, "
                "latency_ms, api_format, request_level, tool_name, parent_id, error_message, "
                "route_tier, route_reason, profile_hash, route_detail) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
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
                    record["route_tier"],
                    record["route_reason"],
                    record["profile_hash"],
                    record["route_detail"],
                ),
            )
            record_id = cursor.lastrowid
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

        # 工具输出落库：带 api_usage_id 关联，供「输出体积 ↔ token 用量」交叉分析
        if tool_outputs:
            record_tool_outputs(
                tool_outputs,
                api_usage_id=record_id,
                stop_reason=stop_reason,
                model=model,
                route_tier=route_tier,
            )
    except Exception as e:
        logger.error(json.dumps({"msg": "usage_record_failed", "error": str(e)}))
