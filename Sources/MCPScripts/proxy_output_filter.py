"""入站请求的 shell 工具输出瘦身。

三层，安全度递减：
  L1 砍头尾——超 max_bytes 保留前 70% + 后 30% 并插自证标记（默认开）
  L2 格式压缩——JSON 无损 minify（默认开）；重复行折叠默认关，它改行数不算无损
  L3 命令规则——按 shell 命令配 drop_lines/keep_lines/max_bytes（默认空表：实测
     本项目 Bash 输出 ≤4KB 占 61%、>8KB 全是内容型，没有 snip 那种模板化噪音）

**只对 shell 类工具生效**：Read/Edit 等是模型点名要的文件内容，截断等于损坏；
shell 输出才是「命令五花八门、结果不可预期」的来源。识别见 `_shell_kind`。

与 proxy_skill_dedup 同构：都在代理转发前就地改 messages，都在 record 之后调用
（记录层留原文，否则度量标尺被自己毁掉）。
"""

from __future__ import annotations

import json
import re

from proxy_skill_dedup import FALLBACK_LANG

API_OPENAI = "openai"

#: 配置 env 名（Swift `TokenProxyManager.outputFilterEnvKey` 注入）。该 env 不经
#: `config.py`，契约第 3 组覆盖不到，故两侧同值由契约脚本单独断言。
OUTPUT_FILTER_ENV_KEY = "MODEL_PROXY_OUTPUT_FILTER"

#: 内置 shell 工具名。跨客户端名字各不相同（Gemini=`run_shell_command`、
#: Cursor=`run_terminal_cmd`、Codex=`local_shell`），故这只是**兜底名单**，
#: 真正的判据是 input 里的 `command`（协议级事实）。配置可增量补充。
SHELL_TOOLS_DEFAULT = ("Bash",)

DEFAULT_MAX_BYTES = 8000
HEAD_RATIO = 0.7
FOLD_MIN_RUN = 3
FOLD_MIN_LEN = 4

TRUNCATE_MARK: dict[str, str] = {
    "zh-Hans": "\n[... 已截断 {n} 字节 ...]\n",
    "en": "\n[... {n} bytes truncated ...]\n",
}


def _mark(lang: str, n: int) -> str:
    tpl = TRUNCATE_MARK.get(lang) or TRUNCATE_MARK[FALLBACK_LANG]
    return tpl.format(n=n)


def _get_text(container: dict) -> str | None:
    """取容器文本：Anthropic 的 tool_result 块与 OpenAI 的 tool 消息都是 content。"""
    content = container.get("content")
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


def _set_text(container: dict, text: str) -> None:
    """就地替换文本，保留外壳与配对字段（tool_use_id/tool_call_id 动不得）。

    与 proxy_skill_dedup 的同名函数差别只有一处：这里不校验块类型，因为
    OpenAI 的 tool 消息没有 type 字段。
    """
    if isinstance(container.get("content"), str):
        container["content"] = text
    else:
        container["content"] = [{"type": "text", "text": text}]


def _anthropic_items(messages: list[dict]):
    """产出 (容器, 工具名, 命令)。命令取自 assistant 的 tool_use.input。"""
    names: dict[str, tuple[str, str | None]] = {}
    for msg in messages:
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            inp = block.get("input")
            cmd = inp.get("command") if isinstance(inp, dict) else None
            names[block.get("id", "")] = (block.get("name", ""), cmd)
    for msg in messages:
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            name, cmd = names.get(block.get("tool_use_id", ""), ("", None))
            yield block, name, cmd


def _openai_items(messages: list[dict]):
    """产出 (容器, 工具名, 命令)。OpenAI 的 function.arguments 是 JSON 字符串。"""
    names: dict[str, tuple[str, str | None]] = {}
    for msg in messages:
        for call in msg.get("tool_calls") or []:
            if not isinstance(call, dict):
                continue
            fn = call.get("function")
            fn = fn if isinstance(fn, dict) else {}
            cmd = None
            if isinstance(fn.get("arguments"), str):
                try:
                    parsed = json.loads(fn["arguments"])
                except (json.JSONDecodeError, ValueError):
                    parsed = None
                if isinstance(parsed, dict):
                    cmd = parsed.get("command")
            names[call.get("id", "")] = (fn.get("name", ""), cmd)
    for msg in messages:
        if msg.get("role") != "tool":
            continue
        name, cmd = names.get(msg.get("tool_call_id", ""), ("", None))
        yield msg, name, cmd


def _shell_kind(name: str, command, shell_tools: set[str]) -> str:
    """``listed``＝名字在名单里；``struct``＝名单外但 input 带 command；``""``＝非 shell。"""
    if name in shell_tools:
        return "listed"
    if isinstance(command, str) and command.strip():
        return "struct"
    return ""


