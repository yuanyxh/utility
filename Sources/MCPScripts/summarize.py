#!/usr/bin/env python3
"""
记忆总结流水线 — 由 Utility TaskScheduler 触发（非 server.py 调度）

用法：
  python3 summarize.py                    # 完整流程：统计报表 + AI 总结
  python3 summarize.py --stats-only       # 仅生成统计报表，跳过 AI 总结

流程：
1. 从 mino-brain REST API 获取过去 3 天记忆
2. 扫描笔记目录结构（排除 SaveWebPages/Self_Data/Works/Works_Jobs）
3. LLM 去重/筛选/按现有目录结构分类（严格基于记忆事实，禁止编造）
4. 写入 Markdown（同标题 H1 段合并去重，异标题末尾新增一节）
5. 同步写入冷层 Qdrant（按内容哈希去重，通过 REST API）
6. 异常 → 写入流水线错误日志

防重复触发：
- 单实例文件锁：同一时刻只允许一个实例运行
- 最小间隔节流：与上次完整总结间隔 < 6 小时则跳过
"""

import argparse
import os
import json
import sqlite3
import time
import re
import fcntl
import hashlib
import subprocess
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
SUMMARY_LLM_RETRIES = 3
SUMMARY_API_TIMEOUT = 10
SUMMARY_GIT_TIMEOUT = 30

# ── 阶段1 记忆聚合（先分类/合并/去重，再走原总结逻辑） ──
AGGREGATE_BATCH_THRESHOLD = 120  # 记忆条数超过此值分批聚合
AGGREGATE_BATCH_SIZE = 120  # 每批条数
AGGREGATE_LLM_TEMPERATURE = 0.2  # 聚合允许归纳，比生成略高
AGGREGATE_LLM_TIMEOUT = 120

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
    """距上次完整总结不足 MIN_RUN_INTERVAL 时返回 False（防重复触发）。"""
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
        LAST_RUN_FILE.write_text(str(now))
        return True
    except Exception:
        return True


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
    prompt: str, temperature: float | None = None, timeout: float | None = None
) -> str | None:
    try:
        resp = _HTTP.post(
            f"{SUMMARY_API_URL}/chat/completions",
            headers={
                "Authorization": f"Bearer {DEEPSEEK_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": SUMMARY_MODEL,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": (
                    temperature if temperature is not None else SUMMARY_LLM_TEMPERATURE
                ),
            },
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
            return None


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


def _build_facts_text(memories: list[dict]) -> str:
    # 记忆项正文在 `memory` 键（REST API 返回），`content` 键不存在 → 读错会拿到空
    return "\n".join(
        f"- [{','.join(m.get('metadata', {}).get('tags', []))}] "
        f"{m.get('memory') or m.get('content') or ''}"
        for m in memories
    )


def _list_extract_summaries() -> list[str]:
    """List existing extract notes (title + first content line) for dedup context."""
    entries = []
    if not EXTRACTS_DIR.exists():
        return entries
    for f in sorted(EXTRACTS_DIR.rglob("*.md")):
        stem = f.stem
        title = re.sub(r"_\d{4}-\d{2}-\d{2}$", "", stem)
        title = title.replace("_", " ")
        excerpt = ""
        try:
            for ln in f.read_text(encoding="utf-8").splitlines():
                s = ln.strip()
                if s and not s.startswith(("#", ">", "---", "-", "|", "```")):
                    excerpt = s[:80]
                    break
        except Exception:
            pass
        entries.append(f"- {title}（{f.parent.name}/）: {excerpt}")
    return entries


