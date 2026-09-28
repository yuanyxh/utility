#!/usr/bin/env python3
"""
MCP MinoBraiN — 冷热双层共享记忆 + 项目依赖图查询

热层: Mem0 → Qdrant (原始碎片记忆, 自动提取/去重/冲突解决)
冷层: Qdrant 独立集合 (已归档知识索引)
项目: SQLite 依赖图查询 (FTS5 + 同义词扩展)

从 self-service-docker 移植, 适配 Utility.app 子进程模式。

重构（2026-08-30，阶段4）：共享 embedder → server_embed.py；项目依赖图查询与
笔记语义检索 → server_search.py；本入口保留记忆操作/冷层/技能/HTTP 服务/main()。
"""

# mem0 内置 PostHog 遥测在无网络环境会卡死初始化, 必须在任何 import 前禁用
import os

os.environ["POSTHOG_DISABLED"] = "1"
# mem0 自带 PostHog 遥测（独立实例，不受 posthog.disabled 影响）
# 在 import 前设此环境变量让 AnonymousTelemetry 直接跳过初始化
os.environ["MEM0_TELEMETRY"] = "False"

import json
import uuid
import sys
import time
import asyncio
import anyio
from datetime import datetime, timedelta

from mem0 import Memory
from qdrant_client import QdrantClient
import uvicorn
from qdrant_client import models
from qdrant_client.models import (
    VectorParams,
    Distance,
    PointStruct,
    Filter,
    FieldCondition,
    MatchValue,
)
from mcp.server import Server
from mcp.server import InitializationOptions
from mcp.server.models import ServerCapabilities
from mcp.server.streamable_http import StreamableHTTPServerTransport
from mcp.types import (
    Tool,
    TextContent,
    ToolsCapability,
)
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

from config import (
    ai_api_key,
    summary_model,
    summary_api_url,
    notes_dir,
)
from server_embed import (
    EMBEDDER_MODEL,
    EMBEDDER_DIMS,
    FASTEMBED_CACHE_DIR,
    _get_shared_embedder,
    describe_dim_mismatch,
    embed_query,
)
from server_search import (
    tool_project_search,
    tool_project_structure,
    tool_project_packages,
    tool_project_exports,
    _query_project_notes,
)
import llm_client
import prompt_loader
from tool_text import param_text
from log_utils import setup_logging

logger = setup_logging("server")

QDRANT_PATH = os.environ.get(
    "QDRANT_PATH", os.path.expanduser("~/Documents/selfdata/database/qdrant_data")
)

MEM0_QDRANT_PATH = os.path.join(QDRANT_PATH, "mem0")


def _cleanup_qdrant_locks() -> None:
    """Qdrant Local 模式崩溃后锁文件残留会阻塞下次启动, 启动前清理。"""
    for root_dir in (
        QDRANT_PATH,
        MEM0_QDRANT_PATH,
        os.path.expanduser("~/.mem0/migrations_qdrant"),
    ):
        lock = os.path.join(root_dir, ".lock")
        if os.path.isfile(lock):
            try:
                os.remove(lock)
                logger.info(f"Cleaned stale lock: {lock}")
            except OSError as e:
                logger.warning(f"Failed to remove lock {lock}: {e}")


_cleanup_qdrant_locks()

COLD_COLLECTION = "knowledge_base"

logger.info(
    f"ENV CHECK: FASTEMBED_CACHE_PATH={FASTEMBED_CACHE_DIR}, MCP_PORT={os.environ.get('MCP_PORT')}, "
    f"QDRANT_PATH={os.environ.get('QDRANT_PATH')}, MEM0_TELEMETRY={os.environ.get('MEM0_TELEMETRY')}"
)

NOTES_DIR = notes_dir()

SKILLS_DIR = os.path.join(NOTES_DIR, "MCP", "Skills")

DESCRIPTIONS_FILE = os.path.join(NOTES_DIR, "MCP", "DESCRIPTIONS.md")

#: recall 默认返回条数。工具 schema 的 default 与运行时兜底共用此常量——
#: 两处各写一份字面量会漂移成「schema 声明 8、实际取 10」，客户端按声明
#: 省略 limit 时拿到的条数与它看到的不一致。
DEFAULT_RECALL_LIMIT = 8

TOOL_DEFAULTS: dict[str, str] = {
    "remember": "用户说「记住/记录」、bug 修复完成、得知关键要点、输出/更新架构设计 → 必须调用本工具。写入单条事实到共享记忆。content: 记忆内容。有产生背景时首行 [背景说明], 次行起 [事实] ...; 无背景直接写事实, 禁止硬凑背景。有背景时按三要素组织——场景(项目/上下文)、决策(怎么做/选)、演进(当前状态/后续变化), 缺的要素省略不硬凑。多条内容请用 remember_batch。",
    "remember_batch": "有多条内容需要记录时优先使用, 可大幅减少调用次数。批量写入多条记忆, 功能与 remember 一致。",
    "recall": "用户说「查一下/搜索/找一下/之前那个」、提到历史/已有信息 → 必须调用本工具。在共享记忆库、知识库和笔记中搜索。禁止用 grep/git log 代替。",
    "catch_up": "用户说「刚才/上次/之前/上回/近期」或问做了什么/进展/未解决问题 → 必须调用本工具。禁止用 git log 代替。获取最近记忆列表, 用于跨会话上下文恢复。",
    "forget": "用户要求删除记忆, 或记忆内容有误/过时 → 调用本工具。删除指定 ID 的记忆。",
    "project_search": "优先使用本工具查找(符号/文件/Package)的定义和位置, 避免全量读取文件。支持中文同义词扩展。项目依赖图查找。",
    "project_structure": "优先使用本工具了解项目目录结构，替代 ls/find 遍历。指定子路径查看下一级。",
    "project_packages": "列出项目三方依赖。",
    "project_exports": "优先使用本工具获取文件或目录的公共接口, 避免全量读取文件。",
    "project_notes": "用户说「查一下/搜索/找一下/之前那个」、提到历史/已有信息 → 必须并行调用本工具。recall 变体, 搜索项目本地信息",
    "tool_resource": "当指示加载 references 文件或需要查看 scripts 脚本内容时调用。返回附属资源内容（references/agents/scripts 目录下的参考文档）。",
    "set_memory_processed": "设置/重置记忆的已处理标识位（metadata.processed 位掩码）。bit0=1 表示已被总结脚本成功处理。测试与还原用：value=1 设置、value=0 重置，幂等。",
}

EXCLUDE_DIRS = {"Self_Data", "Works_Jobs", "SaveWebPages", "Resources", "Attachments"}

NOTE_EXTENSIONS = (".md", ".txt", ".py", ".yaml", ".yml", ".json", ".toml")

# 通过环境变量 SERVER_TIMEOUT 可覆盖（Swift 层从 GeneralConfig.httpTimeout 读取）
DEFAULT_TIMEOUT = float(os.environ.get("SERVER_TIMEOUT", "60.0"))

SUMMARY_LLM_MODEL = summary_model()

SUMMARY_LLM_API_URL = summary_api_url()

AI_API_KEY = ai_api_key()

SUMMARY_LLM_TEMPERATURE = 0.1

DEFAULT_HEAT_SCORE = 1.0

HEAT_INCREMENT = 0.1

HEAT_MAX = 1.0

HEAT_DECAY_PER_DAY = 0.01

HOT_INIT_RUNTIME_COOLDOWN = 60

HOT_INIT_MAX_RUNTIME_FAILURES = 5

PROCESSED_FIELD = "processed"

PROCESSED_MAX_BIT = 7

