"""server 的共享 embedder 模块。

从 server.py 拆分（2026-08-30，重构阶段4）：fastembed 配置与单一 embedder 实例。
被记忆热层（server.py 的 MEM0_CONFIG/_patch_mem0_fastembed）、冷层（search_cold_layer）
与项目向量搜索（server_search.py）共用。代码原样搬移不改逻辑。

注意：本模块不 import mem0/qdrant——server.py 的模块级副作用顺序
（POSTHOG_DISABLED/MEM0_TELEMETRY + _patch_mem0_fastembed 先于 import mem0）不受影响。
"""

from __future__ import annotations

import os

from fastembed import TextEmbedding

from log_utils import setup_logging

# ---------------------------------------------------------------------------
# 配置（与拆分前 server.py 一致；由 Swift MCPProcessManager 经 env 注入）
# ---------------------------------------------------------------------------

EMBEDDER_MODEL = os.environ.get(
    "EMBEDDER_MODEL", "sentence-transformers/all-MiniLM-L6-v2"
)
EMBEDDER_DIMS = 384
FASTEMBED_CACHE_DIR = os.environ.get(
    "FASTEMBED_CACHE_PATH", os.path.expanduser("~/.cache/fastembed_cache")
)
os.environ.setdefault("FASTEMBED_CACHE_PATH", FASTEMBED_CACHE_DIR)

logger = setup_logging("server")

_shared_embedder = None


def _get_shared_embedder():
    """单一 embedder 实例，冷层和项目向量搜索共用，避免重复加载 ONNX 模型。

    优化：enable_cpu_mem_arena=False 禁用 ONNX Runtime CPU arena 预分配（默认会 malloc
    ~1GB 大块）；threads=1 限制线程数；CPUExecutionProvider 避免 CoreML/Azure 提供者
    的额外内存。
    """
    global _shared_embedder
    if _shared_embedder is None:
        try:
            _shared_embedder = TextEmbedding(
                model_name=EMBEDDER_MODEL,
                cache_dir=FASTEMBED_CACHE_DIR,
                threads=1,
                providers=["CPUExecutionProvider"],
                enable_cpu_mem_arena=False,
            )
        except Exception as e:
            logger.warning(f"Shared embedder init failed (retry on next call): {e}")
    return _shared_embedder
