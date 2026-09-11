"""模型代理 provider 配置的字段契约。

providers 列表由 Swift `TokenProxyManager.providersJSON()` 序列化后经
`MODEL_PROXY_PROVIDERS` 环境变量传入，`token_proxy.py`（路由到哪个上游）与
`proxy_router.py`（分类器用哪个上游）都要读。

本模块是这些字段的**唯一解析入口**：字段名两处各写一遍时，Swift 侧一改名就会
两侧同时静默退回默认值——协议转换方向错掉、鉴权 key 丢失，而日志里什么都看不到。
集中在这里之后，这类漂移只需要改一个地方，且可以在此处加校验与告警。
"""

from __future__ import annotations

import json

from log_utils import setup_logging
from proxy_normalize import API_ANTHROPIC, API_OPENAI

logger = setup_logging("token_proxy", json_format=True)

#: JSON 侧键名。与 router 配置块统一使用 snake_case。
KEY_NAME = "name"
KEY_URL = "url"
KEY_API_FORMAT = "api_format"
KEY_API_KEY = "api_key"
KEY_MODELS = "models"

#: 历史拼写（Swift 侧曾是 camelCase）。保留读取只为兼容手写 env 调试，
#: 新代码一律按上面的 snake_case 键读取。
_LEGACY_FORMAT_KEY = "apiFormat"
_LEGACY_API_KEY = "apiKey"

#: 一个 provider 要能参与路由，至少需要这些键非空。
REQUIRED_KEYS = (KEY_NAME, KEY_URL, KEY_MODELS)


def api_format_of(provider: dict) -> str:
    """provider 的协议格式：`anthropic` 或 `openai`（未知/缺失退回 anthropic）。

    退回 anthropic 是保守选择（多数 provider 走 anthropic 兼容端点），但**必须
    留痕**：取值非法说明 Swift 与 Python 的键名或枚举已经漂移，静默退回会让
    协议转换方向错掉——请求发出去能通，只是格式不对，最难排查的那类故障。
    """
    value = provider.get(KEY_API_FORMAT) or provider.get(_LEGACY_FORMAT_KEY)
    if value in (API_ANTHROPIC, API_OPENAI):
        return value
    if value:
        logger.warning(
            json.dumps(
                {
                    "msg": "provider_api_format_invalid",
                    "provider": provider.get(KEY_NAME, ""),
                    "value": str(value),
                    "effect": "退回 anthropic",
                }
            )
        )
    return API_ANTHROPIC


def api_key_of(provider: dict) -> str:
    """provider 的鉴权 key（空串 = 转发时透传客户端自带的 key）。"""
    return provider.get(KEY_API_KEY) or provider.get(_LEGACY_API_KEY) or ""


def missing_keys(provider: dict) -> list[str]:
    """返回该 provider 缺失的必需键（空列表 = 配置完整）。"""
    return [k for k in REQUIRED_KEYS if not provider.get(k)]