#: `set_memory_processed` 的参数校验文案。HTTP 端点（`api_memories_processed`）与 MCP 工具
#: （`_handle_set_memory_processed`）**共用同一批**——两处各写一份时改一处忘一处，会让同一个
#: 错误在两条入口给出不同提示；而这是**给模型看**的文案，措辞不定只会让它更难判断该改哪个参数。
#: 统一英文：这一层（工具返回/内部日志）不与 `UTILITY_LANG` 联动，面向终端用户的文案在 Swift
#: 侧由 `L10n` 覆盖。
ERR_MEMORY_IDS_EMPTY = "memory_ids must not be empty"
ERR_VALUE_INVALID = "value must be 0 (reset) or 1 (set)"
ERR_BIT_VALUE_NOT_INT = "bit/value must be integers"

#: 入口层通用错误：热层未就绪。**6 处**（各工具 handler + HTTP 端点）共用一句——
#: 各写一份时改一处忘一处，同一状态在不同工具下提示不同，调用方难以归纳该怎么重试。
ERR_HOT_LAYER_NOT_READY = "Hot layer not initialized"


def err_bit_out_of_range(bit: int | None = None) -> str:
    """bit 越界文案。带 `bit` 时附上实际值——内部异常用它，日志里能直接看出是哪个值越界。"""
    return f"bit out of range 0-{PROCESSED_MAX_BIT}" + (
        "" if bit is None else f": {bit}"
    )


ARCHIVE_DAYS = 90

HOT_RETENTION_DAYS = 180

ARCHIVE_INTERVAL_HOURS = 24

# 空字符串 = 由 Swift 层通过环境变量注入（传入当前系统用户名）
DEFAULT_USER_ID = os.environ.get("UTILITY_USER_ID", "")

CONTRADICTION_SIMILARITY_THRESHOLD = 0.8

CONTRADICTION_TOP_K = 5

SERVER_NAME = "mino-brain"

SERVER_VERSION = "1.0.0"

MCP_PORT = int(os.environ.get("MCP_PORT", "9001"))


def _patch_mem0_fastembed():
    """Monkey-patch mem0 FastEmbedEmbedding 以启用内存优化参数。

    mem0 原始实现只传 model_name 给 TextEmbedding，缺失 cache_dir/threads/providers
    等优化参数。此处直接替换 init 逻辑，跳过原始 TextEmbedding 创建再重建的浪费。
    """
    try:
        from mem0.embeddings.fastembed import FastEmbedEmbedding
        from mem0.embeddings.base import EmbeddingBase
        import fastembed

        def _optimized_init(self, config=None):
            # 直接调 EmbeddingBase.__init__ 设置 config，跳过 FastEmbedEmbedding 原始
            # init 中的无优化 TextEmbedding 创建
            EmbeddingBase.__init__(self, config)
            self.config.model = self.config.model or "thenlper/gte-large"
            self.dense_model = fastembed.TextEmbedding(
                model_name=self.config.model,
                cache_dir=FASTEMBED_CACHE_DIR,
                threads=1,
                providers=["CPUExecutionProvider"],
                enable_cpu_mem_arena=False,
            )
            if not self.config.embedding_dims:
                self.config.embedding_dims = self.dense_model.embedding_size

        FastEmbedEmbedding.__init__ = _optimized_init
        logger.info("Patched mem0 FastEmbedEmbedding with memory-optimized config")
    except ImportError:
        pass


_patch_mem0_fastembed()

MEM0_CONFIG = {
    "vector_store": {
        "provider": "qdrant",
        "config": {
            "path": MEM0_QDRANT_PATH,
            "on_disk": True,
            "embedding_model_dims": EMBEDDER_DIMS,
        },
    },
    "llm": {
        "provider": "openai",
        "config": {
            "model": SUMMARY_LLM_MODEL,
            "openai_base_url": SUMMARY_LLM_API_URL,
            "api_key": AI_API_KEY,
            "temperature": SUMMARY_LLM_TEMPERATURE,
        },
    },
    "embedder": {
        "provider": "fastembed",
        "config": {
            "model": EMBEDDER_MODEL,
        },
    },
}

hot_memory = None

HOT_INIT_MAX_RETRIES = 3

HOT_INIT_RETRY_DELAY = 5

_hot_runtime_failures = 0

_hot_last_init_attempt = 0.0


def _init_hot_memory() -> bool:
    global hot_memory
    # mem0 内置 PostHog 遥测会阻塞初始化，强制禁用
    try:
        import posthog

        posthog.disabled = True
    except ImportError:
        pass
    logger.info(
        f"Mem0 telemetry disabled (MEM0_TELEMETRY={os.environ.get('MEM0_TELEMETRY')}), "
        "PostHog network calls will be skipped"
    )
    for attempt in range(HOT_INIT_MAX_RETRIES):
        try:
            hot_memory = Memory.from_config(MEM0_CONFIG)
            logger.info("Mem0 (hot layer) initialized")
            return True
        except Exception as e:
            logger.warning(
                f"Hot layer init attempt {attempt + 1}/{HOT_INIT_MAX_RETRIES} failed: {e}"
            )
            if attempt < HOT_INIT_MAX_RETRIES - 1:
                time.sleep(HOT_INIT_RETRY_DELAY)
    logger.error(f"Hot layer init failed after {HOT_INIT_MAX_RETRIES} attempts")
    return False


def _collection_vector_size(client, collection_name: str) -> int | None:
    """读集合的向量维度；读不到返回 None（调用方按「无法判定」跳过校验）。

    本项目用单向量配置；命名向量（dict）形态一并兼容——为读一个维度而崩在启动路径上，
    代价远大于兼容它的几行代码。
    """
    try:
        vectors = client.get_collection(collection_name).config.params.vectors
    except Exception as e:
        logger.warning(f"failed to read dimension of collection {collection_name}: {e}")
        return None
    size = getattr(vectors, "size", None)
    if isinstance(size, int):
        return size
    if isinstance(vectors, dict):
        for config in vectors.values():
            value = getattr(config, "size", None)
            if isinstance(value, int):
                return value
    return None


try:
    qdrant = QdrantClient(path=QDRANT_PATH, force_disable_check_same_thread=True)
    existing = [c.name for c in qdrant.get_collections().collections]
    if COLD_COLLECTION not in existing:
        qdrant.create_collection(
            collection_name=COLD_COLLECTION,
            vectors_config=VectorParams(size=EMBEDDER_DIMS, distance=Distance.COSINE),
        )
        logger.info(f"Cold layer collection '{COLD_COLLECTION}' created")
    else:
        # 集合维度在首次创建时固定：换模型（维度变化）后旧向量与新查询向量不可比，
        # 而检索侧异常会被吞成一条 warning —— 表现为冷层检索静默失效。启动时点出来。
        advice = describe_dim_mismatch(
            _collection_vector_size(qdrant, COLD_COLLECTION), EMBEDDER_DIMS
        )
        if advice:
            logger.error(advice)
            # 禁用冷层，但热层/项目检索照常（其余 qdrant 用法均有 `if qdrant` 守卫）
            qdrant = None
    if qdrant is not None:
        logger.info("Cold layer (Qdrant direct) initialized")
except Exception as e:
    logger.error(f"Cold layer Qdrant init failed: {e}")
    qdrant = None

_ensure_hot_lock = asyncio.Lock()


