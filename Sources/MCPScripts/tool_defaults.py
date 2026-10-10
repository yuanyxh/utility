"""工具参数默认值表：tool name → args name → 默认值。

内置默认（`TOOL_ARG_DEFAULTS`）+ 用户增量（config.yaml 的 `mcp.toolDefaults`，
经 env `MCP_TOOL_DEFAULTS` 注入），合并语义与 synonyms 一致——**同名覆盖**。

单独成表是因为 schema 的 `default` 声明与 handler 的运行时兜底是两处独立推导，
字面量各写一份会漂移成「schema 说 6、实际取 8」——客户端按声明省略参数时，
拿到的条数与它看到的不一致（recall 上次 10→8 就踩过这个坑）。这些默认值直接
决定每次调用的返回量（token 消耗），故做成配置面：改配置即刻生效，不必改代码。
"""

from __future__ import annotations

import json
import os

from log_utils import setup_logging

logger = setup_logging("tool_defaults")

#: 用户自定义默认值的 env 名（跨语言契约，Swift 侧
#: `MCPProcessManager.toolDefaultsEnvKey` 同值，由
#: `scripts/check-router-config-contract.py` 交叉断言）。
TOOL_DEFAULTS_ENV_KEY = "MCP_TOOL_DEFAULTS"

#: 内置默认。未列出的工具/参数不走本表。
TOOL_ARG_DEFAULTS: dict[str, dict[str, int]] = {
    "recall": {"limit": 6},
    "project_search": {"limit": 15},
    "project_structure": {"limit": 15},
    "project_notes": {"limit": 5},
}

_defaults: dict[str, dict[str, int]] | None = None


def load_defaults() -> dict[str, dict[str, int]]:
    """内置默认 + 用户增量（同名覆盖）。首次调用解析并缓存，返回表只读。"""
    global _defaults
    if _defaults is not None:
        return _defaults

    merged = {tool: dict(args) for tool, args in TOOL_ARG_DEFAULTS.items()}
    raw = os.environ.get(TOOL_DEFAULTS_ENV_KEY, "").strip()
    if raw:
        # 坏了不能静默：表现是「我配的默认值没生效」，与「这个参数本来没配」无法区分
        try:
            user = json.loads(raw)
        except ValueError as e:
            logger.error(f"{TOOL_DEFAULTS_ENV_KEY} 不是合法 JSON，已忽略用户配置: {e}")
            user = None
        if isinstance(user, dict):
            for tool, args in user.items():
                if not isinstance(args, dict):
                    logger.error(f"toolDefaults[{tool}] 不是对象，已忽略")
                    continue
                bucket = merged.setdefault(str(tool), {})
                for key, value in args.items():
                    try:
                        bucket[str(key)] = int(value)
                    except (TypeError, ValueError):
                        logger.error(f"toolDefaults[{tool}][{key}] 不是整数，已忽略")
        elif user is not None:
            logger.error(
                f"{TOOL_DEFAULTS_ENV_KEY} 不是对象（得到 {type(user).__name__}），已忽略"
            )

    _defaults = merged
    return _defaults


def arg_default(tool: str, arg: str) -> int:
    """查表取参数默认值。表中缺失即抛 KeyError——配置错误应在开发期暴露，
    静默兜底会让「表里有、实际没生效」与「表里没配」无法区分。"""
    return load_defaults()[tool][arg]
