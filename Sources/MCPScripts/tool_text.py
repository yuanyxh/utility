"""MCP 工具**参数描述**的内置国际化。

参数描述是工具 schema 的一部分、会被模型读到，而「界面语言」与「谁在用」并无绑定
关系——按语言给出与提示词外置是同一件事的两半。工具**描述**（`TOOL_DEFAULTS`）**刻意
不在此列**：它比参数描述长、改动频繁，内置一份译文本只会多出一份没人维护的副本。

语言判据与提示词**同源**（`config.ui_language()` ← `UTILITY_LANG` ← `general.language`），
该语言没有该文案时回退基线 `zh-Hans`（与 `prompt_loader.FALLBACK_LANG` 同值，由
`scripts/check-router-config-contract.py` 断言——两侧漂移会让同一份缺失在提示词与
参数描述上得到不同结果）。

键是**语义**名而非「工具.参数」路径：同一段文案在多个参数上复用时共用同一个键
（`param.db_path` 被 4 个 `project_*` 工具引用、`param.max_results` 被 2 个引用）。按路径
命名会让这类文案在翻译时分叉成几份，而「改一处忘三处」的漂移会随翻译一起放大。

契约（由 `scripts/check-router-config-contract.py` 第 6 组静态断言）：
- `handle_list_tools()` 的 `inputSchema` 里**不允许出现裸 description 字面量**，必须
  经 `param_text(...)` 取——漏改一处就会在混杂语言下露出来，且没人会注意到；
- 引用的键必须存在于 `PARAM_TEXT`（否则运行期抛错，工具列表整体不可用）；
- `PARAM_TEXT` 里不允许有没人引用的键（改名后遗留）；
- 每个键的语言集合**必须一致且包含基线**——schema 是一次性整体呈现的，一部分参数中文、
  一部分英文比全中文更糟。
"""

from __future__ import annotations

from config import ui_language
from log_utils import setup_logging

logger = setup_logging("tool_text")

#: 基线语言。任何语言缺该文案时回退到它；新增键必须提供它。
#: 与 `prompt_loader.FALLBACK_LANG` 同值（契约脚本断言）。
FALLBACK_LANG = "zh-Hans"

PARAM_TEXT: dict[str, dict[str, str]] = {
    #: 三要素口径（场景/决策/演进），与 `server.py` 的 `TOOL_DEFAULTS["remember"]` **逐字**
    #: 一致——两处曾一个三要素、一个五要素，同一段模型行为被两套说法描述。用户裁定
    #: 「三要素为主」后改齐；`TOOL_DEFAULTS` 侧本就是三要素，故只动这里。
    "param.memory_content": {
        "zh-Hans": (
            "记忆内容。有产生背景时首行 [背景说明], 次行起 [事实] ...; 无背景直接写事实, "
            "禁止硬凑背景。有背景时按三要素组织——场景(项目/上下文)、决策(怎么做/选)、"
            "演进(当前状态/后续变化), 缺的要素省略不硬凑。"
        ),
        "en": (
            "The memory content. With background: put [background] on the first line and "
            "[fact] from the second line on. Without background: state the fact directly — "
            "never pad a fact into a fabricated background. With background, organize it by "
            "three elements — scenario (which project / what context), decision (what was "
            "done / how it was chosen), evolution (current state / what changes next); omit "
            "any element you cannot supply rather than forcing it."
        ),
    },
    "param.query": {
        "zh-Hans": "搜索查询",
        "en": "Search query",
    },
    "param.max_results": {
        "zh-Hans": "最大返回结果数",
        "en": "Maximum number of results to return",
    },
    "param.since_days": {
        "zh-Hans": "向前数几天, 默认 3 天",
        "en": "How many days back to look; defaults to 3",
    },
    "param.memory_ids": {
        "zh-Hans": "记忆 ID 列表",
        "en": "List of memory IDs",
    },
    "param.bit": {
        "zh-Hans": "位索引, 0=已总结处理",
        "en": "Bit index; 0 = summarized/processed",
    },
    "param.bit_value": {
        "zh-Hans": "1=设置位, 0=重置位",
        "en": "1 = set the bit, 0 = clear it",
    },
    "param.db_path": {
        "zh-Hans": "必填, 绝对路径 + .utility/deps.sqlite, 示例: `/absolute/path/.utility/deps.sqlite`",
        "en": (
            "Required. Absolute path to the project's .utility/deps.sqlite, "
            "e.g. `/absolute/path/.utility/deps.sqlite`"
        ),
    },
    "param.search_keyword": {
        "zh-Hans": "必填, 搜索关键词(支持中文同义词)",
        "en": "Required. Search keyword (Chinese synonyms are expanded automatically)",
    },
    "param.file_path": {
        "zh-Hans": "可选, 限定文件路径(支持模糊匹配, 如 src/utils/)",
        "en": "Optional. Restrict to a file path (fuzzy match, e.g. src/utils/)",
    },
    "param.symbol_kind": {
        "zh-Hans": "可选, 限定符号类型(class/fun/val/var/interface/...)",
        "en": "Optional. Restrict to a symbol kind (class/fun/val/var/interface/...)",
    },
    "param.subpath": {
        "zh-Hans": "可选子路径",
        "en": "Optional sub-path to inspect",
    },
    "param.file_or_dir": {
        "zh-Hans": "文件或目录路径",
        "en": "File or directory path",
    },
    "param.notes_keyword": {
        "zh-Hans": "搜索关键词，支持自然语言描述",
        "en": "Search keyword; natural-language descriptions are supported",
    },
    "param.project_dir": {
        "zh-Hans": "项目目录绝对路径",
        "en": "Absolute path to the project directory",
    },
    "param.parent_name": {
        "zh-Hans": "tool 注册名，如 check/write/think",
        "en": "Registered tool name, e.g. check/write/think",
    },
    "param.resource_path": {
        "zh-Hans": "附属资源相对 tool 目录的路径，如 references/durable-context.md",
        "en": (
            "Path to the attached resource, relative to the tool directory, "
            "e.g. references/durable-context.md"
        ),
    },
}


class MissingParamText(KeyError):
    """引用了未登记的键。

    直接失败而非回退成键名：静默回退会把 `param.xxx` 这样的内部标识当文案发给模型，
    而契约脚本已在静态层拦下这一类错误，运行期再兜底只会掩盖它。
    """


def param_text(key: str) -> str:
    """按当前语言取参数描述；缺该语言回退基线。"""
    entry = PARAM_TEXT.get(key)
    if entry is None:
        raise MissingParamText(f"未登记的参数描述键: {key!r}")
    lang = ui_language().strip() or FALLBACK_LANG
    if lang in entry:
        return entry[lang]
    if lang != FALLBACK_LANG:
        logger.warning(f"{key}: 无 {lang!r} 文案，回退 {FALLBACK_LANG!r}")
    return entry[FALLBACK_LANG]