async def _ensure_hot_memory() -> bool:
    global hot_memory, _hot_runtime_failures, _hot_last_init_attempt
    if hot_memory is not None:
        return True
    now = time.time()
    if now - _hot_last_init_attempt < HOT_INIT_RUNTIME_COOLDOWN:
        return False
    async with _ensure_hot_lock:
        if hot_memory is not None:
            return True
        if time.time() - _hot_last_init_attempt < HOT_INIT_RUNTIME_COOLDOWN:
            return False
        _hot_last_init_attempt = time.time()
        success = _init_hot_memory()
    if success:
        _hot_runtime_failures = 0
        return True
    _hot_runtime_failures += 1
    logger.error(
        f"Hot layer runtime recovery failed ({_hot_runtime_failures}/{HOT_INIT_MAX_RUNTIME_FAILURES})"
    )
    if _hot_runtime_failures >= HOT_INIT_MAX_RUNTIME_FAILURES:
        fail_msg = f"[{datetime.now().isoformat()}] HOT LAYER FATAL: {_hot_runtime_failures} consecutive init failures"
        logger.critical(fail_msg)
        sys.exit(1)
    return False


def _notes_snippet(text: str, needle: str, max_lines: int = 3) -> str:
    """取前 max_lines 条含 needle 的行，格式与原 `grep -inF -m <max_lines>` 一致。

    输出形如 `12:foo\\n45:bar`（行号:行内容，换行连接）；无命中返回空串。
    """
    if not needle:
        return ""
    hits: list[str] = []
    for line_no, line in enumerate(text.splitlines(), 1):
        if needle in line.lower():
            hits.append(f"{line_no}:{line}")
            if len(hits) >= max_lines:
                break
    return "\n".join(hits)


