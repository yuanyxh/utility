"""在响应末尾追加一行「本轮代理改写了什么」。

模型名取自流里 message_start.message.model；改写清单由请求侧的
output_filter / skill_dedup 统计生成。

**只追加在最终回复**（最后一个 content block 是 text）——工具调用轮最后是
tool_use 块，那行的读者是用户，插在工具调用里既没意义、又可能干扰客户端
对工具块的解析。判据取 block 类型而非 stop_reason：后者要到 message_delta
才出现，那时 content block 已经 stop，来不及再补 delta。

SSE 注入点是**延迟 content_block_stop**：收到 stop 先缓存，等下一个事件
才知道它是不是最后一个——是则在它前面补一个 content_block_delta（复用该
block 的 index），不是就原样放行。不新建 block、不必管理 index 递增。

feed/finish 都收发 bytes，内部用**增量 UTF-8 解码**：SSE 分片可能把多字节
字符切成两半，逐片 `decode()` 会解出替换字符、损坏 JSON。
"""

from __future__ import annotations

import codecs
import json

from proxy_skill_dedup import FALLBACK_LANG

#: 追加行模板。{parts} 是「Bash 过滤/Skill 短提示」这样的清单。
NOTE_TEMPLATE: dict[str, str] = {
    "zh-Hans": "{model} | 已执行: {parts}",
    "en": "{model} | applied: {parts}",
}

#: 各改写机制的显示名，键与请求侧的统计一一对应。
PART_LABELS: dict[str, dict[str, str]] = {
    "outputFilter": {"zh-Hans": "Bash 过滤", "en": "bash filter"},
    "skillDedup": {"zh-Hans": "Skill 短提示", "en": "skill dedup"},
}

#: 本轮无改写时的替代文案——模型名是这行的主信息，不该因为没改写就整行消失
NOTE_EMPTY: dict[str, str] = {
    "zh-Hans": "{model} | 无改写",
    "en": "{model} | no rewrite",
}

#: 追加行与正文之间的间隔
NOTE_SEPARATOR = "\n\n"

#: 开关 env 名（Swift `TokenProxyManager.responseNoteEnvKey` 注入）。该 env 不经
#: `config.py`，契约第 3 组覆盖不到，故两侧同值由契约脚本单独断言。
RESPONSE_NOTE_ENV_KEY = "MODEL_PROXY_RESPONSE_NOTE"


def _label(key: str, lang: str) -> str:
    table = PART_LABELS.get(key) or {}
    return table.get(lang) or table.get(FALLBACK_LANG) or key


def build_note(model: str, parts: list[str], lang: str) -> str | None:
    """生成追加行；**只有拿不到模型名才返回 None**——模型名是这行的主信息，
    无改写时也要显示（新会话开头几轮就是这种情况）。"""
    if not model:
        return None
    if not parts:
        tpl = NOTE_EMPTY.get(lang) or NOTE_EMPTY[FALLBACK_LANG]
        return tpl.format(model=model)
    labels = [_label(p, lang) for p in parts]
    tpl = NOTE_TEMPLATE.get(lang) or NOTE_TEMPLATE[FALLBACK_LANG]
    return tpl.format(model=model, parts="/".join(labels))


def _data_of(event: str) -> dict:
    """取 SSE 事件的 data JSON；缺失或解析失败返回 {}。"""
    for line in event.split("\n"):
        if line.startswith("data: "):
            try:
                parsed = json.loads(line[6:])
            except (json.JSONDecodeError, ValueError):
                return {}
            return parsed if isinstance(parsed, dict) else {}
    return {}


def append_note_to_body(resp: dict, model: str, parts: list[str], lang: str) -> bool:
    """非流式：把追加行并进最后一个 text block。返回是否改动。"""
    note = build_note(model, parts, lang)
    if note is None:
        return False
    content = resp.get("content")
    if not isinstance(content, list) or not content:
        return False
    last = content[-1]
    if not isinstance(last, dict) or last.get("type") != "text":
        return False
    last["text"] = (last.get("text") or "") + NOTE_SEPARATOR + note
    return True


class SSENoteInjector:
    """逐段喂入 anthropic SSE 字节，在最终 text block 收尾前插入追加行。"""

    def __init__(self, parts: list[str], lang: str):
        self._parts = parts
        self._lang = lang
        self._note: str | None = None
        self._buf = ""
        self._block_type: dict = {}
        self._pending_stop: tuple | None = None
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    def feed(self, chunk: bytes) -> bytes:
        """返回应当写给客户端的字节——可能比输入短（stop 被暂存了）。"""
        self._buf += self._decoder.decode(chunk)
        out: list[str] = []
        while True:
            idx = self._buf.find("\n\n")
            if idx < 0:
                break
            event, self._buf = self._buf[: idx + 2], self._buf[idx + 2 :]
            out.append(self._handle(event))
        return "".join(out).encode()

    def finish(self) -> bytes:
        """流结束：残留的 stop 必是最后一个 block，可安全追加。"""
        if not self._buf and self._pending_stop is None:
            return b""
        out = self._release_pending(is_last=True) + self._buf
        self._buf = ""
        return out.encode()

    def _handle(self, event: str) -> str:
        data = _data_of(event)
        etype = data.get("type")
        index = data.get("index")
        if etype == "content_block_start":
            block = data.get("content_block")
            self._block_type[index] = (block or {}).get("type")
            return self._release_pending(is_last=False) + event
        if etype == "content_block_stop":
            self._pending_stop = (index, event)
            return ""
        if etype == "message_start":
            message = data.get("message")
            model = (message or {}).get("model") or ""
            self._note = build_note(model, self._parts, self._lang)
        elif etype in ("message_delta", "message_stop"):
            return self._release_pending(is_last=True) + event
        return event

    def _release_pending(self, is_last: bool) -> str:
        if self._pending_stop is None:
            return ""
        index, raw = self._pending_stop
        self._pending_stop = None
        if not is_last or not self._note:
            return raw
        return self._note_delta(index) + raw

    def _note_delta(self, index) -> str:
        """只在 text block 收尾时追加；tool_use 块保持原样。"""
        if self._block_type.get(index) != "text":
            return ""
        payload = {
            "type": "content_block_delta",
            "index": index,
            "delta": {"type": "text_delta", "text": NOTE_SEPARATOR + self._note},
        }
        body = json.dumps(payload, ensure_ascii=False)
        return f"event: content_block_delta\ndata: {body}\n\n"


class NoteBodyBuffer:
    """非流式响应：先缓冲完整体，再解析并追加。"""

    def __init__(self, parts: list[str], lang: str):
        self._parts = parts
        self._lang = lang
        self._raw = bytearray()

    def feed(self, chunk: bytes) -> bytes:
        self._raw.extend(chunk)
        return b""

    def finish(self) -> bytes:
        raw = bytes(self._raw)
        try:
            resp = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            return raw
        if not isinstance(resp, dict):
            return raw
        model = resp.get("model") or ""
        if not append_note_to_body(resp, model, self._parts, self._lang):
            return raw
        return json.dumps(resp, ensure_ascii=False).encode()
