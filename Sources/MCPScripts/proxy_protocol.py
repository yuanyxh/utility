"""token_proxy 的协议转换与请求注入层。

从 token_proxy.py 拆分（2026-08-30，重构阶段2）：anthropic↔openai 协议转换
（ProtocolConverter/OpenAIToAnthropicStream）、safety classifier 识别与注入、
系统规则注入（_inject_system_prompt）、SSE 流提取。代码原样搬移不改逻辑。
"""

from __future__ import annotations

import json
import os

from config import notes_dir
from log_utils import setup_logging

# 「如何读 Anthropic system 字段」的单一权威实现在归一化层，此处复用，
# 避免同一事实两处推导（system 结构扩展时只改一处）。
# 依赖方向：proxy_protocol → proxy_normalize（后者只依赖标准库，无环）。
from proxy_normalize import system_to_text as _system_to_text

# ---------------------------------------------------------------------------
# 配置（与拆分前 token_proxy.py 一致）
# ---------------------------------------------------------------------------

NOTES_DIR = notes_dir()
SYSTEM_PROMPTS_FILE = os.path.join(NOTES_DIR, "MCP", "System_Prompts.md")

logger = setup_logging("token_proxy", json_format=True)


#: 规则注入块的首尾标记。由注入方（本模块）定义，剥离方（proxy_usage 的用量
#: 摘取）复用同一常量——避免「注入用什么标记」与「剥离认什么标记」两处推导。
RULE_START_MARK = "---rule_start"
RULE_END_MARK = "---rule_end"


def strip_injected_rules(text: str) -> str:
    """剥离 `_inject_system_prompt` 注入的规则块，保留其余用户文本。

    注入块是一整份 `System_Prompts.md`（可达数千字符），而用量记录的摘取上限
    只有 100~500 字符——不剥离的话 `context_summary` / `input_preview` /
    `actual_user_input` 三个字段看到的全是守则开头，真正的用户输入被整个挤出。

    支持剥离多块；未闭合的块丢弃到结尾（防残留半块）。
    """
    if not text or RULE_START_MARK not in text:
        return text
    out: list[str] = []
    rest = text
    while True:
        i = rest.find(RULE_START_MARK)
        if i < 0:
            out.append(rest)
            break
        out.append(rest[:i])
        j = rest.find(RULE_END_MARK, i + len(RULE_START_MARK))
        if j < 0:
            break  # 块未闭合 → 丢弃剩余部分，不把半块规则当用户输入
        rest = rest[j + len(RULE_END_MARK) :]
    return "".join(out).strip()