def search_cold_layer(
    query: str, limit: int = 5, include_archived: bool = False
) -> list[dict]:
    results = []
    qvec = embed_query(query) if qdrant else None
    if qdrant and qvec is not None:
        try:
            vec = qvec.tolist()
            qfilter = None
            if not include_archived:
                qfilter = Filter(
                    must_not=[
                        FieldCondition(key="archived", match=MatchValue(value=True))
                    ]
                )
            resp = qdrant.query_points(
                collection_name=COLD_COLLECTION,
                query=vec,
                limit=limit,
                query_filter=qfilter,
            )
            for h in resp.points:
                results.append(
                    {
                        "id": h.id,
                        "content": h.payload.get("content", ""),
                        "source_file": h.payload.get("source_file", ""),
                        "created_at": h.payload.get("created_at", ""),
                        "type": h.payload.get("type", ""),
                        "score": h.score,
                        "layer": "cold",
                        "heat_score": h.payload.get("heat_score", DEFAULT_HEAT_SCORE),
                        "access_count": h.payload.get("access_count", 0),
                        "last_accessed_at": h.payload.get("last_accessed_at", ""),
                    }
                )
                _update_cold_heat(h.id)
        except Exception as e:
            logger.warning(f"Qdrant cold search failed: {e}")
    tokens = [t for t in query.split() if t]
    if not tokens:
        tokens = [query]
    needles = [t.lower() for t in tokens]
    head = needles[0]

    try:
        for root, dirs, files in os.walk(NOTES_DIR):
            dirs[:] = [
                d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith(".")
            ]
            for f in files:
                if not f.endswith(NOTE_EXTENSIONS):
                    continue
                path = os.path.join(root, f)
                rel = os.path.relpath(path, NOTES_DIR)
                try:
                    with open(path, "r", encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    continue
                # 任一词命中即算命中（等价于原 grep -iFq 的短路语义）。
                # 原实现用 subprocess 逐文件逐词起 grep 进程，454 个文件 × N 词
                # 实测 2.4s(N=1) / 4.5s(N=2) / 7.5s(N=4)，是 recall 的最大单项开销。
                low = text.lower()
                if not any(n in low for n in needles):
                    continue
                results.append(
                    {
                        "id": f"notes:{rel}",
                        "content": _notes_snippet(text, head) or rel,
                        "source_file": rel,
                        "created_at": "",
                        "type": "notes",
                        "score": 0.5 + (len(tokens) / 100),
                        "layer": "notes",
                        "heat_score": DEFAULT_HEAT_SCORE,
                    }
                )
    except Exception as e:
        logger.warning(f"Notes search failed: {e}")
    results.sort(key=_heat_sort_key, reverse=True)
    return results[:limit]


def _parse_skill_frontmatter(raw: str, filename: str) -> tuple[str, str, str]:
    name, description, content = None, "", raw
    if raw.startswith("---"):
        parts = raw.split("---", 2)
        if len(parts) >= 3:
            frontmatter = parts[1].strip()
            content = parts[2].strip()
            for line in frontmatter.split("\n"):
                line = line.strip()
                if ":" in line:
                    key, _, value = line.partition(":")
                    key = key.strip().lower()
                    value = value.strip().strip('"').strip("'")
                    if key == "name":
                        name = value
                    elif key == "description":
                        description = value
    if not name:
        name = filename[:-3]
    return name, description, content


def _normalize_name(name: str) -> str:
    return name.replace("-", "_")


_SKILL_SKIP_DIRS = {"references", "agents", "scripts"}


def _scan_skills() -> dict[str, dict]:
    skills: dict[str, dict] = {}
    if not os.path.isdir(SKILLS_DIR):
        return skills
    try:
        # 递归遍历 SKILLS_DIR 下所有子目录，深度扫描 .md 文件。
        # 仅当当前目录是 Waza 式目录 skill（含 SKILL.md）时，才跳过其
        # references/agents/scripts 附属子目录，并只注册 SKILL.md 本身；
        # 无 SKILL.md 的普通目录不跳过，其内所有 .md（含 references 等
        # 子目录中的）照常注册。
        for root, dirs, files in os.walk(SKILLS_DIR):
            if "SKILL.md" in files:
                dirs[:] = [d for d in dirs if d not in _SKILL_SKIP_DIRS]
                files = [f for f in files if f == "SKILL.md"]
            dirs.sort()
            for f in sorted(files):
                if not f.endswith(".md"):
                    continue
                path = os.path.join(root, f)
                try:
                    with open(path, "r", encoding="utf-8") as fh:
                        raw = fh.read()
                    name, description, content = _parse_skill_frontmatter(raw, f)
                    if name:
                        skills[_normalize_name(name)] = {
                            "name": name,
                            "description": description,
                            "content": content,
                        }
                except Exception:
                    pass
    except Exception:
        pass
    return skills


def _find_skill_dir(name: str) -> str | None:
    """按注册名（normalize 后）定位 skill 目录；返回绝对路径，未找到返回 None。"""
    direct = os.path.join(SKILLS_DIR, name)
    if os.path.isfile(os.path.join(direct, "SKILL.md")):
        return direct
    # 注册名来自 SKILL.md frontmatter 的 name（normalize 后），目录名可能保留原名/连字符
    try:
        entries = os.listdir(SKILLS_DIR)
    except OSError:
        return None
    for entry in sorted(entries):
        skill_dir = os.path.join(SKILLS_DIR, entry)
        skill_md = os.path.join(skill_dir, "SKILL.md")
        if not os.path.isfile(skill_md):
            continue
        try:
            with open(skill_md, "r", encoding="utf-8") as fh:
                raw = fh.read()
        except Exception:
            continue
        fname, _, _ = _parse_skill_frontmatter(raw, skill_md)
        if fname and _normalize_name(fname) == name:
            return skill_dir
    return None


def _load_tool_descriptions() -> dict[str, str]:
    result: dict[str, str] = {}
    if not os.path.isfile(DESCRIPTIONS_FILE):
        return result
    try:
        with open(DESCRIPTIONS_FILE, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except Exception:
        return result
    current_name = None
    current_lines: list[str] = []
    for line in raw.split("\n"):
        stripped = line.strip()
        if stripped.startswith("### "):
            if current_name and current_lines:
                result[current_name] = "\n".join(current_lines).strip()
            current_name = stripped[4:].strip()
            current_lines = []
        elif current_name:
            current_lines.append(line)
    if current_name and current_lines:
        result[current_name] = "\n".join(current_lines).strip()
    return result


def _heat_sort_key(item: dict) -> float:
    score = item.get("score", 0)
    heat = item.get("heat_score", item.get("metadata", {}).get("heat_score", 0.5))
    if isinstance(heat, (int, float)):
        heat = float(heat)
    else:
        heat = 0.5
    return score * (0.8 + 0.2 * min(heat, HEAT_MAX))


def _update_cold_heat(point_id: str) -> None:
    if not qdrant:
        return
    try:
        now_iso = datetime.now().isoformat()
        existing = qdrant.retrieve(
            collection_name=COLD_COLLECTION, ids=[point_id], with_payload=True
        )
        if not existing:
            return
        payload = existing[0].payload or {}
        access_count = payload.get("access_count", 0) + 1
        heat_score = min(
            HEAT_MAX, payload.get("heat_score", DEFAULT_HEAT_SCORE) + HEAT_INCREMENT
        )
        qdrant.set_payload(
            collection_name=COLD_COLLECTION,
            payload={
                "access_count": access_count,
                "last_accessed_at": now_iso,
                "heat_score": heat_score,
            },
            points=[point_id],
        )
    except Exception:
        pass


def _build_metadata(src: dict, now_iso: str) -> dict:
    return {
        "agent_id": src.get("agent_id", "unknown"),
        "visibility": src.get("visibility", "all"),
        "tags": src.get("tags", []),
        "confidence": src.get("confidence", 1.0),
        "heat_score": DEFAULT_HEAT_SCORE,
        "last_accessed_at": now_iso,
        "access_count": 0,
        "archived": False,
        # 已处理位掩码：bit0=1 表示已被总结脚本成功处理（其余位预留）
        "processed": 0,
    }


async def _check_contradiction(content: str, similar_items: list[dict]) -> dict | None:
    if not similar_items or not llm_client.is_configured():
        return None
    items_text = "\n\n---\n\n".join(
        [
            f"[ID: {item.get('id', 'unknown')}] {item.get('content', item.get('memory', ''))}"
            for item in similar_items[:CONTRADICTION_TOP_K]
        ]
    )
    prompt = prompt_loader.prompt(
        "contradiction",
        items_text=items_text,
        content=content,
    )
    raw = await llm_client.achat(
        prompt,
        temperature=0.1,
        timeout=DEFAULT_TIMEOUT,
        label="Contradiction check failed",
    )
    return llm_client.parse_json(raw)


def _mark_hot_disputed(memory_id: str, disputed_by: str, reason: str) -> bool:
    if not hot_memory:
        return False
    try:
        old = hot_memory.get(memory_id)
        if not old:
            return False
        old_content = old.get("memory", "")
        old_meta = dict(old.get("metadata", {}) or {})
        old_meta.setdefault("processed", 0)  # 透传已处理位，避免 delete+add 重建丢失
        old_meta["disputed"] = True
        old_meta["disputed_by"] = disputed_by
        old_meta["dispute_reason"] = reason
        hot_memory.delete(memory_id)
        try:
            hot_memory.add(old_content, user_id=DEFAULT_USER_ID, metadata=old_meta)
        except Exception:
            try:
                hot_memory.add(old_content, user_id=DEFAULT_USER_ID)
            except Exception:
                return False
        return True
    except Exception:
        return False


def _set_processed_bit(memory_id: str, bit: int, value: int) -> bool:
    """设置/重置记忆 metadata['processed'] 的指定位（bit0=已总结处理）。

    经 mem0 update 只改 payload 不重建向量（data=None 跳过 embed），幂等；
    HTTP 端点与 MCP 工具共用，单一实现。
    """
    if not hot_memory:
        return False
    if not (0 <= bit <= PROCESSED_MAX_BIT):
        raise ValueError(err_bit_out_of_range(bit))
    try:
        old = hot_memory.get(memory_id)
        if not old:
            return False
        meta = dict(old.get("metadata", {}) or {})
        flags = int(meta.get(PROCESSED_FIELD, 0) or 0)
        mask = 1 << bit
        meta[PROCESSED_FIELD] = flags | mask if value else flags & ~mask
        hot_memory.update(memory_id, metadata=meta)
        return True
    except Exception as e:
        logger.warning(
            f"failed to set processed bit {memory_id} bit={bit} value={value}: {e}"
        )
        return False


_pending_contradictions: set[asyncio.Task] = set()

_MAX_CONTRADICTION_TASKS = 5


async def _contradiction_check_hot(content: str, memory_id: str) -> None:
    if not hot_memory:
        return
    try:
        # 不传 rerank：MEM0_CONFIG 未配置 reranker，mem0 内部条件
        # `if rerank and self.reranker` 恒假 —— 传了是空操作，徒增误导。
        similar_raw = hot_memory.search(
            content,
            top_k=CONTRADICTION_TOP_K,
            threshold=0.0,
            filters={"user_id": DEFAULT_USER_ID},
        )
        similar_list = (
            similar_raw
            if isinstance(similar_raw, list)
            else similar_raw.get("results", [])
        )
        high_sim = [
            r
            for r in similar_list
            if isinstance(r, dict)
            and r.get("score", 0) >= CONTRADICTION_SIMILARITY_THRESHOLD
            and r.get("id") != memory_id
        ]
        if high_sim:
            result = await _check_contradiction(content, high_sim)
            if result and result.get("relation") == "contradiction":
                cid, reason = result.get("conflicting_id", ""), result.get("reason", "")
                _mark_hot_disputed(memory_id, cid, reason)
                if cid:
                    _mark_hot_disputed(cid, memory_id, reason)
                logger.info(f"Contradiction detected: {memory_id} <-> {cid} ({reason})")
    except Exception as e:
        logger.warning(f"Hot contradiction check failed: {e}")


def _spawn_contradiction_check(coro) -> None:
    """Spawn a contradiction check task, limiting concurrent tasks to avoid memory leak."""
    # 清理已完成的 task
    done = {t for t in _pending_contradictions if t.done()}
    _pending_contradictions.difference_update(done)
    if len(_pending_contradictions) >= _MAX_CONTRADICTION_TASKS:
        return  # 积压过多则跳过，等待下一轮
    task = asyncio.create_task(coro)
    _pending_contradictions.add(task)


async def _contradiction_check_cold(content: str, point_id: str) -> None:
    if not qdrant:
        return
    emb = _get_shared_embedder()
    if emb is None:
        return
    try:
        vec = list(emb.embed(content))[0].tolist()
        resp = qdrant.query_points(
            collection_name=COLD_COLLECTION, query=vec, limit=CONTRADICTION_TOP_K
        )
        high_sim = [
            r
            for r in resp.points
            if r.score >= CONTRADICTION_SIMILARITY_THRESHOLD and r.id != point_id
        ]
        if high_sim:
            similar = [
                {"id": r.id, "content": r.payload.get("content", "")[:500]}
                for r in high_sim
            ]
            result = await _check_contradiction(content, similar)
            if result and result.get("relation") == "contradiction":
                cid, reason = result.get("conflicting_id", ""), result.get("reason", "")
                for pid in [point_id, cid]:
                    if pid:
                        try:
                            qdrant.set_payload(
                                collection_name=COLD_COLLECTION,
                                payload={
                                    "disputed": True,
                                    "disputed_by": cid if pid == point_id else point_id,
                                    "dispute_reason": reason,
                                },
                                points=[pid],
                            )
                        except Exception:
                            pass
                logger.info(
                    f"Cold contradiction detected: {point_id} <-> {cid} ({reason})"
                )
    except Exception as e:
        logger.warning(f"Cold contradiction check failed: {e}")


server = Server(SERVER_NAME)


@server.list_tools()
async def handle_list_tools() -> list[Tool]:
    desc = _load_tool_descriptions()
    tools = [
        Tool(
            name="remember",
            description=desc.get("remember", TOOL_DEFAULTS["remember"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": param_text("param.memory_content"),
                    },
                    "agent_id": {"type": "string", "default": "unknown"},
                    "visibility": {
                        "type": "string",
                        "enum": ["all", "agent-specific", "user-only"],
                        "default": "all",
                    },
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "confidence": {"type": "number", "default": 1.0},
                    "supersedes": {"type": "array", "items": {"type": "string"}},
                    "disputed_by": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["content"],
            },
        ),
        Tool(
            name="remember_batch",
            description=desc.get("remember_batch", TOOL_DEFAULTS["remember_batch"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "memories": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "content": {
                                    "type": "string",
                                    "description": param_text("param.memory_content"),
                                },
                                "agent_id": {"type": "string", "default": "unknown"},
                                "visibility": {
                                    "type": "string",
                                    "enum": ["all", "agent-specific", "user-only"],
                                    "default": "all",
                                },
                                "tags": {"type": "array", "items": {"type": "string"}},
                                "confidence": {"type": "number", "default": 1.0},
                                "supersedes": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                },
                            },
                            "required": ["content"],
                        },
                    },
                },
                "required": ["memories"],
            },
        ),
        Tool(
            name="recall",
            description=desc.get("recall", TOOL_DEFAULTS["recall"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": param_text("param.query"),
                    },
                    "limit": {
                        "type": "integer",
                        "default": DEFAULT_RECALL_LIMIT,
                        "description": param_text("param.max_results"),
                    },
                    "include_archived": {"type": "boolean", "default": False},
                },
                "required": ["query"],
            },
        ),
        Tool(
            name="catch_up",
            description=desc.get("catch_up", TOOL_DEFAULTS["catch_up"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "since_days": {
                        "type": "number",
                        "description": param_text("param.since_days"),
                    },
                },
            },
        ),
        Tool(
            name="forget",
            description=desc.get("forget", TOOL_DEFAULTS["forget"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "memory_id": {"type": "string"},
                    "point_id": {"type": "string"},
                    "layer": {
                        "type": "string",
                        "enum": ["hot", "cold", "all"],
                        "default": "hot",
                    },
                },
            },
        ),
        Tool(
            name="set_memory_processed",
            description=desc.get(
                "set_memory_processed", TOOL_DEFAULTS["set_memory_processed"]
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "memory_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": param_text("param.memory_ids"),
                    },
                    "bit": {
                        "type": "integer",
                        "default": 0,
                        "description": param_text("param.bit"),
                    },
                    "value": {
                        "type": "integer",
                        "default": 1,
                        "description": param_text("param.bit_value"),
                    },
                },
                "required": ["memory_ids"],
            },
        ),
        # ── 项目工具 ──
        Tool(
            name="project_search",
            description=desc.get("project_search", TOOL_DEFAULTS["project_search"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": param_text("param.db_path"),
                    },
                    "query": {
                        "type": "string",
                        "description": param_text("param.search_keyword"),
                    },
                    "file_path": {
                        "type": "string",
                        "description": param_text("param.file_path"),
                    },
                    "kind": {
                        "type": "string",
                        "description": param_text("param.symbol_kind"),
                    },
                },
                "required": ["dbPath", "query"],
            },
        ),
        Tool(
            name="project_structure",
            description=desc.get(
                "project_structure", TOOL_DEFAULTS["project_structure"]
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": param_text("param.db_path"),
                    },
                    "path": {
                        "type": "string",
                        "description": param_text("param.subpath"),
                    },
                },
                "required": ["dbPath"],
            },
        ),
        Tool(
            name="project_packages",
            description=desc.get("project_packages", TOOL_DEFAULTS["project_packages"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": param_text("param.db_path"),
                    },
                    "type": {
                        "type": "string",
                        "description": param_text("param.package_type"),
                    },
                },
                "required": ["dbPath"],
            },
        ),
        Tool(
            name="project_exports",
            description=desc.get("project_exports", TOOL_DEFAULTS["project_exports"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "dbPath": {
                        "type": "string",
                        "description": param_text("param.db_path"),
                    },
                    "path": {
                        "type": "string",
                        "description": param_text("param.file_or_dir"),
                    },
                },
                "required": ["dbPath", "path"],
            },
        ),
        Tool(
            name="project_notes",
            description=desc.get("project_notes", TOOL_DEFAULTS["project_notes"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": param_text("param.notes_keyword"),
                    },
                    "path": {
                        "type": "string",
                        "description": param_text("param.project_dir"),
                    },
                    "limit": {
                        "type": "integer",
                        "description": param_text("param.max_results"),
                        "default": 5,
                    },
                },
                "required": ["query", "path"],
            },
        ),
        Tool(
            name="tool_resource",
            description=desc.get("tool_resource", TOOL_DEFAULTS["tool_resource"]),
            inputSchema={
                "type": "object",
                "properties": {
                    "parentName": {
                        "type": "string",
                        "description": param_text("param.parent_name"),
                    },
                    "path": {
                        "type": "string",
                        "description": param_text("param.resource_path"),
                    },
                },
                "required": ["parentName", "path"],
            },
        ),
    ]
    for skill_name, skill in _scan_skills().items():
        tools.append(
            Tool(
                name=skill_name,
                description=skill["description"],
                inputSchema={"type": "object", "properties": {}},
            )
        )
    return tools


