#!/usr/bin/env python3
"""
记忆总结流水线 — 由 Utility TaskScheduler 触发（非 server.py 调度）

用法：
  python3 summarize.py                    # 完整流程：统计报表 + AI 总结
  python3 summarize.py --stats-only       # 仅生成统计报表，跳过 AI 总结

流程：
1. 从 mino-brain REST API 获取过去 3 天记忆
2. 阶段1 聚合：分批 LLM 按主题分类/合并去重/retain 评估（think disabled，带时间线演进），递归合并至收敛
3. 阶段2 精炼：逐组提炼关键词 → 本地检索 Extracts → 判断归并已有笔记/新建 → think enable 生成正文
4. 写入 Markdown（同标题 H1 段合并去重，异标题末尾新增一节）
5. 同步写入冷层 Qdrant（按内容哈希去重，通过 REST API）
6. 阶段3 规范提炼 → MCP/Skills/Rules/*.md
7. 异常 → 写入流水线错误日志；阶段2 单组失败不中断整体

防重复触发：
- 单实例文件锁：同一时刻只允许一个实例运行
- 最小间隔节流：与上次完整总结间隔 < 6 小时则跳过
"""

import argparse
import difflib
import os
import json
import sqlite3
import time
import re
import fcntl
import hashlib
import subprocess
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone, timedelta
from pathlib import Path

import httpx
from log_utils import (
    setup_logging as _log_setup,
    write_error_log as _shared_write_error_log,
)

# CLI 参数解析
_parser = argparse.ArgumentParser(description="Utility 记忆总结流水线")
_parser.add_argument(
    "--stats-only", action="store_true", help="仅生成统计报表，跳过 AI 总结"
)
_args = _parser.parse_args()
STATS_ONLY = _args.stats_only

logger = _log_setup("summarize")

DEEPSEEK_API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
SUMMARY_MODEL = os.environ.get("SUMMARY_MODEL", "deepseek-v4-flash")
SUMMARY_API_URL = os.environ.get("SUMMARY_API_URL", "https://api.deepseek.com")
NOTES_DIR = Path(
    os.environ.get("NOTES_DIR", os.path.expanduser("~/Documents/selfdata/notes"))
)
ERROR_LOG = NOTES_DIR / "流水线错误日志.jsonl"
MEMORY_SERVER_URL = os.environ.get("MEMORY_SERVER_URL", "http://localhost:9001")
COLD_READY = True
SUMMARY_EXCLUDE_DIRS = {
    "Self_Data",
    "Works_Jobs",
    "SaveWebPages",
    "Resources",
    "Attachments",
    "Extracts",
}
SUMMARY_MEMORY_DAYS = 3
SUMMARY_MEMORY_LIMIT = 200
EXTRACTS_DIR = NOTES_DIR / "Extracts"
SUMMARY_MIN_CONTENT_LEN = 150
SUMMARY_LLM_TEMPERATURE = 0.1
SUMMARY_LLM_TIMEOUT = 90
SUMMARY_API_TIMEOUT = 10
SUMMARY_GIT_TIMEOUT = 30

# ── 阶段1 记忆聚合（先分类/合并/去重/时间线，递归收敛） ──
AGGREGATE_BATCH_THRESHOLD = 60  # 记忆条数超过此值分批聚合
AGGREGATE_BATCH_SIZE = 60  # 每批条数
AGGREGATE_LLM_TEMPERATURE = 0.2  # 聚合允许归纳，比生成略高
AGGREGATE_LLM_TIMEOUT = 120
AGGREGATE_MAX_ROUNDS = 3  # 递归合并最大轮数（组数单调不增，必然收敛）

# ── 阶段2 检索驱动逐组精炼（关键词 → 检索 Extracts → 判断归并/新建 → think enable 生成） ──
SUMMARY_KEYWORD_MAX_TOKENS = 8192  # 关键词提炼
SUMMARY_JUDGE_MAX_TOKENS = 8192  # 归并判断
SUMMARY_GEN_MAX_TOKENS = 16384  # 最终生成（正文较长）
SUMMARY_SEARCH_LIMIT = 5  # 检索返回命中上限
SEARCH_MIN_TOKEN_LEN = 2  # 关键词最小长度，过滤通配词
SUMMARY_KEYWORD_COUNT = 8  # 关键词数量上限
SUMMARY_MERGE_CONTEXT_CHARS = 2000  # 归并判断/生成时截取上下文长度（facts 截断用）
SUMMARY_MERGE_LOOKBACK_CHARS = 8000  # merge 生成时给 LLM 的目标笔记相关段落总长上限（防大文件前 2K 看不到文件尾既有段）
SUMMARY_DUP_SIM_THRESHOLD = 0.7  # 归并内容相对既有段的「匹配覆盖率」超此值视为无增量，跳过（0.8 ratio→0.7 覆盖率，实测 ScanTextUtil 重复 0.767）
# ── 预聚合（同目标同家族组）与微碎片兜底（方案 A+C 融合，2026-08-06） ──
# 实测校准（真实 20 条未处理记忆 12 组）：同族组关键词集共享 ≥1 主题词（Jaccard 0.07-0.15），
# 不相关同 target 组共享 0 词（Jaccard=0）；整文本相似度在族内/跨族区间重叠无阈值可分，
# 故相关性判定弃相似度门、以「共享 ≥1 主题关键词 + Jaccard ≥ 0.05」为 AND 门（详见 _topical_related）。
SUMMARY_TOPIC_JACCARD = 0.05  # 预聚合主题相关性：关键词 Jaccard 下限（≥1 共享词，8+8 词并集上限 16 → 恒 ≥0.0625）
SUMMARY_FRAGMENT_LINE_MIN = 10  # 新建产物行数低于此值视为微碎片，回退归并到命中笔记
# QC 空洞占位：正文含此类「写时无内容」表述即判低质不落盘。
# 注意：排除「待补全/待补充/待完善/待确认」等 TODO 语义——那是已知缺口、
# 后续可能新增的正常演进，不代表空洞（2026-08-06 用户修正）。
SUMMARY_PLACEHOLDER_PATTERNS = (
    "未详述",
    "未记录",
    "未提供",
    "具体方案未",
)

# ── 记忆输入质量门（宁缺毋滥）：fetch 后、进 LLM 聚合前过滤 ──
# 2026-08-06 升级为方案 E v5：截断占位串硬信号 + 中英文快照启发式 + LLM 3 票复核，
# 取代原「过短 + 占位符命中」弱规则（SUMMARY_PLACEHOLDER_PATTERNS 仅保留给输出侧 QC）。
# 验证：合成 5 批×100（35 低质/65 高质）漏拦 0 误伤 0；真实库 782 条回归误伤 0，
# 抓回 5/6 已知漏拦（剩 1 条无特征一次性信息靠聚合层 retain=false 兜底，端到端无泄漏）。
MEMORY_QUALITY_MIN_LEN = 15  # 正文去空白后长度下限，过短无信息量
MEMORY_QUALITY_RESIDUAL_MIN = 12  # 非截断占位词命中后，残余中文实义字符下限
MEMORY_QUALITY_HALF_MAX = 60  # 半词截断仅当整体去空白后仍短才 drop
MEMORY_QUALITY_CN_SHORT_MAX = 50  # 中文短状态快照去空白后长度上限
MEMORY_QUALITY_REVIEW_VOTES = 3  # LLM 复核投票次数（3 次全 drop 才 drop，防误伤）
MEMORY_QUALITY_LLM_THREADS = 4  # 复核并发（降并发防 API 限流，实测 8 并发大量 ERR）

# 截断占位串（17 变体）。全部以「保留/仅保留」连接，不匹配「导致内容截断，但已有信息
# 被保留」这类描述句（描述句用「，但」）。v5 增补 notes 源实测 5 种未覆盖形态。
QUALITY_TRUNC_PLACEHOLDERS = (
    "内容截断，保留已有信息",
    "内容截断，仅保留已有信息",
    "内容截断，仅保留此信息",
    "内容截断，保留此信息",
    "内容截断仅保留已有信息",
    "内容截断仅保留此信息",
    "已截断，保留已有信息",
    "截断，保留已有信息",
    "截断，仅保留已有信息",
    "仅保留已有信息",
    "仅保留此信息",
    # ── v5 增补：notes 源 5 种未覆盖真实形态 ──
    "（内容截断）保留已有信息",
    "内容截断（保留已有信息）",
    "导致响应内容截断（保留已有信息）",
    "当内容截断时，保留已有信息",
    "内容截断，此处保留已有信息",
    "相关内容截断保留",
)
# 正则兜底：容忍括号/时/此处/无标点间隔的「截断…保留…信息」形态（compact 后匹配）
_QUALITY_TRUNC_RE = re.compile(
    r"(?:内容|相关)?内容截断[（(]?[，,、]?(?:时|此处)?[）)]?仅?保留(?:已有|此)(?:信息|内容)"
)
# 非截断占位词（不含「待补全/待补充/待完善/待确认」等 TODO 语义——已知缺口后续演进）
QUALITY_NONTRUNC_PLACEHOLDERS = ("未详述", "未记录", "未提供", "具体方案未")
# 残余信息量计算时需剔除的占位子串
QUALITY_PLACEHOLDER_SUBS = (
    "内容截断",
    "保留已有信息",
    "未详述",
    "未记录",
    "未提供",
    "具体方案未",
    "待补充",
)

_QUALITY_EMPTY_TITLE = re.compile(r"^[-*#]?\s*(?:\*\*)?[^：:]{2,40}(?:\*\*)?：\s*$")
_QUALITY_HALF_TRUNC = re.compile(r"(?:\.{3,}$|Stre$|undefi$|lody_ses$|：$|->\s*$)")
_QUALITY_HALF_CN = re.compile(r"(?:配置文|说明文|使用方|处理方|的具体|的详细)$")
_QUALITY_USER_SNAPSHOT = re.compile(r"^(User|User's)\b", re.IGNORECASE)
_QUALITY_CN_STATE_VERBS = (
    "完成",
    "测试",
    "验证",
    "回归",
    "配置",
    "通过",
    "运行",
    "部署",
    "发布",
    "检查",
)
_QUALITY_QUOTE_PAIRS = [("“", "”"), ("「", "」"), ("『", "』"), ("'", "'"), ('"', '"')]

# ── 已处理位掩码：metadata["processed"] 整数位，bit0=1 表示已被总结脚本成功处理 ──
PROCESSED_FIELD = "processed"
PROCESSED_BIT_SUMMARIZED = 1

# ── 数据目录（脚本自身状态也放这里，与 Swift 数据同目录） ──
UTILITY_DATA_DIR = Path(
    os.environ.get("UTILITY_DATA_DIR", os.path.expanduser("~/.config/utility"))
)

# ── 单实例 / 节流保护 ──
LOCK_FILE = UTILITY_DATA_DIR / "summarize.lock"
LAST_RUN_FILE = UTILITY_DATA_DIR / "summarize_last_run"
MIN_RUN_INTERVAL = 6 * 3600  # 与上次完整总结间隔不足 6 小时则跳过（防重复触发）
COLD_SYNC_DB = UTILITY_DATA_DIR / "cold_sync.sqlite"  # 冷层去重记录

# ── MCP 工具调用统计 ──
STATS_DB = UTILITY_DATA_DIR / "tool_usage.sqlite"
MCP_DIR = NOTES_DIR / "MCP"
STATS_OUTPUT = MCP_DIR / "工具调用统计.md"
STATS_DAYS = 15  # 报表显示最近天数
STATS_RETENTION_DAYS = 90  # 数据保留天数

# ── 阶段3 规范提炼（规则/规范类记忆 → MCP/Skills/Rules/*.md） ──
SKILLS_RULES_DIR = MCP_DIR / "Skills" / "Rules"
RULES_MIN_CANDIDATES = 3  # 本周期规则/规范类有效记忆少于该值则跳过提炼
RULES_MAX_PER_FILE = 60  # 每规范文件条目上限，超出由 LLM 淘汰
RULES_LLM_TEMPERATURE = 0.2  # 提炼允许归纳，与聚合一致
RULES_LLM_TIMEOUT = 120
# 多级规范：global 全局通用 + 各项目类型通用；LLM 判定不了的归入 global
RULES_LEVELS = {
    "global": "全局通用",
    "web_frontend": "Web 前端",
    "mobile": "移动端",
    "macos_tool": "macOS 工具",
    "backend": "后端/服务",
}

_HTTP = httpx.Client(timeout=SUMMARY_API_TIMEOUT)