def _sse_event(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


# ---------------------------------------------------------------------------
# 协议常量
# ---------------------------------------------------------------------------

#: OpenAI `finish_reason` → Anthropic `stop_reason` 的映射。**单一权威定义**，
#: 流式转换 / 非流式转换 / SSE usage 提取三处共用。
#:
#: 分头维护会让同一次上游响应在不同路径上得出不同结论：曾出现 content_filter
#: 只在记录层的表里有映射，两个转换层都缺，于是 `mapping.get(finish, "end_turn")`
#: 把「内容被过滤」当成「正常结束」——客户端看到 end_turn，路由层也据此认定
#: 正常终止，异常信号整个丢失，而数据库里却如实写着 content_filter。
FINISH_REASON_MAP: dict[str, str] = {
    "stop": "end_turn",
    "tool_calls": "tool_use",
    "length": "max_tokens",
    "content_filter": "content_filter",
}

#: 转换层遇到未知 finish_reason 时的兜底——必须是 Anthropic 的合法枚举值，
#: 否则客户端会因非法 stop_reason 拒绝整个响应。
FALLBACK_STOP_REASON = "end_turn"


def _tool_choice_anthropic_to_openai(choice):
    """Anthropic tool_choice → OpenAI tool_choice。

    Anthropic: {"type": "auto"|"any"|"tool"|"none"[, "name": ...]}
    OpenAI:    "auto"|"required"|"none" | {"type":"function","function":{"name":...}}
    """
    if not isinstance(choice, dict):
        return choice
    ctype = choice.get("type")
    if ctype == "any":
        return "required"
    if ctype == "tool":
        return {"type": "function", "function": {"name": choice.get("name", "")}}
    return ctype or "auto"


def _tool_choice_openai_to_anthropic(choice):
    """OpenAI tool_choice → Anthropic tool_choice（上一个函数的逆向）。"""
    if isinstance(choice, str):
        return {"type": {"required": "any", "none": "none"}.get(choice, "auto")}
    if isinstance(choice, dict):
        fn = choice.get("function") or {}
        return {"type": "tool", "name": fn.get("name", "")}
    return choice


class ProtocolConverter:
    """Anthropic Messages API ↔ OpenAI Chat Completions 请求体双向转换。"""

    @staticmethod
    def request_anthropic_to_openai(body: dict) -> dict:
        out: dict = {
            "model": body.get("model", ""),
            "stream": body.get("stream", False),
        }
        if body.get("max_tokens"):
            out["max_tokens"] = body["max_tokens"]
        if body.get("temperature") is not None:
            out["temperature"] = body["temperature"]
        if body.get("top_p") is not None:
            out["top_p"] = body["top_p"]
        # Anthropic 的停止序列字段是 `stop_sequences`（数组），OpenAI 对应 `stop`。
        # 此处曾读 `stop`——Anthropic 请求体里没有该键，转换恒不生效（静默丢配置）。
        if body.get("stop_sequences") is not None:
            out["stop"] = body["stop_sequences"]
        if body.get("tool_choice") is not None:
            out["tool_choice"] = _tool_choice_anthropic_to_openai(body["tool_choice"])

        system_text = _system_to_text(body.get("system"))
        messages: list[dict] = []
        if system_text.strip():
            messages.append({"role": "system", "content": system_text})

        for m in body.get("messages", []):
            role, content = m.get("role"), m.get("content")
            if role == "user":
                if isinstance(content, str):
                    messages.append({"role": "user", "content": content})
                elif isinstance(content, list):
                    text_parts: list[str] = []
                    tool_results: list[dict] = []
                    for b in content:
                        if not isinstance(b, dict):
                            continue
                        bt = b.get("type")
                        if bt == "text":
                            text_parts.append(b.get("text", ""))
                        elif bt == "tool_result":
                            tool_results.append(
                                {
                                    "role": "tool",
                                    "tool_call_id": b.get("tool_use_id", ""),
                                    "content": b.get("content", ""),
                                }
                            )
                        elif bt == "image":
                            src = b.get("source", {})
                            if src.get("type") == "base64":
                                text_parts.append(
                                    "![image](data:{};base64,{})".format(
                                        src.get("media_type", ""), src.get("data", "")
                                    )
                                )
                    if text_parts:
                        messages.append(
                            {"role": "user", "content": "".join(text_parts)}
                        )
                    messages.extend(tool_results)
            elif role == "assistant":
                if isinstance(content, str):
                    messages.append({"role": "assistant", "content": content})
                elif isinstance(content, list):
                    text_parts, tool_calls = [], []
                    for b in content:
                        if not isinstance(b, dict):
                            continue
                        bt = b.get("type")
                        if bt == "text":
                            text_parts.append(b.get("text", ""))
                        elif bt == "tool_use":
                            tool_calls.append(
                                {
                                    "id": b.get("id", ""),
                                    "type": "function",
                                    "function": {
                                        "name": b.get("name", ""),
                                        "arguments": json.dumps(
                                            b.get("input", {}), ensure_ascii=False
                                        ),
                                    },
                                }
                            )
                    msg = {"role": "assistant"}
                    if text_parts:
                        msg["content"] = "".join(text_parts)
                    if tool_calls:
                        msg["tool_calls"] = tool_calls
                    messages.append(msg)

        out["messages"] = messages

        tools = body.get("tools")
        if tools:
            out["tools"] = [
                {
                    "type": "function",
                    "function": {
                        "name": t.get("name", ""),
                        "description": t.get("description", ""),
                        "parameters": t.get(
                            "input_schema", {"type": "object", "properties": {}}
                        ),
                    },
                }
                for t in tools
                if isinstance(t, dict)
            ]
        if body.get("stream"):
            # openai 流式默认不返回 usage，显式要求末尾携带
            out["stream_options"] = {"include_usage": True}
        return out

    @staticmethod
    def request_openai_to_anthropic(body: dict) -> dict:
        out: dict = {
            "model": body.get("model", ""),
            "stream": body.get("stream", False),
        }
        if body.get("max_tokens"):
            out["max_tokens"] = body["max_tokens"]
        if body.get("temperature") is not None:
            out["temperature"] = body["temperature"]
        if body.get("top_p") is not None:
            out["top_p"] = body["top_p"]
        # OpenAI `stop` ↔ Anthropic `stop_sequences`：两侧字段名不同，必须显式转换
        if body.get("stop") is not None:
            out["stop_sequences"] = body["stop"]

        system_text = ""
        messages: list[dict] = []
        for m in body.get("messages", []):
            role = m.get("role")
            if role == "system":
                system_text += (m.get("content") or "") + "\n"
            elif role == "tool":
                messages.append(
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": m.get("tool_call_id", ""),
                                "content": m.get("content", ""),
                            }
                        ],
                    }
                )
            elif role == "user":
                content = m.get("content")
                if isinstance(content, str):
                    messages.append({"role": "user", "content": content})
                elif isinstance(content, list):
                    blocks = []
                    for b in content:
                        if isinstance(b, dict) and b.get("type") == "text":
                            blocks.append({"type": "text", "text": b.get("text", "")})
                    messages.append({"role": "user", "content": blocks})
            elif role == "assistant":
                content = m.get("content")
                blocks = []
                if content:
                    text = (
                        content
                        if isinstance(content, str)
                        else json.dumps(content, ensure_ascii=False)
                    )
                    blocks.append({"type": "text", "text": text})
                for tc in m.get("tool_calls") or []:
                    fn = tc.get("function", {})
                    try:
                        inp = json.loads(fn.get("arguments") or "{}")
                    except (json.JSONDecodeError, TypeError):
                        inp = {}
                    blocks.append(
                        {
                            "type": "tool_use",
                            "id": tc.get("id", ""),
                            "name": fn.get("name", ""),
                            "input": inp,
                        }
                    )
                messages.append({"role": "assistant", "content": blocks})

        if system_text.strip():
            out["system"] = [{"type": "text", "text": system_text.strip()}]
        out["messages"] = messages

        tools = body.get("tools")
        if tools:
            out["tools"] = []
            for t in tools:
                if isinstance(t, dict) and t.get("type") == "function":
                    fn = t.get("function", {})
                    out["tools"].append(
                        {
                            "name": fn.get("name", ""),
                            "description": fn.get("description", ""),
                            "input_schema": fn.get(
                                "parameters", {"type": "object", "properties": {}}
                            ),
                        }
                    )
        if body.get("tool_choice") is not None:
            out["tool_choice"] = _tool_choice_openai_to_anthropic(body["tool_choice"])
        return out

    @staticmethod
    def response_openai_to_anthropic(resp: dict) -> dict:
        """OpenAI Chat Completions 非流式响应 → Anthropic Messages 响应。"""
        choice = (resp.get("choices") or [{}])[0]
        message = choice.get("message", {}) or {}
        content_blocks = []
        text = message.get("content") or ""
        if text:
            content_blocks.append({"type": "text", "text": text})
        for tc in message.get("tool_calls") or []:
            fn = tc.get("function", {})
            try:
                inp = json.loads(fn.get("arguments") or "{}")
            except (json.JSONDecodeError, TypeError):
                inp = {}
            content_blocks.append(
                {
                    "type": "tool_use",
                    "id": tc.get("id", ""),
                    "name": fn.get("name", ""),
                    "input": inp,
                }
            )
        usage = resp.get("usage", {})
        return {
            "id": resp.get("id", "msg_proxy"),
            "type": "message",
            "role": "assistant",
            "model": resp.get("model", ""),
            "content": content_blocks,
            "stop_reason": FINISH_REASON_MAP.get(
                choice.get("finish_reason"), FALLBACK_STOP_REASON
            ),
            "stop_sequence": None,
            "usage": {
                "input_tokens": usage.get("prompt_tokens", 0),
                "output_tokens": usage.get("completion_tokens", 0),
            },
        }