HANDLERS: dict[str, callable] = {}


def _register(name: str):
    def decorator(func):
        HANDLERS[name] = func
        return func

    return decorator


@_register("remember")
async def _handle_remember(arguments: dict) -> list[TextContent]:
    if not await _ensure_hot_memory():
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "error": ERR_HOT_LAYER_NOT_READY,
                        "retry_after_seconds": HOT_INIT_RUNTIME_COOLDOWN,
                    }
                ),
            )
        ]
    content = arguments["content"]
    now_iso = datetime.now().isoformat()
    metadata = _build_metadata(arguments, now_iso)
    for sid in arguments.get("supersedes", []):
        try:
            hot_memory.delete(sid)
        except Exception:
            pass
    result = hot_memory.add(
        content, user_id=DEFAULT_USER_ID, metadata=metadata, infer=False
    )
    results = result.get("results", [])
    memory_id = results[0].get("id") if results else None
    if memory_id:
        _spawn_contradiction_check(_contradiction_check_hot(content, memory_id))
    return [
        TextContent(
            type="text",
            text=json.dumps(
                {
                    "success": memory_id is not None,
                    "memory_id": memory_id,
                    "layer": "hot",
                    "error": None if memory_id else "Content could not be stored.",
                }
            ),
        )
    ]


@_register("remember_batch")
async def _handle_remember_batch(arguments: dict) -> list[TextContent]:
    if not await _ensure_hot_memory():
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "error": ERR_HOT_LAYER_NOT_READY,
                        "retry_after_seconds": HOT_INIT_RUNTIME_COOLDOWN,
                    }
                ),
            )
        ]
    memories = arguments.get("memories", [])
    if not memories:
        return [
            TextContent(
                type="text", text=json.dumps({"error": "memories array is empty"})
            )
        ]
    results = []
    now_iso = datetime.now().isoformat()
    for mem in memories:
        content = mem["content"]
        metadata = _build_metadata(mem, now_iso)
        for sid in mem.get("supersedes", []):
            try:
                hot_memory.delete(sid)
            except Exception:
                pass
        try:
            result = hot_memory.add(
                content, user_id=DEFAULT_USER_ID, metadata=metadata, infer=False
            )
            results_list = result.get("results", [])
            memory_id = results_list[0].get("id") if results_list else None
            item_result = {
                "success": memory_id is not None,
                "memory_id": memory_id,
                "layer": "hot",
            }
            results.append(item_result)
            if memory_id:
                _spawn_contradiction_check(_contradiction_check_hot(content, memory_id))
        except Exception as e:
            results.append({"success": False, "error": str(e)})
    return [
        TextContent(
            type="text",
            text=json.dumps(
                {
                    "results": results,
                    "total": len(results),
                    "succeeded": sum(1 for r in results if r.get("success")),
                    "failed": sum(1 for r in results if not r.get("success")),
                }
            ),
        )
    ]