def write_error_log(msg: str, code: str = "UNKNOWN"):
    try:
        _shared_write_error_log(
            str(ERROR_LOG),
            {
                "code": code,
                "message": msg,
            },
        )
    except Exception as e:
        logger.error(f"Error log write failed: {e}")


def _acquire_single_instance() -> bool:
    """获取单实例文件锁。已有实例在运行时返回 False（由调用方退出）。"""
    try:
        UTILITY_DATA_DIR.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            os.close(fd)
            return False
    except Exception:
        return True  # 锁不可用时放行，避免误阻断


def _throttle_ai_run() -> bool:
    """距上次完整总结不足 MIN_RUN_INTERVAL 时返回 False（防重复触发）。

    只读判断，不更新 last_run——只有总结成功完成后才由 _mark_run_success()
    记录时间，避免「运行开始即写」导致失败后 6h 窗口内无法重试。
    """
    try:
        UTILITY_DATA_DIR.mkdir(parents=True, exist_ok=True)
        now = time.time()
        last = (
            float(LAST_RUN_FILE.read_text().strip()) if LAST_RUN_FILE.exists() else 0.0
        )
        if now - last < MIN_RUN_INTERVAL:
            logger.info(
                f"距上次总结不足 {MIN_RUN_INTERVAL // 3600} 小时，跳过（防重复触发）"
            )
            return False
        return True
    except Exception:
        return True


def _mark_run_success() -> None:
    """总结成功完成后记录 last_run，开启新一轮防重复冷却。"""
    try:
        UTILITY_DATA_DIR.mkdir(parents=True, exist_ok=True)
        LAST_RUN_FILE.write_text(str(time.time()))
    except Exception:
        pass


def _cold_already_synced(content: str, source_file: str) -> bool:
    """按 source_file+content 哈希去重：已同步过的内容跳过，避免冷层重复写入。"""
    h = hashlib.sha256(f"{source_file}|{content}".encode("utf-8")).hexdigest()
    try:
        UTILITY_DATA_DIR.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(COLD_SYNC_DB))
        try:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS synced (hash TEXT PRIMARY KEY, at TEXT)"
            )
            exists = conn.execute("SELECT 1 FROM synced WHERE hash=?", (h,)).fetchone()
            if exists:
                return True
            conn.execute(
                "INSERT OR IGNORE INTO synced (hash, at) VALUES (?, ?)",
                (h, date.today().isoformat()),
            )
            conn.commit()
        finally:
            conn.close()
        return False
    except Exception:
        return False


def write_to_cold_layer(
    content: str,
    source_file: str,
    category: str,
    tags: list | None = None,
    confidence: float = 1.0,
):
    if _cold_already_synced(content, source_file):
        return
    try:
        resp = _HTTP.post(
            f"{MEMORY_SERVER_URL}/api/memory/add_knowledge",
            json={
                "content": content,
                "source_file": source_file,
                "created_at": date.today().isoformat(),
                "category": category,
                "tags": tags or [],
                "confidence": confidence,
            },
        )
        if resp.status_code != 200:
            logger.warning(
                f"Cold layer write failed: {resp.status_code} {resp.text[:200]}"
            )
    except Exception as e:
        logger.warning(f"Cold layer write failed: {e}")


def scan_notes_structure(root: Path, max_depth: int = 3) -> str:
    EXCLUDED = SUMMARY_EXCLUDE_DIRS

    def _scan(dir_path: Path, depth: int = 0) -> list[str]:
        if depth > max_depth:
            return ["  " * depth + "  ..."]
        lines = []
        try:
            for entry in sorted(dir_path.iterdir()):
                name = entry.name
                if name.startswith(".") or name in EXCLUDED:
                    continue
                if entry.is_dir():
                    lines.append("  " * depth + f"- {name}/")
                    lines.extend(_scan(entry, depth + 1))
                elif entry.suffix == ".md":
                    lines.append("  " * depth + f"- {name}")
        except PermissionError:
            lines.append("  " * depth + "(无权限)")
        return lines

    return "\n".join(_scan(root)) if root.exists() else "(空)"


def _normalize_slug(s: str) -> str:
    """Normalize a title/slug for fuzzy dedup matching."""
    # Remove parenthetical content: （...）(...)
    s = re.sub(r"[（(][^）)]*[）)]", "", s)
    # 剥离 .md 后缀，防止生成 .md.md 双后缀文件名
    s = re.sub(r"\.md$", "", s, flags=re.IGNORECASE)
    # Normalize spaces, colons, slashes to underscores
    s = re.sub(r"[\s:/]+", "_", s)
    # Collapse multiple underscores
    s = re.sub(r"_+", "_", s).strip("_")
    return s.lower()


def resolve_target_file(target_dir: Path, title: str) -> tuple[Path, bool]:
    slug = _normalize_slug(title)
    if not slug:
        slug = "未分類"
    filepath = target_dir / f"{slug}.md"

    # Collect all existing .md files across all extract dirs
    all_extract_files: list[tuple[Path, str]] = []
    if EXTRACTS_DIR.exists():
        for d in EXTRACTS_DIR.rglob("*"):
            if d.is_file() and d.suffix == ".md":
                stem = d.stem
                existing_slug = re.sub(r"_\d{4}-\d{2}-\d{2}$", "", stem)
                existing_slug = _normalize_slug(existing_slug)
                if existing_slug:
                    all_extract_files.append((d, existing_slug))

    # Priority 1: exact slug match in the same directory
    for existing_path, existing_slug in all_extract_files:
        if existing_slug == slug and existing_path.parent == target_dir:
            return existing_path, True

    # Priority 2: substring match, limited to the same directory.
    # 跨目录命中会追加到旧文件造成内容错位，故不跨目录匹配；过短的 slug
    # 模糊匹配命中率低且易误配（如 "devflow" 会匹配一切），仅 >=4 字符时启用。
    if len(slug) >= 4:
        for existing_path, existing_slug in all_extract_files:
            if existing_path.parent == target_dir and (
                slug in existing_slug or existing_slug in slug
            ):
                return existing_path, True

    return filepath, False


def git_commit(message: str, stage: str = ""):
    try:
        label = f" ({stage})" if stage else ""
        r_add = subprocess.run(
            ["git", "-C", str(NOTES_DIR), "add", "-A"],
            capture_output=True,
            timeout=SUMMARY_GIT_TIMEOUT,
            text=True,
        )
        if r_add.returncode != 0:
            err = (r_add.stderr or "").strip()
            write_error_log(f"git add 失败{label}: {err[:300]}", code="GIT_ADD")
            return False
        r_cmt = subprocess.run(
            ["git", "-C", str(NOTES_DIR), "commit", "-m", message],
            capture_output=True,
            timeout=SUMMARY_GIT_TIMEOUT,
            text=True,
        )
        out = ((r_cmt.stdout or "") + (r_cmt.stderr or "")).strip()
        if r_cmt.returncode == 0:
            logger.info(f"[git]{label} {out[:200]}")
            return True
        elif r_cmt.returncode == 1 and "nothing to commit" in (r_cmt.stdout or ""):
            logger.info(f"[git]{label} 无变更，跳过提交")
            return True
        else:
            write_error_log(f"git commit 失败{label}: {out[:300]}", code="GIT_COMMIT")
            logger.warning(f"[git]{label} commit 失败: {out[:200]}")
            return False
    except subprocess.TimeoutExpired:
        write_error_log(f"git 操作超时{label}", code="GIT_TIMEOUT")
        return False
    except Exception as e:
        write_error_log(f"git 异常{label}: {e}", code="GIT_ERROR")
        logger.warning(f"[git]{label} commit 失败: {e}")
        return False


def _llm_chat(
    prompt: str,
    temperature: float | None = None,
    timeout: float | None = None,
    max_tokens: int | None = None,
    disable_thinking: bool = False,
    system_prompt: str | None = None,
) -> str | None:
    try:
        messages: list[dict] = [{"role": "user", "content": prompt}]
        if system_prompt:
            messages.insert(0, {"role": "system", "content": system_prompt})
        body = {
            "model": SUMMARY_MODEL,
            "messages": messages,
            "temperature": (
                temperature if temperature is not None else SUMMARY_LLM_TEMPERATURE
            ),
        }
        # 聚合/文章生成等输出较大的阶段显式放宽 max_tokens，
        # 否则 LLM 默认 4096 截断导致 JSON 解析失败（AGGREGATE_JSON 根因）
        if max_tokens:
            body["max_tokens"] = max_tokens
        # deepseek-v4-flash 为推理模型：长 prompt 下 thinking 思考会吃光
        # max_tokens，content 为空 → JSON 解析失败。聚合/生成阶段关思考，
        # 让输出 token 全部用于 content（实测 thinking disabled + 16384 完整输出）
        if disable_thinking:
            body["thinking"] = {"type": "disabled"}
        resp = _HTTP.post(
            f"{SUMMARY_API_URL}/chat/completions",
            headers={
                "Authorization": f"Bearer {DEEPSEEK_API_KEY}",
                "Content-Type": "application/json",
            },
            json=body,
            timeout=timeout if timeout is not None else SUMMARY_LLM_TIMEOUT,
        )
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]
    except Exception as e:
        logger.warning(f"LLM call failed: {e}")
        return None


def _parse_json_any(raw: str) -> dict | None:
    raw = raw.strip()
    m = re.search(r"```json\s*\n(.+?)\n\s*```", raw, re.DOTALL)
    if not m:
        m = re.search(r"```\s*\n(.+?)\n\s*```", raw, re.DOTALL)
    if not m:
        m = re.search(r"\{.*\}", raw, re.DOTALL)
    json_str = m.group(1) if m and m.lastindex else (m.group(0) if m else raw)
    start, end = json_str.find("{"), json_str.rfind("}")
    if start != -1 and end != -1:
        json_str = json_str[start : end + 1]
    try:
        return json.loads(json_str, strict=False)
    except json.decoder.JSONDecodeError:
        fixed = re.sub(r",\s*([}\]])", r"\1", json_str)
        try:
            return json.loads(fixed, strict=False)
        except json.decoder.JSONDecodeError:
            # LLM 复制原文时可能把英文双引号原样带进字符串值且未转义 → 转义后重试
            quoted = _escape_inline_quotes(fixed)
            try:
                return json.loads(quoted, strict=False)
            except json.decoder.JSONDecodeError:
                return None


def _escape_inline_quotes(s: str) -> str:
    """把字符串值内未转义的裸引号转义为 \\"（键结束/值结束引号不受影响）。"""
    out = []
    in_str = False
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if in_str:
            if c == "\\":
                out.append(c)
                if i + 1 < n:
                    out.append(s[i + 1])
                    i += 2
                    continue
            elif c == '"':
                j = i + 1
                while j < n and s[j] in " \t":
                    j += 1
                if j < n and s[j] in ",}]:":
                    in_str = False
                    out.append(c)
                else:
                    out.append('\\"')
            else:
                out.append(c)
        else:
            if c == '"':
                in_str = True
            out.append(c)
        i += 1
    return "".join(out)


def fetch_memories(today: date) -> list | None:
    try:
        three_days_ago = datetime.combine(
            today - timedelta(days=SUMMARY_MEMORY_DAYS),
            datetime.min.time(),
            tzinfo=timezone.utc,
        )
        resp = _HTTP.get(
            f"{MEMORY_SERVER_URL}/api/memories/recent",
            params={"since": three_days_ago.isoformat(), "limit": SUMMARY_MEMORY_LIMIT},
        )
        resp.raise_for_status()
        return resp.json().get("results", [])
    except Exception as e:
        write_error_log(f"获取记忆失败: {e}", code="FETCH_MEMORY")
        return None


def _filter_processed(memories: list[dict]) -> list[dict]:
    """跳过已被成功处理的记忆（metadata.processed bit0=1），避免重复处理。"""
    kept = []
    for m in memories:
        flags = int(m.get("metadata", {}).get(PROCESSED_FIELD, 0) or 0)
        if flags & PROCESSED_BIT_SUMMARIZED:
            continue
        kept.append(m)
    return kept


def _quality_strip_quoted(text: str) -> str:
    """移除成对引号内的内容，返回「引号外」文本。用于豁免元讨论中的占位符引用。"""
    out = text
    for left, right in _QUALITY_QUOTE_PAIRS:
        out = re.sub(
            re.escape(left)
            + r"[^"
            + re.escape(right)
            + r"]{0,200}?"
            + re.escape(right),
            "",
            out,
        )
    return out


