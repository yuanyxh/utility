"""共享配置读取层。

三大单体（server.py / summarize.py / token_proxy.py）重复的 env 读取与默认值统一收束于此，
消除「同一变量在 2-3 个文件各读一遍、默认值硬编码散落」的重复。

用法（同目录扁平 import，复用 log_utils/agent_call 成功模式）：
    from config import deepseek_api_key, summary_model, summary_api_url, notes_dir, data_dir

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

# 公共默认值（与拆分前各文件硬编码一致）
_DEFAULT_SUMMARY_MODEL = "deepseek-v4-flash"
_DEFAULT_SUMMARY_API_URL = "https://api.deepseek.com"
_DEFAULT_NOTES_DIR = "~/Documents/selfdata/notes"
_DEFAULT_DATA_DIR = "~/.config/utility"


def get(key: str, default: str = "") -> str:
    """统一 env 读取入口。"""
    return os.environ.get(key, default)


def deepseek_api_key() -> str:
    return get("DEEPSEEK_API_KEY", "")


def summary_model(default: str = _DEFAULT_SUMMARY_MODEL) -> str:
    return get("SUMMARY_MODEL", default)


def summary_api_url(default: str = _DEFAULT_SUMMARY_API_URL) -> str:
    return get("SUMMARY_API_URL", default)


def notes_dir(default: str = _DEFAULT_NOTES_DIR) -> str:
    return os.path.expanduser(get("NOTES_DIR", default))


def data_dir(default: str = _DEFAULT_DATA_DIR) -> str:
    return os.path.expanduser(get("UTILITY_DATA_DIR", default))


def summary_exclude_tags() -> set[str]:
    """从环境变量 SUMMARY_EXCLUDE_TAGS 读取排除 tag 列表（逗号分隔）。"""
    raw = get("SUMMARY_EXCLUDE_TAGS", "")
    return {t.strip() for t in raw.split(",") if t.strip()}
