"""共享配置读取层。

三大单体（server.py / summarize.py / token_proxy.py）重复的 env 读取与默认值统一收束于此，
消除「同一变量在 2-3 个文件各读一遍、默认值硬编码散落」的重复。

用法（同目录扁平 import，复用 log_utils/agent_call 成功模式）：
    from config import ai_api_key, summary_model, summary_api_url, notes_dir, data_dir

注意：
- 本模块为纯函数层，仅依赖标准库 os，import 无任何副作用——server.py 必须在
  import mem0 前设置 POSTHOG_DISABLED/MEM0_TELEMETRY 的模块级副作用顺序不受影响。
- 返回均为展开后的字符串（默认值做 expanduser），调用方自行决定是否包 Path
  （如 summarize.py 用 Path(...) 包裹）。
- 各脚本专属 env（MCP_PORT / MODEL_PROXY_* / QDRANT_PATH / EMBEDDER_MODEL 等）不在此层——
  只有多文件重复的公共变量收敛。
- SUMMARY_MODEL / SUMMARY_API_URL 默认值因脚本而异：server/summarize 用真实默认值，
  token_proxy 用空串做「未配置即禁用 LLM 调用」守卫（见 token_proxy _ask_model），
  故访问器接受默认值参数，行为与拆分前完全一致。
"""

from __future__ import annotations

import os

# 空字符串 = 由 Swift 层通过环境变量注入，未注入时禁用相关功能
_DEFAULT_SUMMARY_MODEL = ""
_DEFAULT_SUMMARY_API_URL = ""
_DEFAULT_NOTES_DIR = ""
_DEFAULT_DATA_DIR = ""


def get(key: str, default: str = "") -> str:
    """统一 env 读取入口。"""
    return os.environ.get(key, default)


def ai_api_key() -> str:
    """通用 AI API key（文本生成与向量嵌入共用，与 provider 解绑）。

    环境变量 `AI_API_KEY` 由 Swift `EnvKeys.aiAPIKey` 注入，两侧一致性由
    `scripts/check-router-config-contract.py` 断言。
    """
    return get("AI_API_KEY", "")


def llm_timeout(default: float = 120.0) -> float:
    """LLM 单次推理超时（秒）。环境变量 `AI_LLM_TIMEOUT` 由 Swift 从 `ai.llmTimeout` 注入。

    缺省 / 非数字 / 非正值一律回退 `default`，与 Swift 侧 `OpenAIClient.init` 的
    「0 = 用默认值」约定一致。**不要**套用 `general.httpTimeout` 那套「0 = 不限制」：
    同一个 0 在两项配置里含义相反，是最容易被误配成「永不超时」的写法。
    """
    raw = get("AI_LLM_TIMEOUT", "")
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def ui_language(default: str = "") -> str:
    """界面/提示词语言（`zh-Hans` / `en`）。Swift 按 `general.language` 注入 `UTILITY_LANG`。

    提示词目录按它选择（`prompts/<lang>/<feature>.md`），故与界面语言必须同源。
    未注入时返回空串，由调用方（prompt_loader）回退基线语言。
    """
    return get("UTILITY_LANG", default)


def summary_model(default: str = _DEFAULT_SUMMARY_MODEL) -> str:
    return get("SUMMARY_MODEL", default)


def summary_api_url(default: str = _DEFAULT_SUMMARY_API_URL) -> str:
    return get("SUMMARY_API_URL", default)


def notes_dir(default: str = _DEFAULT_NOTES_DIR) -> str:
    raw = get("NOTES_DIR", default)
    if not raw:
        return ""
    return os.path.expanduser(raw)


def data_dir(default: str = _DEFAULT_DATA_DIR) -> str:
    raw = get("UTILITY_DATA_DIR", default)
    if not raw:
        return ""
    return os.path.expanduser(raw)


def summary_exclude_tags() -> set[str]:
    """从环境变量 SUMMARY_EXCLUDE_TAGS 读取排除 tag 列表（逗号分隔）。"""
    raw = get("SUMMARY_EXCLUDE_TAGS", "")
    return {t.strip() for t in raw.split(",") if t.strip()}