def _quality_residual_chars(text: str) -> int:
    """去掉占位串与标点/数字/英文后，剩余的中文实义字符数。"""
    t = text
    for p in QUALITY_PLACEHOLDER_SUBS:
        t = t.replace(p, "")
    t = re.sub(r"[\s\-*#.。，、：:（）()【】\[\]0-9A-Za-z_`|/\\]+", "", t)
    return len(t)


def _quality_is_cn_short_snapshot(t: str) -> bool:
    """中文短句 + 状态动词 → 可能状态快照。送 LLM 复核（不硬 drop），零误伤。"""
    c = "".join(t.split())
    if len(c) >= MEMORY_QUALITY_CN_SHORT_MAX:
        return False
    if not any("一" <= ch <= "鿿" for ch in t):
        return False
    return any(v in t for v in _QUALITY_CN_STATE_VERBS)


def _quality_rule_judge(text: str) -> tuple[str, str]:
    """方案 E v5 规则层（确定性零 LLM）：返回 (drop/keep/review, 理由)。

    核心：把「截断占位符」本身当作硬缺陷信号，而非残余信息量弱代理——
    截断记忆天然保留完整前缀→残余充足→旧方案漏拦；这里出现占位串即 drop。
    """
    t = text.strip()
    compact = "".join(t.split())
    if len(compact) < MEMORY_QUALITY_MIN_LEN:
        return "drop", f"过短({len(compact)}<{MEMORY_QUALITY_MIN_LEN})"
    if _QUALITY_EMPTY_TITLE.match(t):
        return "drop", "空值标题（标题后无内容）"
    # 半词截断：中英文残词结尾且整体短
    if (_QUALITY_HALF_TRUNC.search(t) or _QUALITY_HALF_CN.search(t)) and len(
        compact
    ) < MEMORY_QUALITY_HALF_MAX:
        return "drop", "半词截断"
    # 核心：无引号截断占位串 → drop。先 strip_quoted 再 compact 归一化，
    # 换行/空格不再断裂占位串（Workflow 实测「内容截断，保留已有\n信息」漏匹配形态）。
    outside = _quality_strip_quoted(t)
    outside_compact = "".join(outside.split())
    for p in QUALITY_TRUNC_PLACEHOLDERS:
        if "".join(p.split()) in outside_compact:
            return "drop", f"无引号截断占位串({p})"
    if _QUALITY_TRUNC_RE.search(outside_compact):
        return "drop", "无引号截断占位串(正则兜底)"
    # 带引号截断占位 → 边界（同样 compact 匹配，疑似元讨论）
    compact_all = "".join(t.split())
    if any(
        "".join(p.split()) in compact_all for p in QUALITY_TRUNC_PLACEHOLDERS
    ) or _QUALITY_TRUNC_RE.search(compact_all):
        return "review", "带引号截断占位串（疑似元讨论，交 LLM 复核）"
    # 其他占位词 → 残余信息量判定
    if any(p in t for p in QUALITY_NONTRUNC_PLACEHOLDERS):
        rc = _quality_residual_chars(t)
        if rc < MEMORY_QUALITY_RESIDUAL_MIN:
            return "drop", f"占位词残余信息不足({rc}<{MEMORY_QUALITY_RESIDUAL_MIN})"
        return "keep", f"占位词但残余信息充足({rc}字)"
    # 边界样本：User 开头英文快照 / 中文短状态快照
    if t and len(t) < 200 and _QUALITY_USER_SNAPSHOT.match(t):
        return "review", "User 开头英文快照（可能状态快照，交 LLM 复核）"
    if _quality_is_cn_short_snapshot(t):
        return "review", "中文短句含状态动词（可能状态快照，交 LLM 复核）"
    return "keep", "常规通过"


# 方案 E LLM 复核 system 判据（SYSTEM_PROMPT_STRICT 移植；v5 移除内嵌测试样本原文防测试集调教）。
# 用 system 角色承载判据（与验证一致的请求结构），user 只提供记忆材料。
QUALITY_JUDGE_SYSTEM = """你是知识库记忆质量判定器。判断一条记忆是否值得进入 LLM 聚合沉淀（keep），还是应丢弃（drop）。

DROP 的情形：
- 正文本身就是截断占位，无实质信息（如整条是"内容截断，保留已有信息"、"未详述"等占位文字）
- 关键信息被截断/不完整：正文以截断占位或半截语句结尾，核心结论/路径/参数/接口/原因缺失，无法还原
- 纯状态快照：如"已完成X"、"已配置Y"、"User built an APK"，无任何细节、技术参数或结论
- 纯测试数据、垃圾数据、过短（去空白<15字符）、空泛无具体内容

KEEP 的情形：
- 有实质技术信息：具体文件/组件/参数/判断条件/结论/根因
- 讨论"质量门/截断/审计/修复机制"本身的元讨论，只要包含具体内容就保留
- 用户行为约束/偏好/明确要求等有信息量的记录

关键区分：
- "正文在讨论截断问题"（如"LLM输出被截断导致JSON解析失败"）→ KEEP，信息完整
- "正文本身就是被截断的占位"（如"XX（内容截断，保留已有信息）"）→ DROP，无信息

补充状态快照判据：
- 英文：User 对某文件/项目做了动作（built/split/configured/tested/refactored/created/updated 等），但无任何技术参数、结论、判断 → DROP
- 即使快照具体到文件+动作+日期，只要无可执行信息/技术细节/结论，仍是纯状态快照 → DROP
- 中文：短句记录"已完成X/今天测试了Y/配置了Z"，无技术参数、结论、根因 → DROP
- 有真实技术内容（实现方式/参数/结论/根因/判断条件）的中英文记忆才 KEEP

只输出 JSON：{"judge": "keep" 或 "drop", "reason": "一句中文理由"}"""


def _quality_llm_judge_once(text: str) -> str:
    """单次 LLM 质量判定，返回 keep/drop/ERR（解析失败或异常，fail-open）。"""
    raw = _llm_chat(
        f"记忆内容：\n{text}",
        temperature=0,
        max_tokens=200,
        system_prompt=QUALITY_JUDGE_SYSTEM,
    )
    if not raw:
        return "ERR"
    m = re.search(r'"judge"\s*:\s*"(\w+)"', raw)
    j = m.group(1) if m else ""
    return j if j in ("keep", "drop") else "ERR"


def _quality_llm_review(reviews: list[dict]) -> tuple[list[dict], list[dict]]:
    """LLM 3 票复核边界样本：3 次全 drop 才 drop，其余 keep（fail-open）。

    教训：fail-closed drop 在并发限流时会永久误伤高价值记忆（实测 3 次全 ERR）；
    LLM 对边界记忆判定是概率性的，最保守策略防误伤，聚合层 retain=false 兜底。
    """

    def vote(m: dict) -> tuple[dict, bool]:
        text = str(m.get("memory") or m.get("content") or "")
        votes = [
            _quality_llm_judge_once(text) for _ in range(MEMORY_QUALITY_REVIEW_VOTES)
        ]
        valid = [v for v in votes if v in ("keep", "drop")]
        return m, valid.count("drop") == MEMORY_QUALITY_REVIEW_VOTES

    with ThreadPoolExecutor(max_workers=MEMORY_QUALITY_LLM_THREADS) as ex:
        results = list(ex.map(vote, reviews))
    kept = [m for m, is_drop in results if not is_drop]
    dropped = [m for m, is_drop in results if is_drop]
    return kept, dropped


def _filter_memory_quality(memories: list[dict]) -> list[dict]:
    """记忆输入质量门（方案 E v5）：规则层确定性 drop + LLM 3 票复核边界。

    被丢弃记忆不标记已处理——保留下次重新评估机会。
    """
    kept: list[dict] = []
    reviews: list[dict] = []
    rule_dropped = 0
    for m in memories:
        text = str(m.get("memory") or m.get("content") or "")
        j, why = _quality_rule_judge(text)
        if j == "drop":
            rule_dropped += 1
            logger.debug(f"质量门规则 drop: {why} | {text[:50]!r}")
        elif j == "review":
            reviews.append(m)
        else:
            kept.append(m)
    if reviews:
        r_kept, r_dropped = _quality_llm_review(reviews)
        logger.info(
            f"质量门 LLM 复核 {len(reviews)} 条边界：drop {len(r_dropped)}，keep {len(r_kept)}"
        )
        kept += r_kept
    if rule_dropped:
        logger.info(f"质量门规则层 drop {rule_dropped} 条")
    return kept


def _mark_processed(memory_ids: list[str], bit: int = 0) -> int:
    """把记忆已处理位批量置 1（成功落盘后调用）。失败不阻断总结，返回成功数。"""
    if not memory_ids:
        return 0
    try:
        resp = _HTTP.post(
            f"{MEMORY_SERVER_URL}/api/memories/processed",
            json={"memory_ids": memory_ids, "bit": bit, "value": 1},
        )
        resp.raise_for_status()
        updated = resp.json().get("updated", 0)
        logger.info(f"已标记 {updated}/{len(memory_ids)} 条记忆为已处理")
        return updated
    except Exception as e:
        logger.warning(f"标记已处理失败: {e}")
        return 0


def _memory_date(m: dict) -> str:
    """从记忆条目提取 MM-DD 日期；优先 created_at（服务端 recent 端点已用其过滤排序），
    缺键/异常返回空串。"""
    raw = m.get("created_at") or m.get("updated_at") or ""
    return raw[5:10] if len(raw) >= 10 else ""


def _build_facts_text_v2(memories: list[dict]) -> str:
    # 记忆项正文在 `memory` 键（REST API 返回），`content` 键不存在 → 读错会拿到空
    # 英文双引号归一化为中文引号（成对交替左右）：LLM 复制原文时会把裸引号带进
    # JSON 字符串值且不转义，导致下游 _parse_json_any 解析失败（2026-08-05 实测）
    def _clean(text: str) -> str:
        out = []
        open_q = True
        for ch in text:
            if ch == '"':
                out.append("“" if open_q else "”")
                open_q = not open_q
            else:
                out.append(ch)
        return "".join(out)

    return "\n".join(
        f"- [{','.join(m.get('metadata', {}).get('tags', []))}] "
        f"[{_memory_date(m) or '日期未知'}] "
        f"{_clean(m.get('memory') or m.get('content') or '')}"
        for m in memories
    )


