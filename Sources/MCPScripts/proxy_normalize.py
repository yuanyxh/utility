"""token_proxy 的协议文本提取工具。

把 Anthropic / OpenAI 两种协议下的 `system` 字段与消息 `content` 读成纯文本。
规则注入（proxy_protocol.py）与工具输出提取（proxy_usage.py）都复用本模块，
避免「怎么读这两处字段」在两个调用点各推导一遍。
"""

from __future__ import annotations

API_ANTHROPIC = "anthropic"
API_OPENAI = "openai"


def system_to_text(system) -> str:
    """Anthropic system（string 或 text block 数组）→ 纯文本。

    本函数是「如何读 system 字段」的**单一权威实现**——`proxy_protocol.py`
    的规则注入必须复用它，避免同一事实两处推导。
    """
    if isinstance(system, str):
        return system
    if isinstance(system, list):
        return "\n".join(
            b.get("text", "")
            for b in system
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def _result_text(content) -> str:
    """tool_result / tool 消息的内容 → 纯文本（str 或 block 数组）。"""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""
