"""把代理**实际路由到**的模型名注入到助手回复末尾。

问题：Claude Code 的 statusLine / `/model` 显示的是客户端请求的 model（如
mimo-v2.5），而分级路由把请求转发给的是另一个上游模型（如 deepseek-v4-flash）。
代理知道真相，却没有向客户端展示的通道。因此由代理在响应末尾直接追加模型名。

设计边界（刻意的，勿擅自扩大）：
- **只处理 Anthropic 格式响应**。Claude Code 走 anthropic；OpenAI 格式输出不注入
  （两种流式协议的事件模型差异大，为它再写一套状态机不划算，且无实际使用方）。
- **只处理 `stop_reason == end_turn`**。工具轮（tool_use）不注入：那一轮的文本会
  进入 agent loop 的上下文被模型回读，模型名混进去既无意义又污染历史。
- **实现为追加一个独立文本块**，不改写任何已有 content block。因此不依赖
  「最后一个块是文本块」这一假设（tool_use 块上追加 text_delta 是非法事件），
  也不需要知道已有块的类型。
"""

from __future__ import annotations

import codecs
import json
import re

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

#: 注入文本与模型名之间的分隔。模型名独占一行，避免和正文末句黏在一起；
#: 出参形如 `"\n\ndeepseek-v4-flash"`。
TAG_SEPARATOR = "\n\n"

# Anthropic SSE 事件类型（只列出本模块关心的）
EV_CONTENT_BLOCK_START = "content_block_start"
EV_MESSAGE_DELTA = "message_delta"
EV_MESSAGE_STOP = "message_stop"

#: 「尾段」事件——出现 `message_delta` 之后，一条合法的 Anthropic 流只剩
#: `message_stop`（及可选 `ping`）。暂存从 `message_delta` 起的事件即可覆盖
#: 全部注入时机，且暂存量恒定为 1~2 个事件。
_TAIL_EVENTS = (EV_MESSAGE_DELTA, EV_MESSAGE_STOP)

#: 事件类型探测：优先 `event:` 行（协议冗余字段，最可靠）；缺失时从 data 的
#: JSON 前缀里取 `"type"`。只扫前缀——content_block_delta 的 data 里可能有
#: 几万字符的工具入参，全量 json.loads 纯属浪费。
_TYPE_RE = re.compile(r'"type"\s*:\s*"([A-Za-z_]+)"')
_STOP_RE = re.compile(r'"stop_reason"\s*:\s*(?:"([^"]*)"|(null))')
_INDEX_RE = re.compile(r'"index"\s*:\s*(\d+)')
_PROBE_LIMIT = 256


def _event_type(raw: str) -> str:
    """取一段完整 SSE 事件文本的事件类型；判不出返回空串。"""
    for line in raw.splitlines():
        if line.startswith("event:"):
            return line[6:].strip()
    m = _TYPE_RE.search(raw[:_PROBE_LIMIT])
    return m.group(1) if m else ""


def _stop_reason(raw: str) -> str:
    """取 message_delta 的 stop_reason；null / 缺失返回空串。"""
    m = _STOP_RE.search(raw[:_PROBE_LIMIT])
    if not m or m.group(2):
        return ""
    return m.group(1) or ""


def _block_index(raw: str) -> int:
    """取事件里的 content block index；缺失返回 -1。

    不限于 `content_block_start`：部分兼容网关省略 start 事件，只发 delta /
    stop。任何一个带 index 的事件都能用来推进「下一个可用 index」，取三者
    的并集比只认 start 更耐上游形态差异。
    """
    m = _INDEX_RE.search(raw[:_PROBE_LIMIT])
    return int(m.group(1)) if m else -1


def _sse_event(name: str, payload: dict) -> str:
    """按 Anthropic SSE 线格式序列化一个事件。"""
    return f"event: {name}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"