def _aggregate_round(
    facts_text: str, label: str
) -> tuple[list[dict] | None, str | None]:
    """单轮聚合：把记忆事实按主题分类/组内合并去重/retain 评估，返回 (groups, raw)。

    label 用于日志区分「分批」与「递归合并轮」。LLM 输出无效（重试 1 次后仍失败）
    时返回 (None, raw)，由调用方决定中断（首轮）或保留当前结果继续（递归轮）。
    """
    prompt = f"""\
你正在对一批记忆事实做聚合预处理：按主题分类、组内合并去重、丢弃无长期价值的一次性信息。

记忆事实{label}：
{facts_text}

### 要求

1. **按主题分组**：语义相近/同一主题的事实归为同一组
2. **组内合并去重**：同一件事的重复/相似记录合并为一条连贯文本，不要重复罗列
3. **时间线演进**：同一主题跨多日的记忆，按时间先后组织进 facts（先发生在前），体现「先 A、后改成 B」的演变轨迹；内容发生变化时保留演变过程而非只留最终状态
4. **关键节点标日期**：根因判定、方案选型、决策、修复完成等关键节点在 facts 中标注日期，如（8/3 首次发现，8/5 确认根因）
5. **评估沉淀价值（retain）**：每组判断是否值得沉淀为长期知识笔记，宁缺毋滥——
   - **retain=true**：含可长期复用的知识，如技术方案、架构决策、踩坑与解决办法、可复用的经验结论
   - **retain=false**：以下一律判 false——纯临时工作记录（任务编号流水、无细节的单条调研痕迹、过程性碎片如"对 X 做了调研""讨论了 Y"）、泛泛而谈无具体方案的结论、无定位信息（文件路径/组件名/参数名/判断条件/报错信息）的模糊经验、几天后即无意义的中间态
   - **宁可遗漏，不要产出临时记录**：拿不准就判 false
6. **丢弃一次性信息**：临时状态、过时配置、纯日志类碎片、无上下文的孤句不进入分组
7. **主题要具体**：如 "蓝牙打印机 SDK 集成" 而非 "打印"
8. **只保留记忆中出现的信息**：禁止编造、禁止虚构不存在的 API/组件名/方法名/版本号/配置项/代码/数据
9. **facts 完整度**：必须包含该主题全部记忆条目中的所有可复用细节，特别是文件路径、组件/接口名、参数名、判断条件、报错信息等定位信息，不得因分组而丢弃

返回 JSON：{{"groups": [{{"topic": "具体主题", "facts": "合并去重后按时间组织的事实文本", "tags": ["标签"], "retain": true}}]}}
没有有效内容时返回 {{"groups": []}}。
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    parsed = None
    raw = None
    for attempt in range(2):  # 失败重试 1 次（LLM 偶发输出不完整/非 JSON）
        raw = _llm_chat(
            prompt,
            temperature=AGGREGATE_LLM_TEMPERATURE,
            timeout=AGGREGATE_LLM_TIMEOUT,
            max_tokens=16384,
            disable_thinking=True,
        )
        parsed = _parse_json_any(raw) if raw else None
        if parsed:
            break
        logger.warning(
            f"聚合{label} 第 {attempt + 1} 次尝试无效"
            + ("，重试" if attempt == 0 else "，放弃")
        )
    if not parsed:
        return None, raw
    return parsed.get("groups", []) or [], raw


def _groups_to_facts(groups: list[dict]) -> str:
    """把已聚合 groups 转回事实文本，供递归合并轮再次聚合。"""
    return "\n".join(
        f"- [{','.join(g.get('tags', []) or [])}] "
        f"{g.get('topic', '')}：{g.get('facts', '')}"
        for g in groups
    )


def _filter_retain(groups: list[dict]) -> list[dict]:
    """只保留有长期沉淀价值的组（retain=true）；缺失时按 false 处理（宁缺毋滥）。"""
    retained = []
    for g in groups:
        if g.get("retain") not in (True, "true", "True"):
            logger.info(f"聚合丢弃无沉淀价值组：{g.get('topic', '')!r}")
            continue
        if not str(g.get("facts", "")).strip():
            continue
        retained.append(g)
    return retained


def _run_aggregate_v2(memories: list[dict]) -> tuple[list[dict] | None, int]:
    """阶段1 v2：分批聚合 → 跨批合并 → retain 过滤 → 递归合并直至收敛。

    返回 (groups, rounds)：groups 为 None 仅表示首轮致命失败（中断）；
    rounds 为实际执行的递归轮数（不含首轮分批）。递归只合并不拆散、
    组数单调不增，故 ≤ AGGREGATE_MAX_ROUNDS 必然收敛；递归轮失败保留
    当前结果继续（非致命）。
    """
    batches: list[list[dict]] = []
    if len(memories) > AGGREGATE_BATCH_THRESHOLD:
        for i in range(0, len(memories), AGGREGATE_BATCH_SIZE):
            batches.append(memories[i : i + AGGREGATE_BATCH_SIZE])
    else:
        batches = [memories]

    groups: list[dict] = []
    for bi, batch in enumerate(batches):
        facts_text = _build_facts_text_v2(batch)
        batch_label = f"（{bi + 1}/{len(batches)} 批）" if len(batches) > 1 else ""
        batch_groups, raw = _aggregate_round(facts_text, batch_label)
        if batch_groups is None:
            write_error_log(
                f"聚合批 {bi + 1}/{len(batches)} LLM 输出无效（重试后仍失败）：\n{(raw or '')[:1000]}",
                code="AGGREGATE_JSON",
            )
            return None, 0
        groups.extend(batch_groups)

    if not groups:
        print("聚合无有效主题，跳过总结")
        return [], 0

    # 分批聚合时跨批二次合并：topic 相同/相近的组收敛为一组
    if len(batches) > 1:
        groups = _merge_cross_batch_groups(groups)

    # 递归合并：组数不再减少即收敛；最多 AGGREGATE_MAX_ROUNDS 轮
    rounds = 0
    for rnd in range(1, AGGREGATE_MAX_ROUNDS + 1):
        prev_len = len(groups)
        round_groups, _raw = _aggregate_round(
            _groups_to_facts(groups), f"（第 {rnd} 轮递归合并）"
        )
        if round_groups is None:
            logger.warning(f"递归合并第 {rnd} 轮失败，保留当前分组继续")
            break
        groups = round_groups
        rounds = rnd
        logger.info(f"聚合收敛：第 {rnd} 轮 {prev_len} → {len(groups)} 组")
        if len(groups) >= prev_len:
            break

    return _filter_retain(groups), rounds


def _merge_cross_batch_groups(groups: list[dict]) -> list[dict]:
    """跨批二次合并：把 topic 相同/相近的组收敛为一组（分批聚合时调用）。"""
    entries = "\n".join(
        f"- [{i}] {g.get('topic', '')}：{g.get('facts', '')[:150]}"
        for i, g in enumerate(groups)
    )
    prompt = f"""\
以下为分批聚合得到的记忆组，跨批可能存在主题重复。请将 topic 相同或相近的组收敛为一组。

记忆组：
{entries}

要求：合并后 facts 按时间线组织（先发生在前），同一主题跨批演进时保留演变过程、关键节点保留日期标注。

返回 JSON：{{"groups": [{{"topic": "合并后主题", "facts": "合并后按时间组织的完整事实文本", "tags": ["标签"], "retain": true}}]}}
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    raw = _llm_chat(
        prompt,
        temperature=AGGREGATE_LLM_TEMPERATURE,
        timeout=AGGREGATE_LLM_TIMEOUT,
        max_tokens=16384,
        disable_thinking=True,
    )
    if not raw:
        logger.warning("跨批二次合并 LLM 调用失败，保留原分组")
        return groups
    parsed = _parse_json_any(raw)
    if not parsed or not parsed.get("groups"):
        logger.warning("跨批二次合并解析失败，保留原分组")
        return groups
    return parsed["groups"]


def _llm_json(
    prompt: str,
    *,
    max_tokens: int,
    temperature: float | None = None,
    timeout: float | None = None,
    disable_thinking: bool = False,
) -> dict | None:
    """think enable 输出 JSON；解析失败自动降级 disable_thinking 重试一次。

    返回解析成功的 dict；两次都失败返回 None。disable_thinking=True 时全程禁用。
    """
    for attempt in range(2):
        raw = _llm_chat(
            prompt,
            temperature=temperature,
            timeout=timeout,
            max_tokens=max_tokens,
            disable_thinking=(disable_thinking or attempt > 0),
        )
        if raw:
            parsed = _parse_json_any(raw)
            if parsed:
                return parsed
        if attempt == 0:
            logger.warning("JSON 输出解析失败，降级 disable_thinking 重试一次")
    return None


def _extract_keywords(group: dict) -> list[str]:
    """提炼组主题的检索关键词（3-8 个名词性词）。失败返回 []。"""
    facts = str(group.get("facts", ""))[:SUMMARY_MERGE_CONTEXT_CHARS]
    prompt = f"""\
从以下记忆主题中提炼 3-{SUMMARY_KEYWORD_COUNT} 个用于检索知识库的关键词。

主题：{group.get('topic', '')}
相关事实：
{facts}

要求：
1. 名词性关键词：专有名词、项目名、技术栈、库名、主题中心词
2. 每个关键词 ≥{SEARCH_MIN_TOKEN_LEN} 字符
3. 避免「记忆」「总结」「问题」「修复」「开发」等通配词
4. 用具体词而非描述句
5. 数量 3-{SUMMARY_KEYWORD_COUNT} 个

返回 JSON：{{"keywords": ["关键词1", "关键词2", ...]}}
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    parsed = _llm_json(prompt, max_tokens=SUMMARY_KEYWORD_MAX_TOKENS)
    if not parsed:
        return []
    kws = parsed.get("keywords") or []
    if isinstance(kws, str):
        kws = re.split(r"[、,，]", kws)
    out = []
    for k in kws:
        s = str(k).strip()
        if len(s) >= SEARCH_MIN_TOKEN_LEN:
            out.append(s)
    return out[:SUMMARY_KEYWORD_COUNT]


def _make_snippet(text: str, keyword: str) -> str:
    """取关键词首次命中处前后 ~60 字符作检索摘要。"""
    idx = text.lower().find(keyword.lower())
    if idx == -1:
        return text[:120]
    start = max(0, idx - 60)
    end = min(len(text), idx + len(keyword) + 60)
    prefix = "…" if start > 0 else ""
    suffix = "…" if end < len(text) else ""
    return f"{prefix}{text[start:end].strip()}{suffix}"


def search_extracts(
    keywords: list[str], limit: int = SUMMARY_SEARCH_LIMIT
) -> list[dict]:
    """在 EXTRACTS_DIR 内按关键词子串匹配检索（纯本地，零外部依赖）。

    冷层向量库 ≠ Extracts 全文（冷层只含每次 summarize 同步的聚合条目），
    且 Qdrant local 有排他锁，summarize 独立进程不能直连——故检索用纯
    Python 大小写不敏感子串匹配。返回按命中关键词数降序的前 limit 条
    [{"rel_path", "snippet", "matched", "score"}]。
    """
    if not keywords or not EXTRACTS_DIR.exists():
        return []
    kws = [k for k in keywords if k]
    hits: list[dict] = []
    for f in sorted(EXTRACTS_DIR.rglob("*.md")):
        if any(part.startswith(".") for part in f.relative_to(EXTRACTS_DIR).parts):
            continue
        try:
            text = f.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        low = text.lower()
        matched = [k for k in kws if k.lower() in low]
        if not matched:
            continue
        hits.append(
            {
                "rel_path": str(f.relative_to(EXTRACTS_DIR)),
                "snippet": _make_snippet(text, matched[0]),
                "matched": matched,
                "score": len(matched),
            }
        )
    hits.sort(key=lambda h: h["score"], reverse=True)
    return hits[:limit]


def _existing_extract_tops() -> set[str]:
    """Extracts 现有顶层目录名集合（供目录白名单/LLM 提示复用）。"""
    if not EXTRACTS_DIR.exists():
        return set()
    return {d.name for d in EXTRACTS_DIR.iterdir() if d.is_dir()}


def _dir_excluded(dir_name: str) -> bool:
    """目录路径任一层命中排除目录（notes 根的手写区）。"""
    return any(p in SUMMARY_EXCLUDE_DIRS for p in Path(dir_name).parts)


def _decide_merge(group: dict, hits: list[dict]) -> dict | None:
    """判断该组应归并到已有笔记还是新建。

    无命中返回 None（直接新建）；有命中返回 {"action", "target"(相对Extracts), "reason"}。
    判断 JSON 失败（降级后仍 None）→ 兜底 merge 到 hits[0] 并写 REFINE_JUDGE_JSON 日志。
    """
    if not hits:
        return None

    facts = str(group.get("facts", ""))[:SUMMARY_MERGE_CONTEXT_CHARS]
    candidates = "\n".join(
        f"- [{i}] {h['rel_path']}：{h['snippet'][:120]}" for i, h in enumerate(hits)
    )
    prompt = f"""\
判断以下记忆主题是否应该归并到已有的知识笔记中。

待沉淀主题：{group.get('topic', '')}
相关事实：
{facts}

已有笔记候选（检索命中，按相关度降序）：
{candidates}

判定标准：
1. **归并（action=merge）**：已有笔记与当前主题高度相关——同技术栈/同项目/同一件事的持续演进
2. **新建（action=new）**：仅沾边/命中通用词，或本质是新主题，强行归并会污染已有笔记
3. 多命中时选最相关的一个 target；内容演进/冲突仍可归并（reason 注明）
4. target 必须是上方候选列表中的 rel_path，不要臆造路径

返回 JSON：{{"action": "merge" 或 "new", "target": "相对Extracts的md路径（merge时）", "reason": "一句话理由"}}
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    parsed = _llm_json(prompt, max_tokens=SUMMARY_JUDGE_MAX_TOKENS)
    if parsed:
        action = str(parsed.get("action", "")).strip().lower()
        if action == "merge":
            target = str(parsed.get("target", "")).strip()
            # 校验用 resolve 后路径（/tmp→/private/tmp 等 symlink 环境不致 relative_to 抛错）
            r_extracts = EXTRACTS_DIR.resolve()
            t = (EXTRACTS_DIR / target).resolve()
            if (
                target.endswith(".md")
                and t.is_file()
                and r_extracts in t.parents
                and not _dir_excluded(t.relative_to(r_extracts))
            ):
                return {
                    "action": "merge",
                    "target": target,
                    "reason": str(parsed.get("reason", "")),
                }
            logger.warning(f"归并目标 {target!r} 非法/不存在，回退为新建")
            return {"action": "new", "target": "", "reason": "judge target 非法"}
        return {"action": "new", "target": "", "reason": str(parsed.get("reason", ""))}

    # 判断失败（降级后仍 None）→ 兜底 merge 到首个非排除命中，比乱建好
    # （缺陷2修复：hits[0] 可能在排除目录，跳过取首个合法命中；无则回退新建）
    fallback = next((h for h in hits if not _dir_excluded(h["rel_path"])), None)
    if fallback is None:
        write_error_log(
            f"归并判断 JSON 失败且无合法兜底命中（topic={group.get('topic', '')!r}），回退为新建",
            code="REFINE_JUDGE_JSON",
        )
        return {"action": "new", "target": "", "reason": "judge 失败且无合法兜底"}
    write_error_log(
        f"归并判断 JSON 失败，兜底归并到 {fallback['rel_path']}"
        f"（topic={group.get('topic', '')!r}）",
        code="REFINE_JUDGE_JSON",
    )
    return {
        "action": "merge",
        "target": fallback["rel_path"],
        "reason": "judge 失败兜底",
    }