def _truncate(text: str, max_bytes: int, lang: str) -> tuple[str, int]:
    """超限则保留头尾并插标记，返回 (新文本, 省下字节)。"""
    data = text.encode()
    if max_bytes <= 0 or len(data) <= max_bytes:
        return text, 0
    head_n = int(max_bytes * HEAD_RATIO)
    tail_n = max_bytes - head_n
    head = data[:head_n].decode("utf-8", "ignore")
    tail = data[-tail_n:].decode("utf-8", "ignore") if tail_n > 0 else ""
    dropped = len(data) - len(head.encode()) - len(tail.encode())
    if dropped <= 0:
        return text, 0
    return head + _mark(lang, dropped) + tail, dropped


def _minify_json(text: str) -> tuple[str, int]:
    """JSON 无损 minify（只去空白）；非 JSON 或解析失败原样返回。"""
    stripped = text.strip()
    if not stripped or stripped[0] not in "[{":
        return text, 0
    try:
        parsed = json.loads(stripped)
    except (json.JSONDecodeError, ValueError):
        return text, 0
    if not isinstance(parsed, (dict, list)):
        return text, 0
    minified = json.dumps(parsed, ensure_ascii=False, separators=(",", ":"))
    if len(minified) >= len(text):
        return text, 0
    return minified, len(text.encode()) - len(minified.encode())


def _fold_repeated(text: str) -> tuple[str, int]:
    """连续 ≥3 行完全相同折叠为 `行 (xN)`。**非无损**（行数变了），故默认关闭。"""
    lines = text.split("\n")
    out: list[str] = []
    saved = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        j = i + 1
        while j < len(lines) and lines[j] == line:
            j += 1
        if j - i >= FOLD_MIN_RUN and len(line.strip()) >= FOLD_MIN_LEN:
            out.append(f"{line} (x{j - i})")
            saved += sum(len(x.encode()) + 1 for x in lines[i + 1 : j])
        else:
            out.extend(lines[i:j])
        i = j
    if not saved:
        return text, 0
    return "\n".join(out), saved


def _match_rule(rules: list, command) -> dict | None:
    """按 shell 命令首个 token 匹配规则（与 snip 的 match.command 同义）。"""
    if not isinstance(command, str) or not command.strip():
        return None
    parts = command.split()
    for rule in rules:
        if not isinstance(rule, dict) or rule.get("command") != parts[0]:
            continue
        sub = rule.get("subcommand")
        if sub and (len(parts) < 2 or parts[1] != sub):
            continue
        return rule
    return None


def _apply_rule(text: str, rule: dict) -> tuple[str, int]:
    """先按规则删/留行，返回 (新文本, 省下字节)。"""
    drops = rule.get("drop_lines") or []
    keeps = rule.get("keep_lines") or []
    if not drops and not keeps:
        return text, 0
    out = []
    for line in text.split("\n"):
        if any(re.search(p, line) for p in drops):
            continue
        if keeps and not any(re.search(p, line) for p in keeps):
            continue
        out.append(line)
    new = "\n".join(out)
    return new, max(0, len(text.encode()) - len(new.encode()))


def _parse_config(raw: str) -> dict:
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def filter_tool_outputs(
    body: dict,
    api_format: str,
    raw_config: str,
    lang: str,
) -> dict:
    """就地瘦身 shell 工具的 tool_result 文本，返回统计；无改动返回 {}。"""
    cfg = _parse_config(raw_config)
    if not cfg.get("enabled", True):
        return {}
    messages = body.get("messages")
    if not isinstance(messages, list):
        return {}

    shell_tools = set(SHELL_TOOLS_DEFAULT) | set(cfg.get("shell_tools") or [])
    bypass = set(cfg.get("bypass_tools") or [])
    rules = cfg.get("rules") or []
    max_bytes = cfg.get("max_bytes") or DEFAULT_MAX_BYTES
    compress = cfg.get("format_compress", True) is not False
    fold = bool(cfg.get("fold_repeated_lines", False))

    items = (
        _openai_items(messages)
        if api_format == API_OPENAI
        else _anthropic_items(messages)
    )
    truncated = minified = folded = saved = 0
    unlisted: list[str] = []
    for container, name, command in items:
        text = _get_text(container)
        if text is None or not text.strip():
            continue
        kind = _shell_kind(name, command, shell_tools)
        if not kind or name in bypass:
            continue
        if kind == "struct" and name not in unlisted and len(unlisted) < 5:
            unlisted.append(name)
        original = text
        rule = _match_rule(rules, command)
        if rule:
            text, n = _apply_rule(text, rule)
            saved += n
        if compress:
            text, n = _minify_json(text)
            minified += 1 if n else 0
        if fold:
            text, n = _fold_repeated(text)
            folded += 1 if n else 0
        limit = int(rule.get("max_bytes") or max_bytes) if rule else max_bytes
        text, n = _truncate(text, limit, lang)
        if n:
            truncated += 1
        if text == original:
            continue
        _set_text(container, text)
        saved += len(original.encode()) - len(text.encode())

    if not saved and not unlisted:
        return {}
    return {
        "truncated": truncated,
        "minified": minified,
        "folded": folded,
        "saved_bytes": saved,
        "unlisted_tools": unlisted,
    }
