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
FASTEMBED_CACHE_DIR = os.environ.get(
    "FASTEMBED_CACHE_PATH", os.path.expanduser("~/.cache/fastembed_cache")
)
os.environ.setdefault("FASTEMBED_CACHE_PATH", FASTEMBED_CACHE_DIR)

logger = setup_logging("server")

#: 维度兜底值。**是兜底不是默认值**：只有在 fastembed 元数据里查不到该模型时才用。
#: 384 = `all-MiniLM-L6-v2` 的维度，也是引入本机制前写死的值（故默认路径零行为变化）。
_FALLBACK_EMBEDDER_DIMS = 384

#: fastembed 元数据（`TextEmbedding.list_supported_models()` 条目）的字段名。
#: 单列常量是因为它们是**外部库的字段名**：库改名时在这里一处红，而不是各处静默取不到
#: 值、全体回退兜底。
_META_MODEL_FIELD = "model"
_META_DIM_FIELD = "dim"


def resolve_embedder_dims(
    model_name: str, *, fallback: int = _FALLBACK_EMBEDDER_DIMS
) -> int:
    """从 fastembed 元数据解析模型的向量维度。

    维度是**模型固有属性**，故只从 fastembed 自己的元数据取：交给 Swift 注入等于另建一份
    「模型名 → 维度」映射，与真实值必然漂移（换模型忘了改映射 → 集合维度与向量维度不符）。
    查不到/字段不可用/查询异常一律回退 `fallback` 并记 warning。

    纯元数据读取：不加载 ONNX 模型、不走网络（实测 30 个条目开销可忽略）。
    """
    try:
        for entry in TextEmbedding.list_supported_models():
            if entry.get(_META_MODEL_FIELD) != model_name:
                continue
            dim = entry.get(_META_DIM_FIELD)
            if isinstance(dim, int) and dim > 0:
                return dim
            logger.warning(
                f"fastembed metadata for {model_name!r} has unusable "
                f"{_META_DIM_FIELD}={dim!r}; falling back to {fallback} dims"
            )
            return fallback
    except Exception as e:
        logger.warning(
            f"fastembed metadata lookup failed ({type(e).__name__}: {e}); "
            f"falling back to {fallback} dims"
        )
        return fallback

    logger.warning(
        f"Model {model_name!r} is not in fastembed supported models; "
        f"falling back to {fallback} dims. 若该模型维度不是 {fallback}，"
        "向量检索会以维度不符失败——先核对 EMBEDDER_MODEL 拼写"
    )
    return fallback


#: 当前 embedder 的向量维度（由模型元数据解析，见 `resolve_embedder_dims`）。
EMBEDDER_DIMS = resolve_embedder_dims(EMBEDDER_MODEL)


def describe_dim_mismatch(existing_dims: int | None, expected_dims: int) -> str | None:
    """集合维度与当前 embedder 维度不一致时的处置建议；一致或无法判定返回 None。

    为什么必须显式报错：**集合维度在首次创建时固定**。换模型（维度变化）后旧向量与
    新查询向量不可比，Qdrant 会在 query 时报 dimension 错误——而 `search_cold_layer`
    把异常吞成一条 warning，表现为「冷层检索静默失效、用户只觉得结果变少」。
    启动时点出来，比事后从「检索结果不对」倒查便宜得多。
    """
    if existing_dims is None or existing_dims == expected_dims:
        return None
    return (
        f"冷层集合维度不一致：集合 {existing_dims} 维，当前 embedder "
        f"{EMBEDDER_MODEL!r} 为 {expected_dims} 维。处置（集合维度不可修改）："
        f"改回原模型（EMBEDDER_MODEL / config.yaml mcp.embedderModel），"
        f"或删除冷层集合让其按新维度重建、向量全量重扫"
    )


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