def _gen_new(group: dict, dir_tree: str, existing_tops: set[str]) -> dict | None:
    """think enable 生成新建文章：{"dir", "title", "content"}。失败返回 None。"""
    facts = str(group.get("facts", ""))
    tops_block = "、".join(sorted(existing_tops)) if existing_tops else "（空）"
    prompt = f"""\
将以下记忆事实整理为一篇高质量知识笔记（新建文件）。

待沉淀主题：{group.get('topic', '')}
相关事实：
{facts}

现有笔记目录结构：
{dir_tree}

现有顶层目录：{tops_block}

### 要求

1. **严格基于相关事实写作**：只使用其中出现的信息，禁止编造、禁止虚构不存在的 API/组件名/方法名/版本号/配置项/代码/数据
2. 记忆事实未提供的细节不要补造，宁可缺省也不虚构
3. **时间线演进**：事实含跨日演进时按时间组织，关键节点保留日期标注（如 8/3 首次发现，8/5 确认根因）
4. **目录（dir）**：复用现有顶层目录，或新建单层顶层目录；禁止嵌套多级新目录；禁止使用 {sorted(SUMMARY_EXCLUDE_DIRS)} 作为目录
5. **标题（title）**：具体，如 "UTSJSONObject null 安全访问" 而非 "UTSJSONObject 坑"
6. 篇幅 150-500 字，事实密度优先，不要空泛
7. 正文不需要 # 标题行（脚本会写）

返回 JSON：{{"dir": "相对目录路径", "title": "具体标题", "content": "Markdown 正文"}}
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    parsed = _llm_json(prompt, max_tokens=SUMMARY_GEN_MAX_TOKENS, temperature=0.2)
    if not parsed:
        return None
    dir_name = str(parsed.get("dir", "")).strip().strip("/")
    title = str(parsed.get("title", "")).strip()
    content = str(parsed.get("content", "")).strip()
    if not dir_name or not title or not content:
        return None
    return {"dir": dir_name, "title": title, "content": content}


def _gen_merge(group: dict, target_file: Path, existing_text: str) -> dict | None:
    """think enable 生成归并内容：只写未被已有内容覆盖的新增信息。失败返回 None。

    no_increment 语义判定：LLM 对比「相关事实」与「目标笔记相关段落」，全部要点
    已被覆盖时返回 {"action":"no_increment",...}，由 refine 识别跳过（2026-08-07 新增）。
    仅 no_increment 带 action 字段；正常 merge 不带，避免 results.append 时 **item 的
    action 覆盖 refine 局部 action（fallback_merge 被污染成 merge）。
    上下文取 _relevant_segments 而非前 N 字符——文件大时前 2K 看不到文件尾既有段，
    LLM 无从判断重复（2026-08-07 根因修复）。
    """
    facts = str(group.get("facts", ""))
    context = _relevant_segments(existing_text, facts, SUMMARY_MERGE_LOOKBACK_CHARS)
    prompt = f"""\
将以下记忆事实补充到已有知识笔记中（追加新信息）。

待沉淀主题：{group.get('topic', '')}
相关事实：
{facts}

目标笔记：{target_file.relative_to(EXTRACTS_DIR)}
目标笔记相关段落（按与事实相关度选取，非全文件）：
{context}

### 要求

1. **严格基于相关事实写作**：只使用其中出现的信息，禁止编造
2. **只写已有内容未覆盖的新增信息**：已有内容已写过的细节不要重复
3. **时间线演进**：与已有内容构成先后演进时标注日期（如 8/3 首次发现，8/5 确认根因），体现「先 A、后改成 B」
4. **内容冲突时**：以事实为准，注明与旧结论的差异
5. 篇幅 150-500 字，事实密度优先
6. 正文不需要 # 标题行（脚本会写）
7. **修正旧结论时**：若本次内容否定了旧段结论（supersedes 语义），"supersedes" 置 true；仅补充新信息置 false
8. **无增量判定（重要）**：先对比「相关事实」与「目标笔记相关段落」。若相关事实的全部要点已被既有内容覆盖、本次无实质新增信息 → 返回 {{"action": "no_increment", "reason": "简述哪些内容已存在"}}。仅当存在未被覆盖的新增信息时才正常返回；不确定时视为有增量（宁保留勿丢失）

返回 JSON：{{"action": "merge", "title": "本节标题", "content": "Markdown 正文", "supersedes": true 或 false}}
或无增量时：{{"action": "no_increment", "reason": "重复点简述"}}
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    parsed = _llm_json(prompt, max_tokens=SUMMARY_GEN_MAX_TOKENS, temperature=0.2)
    if not parsed:
        return None
    if str(parsed.get("action", "")).strip().lower() == "no_increment":
        return {
            "action": "no_increment",
            "reason": str(parsed.get("reason", "")).strip(),
        }
    title = str(parsed.get("title", "")).strip()
    content = str(parsed.get("content", "")).strip()
    if not title or not content:
        return None
    return {
        "title": title,
        "content": content,
        "supersedes": bool(parsed.get("supersedes", False)),
    }


def _topical_related(g1: dict, g2: dict, kw1: list[str], kw2: list[str]) -> bool:
    """预聚合合并判定：共享主题关键词 + Jaccard ≥ SUMMARY_TOPIC_JACCARD（纯确定性，0 LLM）。

    实测校准（2026-08-06 真实 20 条未处理记忆 → 12 组 → 4 个命中目标）：
    - 同族组（如 summarize.py 质量门方案/摆锤/5bd2e21/占位词表，同命中 Hermes RSS 笔记）：
      关键词集共享 ≥1 个主题词，Jaccard 0.07-0.15；
    - 不相关同 target 组（如 RSS 日报已读标记约定 vs summarize 族）：共享 0 词，Jaccard=0；
    - 整文本 SequenceMatcher 比值 / char-bigram Jaccard 在族内（0.06-0.17）与跨族（0.06-0.16）
      区间重叠，**无静态阈值可分**——原 `_max_segment_similarity > 0.6` 门把所有组判不相关
      （实测 topic_merged=0、topic_blocked=22，5bd2e21 碎片根因未能收敛）。
    故以「关键词共享 + Jaccard ≥ 0.05（≥1 个共享主题词）」为相关性判定，共享项目/主题词即
    同族信号。ffe8857 过度合并防护不因本门放宽而退化：预聚合组仍走 LLM 终审；且 count 门
    （单 target 单轮限 1 次归并）+ 预聚合后同 target 每组互不相关 → 单 target 单轮最多 1 次
    归并写，结构上杜绝「一次 6 段」堆积。
    """
    set1 = {k.lower() for k in kw1 if k}
    set2 = {k.lower() for k in kw2 if k}
    if not set1 or not set2:
        return False
    inter = set1 & set2
    if not inter:
        return False
    jaccard = len(inter) / len(set1 | set2)
    return jaccard >= SUMMARY_TOPIC_JACCARD


def _resolve_group_targets(groups: list[dict]) -> dict:
    """预解析每组「关键词 + 检索命中 + top1 合法 target」，返回 {index: {...}}。

    target 取 top1 通过合法校验（.md / is_file / EXTRACTS 内 / _dir_excluded）的命中，
    供预聚合与 refine 复用，消除循环内重复关键词提炼/检索（0 新增 LLM）。
    失败/无命中 → {"keywords": [], "hits": [], "target": None}。
    """
    resolved: dict[int, dict] = {}
    for gi, group in enumerate(groups):
        try:
            keywords = _extract_keywords(group)
            if not keywords:
                resolved[gi] = {"keywords": [], "hits": [], "target": None}
                continue
            hits = search_extracts(keywords)
            target = None
            for h in hits:
                rel = h["rel_path"]
                fp = EXTRACTS_DIR / rel
                if (
                    rel.endswith(".md")
                    and fp.is_file()
                    and EXTRACTS_DIR.resolve() in fp.resolve().parents
                    and not _dir_excluded(rel)
                ):
                    target = rel
                    break
            resolved[gi] = {"keywords": keywords, "hits": hits, "target": target}
        except Exception:
            resolved[gi] = {"keywords": [], "hits": [], "target": None}
    return resolved


def _pre_aggregate_same_target(
    groups: list[dict], resolved: dict
) -> tuple[list[dict], dict, dict]:
    """预聚合：命中同一 target 且主题相关的组合并为一组，根治同家族碎片。

    背景：5bd2e21 过度拆分根因是「同主题家族第 2+ 组撞同 target 被 merge_counts
    强制 new」。此处把命中同 target 且 _topical_related 的组在 count 判定**之前**
    合并为单组 → 单次归并写 → count 永不触发；预聚合后桶内组互不相关，count 语义
    自动退化为「限 1 次不相关 merge」，ffe8857 防护原样保留。

    合并：facts 换行拼接、tags 并集（去重保序）、target 保留被并入组的缓存。
    返回 (new_groups, new_resolved, stats)；new_resolved 下标与新组对齐。
    stats: {"topic_merged": 实际合并次数, "topic_blocked": 同 target 判定不相关的次数}
    """
    by_target: dict[str, list[int]] = {}
    for gi, info in resolved.items():
        tgt = info.get("target")
        by_target.setdefault(tgt if tgt else "<none>", []).append(gi)

    new_groups: list[dict] = []
    new_resolved: dict[int, dict] = {}
    merged = 0
    blocked = 0
    new_idx = 0

    for tgt, idxs in by_target.items():
        if tgt == "<none>" or len(idxs) == 1:
            for gi in idxs:
                new_groups.append(groups[gi])
                new_resolved[new_idx] = resolved[gi]
                new_idx += 1
            continue
        # 桶内贪心：每组尝试并入已选代表（相关则并），否则独立成组
        reps: list[dict] = []
        for gi in idxs:
            placed = False
            for rep in reps:
                if _topical_related(
                    groups[gi],
                    rep["group"],
                    resolved[gi]["keywords"],
                    rep["resolved"]["keywords"],
                ):
                    rep["members"].append(gi)
                    placed = True
                    break
                blocked += 1  # 判定不相关：记一次 topic_blocked
            if not placed:
                reps.append(
                    {"members": [gi], "group": groups[gi], "resolved": resolved[gi]}
                )
        for rep in reps:
            members = rep["members"]
            merged_group = dict(groups[members[0]])
            if len(members) > 1:
                parts = [
                    str(groups[m].get("facts", "")).strip()
                    for m in members
                    if str(groups[m].get("facts", "")).strip()
                ]
                tags: list[str] = []
                for m in members:
                    tags.extend(groups[m].get("tags", []) or [])
                merged_group["facts"] = "\n\n".join(parts)
                if tags:
                    merged_group["tags"] = list(dict.fromkeys(t for t in tags if t))
                merged_group["_pre_merged_from"] = members
                merged += len(members) - 1
            new_groups.append(merged_group)
            new_resolved[new_idx] = rep["resolved"]
            new_idx += 1

    return new_groups, new_resolved, {"topic_merged": merged, "topic_blocked": blocked}