def _run_aggregate(memories: list[dict]) -> list[dict] | None:
    """阶段1：将原始记忆按主题分类、组内合并去重、丢弃一次性临时信息。

    返回 [{"topic", "facts", "tags"}, ...]，每组对应一篇后续笔记。
    超过 AGGREGATE_BATCH_THRESHOLD 条时按 AGGREGATE_BATCH_SIZE 分批聚合，
    分批后对 topic 相同/相近的组再做一次跨批合并。
    """
    batches: list[list[dict]] = []
    if len(memories) > AGGREGATE_BATCH_THRESHOLD:
        for i in range(0, len(memories), AGGREGATE_BATCH_SIZE):
            batches.append(memories[i : i + AGGREGATE_BATCH_SIZE])
    else:
        batches = [memories]

    groups: list[dict] = []
    for bi, batch in enumerate(batches):
        facts_text = _build_facts_text(batch)
        batch_label = f"（{bi + 1}/{len(batches)} 批）" if len(batches) > 1 else ""

        prompt = f"""\
你正在对一批记忆事实做聚合预处理：按主题分类、组内合并去重、丢弃无长期价值的一次性信息。

记忆事实{batch_label}：
{facts_text}

### 要求

1. **按主题分组**：语义相近/同一主题的事实归为同一组
2. **组内合并去重**：同一件事的重复/相似记录合并为一条连贯文本，不要重复罗列
3. **评估沉淀价值（retain）**：每组判断是否值得沉淀为长期知识笔记——
   - **retain=true**：含可长期复用的知识，如技术方案、架构决策、踩坑与解决办法、可复用的经验结论
   - **retain=false**：纯临时工作记录，如任务编号流水、无细节的单条调研痕迹、过程性碎片（"对 X 做了调研""讨论了 Y"）、几天后即无意义的中间态
   - **宁可遗漏，不要产出临时记录**
4. **丢弃一次性信息**：临时状态、过时配置、纯日志类碎片不进入分组
5. **主题要具体**：如 "蓝牙打印机 SDK 集成" 而非 "打印"
6. **只保留记忆中出现的信息**：禁止编造、禁止虚构不存在的 API/组件名/方法名/版本号/配置项/代码/数据

返回 JSON：{{"groups": [{{"topic": "具体主题", "facts": "合并去重后的事实文本", "tags": ["标签"], "retain": true}}]}}
没有有效内容时返回 {{"groups": []}}。
只返回严格标准的 JSON 对象，不要代码块包裹。"""
        raw = _llm_chat(
            prompt,
            temperature=AGGREGATE_LLM_TEMPERATURE,
            timeout=AGGREGATE_LLM_TIMEOUT,
        )
        if not raw:
            write_error_log(
                f"聚合批 {bi + 1}/{len(batches)} LLM 调用失败", code="AGGREGATE_LLM"
            )
            return None
        parsed = _parse_json_any(raw)
        if not parsed:
            write_error_log(
                f"聚合批 {bi + 1}/{len(batches)} JSON 解析错误：\n{raw[:1000]}",
                code="AGGREGATE_JSON",
            )
            return None
        groups.extend(parsed.get("groups", []) or [])

    if not groups:
        print("聚合无有效主题，跳过总结")
        return []

    # 分批聚合时跨批二次合并：topic 相同/相近的组收敛为一组
    if len(batches) > 1:
        groups = _merge_cross_batch_groups(groups)

    # 只保留有长期沉淀价值的组（retain=true）；缺失时按 false 处理（宁缺毋滥）
    retained = []
    for g in groups:
        if g.get("retain") not in (True, "true", "True"):
            logger.info(f"聚合丢弃无沉淀价值组：{g.get('topic', '')!r}")
            continue
        if not str(g.get("facts", "")).strip():
            continue
        retained.append(g)
    return retained


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

返回 JSON：{{"groups": [{{"topic": "合并后主题", "facts": "合并后的完整事实文本", "tags": ["标签"], "retain": true}}]}}
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    raw = _llm_chat(
        prompt,
        temperature=AGGREGATE_LLM_TEMPERATURE,
        timeout=AGGREGATE_LLM_TIMEOUT,
    )
    if not raw:
        logger.warning("跨批二次合并 LLM 调用失败，保留原分组")
        return groups
    parsed = _parse_json_any(raw)
    if not parsed or not parsed.get("groups"):
        logger.warning("跨批二次合并解析失败，保留原分组")
        return groups
    return parsed["groups"]