class OpenAIToAnthropicStream:
    """openai SSE 流式响应 → anthropic SSE 事件（增量转换）。

    状态机：首个内容块攒够后发 content_block_start，再逐 delta；工具调用按
    openai 的 index 映射为独立 content block；末尾发 message_delta（stop_reason
    + usage）与 message_stop。块顺序按「首次出现」分配 index。
    """

    def __init__(self):
        self.blocks: list[int] = []
        self.text_block: int | None = None
        self.tool_blocks: dict[int, int] = {}
        self.tool_state: dict[int, dict] = {}
        self.sent_start = False
        self.stop_reason: str | None = None
        self.usage: dict = {}
        self.model = ""

    def feed(self, chunk: dict) -> list[str]:
        events: list[str] = []
        if chunk.get("model"):
            self.model = chunk["model"]

        if not self.sent_start:
            events.append(
                _sse_event(
                    "message_start",
                    {
                        "type": "message_start",
                        "message": {
                            "id": "msg_proxy",
                            "type": "message",
                            "role": "assistant",
                            "content": [],
                            "model": self.model,
                            "stop_reason": None,
                            "stop_sequence": None,
                            "usage": {"input_tokens": 0, "output_tokens": 0},
                        },
                        "usage": {"input_tokens": 0, "output_tokens": 0},
                    },
                )
            )
            self.sent_start = True

        for choice in chunk.get("choices") or []:
            delta = choice.get("delta") or {}
            finish = choice.get("finish_reason")

            text = delta.get("content")
            if text:
                if self.text_block is None:
                    self.text_block = len(self.blocks)
                    self.blocks.append(self.text_block)
                    events.append(
                        _sse_event(
                            "content_block_start",
                            {
                                "type": "content_block_start",
                                "index": self.text_block,
                                "content_block": {"type": "text", "text": ""},
                            },
                        )
                    )
                events.append(
                    _sse_event(
                        "content_block_delta",
                        {
                            "type": "content_block_delta",
                            "index": self.text_block,
                            "delta": {"type": "text_delta", "text": text},
                        },
                    )
                )

            for tc in delta.get("tool_calls") or []:
                t_idx = tc.get("index", 0)
                fn = tc.get("function", {})
                st = self.tool_state.get(t_idx, {"id": "", "name": ""})
                if tc.get("id"):
                    st["id"] = tc["id"]
                if fn.get("name"):
                    st["name"] = fn["name"]
                self.tool_state[t_idx] = st

                if t_idx not in self.tool_blocks:
                    block_idx = len(self.blocks)
                    self.blocks.append(block_idx)
                    self.tool_blocks[t_idx] = block_idx
                    events.append(
                        _sse_event(
                            "content_block_start",
                            {
                                "type": "content_block_start",
                                "index": block_idx,
                                "content_block": {
                                    "type": "tool_use",
                                    "id": st["id"],
                                    "name": st["name"],
                                    "input": {},
                                },
                            },
                        )
                    )
                args = fn.get("arguments") or ""
                if args:
                    events.append(
                        _sse_event(
                            "content_block_delta",
                            {
                                "type": "content_block_delta",
                                "index": self.tool_blocks[t_idx],
                                "delta": {
                                    "type": "input_json_delta",
                                    "partial_json": args,
                                },
                            },
                        )
                    )

            if finish:
                self.stop_reason = FINISH_REASON_MAP.get(finish, FALLBACK_STOP_REASON)

        if chunk.get("usage"):
            u = chunk["usage"]
            self.usage = {
                "input_tokens": u.get("prompt_tokens", 0),
                "output_tokens": u.get("completion_tokens", 0),
            }

        return events

    def finish(self) -> list[str]:
        events: list[str] = []
        for block_idx in self.blocks:
            events.append(
                _sse_event(
                    "content_block_stop",
                    {"type": "content_block_stop", "index": block_idx},
                )
            )
        # input_tokens 必须在这里补发：OpenAI 的 prompt_tokens 只在流的最后一个
        # chunk 才出现，而 message_start 早就发出去了（那时只能写 0）。只发
        # output_tokens 会让客户端（Claude Code 的 statusLine）永远显示 input 为 0。
        events.append(
            _sse_event(
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {
                        "stop_reason": self.stop_reason or FALLBACK_STOP_REASON,
                        "stop_sequence": None,
                    },
                    "usage": {
                        "input_tokens": self.usage.get("input_tokens", 0),
                        "output_tokens": self.usage.get("output_tokens", 0),
                    },
                },
            )
        )
        events.append(_sse_event("message_stop", {"type": "message_stop"}))
        return events


