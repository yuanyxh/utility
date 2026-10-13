"""Append a line at the end of the response: "what the proxy rewrote this turn".

The model name comes from message_start.message.model in the stream; the list of
rewrites is generated from the output_filter / skill_dedup stats on the request
side.

**Only appended to the final reply** (the last content block is text) — a tool
call turn ends with a tool_use block, and the reader of that line is the user;
inserting it into a tool call is both meaningless and may interfere with the
client's parsing of the tool block. The criterion is the block type, not
stop_reason: the latter only appears at message_delta, by which time the content
block has already stopped and there is no time to add another delta.

The SSE injection point is a **deferred content_block_stop**: on receiving stop
it is buffered first, and only when the next event arrives is it known whether
it is the last — if so, a content_block_delta is inserted before it (reusing that
block's index), otherwise it is passed through as-is. No new block is created and
index increments need not be managed.

feed/finish both take and return bytes and internally use **incremental UTF-8
decoding**: SSE fragmentation can split a multi-byte character in half, and
per-fragment `decode()` would produce replacement characters and corrupt the
JSON.
"""

from __future__ import annotations

import codecs
import json

from proxy_skill_dedup import FALLBACK_LANG

#: The appended-line template. {parts} is a list like "Bash filter/Skill note".
NOTE_TEMPLATE: dict[str, str] = {
    "zh-Hans": "{model} | 已执行: {parts}",
    "en": "{model} | applied: {parts}",
}

#: Display names of each rewrite mechanism; the keys correspond one-to-one with the request-side stats.
PART_LABELS: dict[str, dict[str, str]] = {
    "outputFilter": {"zh-Hans": "Bash 过滤", "en": "bash filter"},
    "skillDedup": {"zh-Hans": "Skill 短提示", "en": "skill dedup"},
}

#: Alternate text when nothing was rewritten this turn — the model name is the main
#: information of this line and should not make the whole line disappear just because
#: nothing was rewritten
NOTE_EMPTY: dict[str, str] = {
    "zh-Hans": "{model} | 无改写",
    "en": "{model} | no rewrite",
}

#: The gap between the appended line and the body
NOTE_SEPARATOR = "\n\n"

#: The switch env name (injected by Swift `TokenProxyManager.responseNoteEnvKey`). This
#: env does not go through `config.py`, so contract group 3 cannot cover it; the two
#: sides' identical value is therefore asserted separately by the contract script.
RESPONSE_NOTE_ENV_KEY = "MODEL_PROXY_RESPONSE_NOTE"


def _label(key: str, lang: str) -> str:
    table = PART_LABELS.get(key) or {}
    return table.get(lang) or table.get(FALLBACK_LANG) or key


def build_note(model: str, parts: list[str], lang: str) -> str | None:
    """Build the appended line; **returns None only when the model name is
    unavailable** — the model name is the main information of this line and must be
    shown even when nothing was rewritten (this is the case in the first few turns
    of a new session)."""
    if not model:
        return None
    if not parts:
        tpl = NOTE_EMPTY.get(lang) or NOTE_EMPTY[FALLBACK_LANG]
        return tpl.format(model=model)
    labels = [_label(p, lang) for p in parts]
    tpl = NOTE_TEMPLATE.get(lang) or NOTE_TEMPLATE[FALLBACK_LANG]
    return tpl.format(model=model, parts="/".join(labels))


def _data_of(event: str) -> dict:
    """Get the data JSON of an SSE event; returns {} when missing or unparseable."""
    for line in event.split("\n"):
        if line.startswith("data: "):
            try:
                parsed = json.loads(line[6:])
            except (json.JSONDecodeError, ValueError):
                return {}
            return parsed if isinstance(parsed, dict) else {}
    return {}


def append_note_to_body(resp: dict, model: str, parts: list[str], lang: str) -> bool:
    """Non-streaming: merge the appended line into the last text block. Returns whether it changed anything."""
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
    """Feed anthropic SSE bytes segment by segment, inserting the appended line before the final text block closes."""

    def __init__(self, parts: list[str], lang: str):
        self._parts = parts
        self._lang = lang
        self._note: str | None = None
        self._buf = ""
        self._block_type: dict = {}
        self._pending_stop: tuple | None = None
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    def feed(self, chunk: bytes) -> bytes:
        """Return the bytes that should be written to the client — may be shorter than the input (stop was buffered)."""
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
        """End of stream: any residual stop must be the last block, so appending is safe."""
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
        """Only append when a text block closes; tool_use blocks are left as-is."""
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
    """Non-streaming response: buffer the full body first, then parse and append."""

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