def _run_phase1(groups: list[dict], dir_tree: str) -> list[dict] | None:
    existing = _list_extract_summaries()
    existing_block = "\n".join(existing) if existing else "(暂无已有笔记)"
    groups_block = "\n".join(
        f"- [{i}] {g.get('topic', '')}：{g.get('facts', '')[:120]}"
        for i, g in enumerate(groups)
    )

    prompt = f"""\
你正在将过去 3 天的记忆事实整理为高质量的详细知识笔记。

以下为已按主题聚合的记忆组（每组对应一篇笔记，请每组独立成篇，不要合并组）：
{groups_block}

现有笔记目录结构：
{dir_tree}

已有知识笔记（标题+首行摘要，用于判断是否复用已有文件）：
{existing_block}

### 要求

1. **宁缺毋滥**：输入组虽经价值评估，但若某组主题仍是临时工作记录或信息量不足以成篇，直接忽略该组，不要为其创建写入目标；产出 0 篇是可接受的结果
2. **每组独立成篇**：每个记忆组生成一个写入目标，不要合并不同组
3. **只保留有长期价值的内容**，丢弃一次性/临时状态碎片信息
4. **根据现有目录结构**决定存放目录（目录路径相对于笔记根目录）：目录必须复用已有目录，或与已有目录同级的新顶层目录，禁止随意嵌套多级新目录
5. **标题要具体**，如 "UTSJSONObject null 安全访问" 而非 "UTSJSONObject 坑"
6. **优先复用已有知识笔记**：如果已有笔记与当前主题相关（标题或摘要相关），使用相同的 dir 和 title 使内容合并到同一文件，不要为相同主题另建新文件

返回 JSON：{{"writes": [{{"group_index": 记忆组序号, "dir": "相对目录路径", "title": "具体的标题"}}]}}
没有有效内容时返回 {{}}。
只返回严格标准的 JSON 对象，不要代码块包裹。"""
    raw = _llm_chat(prompt)
    if not raw:
        write_error_log("Phase 1 LLM 调用失败", code="PHASE1_LLM")
        return None
    parsed = _parse_json_any(raw)
    if not parsed:
        write_error_log(f"Phase 1 JSON 解析错误：\n{raw[:1000]}", code="PHASE1_JSON")
        return None
    # 防御：group_index 越界/缺失的写入目标剔除，避免 Phase 2 无对应事实
    writes = []
    for w in parsed.get("writes", []):
        gi = w.get("group_index")
        if isinstance(gi, int) and 0 <= gi < len(groups):
            w["group_index"] = gi
            writes.append(w)
        else:
            logger.warning(
                f"Phase 1 写入目标 group_index={gi!r} 越界/缺失，剔除 '{w.get('title', '')}'"
            )
    if not writes:
        print("无有效内容需要归档，跳过总结")
        return []
    return writes


def _run_phase2(writes: list[dict], groups: list[dict], dir_tree: str) -> list[dict]:
    phase2_items = []
    for idx, item in enumerate(writes):
        target_dir_name = str(item.get("dir", "")).strip()
        title = (
            str(item.get("title", "")).strip()
            or target_dir_name.split("/")[-1]
            or "未分类"
        )
        # 取对应组的聚合事实作为上下文；越界/缺失时跳过该篇
        group_index = item.get("group_index")
        group_facts = ""
        if isinstance(group_index, int) and 0 <= group_index < len(groups):
            group_facts = str(groups[group_index].get("facts", "")).strip()
        if not group_facts:
            logger.warning(
                f"Skipping '{title}': group_index={group_index!r} 无聚合事实"
            )
            continue
        target_parts = Path(target_dir_name).parts
        if any(part in SUMMARY_EXCLUDE_DIRS for part in target_parts):
            logger.warning(f"Skipping excluded path: {target_dir_name}")
            continue

        # 目录白名单：新顶层目录只允许单层，禁止随意嵌套多级新目录
        parts = [p for p in Path(target_dir_name).parts if p]
        if len(parts) > 1:
            existing_tops = (
                {d.name for d in EXTRACTS_DIR.iterdir() if d.is_dir()}
                if EXTRACTS_DIR.exists()
                else set()
            )
            if parts[0] not in existing_tops:
                logger.warning(
                    f"新建多级目录 {target_dir_name}，回退为单层目录 {parts[0]}"
                )
                target_dir_name = parts[0]

        # 读取目标文件已有内容，追加时避免与旧内容重复
        existing_excerpt = ""
        filepath, is_append = resolve_target_file(EXTRACTS_DIR / target_dir_name, title)
        if is_append and filepath.exists():
            existing_excerpt = filepath.read_text(encoding="utf-8")[:1200]

        context_block = (
            f"### 目标文件已有内容（补充时只写新增信息，不要重复）\n{existing_excerpt}"
            if existing_excerpt
            else "（目标文件不存在，将新建）"
        )

        prompt = f"""\
你正在将过去 3 天的记忆事实整理为详细的知识笔记。

主题："{title}"
存放目录：{target_dir_name}

{context_block}

### 生成要求

1. **严格基于下方"相关记忆事实"写作**：只使用其中出现的信息，禁止编造、禁止虚构不存在的 API/组件名/方法名/版本号/配置项/代码/数据
2. 记忆事实未提供的细节**不要补造**，宁可缺省也不虚构
3. **只围绕此主题展开**，不要输出无关内容
4. 若目标文件已有内容，仅补充新的、未覆盖的信息
5. 篇幅以事实密度优先（150-500 字），不要为凑字数写空泛泛化内容
6. **直接返回 Markdown 正文**，不需要 JSON 包装，不需要代码块包裹正文

相关记忆事实：
{group_facts}"""
        content = None
        for attempt in range(SUMMARY_LLM_RETRIES):
            logger.info(
                f"  Generating '{title}' (attempt {attempt + 1}/{SUMMARY_LLM_RETRIES})..."
            )
            raw = _llm_chat(prompt)
            if raw:
                content = raw.strip()
                break
            if attempt < SUMMARY_LLM_RETRIES - 1:
                time.sleep(3 * (attempt + 1))
        if not content or len(content) < SUMMARY_MIN_CONTENT_LEN:
            logger.warning(
                f"Skipping '{title}': content too short "
                f"({len(content) if content else 0} < {SUMMARY_MIN_CONTENT_LEN})"
            )
            continue
        phase2_items.append(
            {"dir": target_dir_name, "title": title, "content": content}
        )
    return phase2_items


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
    raw = _llm_chat(prompt, temperature=0.1, timeout=RULES_LLM_TIMEOUT)
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
        prompt, temperature=RULES_LLM_TEMPERATURE, timeout=RULES_LLM_TIMEOUT
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


