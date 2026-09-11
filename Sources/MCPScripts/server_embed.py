"""server 的共享 embedder 模块。

从 server.py 拆分（2026-08-30，重构阶段4）：fastembed 配置与单一 embedder 实例。
被记忆热层（server.py 的 MEM0_CONFIG/_patch_mem0_fastembed）、冷层（search_cold_layer）
与项目向量搜索（server_search.py）共用。代码原样搬移不改逻辑。

注意：本模块不 import mem0/qdrant——server.py 的模块级副作用顺序
（POSTHOG_DISABLED/MEM0_TELEMETRY + _patch_mem0_fastembed 先于 import mem0）不受影响。
"""

from __future__ import annotations

import os
import threading
from collections import OrderedDict

import numpy as np
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


# ---------------------------------------------------------------------------
# 查询向量缓存
# ---------------------------------------------------------------------------

#: 查询嵌入 LRU 容量（条）。0 表示不缓存。
_QUERY_CACHE_SIZE = int(os.environ.get("EMBED_QUERY_CACHE_SIZE", "64"))
_query_cache: OrderedDict[str, np.ndarray] = OrderedDict()
_query_cache_lock = threading.Lock()


def embed_query(text: str) -> np.ndarray | None:
    """嵌入单个查询串，带小容量 LRU。embedder 不可用时返回 None。

    同一轮 agent 常对同一 query 并发调用多个检索工具（recall / project_notes /
    project_search 都在提示里被要求「并行调用」），此前各自独立嵌入一次查询。
    查询嵌入是纯函数、单条约 45ms，缓存可消除这类重复计算。
    注意 mem0 内部走它自己的 embedder，不经过本函数，那一路无法共享。

    返回 float32 ndarray。**调用方只读**——缓存里存的就是这个对象本身。
    """
    emb = _get_shared_embedder()
    if emb is None:
        return None

    if _QUERY_CACHE_SIZE > 0:
        with _query_cache_lock:
            hit = _query_cache.get(text)
            if hit is not None:
                _query_cache.move_to_end(text)
                return hit

    vec = np.asarray(list(emb.embed([text]))[0], dtype=np.float32)

    if _QUERY_CACHE_SIZE > 0:
        with _query_cache_lock:
            _query_cache[text] = vec
            _query_cache.move_to_end(text)
            while len(_query_cache) > _QUERY_CACHE_SIZE:
                _query_cache.popitem(last=False)
    return vec