@_register("recall")
async def _handle_recall(arguments: dict) -> list[TextContent]:
    query = arguments["query"]
    limit = arguments.get("limit", DEFAULT_RECALL_LIMIT)
    include_archived = arguments.get("include_archived", False)
    results = []
    if hot_memory:
        try:
            # 不传 rerank：MEM0_CONFIG 未配置 reranker，mem0 内部条件
            # `if rerank and self.reranker` 恒假 —— 传了是空操作，徒增误导。
            hot_raw = hot_memory.search(
                query,
                filters={"user_id": DEFAULT_USER_ID},
                top_k=limit,
                threshold=0.0,
            )
            hot = hot_raw if isinstance(hot_raw, list) else hot_raw.get("results", [])
            for r in hot:
                if isinstance(r, str):
                    continue
                meta = r.get("metadata", {})
                if not include_archived and meta.get("archived"):
                    continue
                r["layer"] = "hot"
                r["content"] = r.get("memory", r.get("content", ""))
                r["heat_score"] = meta.get("heat_score", DEFAULT_HEAT_SCORE)
                results.append(r)
        except Exception as e:
            logger.warning(f"Hot search failed: {e}")
    cold = search_cold_layer(query, limit, include_archived=include_archived)
    results.extend(cold)
    results.sort(key=_heat_sort_key, reverse=True)
    return [
        TextContent(
            type="text",
            text=json.dumps(
                {
                    "results": results[:limit],
                    "count": len(results[:limit]),
                    "hot_count": sum(1 for r in results if r.get("layer") == "hot"),
                    "cold_count": sum(1 for r in results if r.get("layer") == "cold"),
                    "notes_count": sum(1 for r in results if r.get("layer") == "notes"),
                }
            ),
        )
    ]


@_register("catch_up")
async def _handle_catch_up(arguments: dict) -> list[TextContent]:
    if not await _ensure_hot_memory():
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "error": ERR_HOT_LAYER_NOT_READY,
                        "retry_after_seconds": HOT_INIT_RUNTIME_COOLDOWN,
                    }
                ),
            )
        ]
    since_days = arguments.get("since_days", 3)
    try:
        data = hot_memory.get_all(filters={"user_id": DEFAULT_USER_ID}, top_k=5000)
        if isinstance(data, dict):
            data = data.get("results", [])
    except Exception as e:
        logger.warning(f"Hot layer catch_up failed: {e}")
        data = []
    since_ts = (datetime.now() - timedelta(days=since_days)).timestamp()
    data = [
        m
        for m in data
        if datetime.fromisoformat(m.get("created_at", "")).timestamp() >= since_ts
    ]
    data = sorted(
        data,
        key=lambda x: datetime.fromisoformat(x.get("created_at", "")).timestamp(),
        reverse=True,
    )
    return [
        TextContent(type="text", text=json.dumps({"results": data, "count": len(data)}))
    ]


@_register("forget")
async def _handle_forget(arguments: dict) -> list[TextContent]:
    memory_id = arguments.get("memory_id", "")
    point_id = arguments.get("point_id", "")
    layer = arguments.get("layer", "hot")
    if layer in ("hot", "all") and memory_id:
        if await _ensure_hot_memory():
            try:
                hot_memory.delete(memory_id)
            except Exception:
                pass
    if layer in ("cold", "all") and point_id and qdrant:
        try:
            qdrant.delete(collection_name=COLD_COLLECTION, points_selector=[point_id])
        except Exception:
            pass
    return [TextContent(type="text", text=json.dumps({"success": True}))]


@_register("set_memory_processed")
async def _handle_set_memory_processed(arguments: dict) -> list[TextContent]:
    if not await _ensure_hot_memory():
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "error": ERR_HOT_LAYER_NOT_READY,
                        "retry_after_seconds": HOT_INIT_RUNTIME_COOLDOWN,
                    }
                ),
            )
        ]
    memory_ids = arguments.get("memory_ids", [])
    bit = int(arguments.get("bit", 0))
    value = int(arguments.get("value", 1))
    if not memory_ids:
        return [
            TextContent(type="text", text=json.dumps({"error": ERR_MEMORY_IDS_EMPTY}))
        ]
    if not (0 <= bit <= PROCESSED_MAX_BIT):
        return [
            TextContent(
                type="text",
                text=json.dumps({"error": err_bit_out_of_range()}),
            )
        ]
    if value not in (0, 1):
        return [
            TextContent(
                type="text",
                text=json.dumps({"error": ERR_VALUE_INVALID}),
            )
        ]
    results = []
    for mid in memory_ids:
        try:
            ok = await asyncio.to_thread(_set_processed_bit, mid, bit, value)
            results.append({"memory_id": mid, "success": ok})
        except Exception as e:
            results.append({"memory_id": mid, "success": False, "error": str(e)})
    return [
        TextContent(
            type="text",
            text=json.dumps(
                {
                    "results": results,
                    "updated": sum(1 for r in results if r.get("success")),
                    "failed": sum(1 for r in results if not r.get("success")),
                },
                ensure_ascii=False,
            ),
        )
    ]


@_register("project_search")
async def _handle_project_search(arguments: dict) -> list[TextContent]:
    try:
        result = await asyncio.to_thread(
            tool_project_search,
            arguments["dbPath"],
            arguments["query"],
            file_path=arguments.get("file_path", ""),
            kind=arguments.get("kind", ""),
        )
        return [TextContent(type="text", text=json.dumps(result))]
    except Exception:
        # 上抛给 handle_call_tool：此处返回 {"error": ...} 会让 SDK 视为成功，
        # 真实故障在客户端被读成「查到了、只是没结果」。日志由兜底层统一记录。
        raise


@_register("project_structure")
async def _handle_project_structure(arguments: dict) -> list[TextContent]:
    try:
        result = await asyncio.to_thread(
            tool_project_structure, arguments["dbPath"], arguments.get("path", "")
        )
        return [TextContent(type="text", text=json.dumps(result))]
    except Exception:
        # 上抛给 handle_call_tool：此处返回 {"error": ...} 会让 SDK 视为成功，
        # 真实故障在客户端被读成「查到了、只是没结果」。日志由兜底层统一记录。
        raise


@_register("project_packages")
async def _handle_project_packages(arguments: dict) -> list[TextContent]:
    try:
        result = await asyncio.to_thread(
            tool_project_packages, arguments["dbPath"], arguments.get("type", "")
        )
        return [TextContent(type="text", text=json.dumps(result))]
    except Exception:
        # 上抛给 handle_call_tool：此处返回 {"error": ...} 会让 SDK 视为成功，
        # 真实故障在客户端被读成「查到了、只是没结果」。日志由兜底层统一记录。
        raise


