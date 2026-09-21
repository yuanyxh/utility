"""summarize 共享 LLM/网络基础设施。

从 summarize.py 拆分（2026-08-30，重构阶段3）：LLM 调用、JSON 解析、
错误日志写入。被核心流水线（summarize.py）与阶段3 规范提炼（summary_rules.py）共用。
代码原样搬移不改逻辑。
"""

from __future__ import annotations

from pathlib import Path

import httpx

import llm_client
from config import ai_api_key, notes_dir
from log_utils import (
    setup_logging,
    write_error_log as _shared_write_error_log,
)

# ---------------------------------------------------------------------------
# 配置（与拆分前 summarize.py 一致）
# ---------------------------------------------------------------------------

#: 主模型 key。本模块不再直接用它发请求（LLM 调用统一走 `llm_client`），
#: 保留是因为 `summarize.py` 的 `main()` 守卫从这里取（缺 key 直接退出）。
AI_API_KEY = ai_api_key()
NOTES_DIR = Path(notes_dir())
ERROR_LOG = NOTES_DIR / "流水线错误日志.jsonl"
SUMMARY_LLM_TEMPERATURE = 0.1
#: LLM 调用超时（秒）。单一来源 = `llm_client.DEFAULT_SYNC_TIMEOUT` ← config `ai.llmTimeout`。
#: 原先此处写死 90、而 `summary_rules`/`summarize` 各写死 120——同一类调用三个值。
SUMMARY_LLM_TIMEOUT = llm_client.DEFAULT_SYNC_TIMEOUT
SUMMARY_API_TIMEOUT = 10

logger = setup_logging("summarize")

_HTTP = httpx.Client(timeout=SUMMARY_API_TIMEOUT)


def write_error_log(msg: str, code: str = "UNKNOWN"):
    try:
        _shared_write_error_log(
            str(ERROR_LOG),
            {
                "code": code,
                "message": msg,
            },
        )
    except Exception as e:
        logger.error(f"Error log write failed: {e}")


def _llm_chat(
    prompt: str,
    temperature: float | None = None,
    timeout: float | None = None,
    max_tokens: int | None = None,
    disable_thinking: bool = False,
    system_prompt: str | None = None,
) -> str | None:
    """summarize 全链路的同步 LLM 调用薄封装（转发 `llm_client.chat`）。

    保留此名字而不是让 6 个调用点直接调 `llm_client.chat`：调用点之间的差异只是
    「温度 / 超时 / 关思考」几个默认值，收敛在这一处即可，不必动调用点。
    """
    return llm_client.chat(
        prompt,
        system=system_prompt,
        temperature=(
            temperature if temperature is not None else SUMMARY_LLM_TEMPERATURE
        ),
        max_tokens=max_tokens,
        timeout=timeout if timeout is not None else SUMMARY_LLM_TIMEOUT,
        disable_thinking=disable_thinking,
        # deepseek-v4-flash 等推理模型：长 prompt 下思考会吃光 max_tokens、
        # content 为空 → JSON 解析失败（AGGREGATE_JSON 根因），故聚合/生成阶段关思考。
        # 这是该 provider 的**私有字段**（非 OpenAI 协议事实），只能由调用方显式传出：
        # 写进 llm_client 的公共层会让其他 openai provider 收到未知字段而 400。
        extra_body={"thinking": {"type": "disabled"}} if disable_thinking else None,
        label="LLM call failed",
    )


#: 保留历史名：`summarize.py` / `summary_rules.py` 共 6 处调用点依赖它。
#: 实现已迁至 `llm_client.parse_json`（原 `_escape_inline_quotes` 随迁）。
_parse_json_any = llm_client.parse_json