def _strip_leading_h1(content: str) -> str:
    """剥离正文开头自带的 # 标题，避免与脚本写入的文件标题重复。"""
    lines = content.splitlines()
    while lines and re.match(r"^#\s+\S", lines[0]):
        lines.pop(0)
    return "\n".join(lines).strip()


def _merge_into_file(
    filepath: Path, title: str, content: str, today_str: str, is_append: bool
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
            # 同名 H1 段：保留旧内容，新内容追加为段内子节（防止覆盖历史）
            out.append(
                seg.rstrip()
                + "\n\n---\n\n> 补充于 "
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


def _write_articles(
    writes: list[dict], today_str: str, all_tags: list[str]
) -> dict[str, str]:
    updated = {}
    for item in writes:
        target_dir_name = item["dir"]
        content = item["content"]
        title = item["title"]
        target_dir = EXTRACTS_DIR / target_dir_name
        target_dir.mkdir(parents=True, exist_ok=True)
        filepath, is_append = resolve_target_file(target_dir, title)
        if _merge_into_file(filepath, title, content, today_str, is_append):
            # 轻量 QC：文件体积异常时告警（不阻断）
            try:
                size = filepath.stat().st_size
                if size > 500_000:
                    logger.warning(f"QC: {filepath} 体积异常 ({size // 1024}KB)")
            except OSError:
                pass
            updated[str(filepath)] = "追加" if is_append else "新建"
            write_to_cold_layer(
                content=content,
                source_file=str(filepath),
                category=target_dir_name,
                tags=all_tags,
                confidence=1.0,
            )
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


def _print_report(
    today_str: str,
    memory_count: int,
    updated_files: dict[str, str],
    rules_updates: str = "",
):
    print(f"📝 记忆总结报告 ({today_str})")
    print(f"   过去 3 天事实: {memory_count} 条")
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

    logger.info("Scanning notes directory structure...")
    dir_tree = scan_notes_structure(NOTES_DIR)

    # 阶段1：记忆聚合（分类/合并/去重/分批）
    logger.info(f"Aggregating {len(recent_memories)} memories into groups...")
    groups = _run_aggregate(recent_memories)
    if groups is None:
        print("⚠️ 记忆聚合失败，跳过本次总结")
        return
    if not groups:
        return

    phase1_writes = _run_phase1(groups, dir_tree)
    if phase1_writes is None:
        print("⚠️ Phase 1 分类失败，跳过本次总结")
        return
    if not phase1_writes:
        return

    logger.info(f"Phase 2: Generating content for {len(phase1_writes)} articles...")
    writes = _run_phase2(phase1_writes, groups, dir_tree)
    if not writes:
        print("所有文章生成失败或内容过短，跳过总结")
        return

    all_tags = _collect_tags(recent_memories)
    updated_files = _write_articles(writes, today_str, all_tags)

    # 阶段3：规范提炼（规则/规范类记忆 → MCP/Skills/Rules/*.md）
    phase3 = _run_phase3(groups, today_str)
    rules_updates = phase3.get("updated", "")
    if rules_updates:
        git_commit(f"规范提炼：{rules_updates}", stage="rules")

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
    overview = f"{now_str} - 记忆总结（{len(recent_memories)} 条事实，{len(updated_files)} 个文件）"
    git_commit(overview, stage="写入后")

    _print_report(today_str, len(recent_memories), updated_files, rules_updates)


if __name__ == "__main__":
    main()
