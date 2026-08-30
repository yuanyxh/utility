"""summarize 共享 LLM/网络基础设施。

从 summarize.py 拆分（2026-08-30，重构阶段3）：LLM 调用、JSON 解析、
错误日志写入。被核心流水线（summarize.py）与阶段3 规范提炼（summary_rules.py）共用。
代码原样搬移不改逻辑。
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import httpx

from config import deepseek_api_key, notes_dir, summary_api_url, summary_model
from log_utils import (
    setup_logging,
    write_error_log as _shared_write_error_log,
)

# ---------------------------------------------------------------------------
# 配置（与拆分前 summarize.py 一致）
# ---------------------------------------------------------------------------

DEEPSEEK_API_KEY = deepseek_api_key()
SUMMARY_MODEL = summary_model()
SUMMARY_API_URL = summary_api_url()
NOTES_DIR = Path(notes_dir())
ERROR_LOG = NOTES_DIR / "流水线错误日志.jsonl"
SUMMARY_LLM_TEMPERATURE = 0.1
SUMMARY_LLM_TIMEOUT = 90
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
    try:
        messages: list[dict] = [{"role": "user", "content": prompt}]
        if system_prompt:
            messages.insert(0, {"role": "system", "content": system_prompt})
        body = {
            "model": SUMMARY_MODEL,
            "messages": messages,
            "temperature": (
                temperature if temperature is not None else SUMMARY_LLM_TEMPERATURE
            ),
        }
        # 聚合/文章生成等输出较大的阶段显式放宽 max_tokens，
        # 否则 LLM 默认 4096 截断导致 JSON 解析失败（AGGREGATE_JSON 根因）
        if max_tokens:
            body["max_tokens"] = max_tokens
        # deepseek-v4-flash 为推理模型：长 prompt 下 thinking 思考会吃光
        # max_tokens，content 为空 → JSON 解析失败。聚合/生成阶段关思考，
        # 让输出 token 全部用于 content（实测 thinking disabled + 16384 完整输出）
        if disable_thinking:
            body["thinking"] = {"type": "disabled"}
        resp = _HTTP.post(
            f"{SUMMARY_API_URL}/chat/completions",
            headers={
                "Authorization": f"Bearer {DEEPSEEK_API_KEY}",
                "Content-Type": "application/json",
            },
            json=body,
            timeout=timeout if timeout is not None else SUMMARY_LLM_TIMEOUT,
        )
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]
    except Exception as e:
        logger.warning(f"LLM call failed: {e}")
        return None


def _parse_json_any(raw: str) -> dict | None:
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