def _run_refine(groups: list[dict], dir_tree: str) -> tuple[list[dict], dict]:
    """阶段2：逐组「提炼关键词 → 检索 Extracts → 判断归并/新建 → think enable 生成」。

    单组任一环节失败不中断整体：write_error_log + stats 计数 + 跳过该组。
    返回 (results, stats)；results 为写入单元（含 action: new/merge）。
    """
    stats = {
        "ok": 0,
        "kw_fail": 0,
        "gen_fail": 0,
        "too_short": 0,
        "too_low_quality": 0,
        "dup_skip": 0,
        "new": 0,
        "merge": 0,
        "topic_merged": 0,  # 预聚合合并组数（同 target 同家族）
        "topic_blocked": 0,  # 同 target 判定不相关的次数（保 ffe8857 防护）
        "fallback_merge": 0,  # 微碎片回退归并次数
        "fallback_dropped": 0,  # 微碎片回退失败/无目标次数
        "hit_files": set(),
    }
    merge_counts: dict[str, int] = {}  # 单次运行各目标文件的归并次数（限 1 主题）
    results: list[dict] = []
    existing_tops = _existing_extract_tops()
    # 预解析所有组关键词/检索/target + 同 target 同家族预聚合（方案 A+C 融合）
    resolved_all = _resolve_group_targets(groups)
    groups, resolved_all, pre_stats = _pre_aggregate_same_target(groups, resolved_all)
    stats["topic_merged"] = pre_stats["topic_merged"]
    stats["topic_blocked"] = pre_stats["topic_blocked"]
    if pre_stats["topic_merged"]:
        logger.info(
            f"预聚合：同目标同家族合并 {pre_stats['topic_merged']} 组，"
            f"同目标不相关 {pre_stats['topic_blocked']} 次"
        )
    for gi, group in enumerate(groups):
        topic = str(group.get("topic", "")) or f"组{gi}"
        logger.info(f"Refine [{gi}] {topic} ...")
        try:
            keywords = (resolved_all.get(gi) or {}).get("keywords", [])
            if not keywords:
                stats["kw_fail"] += 1
                write_error_log(
                    f"主题 {topic!r} 关键词提炼失败，跳过", code="REFINE_KEYWORD"
                )
                continue
            hits = (resolved_all.get(gi) or {}).get("hits", []) or []
            if hits:
                stats["hit_files"].add(hits[0]["rel_path"])

            try:
                decision = _decide_merge(group, hits)
            except Exception as e:
                stats["gen_fail"] += 1
                write_error_log(
                    f"主题 {topic!r} 归并判断异常: {e}", code="REFINE_JUDGE"
                )
                continue

            # 单次运行同一目标文件最多归并 1 次：独立主题拆散为各自文件（防「一次 6 段」反例）
            if (
                decision is not None
                and decision["action"] == "merge"
                and merge_counts.get(decision["target"], 0) >= 1
            ):
                logger.warning(
                    f"主题 {topic!r} 目标 {decision['target']} 已归并过，本次改为新建"
                )
                decision = {
                    "action": "new",
                    "target": "",
                    "reason": "目标已归并，单文件限 1 主题",
                }

            try:
                if decision is not None and decision["action"] == "merge":
                    target_file = EXTRACTS_DIR / decision["target"]
                    existing_text = (
                        target_file.read_text(encoding="utf-8")
                        if target_file.exists()
                        else ""
                    )
                    item = _gen_merge(group, target_file, existing_text)
                    action = "merge"
                    target_label = decision["target"]
                    if item:
                        # _gen_merge 返回 {action, title, content, ...}，补 target 供写入层定位
                        item["target"] = decision["target"]
                        # LLM 无增量判定（改写式重复：措辞不同但信息已被既有段覆盖，
                        # 机械相似度阈值拦不住——2026-08-07 根因修复）
                        if item.get("action") == "no_increment":
                            stats["dup_skip"] += 1
                            logger.warning(
                                f"主题 {topic!r} 判定无增量（LLM）："
                                f"{item.get('reason', '')}"
                            )
                            continue
                        # 写前增量判定：生成段相对既有某段匹配覆盖率过高视为无新增，跳过不写
                        sim = _max_segment_similarity(
                            item.get("content", ""), existing_text
                        )
                        if sim > SUMMARY_DUP_SIM_THRESHOLD:
                            stats["dup_skip"] += 1
                            logger.warning(
                                f"主题 {topic!r} 与 {decision['target']} 既有内容"
                                f"覆盖率 {sim:.2f} 过高，判定无增量跳过"
                            )
                            continue
                        # 注：merge_counts 原在 dup_skip 后即自增——QC 占位/过短拒绝在
                        # 其后，导致「归并内容被 QC 拒写」仍占用该文件归并名额，
                        # 后续合法归并被误拦（实测组[0]/[1] 占位拒绝后组[3] 被误 block）。
                        # 移入成功写入后统计（见 results.append 前），仅计真实落盘归并。
                else:
                    item = _gen_new(group, dir_tree, existing_tops)
                    action = "new"
                    target_label = item["dir"] if item else ""
                    # 微碎片兜底（C）：新建产物 <10 行 → 回退归并到 hits 首个非排除命中。
                    # 归并产物过相似度门则正常归并；无可用目标/归并失败维持新建落盘（防信息丢失）。
                    if (
                        item
                        and len(str(item.get("content", "")).splitlines())
                        < SUMMARY_FRAGMENT_LINE_MIN
                    ):
                        fb = next(
                            (
                                h
                                for h in (resolved_all.get(gi) or {}).get("hits", [])
                                if not _dir_excluded(h["rel_path"])
                            ),
                            None,
                        )
                        if fb is not None:
                            try:
                                fb_file = EXTRACTS_DIR / fb["rel_path"]
                                fb_text = (
                                    fb_file.read_text(encoding="utf-8")
                                    if fb_file.exists()
                                    else ""
                                )
                                fb_item = _gen_merge(group, fb_file, fb_text)
                                if fb_item:
                                    fb_item["target"] = fb["rel_path"]
                                    if fb_item.get("action") == "no_increment":
                                        stats["dup_skip"] += 1
                                        logger.warning(
                                            f"主题 {topic!r} 碎片回退归并判定无增量"
                                            f"（LLM）：{fb_item.get('reason', '')}"
                                        )
                                        continue
                                    fb_sim = _max_segment_similarity(
                                        fb_item.get("content", ""), fb_text
                                    )
                                    if fb_sim > SUMMARY_DUP_SIM_THRESHOLD:
                                        stats["dup_skip"] += 1
                                        logger.warning(
                                            f"主题 {topic!r} 碎片回退归并 "
                                            f"{fb['rel_path']} 覆盖率 {fb_sim:.2f} "
                                            f"无增量，跳过"
                                        )
                                        continue
                                    item = fb_item
                                    action = "fallback_merge"
                                    target_label = fb["rel_path"]
                                    # 计数由末尾 stats[action] 统一累加，这里不重复加
                                else:
                                    stats["fallback_dropped"] += 1
                                    logger.warning(
                                        f"主题 {topic!r} 碎片回退归并生成失败，维持新建"
                                    )
                            except Exception as e:
                                stats["fallback_dropped"] += 1
                                write_error_log(
                                    f"主题 {topic!r} 碎片回退归并异常: {e}",
                                    code="REFINE_FALLBACK",
                                )
                        else:
                            stats["fallback_dropped"] += 1
                            logger.warning(
                                f"主题 {topic!r} 碎片无可用回退目标，维持新建落盘"
                            )
            except Exception as e:
                stats["gen_fail"] += 1
                write_error_log(f"主题 {topic!r} 生成异常: {e}", code="REFINE_GEN")
                continue

            if not item:
                stats["gen_fail"] += 1
                write_error_log(f"主题 {topic!r} 生成失败，跳过", code="REFINE_GEN")
                continue
            content_text = str(item.get("content", ""))
            if len(content_text) < SUMMARY_MIN_CONTENT_LEN:
                stats["too_short"] += 1
                logger.warning(f"主题 {topic!r} 内容过短，跳过")
                continue
            # QC 占位符检测：含「未详述/待补全」等占位表述视为低质，不落盘
            ph = next(
                (p for p in SUMMARY_PLACEHOLDER_PATTERNS if p in content_text), None
            )
            if ph:
                stats["too_low_quality"] += 1
                logger.warning(f"主题 {topic!r} 含占位表述「{ph}」，判定低质跳过")
                continue

            if action == "merge":
                # 成功落盘的直接归并才占名额（QC 拒写不占用），fallback_merge 为碎片
                # 兜底不受 count 限（<10 行微碎片，不可能构成 ffe8857 大量不相关段堆积）
                merge_counts[item["target"]] = merge_counts.get(item["target"], 0) + 1

            results.append({"topic": topic, "action": action, **item})
            stats["ok"] += 1
            stats[action] += 1
            logger.info(f"  → {action} {target_label} ({topic})")
        except Exception as e:
            stats["gen_fail"] += 1
            write_error_log(f"主题 {topic!r} 精炼异常: {e}", code="REFINE_GEN")
            continue
    stats["hit_files"] = sorted(stats["hit_files"])
    return results, stats


def _parse_rules_entries(text: str) -> list[dict]:
    """从规范文件正文解析条目列表。"""
    entries = []
    cur = None
    for line in text.splitlines():
        if line.startswith("### "):
            if cur:
                entries.append(cur)
            cur = {
                "title": line[4:].strip(),
                "domain": "",
                "norm": "",
                "source": "",
                "date": "",
                "keywords": [],
            }
        elif cur:
            if line.startswith("- 领域: "):
                cur["domain"] = line[len("- 领域: ") :].strip()
            elif line.startswith("- 规范: "):
                cur["norm"] = line[len("- 规范: ") :].strip()
            elif line.startswith("- 来源: "):
                cur["source"] = line[len("- 来源: ") :].strip()
            elif line.startswith("- 提炼于: "):
                cur["date"] = line[len("- 提炼于: ") :].strip()
            elif line.startswith("- 关键词: "):
                cur["keywords"] = [
                    k.strip()
                    for k in re.split(r"[、,，]", line[len("- 关键词: ") :].strip())
                    if k.strip()
                ]
    if cur:
        entries.append(cur)
    return entries


