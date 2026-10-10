"""入站请求的 tool_result 内容去重。

同一会话里同一 skill（MCP 工具）被反复调用时，每次都把整份 SKILL.md 再插一遍
——实测 6 份逐字节相同的 15184 B。本模块把第二份起换成短提示，保留第一次
（模型仍能在上文读到完整内容）。

判据是**内容逐字节相同**而非工具名：代理拿不到 skill 名单（那份名单在 MCP
server 内），且内容相同即语义相同。副作用是重复的非 skill 输出（两次相同的
ls）也被折叠——无害且同样省 token。

放代理层而非 MCP server 层：server 无会话历史视野，只能靠进程内状态记
「已返回过」，多会话共用时会把 A 会话的加载状态泄漏给 B（B 收到「已加载」
而上文没有 → 静默失效，属最难排查的一类）。
"""

from __future__ import annotations

API_OPENAI = "openai"

#: 短提示文案（按 UI 语言选，缺该语言回退 `FALLBACK_LANG`）。
#: 语言判据与 tool_text / prompt_loader 同源（`config.ui_language()`）。
SKILL_DEDUP_NOTES: dict[str, str] = {
    "zh-Hans": "{name} 的结果已存在，见上文",
    "en": "{name} result already exists; see above",
}

FALLBACK_LANG = "zh-Hans"

#: 工具名映射不到时的占位，避免渲染出「技能  已于上文加载」
UNKNOWN_NAME = "?"


def note_for(name: str, lang: str) -> str:
    """选语言并渲染短提示；未翻译的语言回退基线。"""
    template = SKILL_DEDUP_NOTES.get(lang) or SKILL_DEDUP_NOTES[FALLBACK_LANG]
    return template.replace("{name}", name or UNKNOWN_NAME)


def _tool_result_text(block: dict) -> str | None:
    """Anthropic tool_result 块 → 文本；非 tool_result 返回 None。"""
    if block.get("type") != "tool_result":
        return None
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        return "\n".join(parts) if parts else None
    return None


def _set_tool_result_text(block: dict, text: str) -> None:
    """就地替换文本，**保留块的其余字段与消息外壳**——配对信息（tool_use_id）
    动不得，上游会以「tool_use 缺少配对的 tool_result」直接 400。"""
    content = block.get("content")
    if isinstance(content, str):
        block["content"] = text
    else:
        block["content"] = [{"type": "text", "text": text}]


def _resolve_anthropic_names(messages: list[dict]) -> dict[str, str]:
    """tool_use_id → 工具名（名字在 assistant 消息的 tool_use 块上）。"""
    names: dict[str, str] = {}
    for msg in messages:
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                names[block.get("id", "")] = block.get("name", "")
    return names


def _resolve_openai_names(messages: list[dict]) -> dict[str, str]:
    """tool_call_id → 工具名（名字在 assistant 消息的 tool_calls 里）。"""
    names: dict[str, str] = {}
    for msg in messages:
        for call in msg.get("tool_calls") or []:
            if not isinstance(call, dict):
                continue
            fn = call.get("function")
            names[call.get("id", "")] = (
                fn.get("name", "") if isinstance(fn, dict) else ""
            )
    return names


def _dedup_anthropic(messages: list[dict], lang: str) -> int:
    names = _resolve_anthropic_names(messages)
    seen: set[str] = set()
    replaced = 0
    for msg in messages:
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            text = _tool_result_text(block)
            if text is None or not text.strip():
                continue
            if text in seen:
                name = names.get(block.get("tool_use_id", ""), "")
                _set_tool_result_text(block, note_for(name, lang))
                replaced += 1
            else:
                seen.add(text)
    return replaced


def _dedup_openai(messages: list[dict], lang: str) -> int:
    names = _resolve_openai_names(messages)
    seen: set[str] = set()
    replaced = 0
    for msg in messages:
        if msg.get("role") != "tool":
            continue
        content = msg.get("content")
        if not isinstance(content, str) or not content.strip():
            continue
        if content in seen:
            name = names.get(msg.get("tool_call_id", ""), "")
            msg["content"] = note_for(name, lang)
            replaced += 1
        else:
            seen.add(content)
    return replaced


def dedup_tool_results(body: dict, api_format: str, lang: str) -> int:
    """就地去除重复的 tool_result 文本，返回被替换的条数。

    只保留每个文本的**第一次**出现——模型仍能在上文读到完整内容。
    """
    messages = body.get("messages")
    if not isinstance(messages, list):
        return 0
    if api_format == API_OPENAI:
        return _dedup_openai(messages, lang)
    return _dedup_anthropic(messages, lang)