@_register("project_exports")
async def _handle_project_exports(arguments: dict) -> list[TextContent]:
    try:
        result = await asyncio.to_thread(
            tool_project_exports, arguments["dbPath"], arguments["path"]
        )
        return [TextContent(type="text", text=json.dumps(result))]
    except Exception:
        # 上抛给 handle_call_tool：此处返回 {"error": ...} 会让 SDK 视为成功，
        # 真实故障在客户端被读成「查到了、只是没结果」。日志由兜底层统一记录。
        raise


@_register("project_notes")
async def _handle_project_notes(arguments: dict) -> list[TextContent]:
    try:
        query = arguments["query"]
        path = arguments["path"]
        limit = int(arguments.get("limit", 5))

        if not query or not query.strip():
            return [
                TextContent(
                    type="text",
                    text=json.dumps({"error": "query must not be empty"}),
                )
            ]
        if not os.path.isdir(path):
            return [
                TextContent(
                    type="text",
                    text=json.dumps({"error": f"project directory not found: {path}"}),
                )
            ]

        # 在后台线程运行避免阻塞事件循环（ONNX embedding 是 CPU 密集操作）
        result = await asyncio.to_thread(
            _query_project_notes, path, query.strip(), limit
        )
        return [TextContent(type="text", text=json.dumps(result, ensure_ascii=False))]

    except Exception:
        # 同上：日志与 isError 由 handle_call_tool 兜底层统一处理
        raise


@_register("tool_resource")
async def _handle_tool_resource(arguments: dict) -> list[TextContent]:
    parent_name = str(arguments.get("parentName", "")).strip()
    rel_path = str(arguments.get("path", "")).strip()
    if not parent_name or not rel_path:
        return [
            TextContent(
                type="text",
                text=json.dumps({"error": "parentName and path are required"}),
            )
        ]
    skill_dir = _find_skill_dir(parent_name)
    if skill_dir is None:
        return [
            TextContent(
                type="text",
                text=json.dumps({"error": f"skill not found: {parent_name}"}),
            )
        ]
    # 只允许引用附属子目录（references/agents/scripts）内资源
    top = rel_path.split("/", 1)[0]
    if top not in _SKILL_SKIP_DIRS:
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {"error": f"path must be under one of: {sorted(_SKILL_SKIP_DIRS)}"}
                ),
            )
        ]
    full = os.path.normpath(os.path.join(skill_dir, rel_path))
    if full != skill_dir and not full.startswith(skill_dir + os.sep):
        return [
            TextContent(
                type="text",
                text=json.dumps({"error": "path escapes the skill directory"}),
            )
        ]
    # symlink 防护：normpath 只挡语法层 ../，不解析 symlink。
    # 解析真实路径后仍须位于 skill 目录真实路径内，防 skill 附属目录内
    # symlink 指向外部文件造成信息泄露。读取统一用 real_full（已解析），
    # 避免校验后到 open 之间二次跟随（TOCTOU）。
    real_skill = os.path.realpath(skill_dir)
    real_full = os.path.realpath(full)
    if real_full != real_skill and not real_full.startswith(real_skill + os.sep):
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {"error": "path escapes the skill directory via symlink"}
                ),
            )
        ]
    full = real_full
    if not os.path.isfile(full):
        return [
            TextContent(
                type="text",
                text=json.dumps({"error": f"resource not found: {rel_path}"}),
            )
        ]
    try:
        with open(full, "r", encoding="utf-8") as fh:
            content = fh.read()
    except UnicodeDecodeError:
        return [
            TextContent(
                type="text",
                text=json.dumps({"error": "resource is not utf-8 text"}),
            )
        ]
    except Exception as e:
        # 同 handle_call_tool：未预期异常必须上抛，否则 isError 恒为 False
        logger.error(f"[tool_resource] {e}", exc_info=True)
        raise
    return [TextContent(type="text", text=content)]


@server.call_tool()
async def handle_call_tool(name: str, arguments: dict) -> list[TextContent]:
    try:
        handler = HANDLERS.get(name)
        if handler:
            return await handler(arguments)
        skills = _scan_skills()
        if name in skills:
            return [TextContent(type="text", text=skills[name]["content"])]
        normalized = _normalize_name(name)
        if normalized in skills:
            return [TextContent(type="text", text=skills[normalized]["content"])]
        return [
            TextContent(
                type="text", text=json.dumps({"error": f"Unknown tool: {name}"})
            )
        ]
    except Exception as e:
        # 必须继续上抛：此处若 return 一个 {"error": ...} 的 TextContent，
        # 对 SDK 而言就是「工具正常返回」，isError 保持 False —— 真实故障
        # 在客户端被当成成功、只是结果里多了个 error 字段，调用方无从据以
        # 重试或降级。上抛后由 SDK 的 call_tool 兜底转成 isError=True。
        logger.error(f"Error in {name}: {e}", exc_info=True)
        raise


def _run_archive_sync_impl() -> tuple[int, int, int]:
    cutoff = (datetime.now() - timedelta(days=ARCHIVE_DAYS)).isoformat()
    deleted_hot, archived_count, decayed_count = 0, 0, 0
    if hot_memory:
        try:
            hot_cutoff = (
                datetime.now() - timedelta(days=HOT_RETENTION_DAYS)
            ).isoformat()
            vs = hot_memory.vector_store
            qfilter = vs._create_filter({"user_id": DEFAULT_USER_ID})
            scroll_result = vs.client.scroll(
                collection_name=vs.collection_name,
                scroll_filter=qfilter,
                limit=1000,
                with_payload=True,
                with_vectors=False,
            )
            points, _ = (
                scroll_result
                if isinstance(scroll_result, tuple)
                else (scroll_result, None)
            )
            for point in points:
                payload = point.payload or {}
                created = payload.get("created_at", "")
                if created and created < hot_cutoff:
                    try:
                        vs.client.delete(
                            collection_name=vs.collection_name,
                            points_selector=models.PointIdsList(points=[point.id]),
                        )
                        deleted_hot += 1
                    except Exception:
                        pass
        except Exception as e:
            logger.warning(f"Hot cleanup failed: {e}")
    if qdrant:
        try:
            scroll_limit, scroll_offset, cold_processed = 1000, None, 0
            while True:
                batch, scroll_offset = qdrant.scroll(
                    collection_name=COLD_COLLECTION,
                    with_payload=True,
                    with_vectors=False,
                    limit=scroll_limit,
                    offset=scroll_offset,
                )
                if not batch:
                    break
                for point in batch:
                    cold_processed += 1
                    payload = point.payload or {}
                    last_access = payload.get("last_accessed_at", "")
                    heat_score = payload.get("heat_score", DEFAULT_HEAT_SCORE)
                    if (
                        last_access
                        and last_access < cutoff
                        and not payload.get("archived")
                    ):
                        try:
                            qdrant.set_payload(
                                collection_name=COLD_COLLECTION,
                                payload={"archived": True},
                                points=[point.id],
                            )
                            archived_count += 1
                        except Exception:
                            pass
                    if last_access and not payload.get("archived"):
                        try:
                            last_dt = datetime.fromisoformat(last_access)
                            days_since = (datetime.now() - last_dt).days
                            if days_since > 0:
                                new_heat = max(
                                    0.1, heat_score - HEAT_DECAY_PER_DAY * days_since
                                )
                                if abs(new_heat - heat_score) > 0.001:
                                    qdrant.set_payload(
                                        collection_name=COLD_COLLECTION,
                                        payload={"heat_score": new_heat},
                                        points=[point.id],
                                    )
                                    decayed_count += 1
                        except Exception:
                            pass
                if scroll_offset is None:
                    break
        except Exception as e:
            logger.warning(f"Cold archive check failed: {e}")
    return deleted_hot, archived_count, decayed_count


async def _run_archive_sync() -> tuple[int, int, int]:
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, _run_archive_sync_impl)


