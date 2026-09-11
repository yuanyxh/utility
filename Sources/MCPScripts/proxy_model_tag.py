"""把代理**实际路由到**的模型名注入到助手回复末尾。

问题：Claude Code 的 statusLine / `/model` 显示的是客户端请求的 model（如
mimo-v2.5），而分级路由把请求转发给的是另一个上游模型（如 deepseek-v4-flash）。
代理知道真相，却没有向客户端展示的通道。因此由代理在响应末尾直接追加模型名。

支持 Anthropic 与 OpenAI 两种响应格式：
- **Anthropic**：追加一个**独立文本 content_block**（start/delta/stop 三事件），
  Claude Code 把它当助手回复的一部分展示，但不进入下一轮模型上下文。
- **OpenAI**：追加一个 **delta.content 文本块**（在 `[DONE]` 前），会作为普通
  文本追加到助手回复末尾，下一轮请求中模型会回读这段文本——这是有意为之：
  路由切换后模型名混入上下文的代价远小于「用户永远不知道实际用了什么模型」
  的信息损失。

通用约束（两种格式共用）：
- **只处理 `stop_reason == end_turn`**。工具轮（tool_use/tool_calls）不注入：
  那一轮的文本会进入 agent loop 的上下文被模型回读，模型名混进去既无意义又
  污染历史。
- **只在「路由真的接管了」时注入**。没接管说明用的就是客户端自己选的模型，
  用户无需被告知。classifier 快速路径是 Claude Code 的 safety 调用，排除。
"""

from __future__ import annotations

import codecs
import json
import re

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

#: 注入文本与模型名之间的分隔。模型名独占一行，避免和正文末句黏在一起。
TAG_SEPARATOR = "\n\n"

# SSE 事件类型（只列出本模块关心的）
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


# ---------------------------------------------------------------------------
# SSE 事件切分（Anthropic 与 OpenAI 共用）
# ---------------------------------------------------------------------------


def _take_sse_event(buffer: str) -> tuple[str | None, str]:
    """切出缓冲里第一条完整 SSE 事件（含结尾空行）；不完整返回 None。

    SSE 规范允许 CRLF 行尾。只认 `\\n\\n` 的话，CRLF 上游会永远切不出事件
    ——不报错，只是整个流都堆在缓冲里直到结束，静默退化成「不流式」。
    """
    lf = buffer.find("\n\n")
    crlf = buffer.find("\r\n\r\n")
    if crlf >= 0 and (lf < 0 or crlf + 2 <= lf):
        cut = crlf + 4
    elif lf >= 0:
        cut = lf + 2
    else:
        return None, buffer
    return buffer[:cut], buffer[cut:]


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


# ---------------------------------------------------------------------------
# Anthropic 格式注入
# ---------------------------------------------------------------------------


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
            raw, self._rest = _take_sse_event(self._rest)
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

    @property
    def injected(self) -> bool:
        return self._injected

    # -- 状态机 -----------------------------------------------------------

    def _consume(self, raw: str) -> list[str]:
        etype = _event_type(raw)
        out: list[str] = []

        # 暂存段只在 `message_delta` 之后成立。一旦出现别的事件（例如还有下一个
        # content_block_start），说明暂存的那些不是尾段，原样放行。
        if self._held and etype not in _TAIL_EVENTS:
            out.extend(self._held)
            self._held = []

        # 任何带 index 的事件都推进「下一个可用 index」
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
            _sse_event(
                "content_block_stop", {"type": "content_block_stop", "index": idx}
            ),
        ]


# ---------------------------------------------------------------------------
# Anthropic 格式非流式注入
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# OpenAI 格式注入
# ---------------------------------------------------------------------------


class OpenAITagInserter:
    """在 OpenAI SSE 流的 `[DONE]` 标记前注入模型名文本块。

    与 `AnthropicSSETagger` 的设计差异：
    - Anthropic 注入是**独立 content_block**，客户端把它当作助手回复的一部分
      展示，但**不进入**下一轮模型的上下文（content_block 有明确语义边界）。
    - OpenAI 注入是**普通 delta.content**，会作为文本直接追加到助手回复末尾，
      下一轮请求中模型**会回读**这段文本——这是有意为之：路由切换后模型名
      混入上下文的代价远小于「用户永远不知道实际用了什么模型」的信息损失。
    """

    def __init__(self, model: str):
        self.model = model
        self._rest = ""  # 跨 chunk 未凑齐空行的残段
        self._injected = False
        #: 上游 chunk 的公共元数据（id / object / created），注入事件复用它们，
        #: 避免发出一条字段残缺的 chunk——严格的客户端会拒绝或解析失败。
        self._meta: dict = {}

    def feed(self, chunk: bytes) -> bytes:
        """喂入上游 SSE 字节，返回应写往客户端的字节。"""
        self._rest += chunk.decode("utf-8", errors="replace")
        out: list[str] = []
        while True:
            raw, self._rest = _take_sse_event(self._rest)
            if raw is None:
                break
            self._remember_meta(raw)
            # OpenAI 的结束标记是 `data: [DONE]`（一个独立的 SSE 事件）
            if "data: [DONE]" in raw and not self._injected:
                inject = self._make_inject_event()
                out.append(inject)
                self._injected = True
            out.append(raw)
        return "".join(out).encode()

    def _remember_meta(self, raw: str) -> None:
        """从一条 SSE 事件里记住 chunk 公共元数据（只扫前缀，不做全量解析）。"""
        for line in raw.splitlines():
            if not line.startswith("data: "):
                continue
            payload = line[6:].strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                obj = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict):
                for key in ("id", "object", "created"):
                    if key in obj:
                        self._meta[key] = obj[key]
            return

    def finish(self) -> bytes:
        """上游流结束：放行残段；如果 [DONE] 没到则兜底注入。"""
        rest = self._rest
        self._rest = ""
        if not self._injected and rest.strip():
            inject = self._make_inject_event()
            self._injected = True
            return (inject + rest).encode()
        return rest.encode() if rest else b""

    @property
    def injected(self) -> bool:
        return self._injected

    def _make_inject_event(self) -> str:
        """生成承载模型名的 delta 事件（一条 data 行）。

        复用上游 chunk 的 id/object/created，只把 model 换成**实际路由到的**
        上游模型名——那正是本模块要向客户端展示的信息，不能被上游回显的
        请求模型名盖回去。
        """
        data = dict(self._meta)
        data["model"] = self.model
        data.setdefault("object", "chat.completion.chunk")
        data["choices"] = [
            {
                "index": 0,
                "delta": {"content": TAG_SEPARATOR + self.model},
                "finish_reason": None,
            }
        ]
        return f"data: {json.dumps(data, ensure_ascii=False)}\n\n"


def tag_openai_message(body: bytes, model: str) -> bytes:
    """非流式 OpenAI 响应：在 choices[0].message.content 末尾追加模型名。

    不满足注入条件时原样返回，**不改动入参**。
    """
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return body
    choices = data.get("choices") or []
    if not choices:
        return body
    msg = choices[0].get("message") or {}
    content = msg.get("content")
    if not isinstance(content, str) or not content:
        return body
    msg["content"] = content + TAG_SEPARATOR + model
    return json.dumps(data, ensure_ascii=False).encode()