class AnthropicSSETagger:
    """在 Anthropic SSE 流的末尾注入模型名文本块。

    用法：`feed()` 喂入上游字节、写出返回值；上游流结束后调 `finish()` 并写出
    其返回值。**两个出口都必须写**，否则暂存的事件会丢——那正是 message_delta /
    message_stop，丢了客户端就认为流没结束。
    """

    def __init__(self, model: str):
        self.model = model
        self._rest = ""  # 跨 chunk 尚未凑齐空行的残段
        self._held: list[str] = []  # 暂存的尾段事件原文
        self._next_index = 0  # 下一个可用的 content block index
        self._stop_reason = ""
        self._injected = False
        # 增量解码器：aiohttp 的 chunk 边界由网络决定，一个多字节字符（中文回复
        # 里到处都是）完全可能被切成两半。逐 chunk 单独 decode 会把两半各自变成
        # U+FFFD，整段中文变问号。增量解码器把不完整序列留到下一次 decode。
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    # -- 出口 -------------------------------------------------------------

    def feed(self, chunk: bytes) -> bytes:
        """喂入上游 SSE 字节，返回应写往客户端的字节（可能为空）。"""
        self._rest += self._decoder.decode(chunk)
        out: list[str] = []
        while True:
            raw = self._take_event()
            if raw is None:
                break
            out.extend(self._consume(raw))
        return "".join(out).encode()

    def finish(self) -> bytes:
        """上游流结束：放行残段与暂存事件（命中 end_turn 则先注入）。"""
        self._rest += self._decoder.decode(b"", final=True)
        out: list[str] = []
        if self._rest:
            out.append(self._rest)
            self._rest = ""
        if self._held:
            if self._stop_reason == "end_turn":
                out.extend(self._render_tag())
            out.extend(self._held)
            self._held = []
        return "".join(out).encode()

    def _take_event(self) -> str | None:
        """切出缓冲里第一条完整 SSE 事件（含结尾空行）；不完整返回 None。

        SSE 规范允许 CRLF 行尾。只认 `\\n\\n` 的话，CRLF 上游会永远切不出事件
        ——不报错，只是整个流都堆在缓冲里直到结束，静默退化成「不流式」。
        """
        lf = self._rest.find("\n\n")
        crlf = self._rest.find("\r\n\r\n")
        if crlf >= 0 and (lf < 0 or crlf + 2 <= lf):
            cut = crlf + 4
        elif lf >= 0:
            cut = lf + 2
        else:
            return None
        raw, self._rest = self._rest[:cut], self._rest[cut:]
        return raw

    # -- 状态机 -----------------------------------------------------------

    def _consume(self, raw: str) -> list[str]:
        etype = _event_type(raw)
        out: list[str] = []

        # 暂存段只在 `message_delta` 之后成立。一旦出现别的事件（例如还有下一个
        # content_block_start），说明暂存的那些不是尾段，原样放行。
        if self._held and etype not in _TAIL_EVENTS:
            out.extend(self._held)
            self._held = []

        # 任何带 index 的事件都推进「下一个可用 index」（见 _block_index 注释）
        idx = _block_index(raw)
        if idx >= 0:
            self._next_index = max(self._next_index, idx + 1)
        if etype == EV_MESSAGE_DELTA:
            self._stop_reason = _stop_reason(raw)

        if etype in _TAIL_EVENTS:
            self._held.append(raw)
            return out

        out.append(raw)
        return out

    def _render_tag(self) -> list[str]:
        """生成承载模型名的独立文本块（start / delta / stop）。"""
        idx = self._next_index
        self._injected = True
        return [
            _sse_event(
                EV_CONTENT_BLOCK_START,
                {
                    "type": EV_CONTENT_BLOCK_START,
                    "index": idx,
                    "content_block": {"type": "text", "text": ""},
                },
            ),
            _sse_event(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": idx,
                    "delta": {"type": "text_delta", "text": TAG_SEPARATOR + self.model},
                },
            ),
            _sse_event("content_block_stop", {"type": "content_block_stop", "index": idx}),
        ]

    @property
    def injected(self) -> bool:
        """是否真的注入过（供日志观测，防静默失效）。"""
        return self._injected


def tag_message_dict(data: object, model: str) -> dict | None:
    """非流式 Anthropic 消息对象：在 content 末尾追加模型名文本块。

    不满足注入条件（非 end_turn / 结构不符）时返回 None，**不改动入参**——
    注入是锦上添花，任何情况下都不能破坏响应体。
    """
    if not isinstance(data, dict) or data.get("stop_reason") != "end_turn":
        return None
    content = data.get("content")
    if not isinstance(content, list):
        return None
    content.append({"type": "text", "text": TAG_SEPARATOR + model})
    return data


def tag_json_response(body: bytes, model: str) -> bytes:
    """非流式 Anthropic 响应的字节级入口；不满足条件则原样返回。"""
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return body
    if tag_message_dict(data, model) is None:
        return body
    try:
        return json.dumps(data, ensure_ascii=False).encode()
    except (TypeError, ValueError):
        return body