async def archive_scheduler():
    await asyncio.sleep(300)
    while True:
        logger.info("=== Archive check started ===")
        try:
            deleted_hot, archived_count, decayed_count = await asyncio.wait_for(
                _run_archive_sync(), timeout=300
            )
            logger.info(
                f"=== Archive check finished: hot_deleted={deleted_hot}, "
                f"cold_archived={archived_count}, cold_decayed={decayed_count} ==="
            )
        except asyncio.TimeoutError:
            logger.warning("Archive check timed out")
        except Exception as e:
            logger.warning(f"Archive check failed: {e}")
        await asyncio.sleep(ARCHIVE_INTERVAL_HOURS * 3600)


async def main():
    asyncio.create_task(archive_scheduler())

    transport = StreamableHTTPServerTransport(
        mcp_session_id=None, is_json_response_enabled=True
    )

    async def health_check(scope, receive, send):
        """Health check endpoint for process manager monitoring."""
        response = JSONResponse({"status": "ok", "service": SERVER_NAME})
        await response(scope, receive, send)

    async def mcp_asgi_app(scope, receive, send):
        if scope["path"] == "/health":
            await health_check(scope, receive, send)
            return
        if scope["path"].startswith("/api/"):
            rest_scope = dict(scope)
            await rest_app(rest_scope, receive, send)
            return
        await transport.handle_request(scope, receive, send)

    async def api_memory_add_knowledge(request):
        body = await request.json()
        emb = _get_shared_embedder()
        if not qdrant or emb is None:
            return JSONResponse(
                {"error": "Cold layer not initialized"}, status_code=500
            )
        content = body["content"]
        now_iso = datetime.now().isoformat()
        vec = list(emb.embed(content))[0].tolist()
        point_id = str(uuid.uuid4())
        qdrant.upsert(
            collection_name=COLD_COLLECTION,
            points=[
                PointStruct(
                    id=point_id,
                    vector=vec,
                    payload={
                        "content": content,
                        "source_file": body.get("source_file", ""),
                        "created_at": body.get("created_at", ""),
                        "category": body.get("category", ""),
                        "type": "knowledge",
                        "heat_score": DEFAULT_HEAT_SCORE,
                        "last_accessed_at": now_iso,
                        "access_count": 0,
                        "archived": False,
                        "tags": body.get("tags", []),
                        "user_id": DEFAULT_USER_ID,
                        "confidence": body.get("confidence", 1.0),
                    },
                )
            ],
        )
        _spawn_contradiction_check(_contradiction_check_cold(content, point_id))
        return JSONResponse({"success": True, "layer": "cold"})

    async def api_memories_recent(request):
        if not await _ensure_hot_memory():
            return JSONResponse({"error": ERR_HOT_LAYER_NOT_READY}, status_code=503)
        since_str = request.query_params.get("since", "")
        limit = int(request.query_params.get("limit", 200))
        try:
            data = hot_memory.get_all(filters={"user_id": DEFAULT_USER_ID}, top_k=5000)
            if isinstance(data, dict):
                data = data.get("results", [])
        except Exception:
            data = []
        if since_str:
            try:
                since_dt = datetime.fromisoformat(since_str)
                since_ts = since_dt.timestamp()
            except ValueError:
                since_ts = (datetime.now() - timedelta(days=3)).timestamp()
        else:
            since_ts = (datetime.now() - timedelta(days=3)).timestamp()
        data = [
            m
            for m in data
            if datetime.fromisoformat(m.get("created_at", "")).timestamp() >= since_ts
        ]
        data = sorted(
            data,
            key=lambda x: datetime.fromisoformat(x.get("created_at", "")).timestamp(),
            reverse=True,
        )[:limit]
        return JSONResponse({"results": data, "count": len(data)})

    async def api_memories_processed(request):
        """批量设置/重置记忆已处理位（bit0=已总结处理），幂等；供 summarize 写回与测试还原。"""
        if not await _ensure_hot_memory():
            return JSONResponse({"error": ERR_HOT_LAYER_NOT_READY}, status_code=503)
        try:
            body = await request.json()
        except Exception:
            return JSONResponse({"error": "invalid JSON body"}, status_code=400)
        memory_ids = body.get("memory_ids", [])
        try:
            bit = int(body.get("bit", 0))
            value = int(body.get("value", 1))
        except (TypeError, ValueError):
            return JSONResponse({"error": ERR_BIT_VALUE_NOT_INT}, status_code=400)
        if not memory_ids:
            return JSONResponse({"error": ERR_MEMORY_IDS_EMPTY}, status_code=400)
        if not (0 <= bit <= PROCESSED_MAX_BIT):
            return JSONResponse({"error": err_bit_out_of_range()}, status_code=400)
        if value not in (0, 1):
            return JSONResponse({"error": ERR_VALUE_INVALID}, status_code=400)
        updated = 0
        failed_ids = []
        for mid in memory_ids:
            try:
                if await asyncio.to_thread(_set_processed_bit, mid, bit, value):
                    updated += 1
                else:
                    failed_ids.append(mid)
            except Exception:
                failed_ids.append(mid)
        return JSONResponse(
            {
                "success": not failed_ids,
                "bit": bit,
                "value": value,
                "updated": updated,
                "failed": len(failed_ids),
                "failed_ids": failed_ids,
            }
        )

    async def api_project_search(request):
        body = await request.json()
        try:
            result = tool_project_search(body.get("dbPath", ""), body.get("query", ""))
            return JSONResponse(result)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=500)

    async def api_project_structure(request):
        body = await request.json()
        try:
            result = tool_project_structure(
                body.get("dbPath", ""), body.get("path", "")
            )
            return JSONResponse(result)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=500)

    async def api_project_packages(request):
        body = await request.json()
        try:
            result = tool_project_packages(body.get("dbPath", ""), body.get("type", ""))
            return JSONResponse(result)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=500)

    async def api_project_exports(request):
        body = await request.json()
        try:
            result = tool_project_exports(body.get("dbPath", ""), body.get("path", ""))
            return JSONResponse(result)
        except Exception as e:
            return JSONResponse({"error": str(e)}, status_code=500)

    rest_app = Starlette(
        routes=[
            Route(
                "/api/memory/add_knowledge",
                endpoint=api_memory_add_knowledge,
                methods=["POST"],
            ),
            Route(
                "/api/memories/recent", endpoint=api_memories_recent, methods=["GET"]
            ),
            Route(
                "/api/memories/processed",
                endpoint=api_memories_processed,
                methods=["POST"],
            ),
            Route("/api/project/search", endpoint=api_project_search, methods=["POST"]),
            Route(
                "/api/project/structure",
                endpoint=api_project_structure,
                methods=["POST"],
            ),
            Route(
                "/api/project/packages", endpoint=api_project_packages, methods=["POST"]
            ),
            Route(
                "/api/project/exports", endpoint=api_project_exports, methods=["POST"]
            ),
        ]
    )

    app = Starlette(routes=[Mount("/", app=mcp_asgi_app)])
    config = uvicorn.Config(app, host="127.0.0.1", port=MCP_PORT, log_level="info")
    uvi_server = uvicorn.Server(config)

    async with transport.connect() as streams:
        async with anyio.create_task_group() as tg:
            tg.start_soon(
                server.run,
                streams[0],
                streams[1],
                InitializationOptions(
                    server_name=SERVER_NAME,
                    server_version=SERVER_VERSION,
                    capabilities=ServerCapabilities(tools=ToolsCapability()),
                ),
            )
            await anyio.sleep(0.1)
            await uvi_server.serve()


if __name__ == "__main__":
    asyncio.run(main())