def _render_rules_file(level: str, entries: list[dict]) -> str:
    """渲染规范文件完整内容（frontmatter + 条目区）。

    description 按规范级别定制触发语，供 _scan_skills 注册成 MCP 工具后，
    大模型据此判断何时调用：
    - global：行为约束 + 通用原则，涉及多领域 → 宽泛触发「操作前获取本行为规范」
    - 项目类型：按「开始开发该类型项目时」触发
    keywords 保留在正文条目作覆盖范围说明，不拼进 description（避免词堆）。
    """
    label = RULES_LEVELS[level]
    if level == "global":
        description = (
            f"操作前，获取本行为规范；全局通用规范，共 {len(entries)} 条，"
            f"适用于编码、审查、协作、总结等任何操作前的行为约束与通用原则。"
        )
    else:
        description = (
            f"当开始开发{label}项目时触发，获取{label}开发规范指南；"
            f"{label}通用规范，共 {len(entries)} 条。"
        )
    lines = [
        "---",
        f"name: norms_{level}",
        f"description: {description}",
        "---",
        "",
        f"# {label}规范",
        "",
        f"> 由 summarize 阶段3 自动提炼维护。条目带来源可追溯，容量上限 "
        f"{RULES_MAX_PER_FILE} 条。",
        "",
        "## 条目",
        "",
    ]
    for e in entries:
        lines.append(f"### {e['title']}")
        lines.append(f"- 领域: {e.get('domain', '')}")
        lines.append(f"- 规范: {e.get('norm', '')}")
        if e.get("keywords"):
            lines.append(f"- 关键词: {'、'.join(e['keywords'])}")
        lines.append(f"- 来源: {e.get('source', '')}")
        lines.append(f"- 提炼于: {e.get('date', '')}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _load_rules_entries(level: str) -> tuple[list[dict], Path]:
    """读取指定级别规范文件的现有条目；文件不存在时返回空列表与目标路径。"""
    path = SKILLS_RULES_DIR / f"norms_{level}.md"
    if not path.exists():
        return [], path
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        logger.warning(f"读取规范文件失败 {path}: {e}")
        return [], path
    if text.startswith("---"):
        parts = text.split("---", 2)
        if len(parts) == 3:
            text = parts[2]
    return _parse_rules_entries(text), path


def _trim_rules_entries(level: str, entries: list[dict]) -> list[dict]:
    """容量超限时由 LLM 淘汰低复用价值条目，保留不超过上限。"""
    if len(entries) <= RULES_MAX_PER_FILE:
        return entries
    item_list = "\n".join(
        f"- [{i}] {e['title']}：{e.get('norm', '')[:80]}" for i, e in enumerate(entries)
    )
    prompt = f"""\
规范文件「{RULES_LEVELS[level]}」条目超过上限 {RULES_MAX_PER_FILE} 条，需要淘汰复用价值最低的条目。

现有条目：
{item_list}

要求：保留最有复用价值、最能指导行动的 {RULES_MAX_PER_FILE} 条，淘汰过时/低复用/重复的。

返回 JSON：{{"keep_indexes": [保留的条目下标数组]}}
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    raw = _llm_chat(
        prompt,
        temperature=0.1,
        timeout=RULES_LLM_TIMEOUT,
        max_tokens=16384,
        disable_thinking=True,
    )
    if not raw:
        logger.warning(f"规范文件淘汰 LLM 调用失败，保留前 {RULES_MAX_PER_FILE} 条")
        return entries[:RULES_MAX_PER_FILE]
    parsed = _parse_json_any(raw)
    keep = parsed.get("keep_indexes", []) if parsed else []
    keep = [int(i) for i in keep if str(i).strip().isdigit()]
    kept = [entries[i] for i in keep if 0 <= i < len(entries)]
    if not kept:
        logger.warning("淘汰结果为空，保留前 N 条兜底")
        return entries[:RULES_MAX_PER_FILE]
    return kept[:RULES_MAX_PER_FILE]


def _run_phase3(groups: list[dict], today_str: str) -> dict:
    """阶段3：从本周期聚合记忆中提炼"规则/规范类"规范，写入 MCP/Skills/Rules/*.md。

    只提炼可复用、稳定、能指导行动的知识；偶遇 bug、一次性修复、
    版本绑定 workaround 不提炼。本周期有效候选 < RULES_MIN_CANDIDATES 时跳过。
    """
    if not groups:
        return {"skipped": "no_groups"}

    facts_text = "\n".join(
        f"- {g.get('topic', '')}：{g.get('facts', '')}" for g in groups
    )

    # 已有标题清单，供 LLM 提炼时避开重复
    existing_titles = {}
    for level in RULES_LEVELS:
        entries, _ = _load_rules_entries(level)
        existing_titles[level] = [e["title"] for e in entries]
    titles_block = "\n".join(
        f"[{level}] {'; '.join(titles)}" if titles else f"[{level}] （空）"
        for level, titles in existing_titles.items()
    )
    level_labels = "\n".join(f"- {k}: {v}" for k, v in RULES_LEVELS.items())

    prompt = f"""\
你正在对一批"已聚合的长期记忆"做规范提炼。聚合内容里混有「偶遇 bug / 一次性修复」与
「真正的规范 / 规则」两类。本次**只提炼后者**，宁缺毋滥。

本周期聚合记忆：
{facts_text}

### 什么是"真正的规范"（可提炼）——四条判据，满足越多越值得提炼
1. **主动约定**：事前制定的行为准则/约定，而不是踩坑后的补救措施
2. **抽象通用**：换项目、换技术栈依然成立；删掉具体库名/字段名/版本号/报错信息后，这句话仍然说得通
3. **反复出现**：同一经验在多个记忆、多个场景中重复沉淀过，而非单次偶遇
4. **架构/原则**：属于架构决策、设计原则、工程流程约定（如分层解耦、单一职责、配置用常量、提交前验证）

### 什么"不算规范"（绝不提炼）——以下情形一律丢弃
- 从某个具体 bug 修复中得出的结论（如"某字段要同时判 IS NULL 和空串""某工具参数要先探测 schema"），即使能概括成一句话
- 绑定具体报错信息/版本号/环境的一次性补救
- 单次踩坑经验，未在多场景重复出现
- 纯操作步骤记录

### 判定技巧
- 自问：如果从来没踩过那个坑，我还会主动说出这条规则吗？——不会 → 是踩坑教训，不是规范
- 自问：去掉所有技术名词后，这句话还剩什么？——剩不下 → 不够抽象，丢弃

### 提炼要求
1. 提炼 0-5 条，宁缺毋滥，无法提炼则返回空数组
2. 每条规范一句话说清、可行动、**不绑定任何具体技术细节**
3. 每条规范给出 keywords：3-5 个触发关键词/场景（覆盖技术域、动作、对象等触发面），供工具描述生成"当 xxx 时触发"信号
4. 级别 level 从以下选择，判定不了归入 global：
{level_labels}

### 避免重复
已有标题清单（新规范标题不要与它们重复/高度重叠）：
{titles_block}

返回 JSON：{{"candidates": ["判定为规范类的记忆主题列表"], "norms": [{{"title": "标题", "level": "global", "summary": "可行动的规范", "keywords": ["触发关键词1", "触发关键词2", "触发关键词3"], "source": "来源记忆主题"}}]}}
没有规范类内容时返回 {{"candidates": [], "norms": []}}。
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    raw = _llm_chat(
        prompt,
        temperature=RULES_LLM_TEMPERATURE,
        timeout=RULES_LLM_TIMEOUT,
        max_tokens=16384,
        disable_thinking=True,
    )
    if not raw:
        write_error_log("阶段3 规范提炼 LLM 调用失败", code="RULES_LLM")
        return {"skipped": "llm_failed"}
    parsed = _parse_json_any(raw)
    if not parsed:
        write_error_log(
            f"阶段3 规范提炼 JSON 解析错误：\n{raw[:1000]}", code="RULES_JSON"
        )
        return {"skipped": "json_failed"}

    candidates = parsed.get("candidates", []) or []
    norms = parsed.get("norms", []) or []
    # 门槛以实际提炼出的 norms 为准（candidates 是 LLM 自评主题列表，
    # 一个主题可提炼多条规范，数量与 norms 天然不一致，不能作门槛依据）
    if not norms:
        logger.info("阶段3 跳过：无提炼出的规范条目")
        return {"skipped": "no_norms"}
    if len(norms) < RULES_MIN_CANDIDATES:
        logger.info(f"阶段3 跳过：提炼出的规范 {len(norms)} < {RULES_MIN_CANDIDATES}")
        return {"skipped": "norms_lt_min", "count": len(norms)}

    updated = {}
    for norm in norms:
        title = str(norm.get("title", "")).strip()
        level = str(norm.get("level", "global")).strip()
        summary = str(norm.get("summary", "")).strip()
        if not title or not summary:
            continue
        if level not in RULES_LEVELS:
            level = "global"
        entries, path = _load_rules_entries(level)
        if any(e["title"] == title for e in entries):
            logger.info(f"阶段3 跳过重复规范：{title}")
            continue
        # keywords 兼容 LLM 返回字符串（逗号分隔）或数组两种形态
        kws = norm.get("keywords") or []
        if isinstance(kws, str):
            kws = re.split(r"[、,，]", kws)
        keywords = [k.strip() for k in kws if str(k).strip()]
        entries.append(
            {
                "title": title,
                "domain": RULES_LEVELS[level],
                "norm": summary,
                "keywords": keywords,
                "source": str(norm.get("source", "")).strip(),
                "date": today_str,
            }
        )
        entries = _trim_rules_entries(level, entries)
        SKILLS_RULES_DIR.mkdir(parents=True, exist_ok=True)
        path.write_text(_render_rules_file(level, entries), encoding="utf-8")
        updated[path.name] = updated.get(path.name, 0) + 1

    logger.info(f"阶段3 完成：{updated}")
    # 无实际写入时返回空字符串，main() 据此跳过 git_commit，避免空提交
    return {"updated": ", ".join(f"{k}+{v}" for k, v in updated.items())}


def _collect_tags(memories: list[dict]) -> list[str]:
    return list(set(t for m in memories for t in m.get("metadata", {}).get("tags", [])))


def _max_segment_similarity(new_content: str, existing_text: str) -> float:
    """归并内容相对目标文件既有段的最大「匹配覆盖率」（difflib，零外部依赖）。

    语义：new_content 中「被既有段逐字匹配」的字符占比，直接衡量新增信息量——
    覆盖率趋近 1 → 生成段基本是既有段的复述 → 判定无新增跳过。
    ratio 受长度差干扰（长段稀释、短段虚高），覆盖率对「改写式重复」区分度更好
    （实测 ScanTextUtil 重复覆盖率 0.767 vs 典型增量 0.595）。
    切段用多级标题（#{1,6}）而非仅 H1：多级标题组织（##/###）的文件按 H1 切会
    退化成整文件一段，相似度被不相关内容稀释（2026-08-07 根因修复）。
    """
    if not new_content or not existing_text:
        return 0.0
    best = 0.0
    for seg in re.split(r"(?m)^(?=#{1,6}\s)", existing_text):
        body = "\n".join(seg.splitlines()[1:]).strip()
        if not body:
            continue
        sm = difflib.SequenceMatcher(None, new_content, body)
        matched = sum(b.size for b in sm.get_matching_blocks())
        cov = matched / len(new_content)
        if cov > best:
            best = cov
    return best


def _relevant_segments(existing_text: str, facts: str, max_chars: int) -> str:
    """从目标笔记切出与 facts 最相关的既有段，供 merge 生成时给 LLM 做增量判断。

    原实现取 existing_text 前 N 字符：文件大时目标段在文件尾部（如既有段追加在
    末尾），LLM 看不到既有内容、无从判断重复，直接复述相关事实 → 重复段（2026-08-07
    根因修复）。改为按多级标题切段后以 facts 相似度排序，取 top 相关段，总长限 max_chars。
    无相关段（facts 空/无段）时兜底返回文件头。
    """
    if not existing_text or not facts:
        return existing_text[:max_chars]
    scored = []
    for seg in re.split(r"(?m)^(?=#{1,6}\s)", existing_text):
        if not seg.strip():
            continue
        body = "\n".join(seg.splitlines()[1:]).strip()
        if not body:
            continue
        sim = difflib.SequenceMatcher(None, facts, body).ratio()
        scored.append((sim, seg))
    scored.sort(reverse=True, key=lambda x: x[0])
    out: list[str] = []
    total = 0
    for _, seg in scored:
        if out and total + len(seg) > max_chars:
            break
        out.append(seg)
        total += len(seg)
    if not out:
        return existing_text[:max_chars]
    return "".join(out)[:max_chars]


def _strip_leading_h1(content: str) -> str:
    """剥离正文开头自带的 # 标题，避免与脚本写入的文件标题重复。"""
    lines = content.splitlines()
    while lines and re.match(r"^#\s+\S", lines[0]):
        lines.pop(0)
    return "\n".join(lines).strip()


def _merge_into_file(
    filepath: Path,
    title: str,
    content: str,
    today_str: str,
    is_append: bool,
    supersedes: bool = False,
) -> bool:
    """写入文件。新建时创建；追加时按 H1 段合并：同名 H1 段替换（去重），
    否则在末尾新增一节（保留历史）。返回是否写入成功。"""
    content = _strip_leading_h1(content)
    block = f"# {title}\n\n> 补充于 {today_str}\n\n{content}\n"
    if not is_append:
        filepath.write_text(
            f"# {title}\n\n> 自动总结于 {today_str}\n\n{content}\n",
            encoding="utf-8",
        )
        return True

    old = filepath.read_text(encoding="utf-8")
    target_slug = _normalize_slug(title)
    segments = re.split(r"(?m)^(?=#\s)", old)
    replaced = False
    out = []
    for seg in segments:
        head = seg.splitlines()[0] if seg.strip() else ""
        seg_slug = _normalize_slug(re.sub(r"^#\s+", "", head))
        if seg_slug and seg_slug == target_slug:
            # 同名 H1 段：保留旧内容，新内容追加为段内子节（防止覆盖历史）。
            # content 已被 _strip_leading_h1 剥掉首 H1，补充段需补 # {title} 防无标题块。
            old = seg.rstrip()
            if supersedes:
                # 修正类：旧段末尾标注废弃，避免新旧结论并存互否
                old += "\n\n> 已废弃（被以下补充取代）"
            out.append(
                old
                + "\n\n---\n\n# "
                + title
                + "\n\n> 补充于 "
                + today_str
                + "\n\n"
                + content
                + "\n"
            )
            replaced = True
        else:
            out.append(seg)
    merged = "".join(out) if replaced else old.rstrip() + "\n\n---\n\n" + block
    filepath.write_text(merged.rstrip() + "\n", encoding="utf-8")
    return True


def _sanitize_new_dir(dir_name: str) -> str:
    """清洗 LLM 给定的新建目录：剔除排除目录；多级嵌套仅当顶层是已有顶层时
    保留，否则回退单层（防御 LLM 造深层路径）。"""
    raw = str(dir_name or "").strip().strip("/")
    parts = [p for p in Path(raw).parts if p and p not in SUMMARY_EXCLUDE_DIRS]
    if not parts:
        return ""
    existing_tops = _existing_extract_tops()
    if len(parts) > 1 and parts[0] not in existing_tops:
        logger.warning(f"新建多级目录 {raw}，回退为单层目录 {parts[0]}")
        return parts[0]
    return "/".join(parts)


def _write_articles_v2(
    results: list[dict], today_str: str, all_tags: list[str]
) -> dict[str, str]:
    """阶段2 写入：merge/fallback_merge 直写判断目标；new 走 resolve_target_file 兜底防撞。
    写入异常逐条 try/except 记录 WRITE 错误日志，不中断其余写入。
    批写盲区修复：_run_refine 的 dup_skip 读「批写前」文件，同 run 前序待写段
    （同 target 先 merge 后 fallback_merge）看不到；写入层落盘前按磁盘当前内容复查。"""
    updated = {}
    for item in results:
        try:
            if item["action"] in ("merge", "fallback_merge"):
                filepath = EXTRACTS_DIR / item["target"]
                filepath.parent.mkdir(parents=True, exist_ok=True)
                is_append = True
                # 批写盲区修复(a)：同 run 前序已写该文件时，重读磁盘当前内容做相似度复查，
                # 拦下 fallback_merge 对前序段高度相似的重复追加（实测 sim 0.919）。
                if str(filepath) in updated:
                    cur_text = filepath.read_text(encoding="utf-8")
                    sim = _max_segment_similarity(item.get("content", ""), cur_text)
                    if sim > SUMMARY_DUP_SIM_THRESHOLD:
                        logger.warning(
                            f"批写复查：{item['target']} 与同 run 前序写入段"
                            f"相似度 {sim:.2f} 过高，跳过"
                        )
                        continue
            else:
                dir_name = _sanitize_new_dir(item["dir"])
                target_dir = EXTRACTS_DIR / dir_name if dir_name else EXTRACTS_DIR
                target_dir.mkdir(parents=True, exist_ok=True)
                filepath, is_append = resolve_target_file(target_dir, item["title"])
            ok = _merge_into_file(
                filepath,
                item["title"],
                item["content"],
                today_str,
                is_append,
                supersedes=bool(item.get("supersedes", False)),
            )
            if not ok:
                continue
            # 轻量 QC：文件体积异常时告警（不阻断）
            try:
                size = filepath.stat().st_size
                if size > 500_000:
                    logger.warning(f"QC: {filepath} 体积异常 ({size // 1024}KB)")
            except OSError:
                pass
            updated[str(filepath)] = "追加" if is_append else "新建"
            write_to_cold_layer(
                content=item["content"],
                source_file=str(filepath),
                category=filepath.parent.name or "Extracts",
                tags=all_tags,
                confidence=1.0,
            )
        except Exception as e:
            write_error_log(f"写入失败 {item.get('topic', '')!r}: {e}", code="WRITE")
            continue
    return updated


def _get_stats_db_readonly() -> sqlite3.Connection | None:
    """只读连接，用于报表生成。"""
    if not STATS_DB.exists():
        return None
    try:
        conn = sqlite3.connect(str(STATS_DB))
        conn.execute("PRAGMA busy_timeout=5000")
        conn.row_factory = sqlite3.Row
        return conn
    except Exception:
        return None


def _cleanup_old_stats() -> None:
    """清理超过 STATS_RETENTION_DAYS 的旧数据。"""
    try:
        conn = sqlite3.connect(str(STATS_DB))
        conn.execute("PRAGMA busy_timeout=5000")
        cutoff = (date.today() - timedelta(days=STATS_RETENTION_DAYS)).isoformat()
        conn.execute("DELETE FROM tool_calls WHERE called_at < ?", (cutoff,))
        conn.commit()
        conn.close()
    except Exception:
        pass


def _generate_stats_report() -> None:
    """生成 MCP 工具调用统计报表。"""
    try:
        _cleanup_old_stats()
        conn = _get_stats_db_readonly()
        if conn is None:
            content = "# MCP 工具调用统计\n\n暂无数据。"
            MCP_DIR.mkdir(parents=True, exist_ok=True)
            STATS_OUTPUT.write_text(content, encoding="utf-8")
            return

        cutoff = (date.today() - timedelta(days=STATS_DAYS)).isoformat()
        rows = conn.execute(
            """SELECT date(called_at) as day, tool_name,
                      COUNT(*) as calls,
                      SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) as errors,
                      ROUND(AVG(duration_ms), 1) as avg_duration
               FROM tool_calls
               WHERE called_at >= ?
               GROUP BY day, tool_name
               ORDER BY day DESC, calls DESC""",
            (cutoff,),
        ).fetchall()
        conn.close()

        if not rows:
            content = "# MCP 工具调用统计\n\n最近 15 天无调用记录。"
            MCP_DIR.mkdir(parents=True, exist_ok=True)
            STATS_OUTPUT.write_text(content, encoding="utf-8")
            return

        # 组装数据: {day: [(tool_name, calls, errors, avg_duration), ...]}
        days: dict[str, list] = {}
        total_calls = 0
        total_errors = 0
        for r in rows:
            day = r["day"]
            if day not in days:
                days[day] = []
            days[day].append(
                (r["tool_name"], r["calls"], r["errors"], r["avg_duration"])
            )
            total_calls += r["calls"]
            total_errors += r["errors"]

        success_rate = (
            round((total_calls - total_errors) / total_calls * 100, 1)
            if total_calls > 0
            else 100.0
        )
        day_count = len(days)
        daily_avg = round(total_calls / day_count, 1) if day_count > 0 else 0

        now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
        lines = [
            "# MCP 工具调用统计\n",
            f"> 更新于 {now_str}\n",
            "## 📊 总览\n",
            "| 指标 | 数值 |",
            "|------|------|",
            f"| 过去 {STATS_DAYS} 天总调用 | {total_calls} 次 |",
            f"| 日均 | {daily_avg} 次 |",
            f"| 成功率 | {success_rate}% |",
            "",
        ]

        sorted_days = sorted(days.keys(), reverse=True)
        for day in sorted_days:
            tool_stats = days[day]
            day_total = sum(t[1] for t in tool_stats)
            day_errors = sum(t[2] for t in tool_stats)
            max_calls = max(t[1] for t in tool_stats)
            bar_width = 20

            lines.append(f"## {day}（共 {day_total} 次）\n")
            lines.append("| 工具 | 调用 | 错误 | 平均耗时 |")
            lines.append("|:-----|:----|:----|:--------|")
            for tool_name, calls, errors, avg_dur in tool_stats:
                bar_len = max(1, round(calls / max_calls * bar_width))
                bar = "█" * bar_len
                dur_str = f"{avg_dur}ms" if avg_dur else "-"
                lines.append(f"| {tool_name} | {bar} {calls} | {errors} | {dur_str} |")
            lines.append("")

        content = "\n".join(lines)
        MCP_DIR.mkdir(parents=True, exist_ok=True)
        STATS_OUTPUT.write_text(content, encoding="utf-8")
        logger.info(
            f"工具调用统计已写入: {STATS_OUTPUT} "
            f"({day_count} 天, {total_calls} 次调用)"
        )
    except Exception as e:
        logger.warning(f"工具调用统计生成失败: {e}")


def _print_report_v2(
    today_str: str,
    memory_count: int,
    updated_files: dict[str, str],
    rules_updates: str = "",
    refine_stats: dict | None = None,
    agg_rounds: int = 0,
    skipped_processed: int = 0,
    skipped_quality: int = 0,
):
    print(f"📝 记忆总结报告 ({today_str})")
    print(f"   本次处理事实: {memory_count} 条")
    if skipped_processed or skipped_quality:
        print(
            f"   输入过滤: 已处理跳过 {skipped_processed}，"
            f"低质丢弃 {skipped_quality}"
        )
    if refine_stats:
        print(
            f"   阶段2 精炼: {refine_stats['ok']} 成功"
            f"（新建 {refine_stats['new']} / 归并 {refine_stats['merge']}），"
            f"关键词失败 {refine_stats['kw_fail']}，生成失败 {refine_stats['gen_fail']}，"
            f"过短 {refine_stats['too_short']}，"
            f"占位低质 {refine_stats.get('too_low_quality', 0)}，"
            f"重复跳过 {refine_stats.get('dup_skip', 0)}，"
            f"检索命中 {len(refine_stats['hit_files'])}"
        )
    if agg_rounds:
        print(f"   聚合收敛轮数: {agg_rounds}")
    print(f"   写入文件: {len(updated_files)} 个")
    for path, action in updated_files.items():
        print(f"     {'📄' if action == '新建' else '📎'} {path} ({action})")
    if rules_updates:
        print(f"   📐 规范提炼: {rules_updates}")
    print(f"   冷层同步: {'✓' if COLD_READY else '⚠️ 未启用'}")


def main():
    if not _acquire_single_instance():
        print("⚠️ 已有 summarize 实例在运行，跳过本次")
        return

    # 工具调用统计报表独立于总结流程，每次 summarize 运行都生成
    _generate_stats_report()

    if STATS_ONLY:
        logger.info("--stats-only 模式，跳过 AI 总结")
        return

    if not DEEPSEEK_API_KEY:
        write_error_log("DEEPSEEK_API_KEY not set", code="CONFIG")
        print("❌ DEEPSEEK_API_KEY 未设置")
        return

    if not _throttle_ai_run():
        return

    today = date.today()
    today_str = today.isoformat()
    EXTRACTS_DIR.mkdir(parents=True, exist_ok=True)

    logger.info("Fetching memories from past 3 days via REST API...")
    recent_memories = fetch_memories(today)
    if recent_memories is None:
        print("❌ 获取记忆失败")
        return
    if not recent_memories:
        print("过去 3 天无新记忆，跳过总结")
        return

    # 输入过滤：跳过已处理 + 质量门（宁缺毋滥），仅收集通过记忆的 id
    skipped_processed = len(recent_memories)
    recent_memories = _filter_processed(recent_memories)
    skipped_processed -= len(recent_memories)
    skipped_quality = len(recent_memories)
    recent_memories = _filter_memory_quality(recent_memories)
    skipped_quality -= len(recent_memories)
    if skipped_processed or skipped_quality:
        logger.info(
            f"输入过滤：已处理跳过 {skipped_processed}，低质丢弃 {skipped_quality}，"
            f"剩余 {len(recent_memories)} 条"
        )
    consumed_ids = [m["id"] for m in recent_memories if m.get("id")]
    if not recent_memories:
        print("无可处理的新记忆（均已处理或质量不合格），跳过总结")
        return

    logger.info("Scanning notes directory structure...")
    dir_tree = scan_notes_structure(NOTES_DIR)

    # 阶段1：记忆聚合（分类/合并/去重/时间线，递归收敛）
    logger.info(f"Aggregating {len(recent_memories)} memories into groups...")
    groups, agg_rounds = _run_aggregate_v2(recent_memories)
    if groups is None:
        print("⚠️ 记忆聚合失败，跳过本次总结")
        return
    if not groups:
        return

    # 阶段2：逐组「关键词 → 检索 Extracts → 判断归并/新建 → think enable 生成」
    logger.info(
        f"Phase 2: Refining {len(groups)} groups (keyword → search → merge/new)..."
    )
    writes, refine_stats = _run_refine(groups, dir_tree)
    try:
        _stats_dump = dict(refine_stats)
        if isinstance(_stats_dump.get("hit_files"), set):
            _stats_dump["hit_files"] = sorted(_stats_dump["hit_files"])
        print("REFINE_STATS=" + json.dumps(_stats_dump, ensure_ascii=False))
    except Exception:
        pass
    if not writes:
        print("所有文章生成失败或内容过短，跳过总结")
        return

    all_tags = _collect_tags(recent_memories)
    updated_files = _write_articles_v2(writes, today_str, all_tags)

    # 有落盘才标记已处理：成功消费的记忆置 bit0，避免下轮重复处理。
    # 无落盘（本轮全被 LLM 判无沉淀价值）不标记，下轮重新评估。
    if updated_files and consumed_ids:
        _mark_processed(consumed_ids)

    # 阶段3：规范提炼（规则/规范类记忆 → MCP/Skills/Rules/*.md）
    phase3 = _run_phase3(groups, today_str)
    rules_updates = phase3.get("updated", "")
    if rules_updates:
        git_commit(f"规范提炼：{rules_updates}", stage="rules")

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
    overview = f"{now_str} - 记忆总结（{len(recent_memories)} 条事实，{len(updated_files)} 个文件）"
    git_commit(overview, stage="写入后")

    _mark_run_success()

    _print_report_v2(
        today_str,
        len(recent_memories),
        updated_files,
        rules_updates,
        refine_stats,
        agg_rounds,
        skipped_processed,
        skipped_quality,
    )


if __name__ == "__main__":
    main()
