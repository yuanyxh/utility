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


def _llm_chat(prompt: str) -> str | None:
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
                "temperature": SUMMARY_LLM_TEMPERATURE,
            },
            timeout=SUMMARY_LLM_TIMEOUT,
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
    return "\n".join(
        f"- [{','.join(m.get('metadata', {}).get('tags', []))}] {m.get('content', '')}"
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


def _run_phase1(facts_text: str, dir_tree: str) -> list[dict] | None:
    existing = _list_extract_summaries()
    existing_block = "\n".join(existing) if existing else "(暂无已有笔记)"

    prompt = f"""\
你正在将过去 3 天的记忆事实整理为高质量的详细知识笔记。

现有笔记目录结构：
{dir_tree}

已有知识笔记（标题+首行摘要，用于判断是否复用已有文件）：
{existing_block}

### 要求

1. **合并关联事实**：同一主题的多条事实务必合并为一篇，不要分散
2. **只保留有长期价值的内容**，丢弃一次性/临时状态碎片信息
3. **根据现有目录结构**决定存放目录（目录路径相对于笔记根目录）：目录必须复用已有目录，或与已有目录同级的新顶层目录，禁止随意嵌套多级新目录
4. **标题要具体**，如 "UTSJSONObject null 安全访问" 而非 "UTSJSONObject 坑"
5. **优先复用已有知识笔记**：如果已有笔记与当前主题相关（标题或摘要相关），使用相同的 dir 和 title 使内容合并到同一文件，不要为相同主题另建新文件

记忆事实：
{facts_text}

返回 JSON：{{"writes": [{{"dir": "相对目录路径", "title": "具体的标题"}}]}}
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
    writes = parsed.get("writes", [])
    if not writes:
        print("无有效内容需要归档，跳过总结")
        return []
    return writes


def _run_phase2(writes: list[dict], facts_text: str, dir_tree: str) -> list[dict]:
    phase2_items = []
    for idx, item in enumerate(writes):
        target_dir_name = str(item.get("dir", "")).strip()
        title = (
            str(item.get("title", "")).strip()
            or target_dir_name.split("/")[-1]
            or "未分类"
        )
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

1. **严格基于下方"相关记忆事实"写作**：只使用其中出现的信息，禁止编造、禁止虚构不存在的 API/组件名/方法名/版本号/配置项/代码
2. 记忆事实未提供的细节**不要补造**，宁可缺省也不虚构
3. **只围绕此主题展开**，不要输出无关内容
4. 若目标文件已有内容，仅补充新的、未覆盖的信息
5. 篇幅以事实密度优先（150-500 字），不要为凑字数写空泛泛化内容
6. **直接返回 Markdown 正文**，不需要 JSON 包装，不需要代码块包裹正文

相关记忆事实：
{facts_text}"""
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
            out.append(block)
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


def _print_report(today_str: str, memory_count: int, updated_files: dict[str, str]):
    print(f"📝 记忆总结报告 ({today_str})")
    print(f"   过去 3 天事实: {memory_count} 条")
    print(f"   写入文件: {len(updated_files)} 个")
    for path, action in updated_files.items():
        print(f"     {'📄' if action == '新建' else '📎'} {path} ({action})")
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

    facts_text = _build_facts_text(recent_memories)
    phase1_writes = _run_phase1(facts_text, dir_tree)
    if phase1_writes is None:
        print("⚠️ Phase 1 分类失败，跳过本次总结")
        return
    if not phase1_writes:
        return

    logger.info(f"Phase 2: Generating content for {len(phase1_writes)} articles...")
    writes = _run_phase2(phase1_writes, facts_text, dir_tree)
    if not writes:
        print("所有文章生成失败或内容过短，跳过总结")
        return

    all_tags = _collect_tags(recent_memories)
    updated_files = _write_articles(writes, today_str, all_tags)

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
    overview = f"{now_str} - 记忆总结（{len(recent_memories)} 条事实，{len(updated_files)} 个文件）"
    git_commit(overview, stage="写入后")

    _print_report(today_str, len(recent_memories), updated_files)


if __name__ == "__main__":
    main()