def _detect_api_format(body: dict) -> str:
    """从请求体检测 API 格式：'anthropic' 或 'openai'。"""
    if "system" in body and isinstance(body.get("system"), list):
        return "anthropic"
    messages = body.get("messages", [])
    if messages and messages[0].get("role") == "system":
        return "openai"
    tools = body.get("tools", [])
    if tools and isinstance(tools[0], dict):
        # Anthropic 的工具定义字段是 `input_schema`（snake_case）。此处曾误写成
        # `inputSchema`（那是 MCP tools/list 的拼写，不属于任何一种 API 格式），
        # 使这个分支永不命中、退化成死代码，只靠末尾的 anthropic 兜底「碰巧正确」。
        if "input_schema" in tools[0]:
            return "anthropic"
        if tools[0].get("type") == "function":
            return "openai"
    return "anthropic"


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


_sys_prompt_content: str | None = None

_sys_prompt_mtime: float = 0


def _inject_system_prompt(body: dict) -> tuple[bytes | None, int]:
    """读取 System_Prompts.md，注入到最后一条真实用户输入前。

    从后往前找 role==user 且 content 为字符串 / 数组含 text 块的真实
    用户输入（纯 tool_result 消息不含 text，会被跳过），在其前插入规则块；
    若该消息本身也含 tool_result（用户在工具执行中插话的形态），则改插到
    最后一个 tool_result 之后——该块必须始终保持在这条消息的首位。返回
    (body_bytes, 命中索引)，命中索引为注入目标的 messages 下标，
    文件缺失 / 读取失败 / 未命中时为 -1。mtime 未变时跳过读盘。
    """
    global _sys_prompt_content, _sys_prompt_mtime

    try:
        current_mtime = os.path.getmtime(SYSTEM_PROMPTS_FILE)
    except OSError:
        _sys_prompt_content = None
        return None, -1

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
            return None, -1

    if _sys_prompt_content is None:
        return None, -1

    # 用户消息注入：只注入到真实用户输入（跳过 tool_result 消息）
    messages = body.get("messages", [])
    target_index = -1
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].get("role") != "user":
            continue
        msg = messages[i]
        content = msg.get("content", "")
        # 判断是否为真实用户输入：字符串类型，或数组中含 text 类型块
        is_real_user_input = False
        if isinstance(content, str):
            is_real_user_input = True
        elif isinstance(content, list):
            is_real_user_input = any(
                b.get("type") == "text" for b in content if isinstance(b, dict)
            )
        if not is_real_user_input:
            continue
        target_index = i
        # 注入规则
        rule_block = (
            f"{RULE_START_MARK}\n" + _sys_prompt_content + f"\n{RULE_END_MARK}\n\n"
        )
        if isinstance(content, str):
            msg["content"] = rule_block + content
        elif isinstance(content, list):
            # Anthropic 硬约束：响应 tool_use 的消息里 tool_result 必须是首个块
            # （官方 Troubleshooting 明列此错因）。插到首位会把 tool_result 挤后，
            # 上游按「tool_use 后未紧跟 tool_result」直接 400，故插到最后一个
            # tool_result **之后**；无 tool_result 时退化为首位，行为不变。
            last_tool_result = -1
            for idx, block in enumerate(content):
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    last_tool_result = idx
            content.insert(last_tool_result + 1, {"type": "text", "text": rule_block})
        break

    # 文件存在但未找到真实用户输入（如全部 user 消息都是 tool_result）→ 记录告警防静默失效
    if target_index == -1:
        logger.warning(
            json.dumps(
                {
                    "msg": "rule_inject_no_target",
                    "user_messages": sum(
                        1 for m in messages if m.get("role") == "user"
                    ),
                }
            )
        )

    return json.dumps(body).encode(), target_index


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
                        # 统一映射表（见 FINISH_REASON_MAP）。未知值保留原样：
                        # 记录层要如实落库，不能把未知原因伪装成 end_turn。
                        detected_stop_reason = FINISH_REASON_MAP.get(fr, fr)

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
