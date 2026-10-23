#!/usr/bin/env python3
"""
Memory-summary pipeline — triggered by the Utility TaskScheduler (not scheduled by server.py)

Usage:
  python3 summarize.py                    # Full flow: AI summary

Refactor (2026-08-30, phase 3): LLM/error logging -> summary_llm.py; phase 3 rules
extraction -> summary_rules.py; terminal report printing -> summary_stats.py; this
entry point keeps the core pipeline (memory fetch / aggregate / refine / write /
single-instance throttle) and main().
"""

import difflib
import fcntl
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from utility.core import prompt_loader
from utility.core.config import (
    data_dir,
    notes_dir,
    note_exclude_dirs,
    note_extensions,
    summary_exclude_tags,
)
from utility.core.l10n import all_templates, t
from utility.core.memory_lifecycle import (
    COLD_SOURCE_MEMORY_IDS_FIELD,
    PROCESSED_CONSUMED_MASK,
    PROCESSED_FIELD,
    STATUS_ACTIVE,
    STATUS_FIELD,
)
from utility.core.log_utils import (
    setup_logging as _log_setup,
)
from utility.services.summarize.summary_llm import (
    _HTTP,
    AI_API_KEY,
    SUMMARY_LLM_TIMEOUT,
    _llm_chat,
    _parse_json_any,
    write_error_log,
)
from utility.services.summarize.summary_rules import _run_phase3
from utility.services.summarize.summary_stats import _print_report_v2

logger = _log_setup("summarize")

NOTES_DIR = Path(notes_dir())

# Empty string = injected by the Swift layer via an environment variable; when not injected, related features are disabled
MEMORY_SERVER_URL = os.environ.get("MEMORY_SERVER_URL", "")

#: Directories skipped when reading the notes tree. Empty = skip nothing; the
#: list is fully user-configured (`mcp.noteExcludeDirs`). Put "Extracts" there
#: if summaries must not rescan their own output.
SUMMARY_EXCLUDE_DIRS = note_exclude_dirs()

#: Extensions listed in the notes-tree prompt. Empty config = markdown only.
SUMMARY_NOTE_EXTENSIONS = note_extensions((".md",))

SUMMARY_MEMORY_DAYS = 3

SUMMARY_MEMORY_LIMIT = 200

EXTRACTS_DIR = NOTES_DIR / "Extracts"

SUMMARY_MIN_CONTENT_LEN = 150

SUMMARY_GIT_TIMEOUT = 30

AGGREGATE_BATCH_THRESHOLD = 60

AGGREGATE_BATCH_SIZE = 60

AGGREGATE_LLM_TEMPERATURE = 0.2

#: LLM timeout for batch aggregation. Same source (config `ai.llmTimeout`) -- the
#: aggregate output is longer (max_tokens relaxed to 16384), but it hits the same
#: upstream timeout, so it shares the value with single summary instead of each
#: writing its own.
AGGREGATE_LLM_TIMEOUT = SUMMARY_LLM_TIMEOUT

AGGREGATE_MAX_ROUNDS = 3

SUMMARY_KEYWORD_MAX_TOKENS = 8192

SUMMARY_JUDGE_MAX_TOKENS = 8192

SUMMARY_GEN_MAX_TOKENS = 16384

SUMMARY_SEARCH_LIMIT = 5

SEARCH_MIN_TOKEN_LEN = 2

SUMMARY_KEYWORD_COUNT = 8

SUMMARY_MERGE_CONTEXT_CHARS = 2000

SUMMARY_MERGE_LOOKBACK_CHARS = 8000

SUMMARY_DUP_SIM_THRESHOLD = 0.7

SUMMARY_TOPIC_JACCARD = 0.05

SUMMARY_FRAGMENT_LINE_MIN = 10


def _marker_set(key: str) -> tuple[str, ...]:
    """Union of a newline-separated marker list across languages.

    Detection must work for content generated under either language (and for memories
    written before the language changed), so every language's markers are accepted.
    """
    markers: list[str] = []
    for template in all_templates(key).values():
        markers.extend(line.strip() for line in template.splitlines() if line.strip())
    return tuple(dict.fromkeys(markers))


SUMMARY_PLACEHOLDER_PATTERNS = _marker_set("mcp.summary.placeholder_markers")

MEMORY_QUALITY_MIN_LEN = 15

MEMORY_QUALITY_RESIDUAL_MIN = 12

MEMORY_QUALITY_HALF_MAX = 60

MEMORY_QUALITY_CN_SHORT_MAX = 50

MEMORY_QUALITY_REVIEW_VOTES = 3

MEMORY_QUALITY_LLM_THREADS = 4

QUALITY_TRUNC_PLACEHOLDERS = _marker_set("mcp.summary.truncation_markers")

_QUALITY_TRUNC_RE = re.compile(
    r"(?:内容|相关)?内容截断[（(]?[，,、]?(?:时|此处)?[）)]?仅?保留(?:已有|此)(?:信息|内容)"
    r"|(?:content\s+)?truncated[,;:]?\s*(?:only\s+)?(?:the\s+)?(?:existing\s+)?information\s+(?:kept|retained)"
    r"|only\s+(?:the\s+)?(?:existing|this)\s+information\s+(?:kept|retained)",
    re.IGNORECASE,
)

QUALITY_NONTRUNC_PLACEHOLDERS = _marker_set("mcp.summary.placeholder_markers")

QUALITY_PLACEHOLDER_SUBS = _marker_set("mcp.summary.placeholder_subterms")

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


UTILITY_DATA_DIR = Path(data_dir())

LOCK_FILE = UTILITY_DATA_DIR / "summarize.lock"

LAST_RUN_FILE = UTILITY_DATA_DIR / "summarize_last_run"

MIN_RUN_INTERVAL = 6 * 3600

COLD_SYNC_DB = UTILITY_DATA_DIR / "cold_sync.sqlite"


def _acquire_single_instance() -> bool:
    """Acquire the single-instance file lock. Returns False when an instance is already running (the caller exits)."""
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
        return True


def _throttle_ai_run() -> bool:
    """Returns False when less than MIN_RUN_INTERVAL has elapsed since the last full summary (prevents duplicate triggering).

    Read-only check; does not update last_run -- only _mark_run_success() records the
    time after a summary completes successfully, avoiding "write at run start" making a
    retry impossible within the 6h window after a failure.
    """
    try:
        UTILITY_DATA_DIR.mkdir(parents=True, exist_ok=True)
        now = time.time()
        last = (
            float(LAST_RUN_FILE.read_text().strip()) if LAST_RUN_FILE.exists() else 0.0
        )
        if now - last < MIN_RUN_INTERVAL:
            logger.info(
                f"Less than {MIN_RUN_INTERVAL // 3600} hours since the last summary, skipping (duplicate-trigger guard)"
            )
            return False
        return True
    except Exception:
        return True


def _mark_run_success() -> None:
    """Record last_run after a summary completes successfully, starting a new duplicate-prevention cooldown."""
    try:
        UTILITY_DATA_DIR.mkdir(parents=True, exist_ok=True)
        LAST_RUN_FILE.write_text(str(time.time()))
    except Exception:
        pass


def _cold_already_synced(content: str, source_file: str) -> bool:
    """Dedup by source_file+content hash: skip content already synced, to avoid duplicate writes to the cold layer."""
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
    source_memory_ids: list | None = None,
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
                COLD_SOURCE_MEMORY_IDS_FIELD: source_memory_ids or [],
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
                elif entry.suffix.lower() in SUMMARY_NOTE_EXTENSIONS:
                    lines.append("  " * depth + f"- {name}")
        except PermissionError:
            lines.append("  " * depth + t("mcp.summary.no_permission"))
        return lines

    return "\n".join(_scan(root)) if root.exists() else t("mcp.summary.empty_tree")


def _normalize_slug(s: str) -> str:
    """Normalize a title/slug for fuzzy dedup matching."""
    # Remove parenthetical content: （...）(...)
    s = re.sub(r"[（(][^）)]*[）)]", "", s)
    # Strip the .md suffix to avoid producing a .md.md double-suffix filename
    s = re.sub(r"\.md$", "", s, flags=re.IGNORECASE)
    # Normalize spaces, colons, slashes to underscores
    s = re.sub(r"[\s:/]+", "_", s)
    # Collapse multiple underscores
    s = re.sub(r"_+", "_", s).strip("_")
    return s.lower()


def resolve_target_file(target_dir: Path, title: str) -> tuple[Path, bool]:
    slug = _normalize_slug(title)
    if not slug:
        slug = t("mcp.summary.uncategorized")
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
    # A cross-directory hit would append to an old file and misplace content, so we do
    # not match across directories; overly short slugs have a low fuzzy-match hit rate
    # and misfire easily (e.g. "devflow" would match everything), so only enable for >=4 chars.
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
            write_error_log(f"git add failed{label}: {err[:300]}", code="GIT_ADD")
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
            logger.info(f"[git]{label} no changes, skipping commit")
            return True
        else:
            write_error_log(f"git commit failed{label}: {out[:300]}", code="GIT_COMMIT")
            logger.warning(f"[git]{label} commit failed: {out[:200]}")
            return False
    except subprocess.TimeoutExpired:
        write_error_log(f"git operation timed out{label}", code="GIT_TIMEOUT")
        return False
    except Exception as e:
        write_error_log(f"git exception{label}: {e}", code="GIT_ERROR")
        logger.warning(f"[git]{label} commit failed: {e}")
        return False


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
        write_error_log(f"Failed to fetch memories: {e}", code="FETCH_MEMORY")
        return None


def _filter_processed(memories: list[dict]) -> list[dict]:
    """Skip summarized (bit0) and retired (bit1) memories, plus non-active lifecycle states.

    bit1 is the belt-and-braces signal: even a consumer that only reads processed will
    not re-digest content a newer revision replaced.
    """
    kept = []
    for m in memories:
        # metadata may be explicitly null (key present, value None); `.get("metadata", {})` would return None and raise AttributeError
        meta = m.get("metadata") or {}
        flags = int(meta.get(PROCESSED_FIELD, 0) or 0)
        if flags & PROCESSED_CONSUMED_MASK:
            continue
        if str(meta.get(STATUS_FIELD) or STATUS_ACTIVE) != STATUS_ACTIVE:
            continue
        kept.append(m)
    return kept


def _filter_by_tags(memories: list[dict]) -> list[dict]:
    """Skip memories containing excluded tags (workflow/format entries, not technical knowledge).

    The excluded-tag list is read from the SUMMARY_EXCLUDE_TAGS environment variable
    (comma-separated), or from the mcp.excludeTags config in config.yaml.
    """
    exclude = summary_exclude_tags()
    if not exclude:
        return memories
    kept = []
    skipped = 0
    for m in memories:
        tags = set((m.get("metadata") or {}).get("tags", []))
        if tags & exclude:
            skipped += 1
            logger.debug(
                "tag filter skip: tags=%s | %s",
                tags & exclude,
                str(m.get("memory", ""))[:50],
            )
        else:
            kept.append(m)
    if skipped:
        logger.info(
            f"tag filter skipped {skipped} entries (excluded tags: {exclude}), {len(kept)} remaining"
        )
    return kept


def _quality_strip_quoted(text: str) -> str:
    """Remove content inside paired quotes and return the text "outside quotes". Used to exempt placeholder references in meta-discussion."""
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
    """Count of remaining meaningful CJK characters after removing placeholder strings and punctuation/digits/English."""
    t = text.lower()
    for p in QUALITY_PLACEHOLDER_SUBS:
        t = t.replace(p.lower(), "")
    t = re.sub(r"[\s\-*#.。，、：:（）()【】\[\]0-9A-Za-z_`|/\\]+", "", t)
    return len(t)


def _has_cjk(text: str) -> bool:
    return any("一" <= ch <= "鿿" for ch in text)


def _quality_is_cn_short_snapshot(t: str) -> bool:
    """Short CJK sentence + state verb -> possibly a state snapshot. Sent to the LLM for review (no hard drop), zero false positives."""
    c = "".join(t.split())
    if len(c) >= MEMORY_QUALITY_CN_SHORT_MAX:
        return False
    if not _has_cjk(t):
        return False
    return any(v in t for v in _QUALITY_CN_STATE_VERBS)


def _quality_rule_judge(text: str) -> tuple[str, str]:
    """Scheme E v5 rule layer (deterministic, zero LLM): returns (drop/keep/review, reason).

    Core idea: treat the "truncation placeholder" itself as a hard-defect signal, rather
    than using residual information as a weak proxy -- a truncated memory naturally keeps
    a complete prefix -> residual is sufficient -> the old scheme missed it; here, the
    presence of a placeholder string means drop.
    """
    t = text.strip()
    compact = "".join(t.split())
    if len(compact) < MEMORY_QUALITY_MIN_LEN:
        return "drop", f"too short ({len(compact)}<{MEMORY_QUALITY_MIN_LEN})"
    if _QUALITY_EMPTY_TITLE.match(t):
        return "drop", "empty-value title (no content after the title)"
    # Half-word truncation: ends with a residual EN/CN word fragment and is short overall
    if (_QUALITY_HALF_TRUNC.search(t) or _QUALITY_HALF_CN.search(t)) and len(
        compact
    ) < MEMORY_QUALITY_HALF_MAX:
        return "drop", "half-word truncation"
    # Core: unquoted truncation placeholder string -> drop. strip_quoted first, then
    # compact-normalize, so newlines/spaces no longer split the placeholder string
    # (Workflow measured the missed-match form 「内容截断，保留已有\n信息」).
    outside = _quality_strip_quoted(t)
    outside_compact = "".join(outside.split()).lower()
    for p in QUALITY_TRUNC_PLACEHOLDERS:
        if "".join(p.split()).lower() in outside_compact:
            return "drop", f"unquoted truncation placeholder string ({p})"
    if _QUALITY_TRUNC_RE.search(outside_compact):
        return "drop", "unquoted truncation placeholder string (regex fallback)"
    # Quoted truncation placeholder -> borderline (same compact match, likely meta-discussion)
    compact_all = "".join(t.split()).lower()
    if any(
        "".join(p.split()).lower() in compact_all for p in QUALITY_TRUNC_PLACEHOLDERS
    ) or _QUALITY_TRUNC_RE.search(compact_all):
        return (
            "review",
            "quoted truncation placeholder string (likely meta-discussion, sent to LLM for review)",
        )
    # Other placeholder words -> residual-information judgment
    if any(p.lower() in t.lower() for p in QUALITY_NONTRUNC_PLACEHOLDERS):
        # The residual metric counts CJK characters only; it reads every English-only text
        # as "0 residual" and would hard-drop legitimate English memories. Defer those to
        # the LLM judge instead.
        if not _has_cjk(t):
            return (
                "keep",
                "placeholder word in non-CJK text (residual metric not applicable)",
            )
        rc = _quality_residual_chars(t)
        if rc < MEMORY_QUALITY_RESIDUAL_MIN:
            return (
                "drop",
                f"placeholder word with insufficient residual information ({rc}<{MEMORY_QUALITY_RESIDUAL_MIN})",
            )
        return (
            "keep",
            f"placeholder word but sufficient residual information ({rc} chars)",
        )
    # Borderline samples: English snapshot starting with User / short CJK state snapshot
    if t and len(t) < 200 and _QUALITY_USER_SNAPSHOT.match(t):
        return (
            "review",
            "English snapshot starting with User (possibly a state snapshot, sent to LLM for review)",
        )
    if _quality_is_cn_short_snapshot(t):
        return (
            "review",
            "short CJK sentence containing a state verb (possibly a state snapshot, sent to LLM for review)",
        )
    return "keep", "passed as normal"


def _quality_llm_judge_once(text: str) -> str:
    """Single LLM quality judgment, returns keep/drop/ERR (parse failure or exception, fail-open)."""
    raw = _llm_chat(
        # The user prefix is a prompt too: it was hardcoded as `f"记忆内容：\n{text}"`,
        # which under English would pair a Chinese prefix with an English system. The
        # system and user each have their own template file (see prompt_loader).
        prompt_loader.prompt("quality_judge_user", text=text),
        temperature=0,
        max_tokens=200,
        system_prompt=prompt_loader.prompt("quality_judge"),
    )
    if not raw:
        return "ERR"
    m = re.search(r'"judge"\s*:\s*"(\w+)"', raw)
    j = m.group(1) if m else ""
    return j if j in ("keep", "drop") else "ERR"


def _quality_llm_review(reviews: list[dict]) -> tuple[list[dict], list[dict]]:
    """LLM 3-vote review of borderline samples: drop only when all 3 votes are drop, otherwise keep (fail-open).

    Lesson: fail-closed drop permanently harms high-value memories under concurrent
    rate limiting (measured 3/3 ERR); LLM judgment on borderline memories is
    probabilistic, so the most conservative policy avoids false positives, with the
    aggregate layer's retain=false as a backstop.
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
    """Memory input quality gate (Scheme E v5): deterministic drop at the rule layer + LLM 3-vote review of borderline cases.

    Dropped memories are not marked processed -- they keep a chance to be re-evaluated next time.
    """
    kept: list[dict] = []
    reviews: list[dict] = []
    rule_dropped = 0
    for m in memories:
        text = str(m.get("memory") or m.get("content") or "")
        j, why = _quality_rule_judge(text)
        if j == "drop":
            rule_dropped += 1
            logger.debug(f"quality-gate rule drop: {why} | {text[:50]!r}")
        elif j == "review":
            reviews.append(m)
        else:
            kept.append(m)
    if reviews:
        r_kept, r_dropped = _quality_llm_review(reviews)
        logger.info(
            f"quality-gate LLM review of {len(reviews)} borderline items: drop {len(r_dropped)}, keep {len(r_kept)}"
        )
        kept += r_kept
    if rule_dropped:
        logger.info(f"quality-gate rule layer dropped {rule_dropped} entries")
    return kept


def _mark_processed(memory_ids: list[str], bit: int = 0) -> int:
    """Batch-set the processed bit to 1 for memories (called after a successful write). A failure does not block the summary; returns the success count."""
    if not memory_ids:
        return 0
    try:
        resp = _HTTP.post(
            f"{MEMORY_SERVER_URL}/api/memories/processed",
            json={"memory_ids": memory_ids, "bit": bit, "value": 1},
        )
        resp.raise_for_status()
        updated = resp.json().get("updated", 0)
        logger.info(f"Marked {updated}/{len(memory_ids)} memories as processed")
        return updated
    except Exception as e:
        logger.warning(f"Failed to mark as processed: {e}")
        return 0


def _memory_date(m: dict) -> str:
    """Extract the MM-DD date from a memory entry; prefers created_at (the server's recent
    endpoint already filters and sorts by it), returns an empty string on missing key/exception."""
    raw = m.get("created_at") or m.get("updated_at") or ""
    return raw[5:10] if len(raw) >= 10 else ""


def _build_facts_text_v2(memories: list[dict]) -> str:
    # A memory item's body is under the `memory` key (returned by the REST API); the
    # `content` key does not exist -> reading the wrong one yields empty
    # Straight double quotes are normalized to CJK quotes (alternating open/close as a
    # pair): when the LLM copies source text it carries bare quotes into JSON string
    # values without escaping, causing downstream _parse_json_any to fail (measured 2026-08-05)
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
        f"[{_memory_date(m) or t('mcp.summary.unknown_date')}] "
        f"{_clean(m.get('memory') or m.get('content') or '')}"
        for m in memories
    )


def _aggregate_round(
    facts_text: str, label: str
) -> tuple[list[dict] | None, str | None]:
    """Single aggregate round: classify memory facts by topic / merge and dedupe within groups / assess retain, returns (groups, raw).

    label is used in logs to distinguish "batching" from "recursive merge round". When the
    LLM output is invalid (still failing after 1 retry), returns (None, raw); the caller
    decides whether to abort (first round) or keep the current result and continue (recursive round).
    """
    prompt = prompt_loader.prompt(
        "aggregate",
        label=label,
        facts_text=facts_text,
    )
    parsed = None
    raw = None
    for attempt in range(
        2
    ):  # retry once on failure (the LLM occasionally outputs incomplete/non-JSON)
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
            f"aggregate{label} attempt {attempt + 1} invalid"
            + (", retrying" if attempt == 0 else ", giving up")
        )
    if not parsed:
        return None, raw
    return parsed.get("groups", []) or [], raw


def _groups_to_facts(groups: list[dict]) -> str:
    """Convert aggregated groups back to fact text for the recursive merge round to aggregate again."""
    return "\n".join(
        f"- [{','.join(g.get('tags', []) or [])}] "
        f"{g.get('topic', '')}：{g.get('facts', '')}"
        for g in groups
    )


def _filter_retain(groups: list[dict]) -> list[dict]:
    """Keep only groups with long-term sedimentation value (retain=true); treat missing as false (better none than a bad one)."""
    retained = []
    for g in groups:
        if g.get("retain") not in (True, "true", "True"):
            logger.info(
                f"aggregate discarded group with no sedimentation value: {g.get('topic', '')!r}"
            )
            continue
        if not str(g.get("facts", "")).strip():
            continue
        retained.append(g)
    return retained


def _run_aggregate_v2(memories: list[dict]) -> tuple[list[dict] | None, int]:
    """Phase 1 v2: batch aggregate -> cross-batch merge -> retain filter -> recursive merge until convergence.

    Returns (groups, rounds): groups being None only means a fatal failure in the first
    round (abort); rounds is the number of recursive rounds actually executed (not
    counting the first batching). Recursion only merges and never splits, so the group
    count is monotonically non-increasing and it must converge within
    AGGREGATE_MAX_ROUNDS; a failed recursive round keeps the current result and
    continues (non-fatal).
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
        batch_label = (
            t("mcp.summary.batch_label", index=bi + 1, total=len(batches))
            if len(batches) > 1
            else ""
        )
        batch_groups, raw = _aggregate_round(facts_text, batch_label)
        if batch_groups is None:
            write_error_log(
                f"aggregate batch {bi + 1}/{len(batches)} LLM output invalid (still failing after retry):\n{(raw or '')[:1000]}",
                code="AGGREGATE_JSON",
            )
            return None, 0
        groups.extend(batch_groups)

    if not groups:
        print("aggregate produced no valid topics, skipping summary")
        return [], 0

    # When batch-aggregating, do a second cross-batch merge: groups with the same/similar topic converge into one
    if len(batches) > 1:
        groups = _merge_cross_batch_groups(groups)

    # Recursive merge: converges when the group count stops decreasing; at most AGGREGATE_MAX_ROUNDS rounds
    rounds = 0
    for rnd in range(1, AGGREGATE_MAX_ROUNDS + 1):
        prev_len = len(groups)
        round_groups, _raw = _aggregate_round(
            _groups_to_facts(groups), t("mcp.summary.round_label", round=rnd)
        )
        if round_groups is None:
            logger.warning(
                f"recursive merge round {rnd} failed, keeping current grouping and continuing"
            )
            break
        groups = round_groups
        rounds = rnd
        logger.info(
            f"aggregate converged: round {rnd} {prev_len} -> {len(groups)} groups"
        )
        if len(groups) >= prev_len:
            break

    return _filter_retain(groups), rounds


def _merge_cross_batch_groups(groups: list[dict]) -> list[dict]:
    """Second cross-batch merge: converge groups with the same/similar topic into one (called when batch-aggregating)."""
    entries = "\n".join(
        f"- [{i}] {g.get('topic', '')}：{g.get('facts', '')[:150]}"
        for i, g in enumerate(groups)
    )
    prompt = prompt_loader.prompt(
        "merge_cross_batch",
        entries=entries,
    )
    raw = _llm_chat(
        prompt,
        temperature=AGGREGATE_LLM_TEMPERATURE,
        timeout=AGGREGATE_LLM_TIMEOUT,
        max_tokens=16384,
        disable_thinking=True,
    )
    if not raw:
        logger.warning(
            "cross-batch second merge LLM call failed, keeping original grouping"
        )
        return groups
    parsed = _parse_json_any(raw)
    if not parsed or not parsed.get("groups"):
        logger.warning(
            "cross-batch second merge parse failed, keeping original grouping"
        )
        return groups
    return parsed["groups"]


def _llm_json(
    prompt: str,
    *,
    max_tokens: int,
    temperature: float | None = None,
    timeout: float | None = None,
    disable_thinking: bool = False,
    feature: str | None = None,
) -> dict | None:
    """think enabled, output JSON; on parse failure automatically downgrades to disable_thinking and retries once.

    Returns the successfully parsed dict; returns None if both attempts fail (fail-open,
    each caller handles its own fallback). When `feature` is passed, it adds two
    **external signals** -- previously a failure here was completely silent (only
    returning None, with the caller continuing as "no result"), so a bad prompt or a
    model that ignores the format was impossible to detect:
      - both attempts fail to parse -> `write_error_log(PROMPT_JSON_PARSE)`
      - parses but is missing the template-declared `json_keys` -> `write_error_log(PROMPT_JSON_MISS)`,
        **without changing the return value**: a missing key is "the model did not output
        to contract", which is different from a parse failure, and whether to treat it as
        a failure is up to the caller (this only makes it visible).
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
                if feature:
                    missing = prompt_loader.missing_json_keys(feature, parsed)
                    if missing:
                        write_error_log(
                            f"{feature}: model output is missing template-declared keys {list(missing)}",
                            code="PROMPT_JSON_MISS",
                        )
                return parsed
        if attempt == 0:
            logger.warning(
                "JSON output parse failed, downgrading to disable_thinking and retrying once"
            )
    if feature:
        write_error_log(
            f"{feature}: LLM output failed to parse as JSON on both attempts (abnormal prompt or model output)",
            code="PROMPT_JSON_PARSE",
        )
    return None


def _extract_keywords(group: dict) -> list[str]:
    """Extract retrieval keywords for a group's topic (3-8 noun-like words). Returns [] on failure."""
    facts = str(group.get("facts", ""))[:SUMMARY_MERGE_CONTEXT_CHARS]
    prompt = prompt_loader.prompt(
        "extract_keywords",
        SUMMARY_KEYWORD_COUNT=SUMMARY_KEYWORD_COUNT,
        topic=group.get("topic", ""),
        facts=facts,
        SEARCH_MIN_TOKEN_LEN=SEARCH_MIN_TOKEN_LEN,
    )
    parsed = _llm_json(
        prompt, max_tokens=SUMMARY_KEYWORD_MAX_TOKENS, feature="extract_keywords"
    )
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
    """Take ~60 characters around the first keyword hit as the retrieval snippet."""
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
    """Search within EXTRACTS_DIR by keyword substring match (purely local, zero external dependencies).

    The cold-layer vector store != the Extracts full text (the cold layer contains only the
    aggregate entries synced each summarize run), and Qdrant local holds an exclusive lock
    so the standalone summarize process cannot connect directly -- hence retrieval uses
    pure-Python case-insensitive substring matching. Returns the top `limit` entries by
    descending hit-keyword count as [{"rel_path", "snippet", "matched", "score"}].
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
        # P1 hit weighting: keywords hitting the relative path (filename/dir name) + the
        # first section are counted separately as topical hits. Incidental hits in the body
        # (same word but off-topic) are not counted as title_matched and sink in the sort.
        title_feature = (
            str(f.relative_to(EXTRACTS_DIR)) + " " + re.split(r"(?m)^#", text)[0][:200]
        ).lower()
        title_matched = [k for k in matched if k.lower() in title_feature]
        hits.append(
            {
                "rel_path": str(f.relative_to(EXTRACTS_DIR)),
                "snippet": _make_snippet(text, matched[0]),
                "matched": matched,
                "title_matched": title_matched,
                "score": len(matched),
            }
        )
    # Sort: topical hits first, then total number of hit words
    hits.sort(key=lambda h: (len(h["title_matched"]), h["score"]), reverse=True)
    return hits[:limit]


def _existing_extract_tops() -> set[str]:
    """Set of existing top-level directory names in Extracts (reused for the directory whitelist / LLM prompt)."""
    if not EXTRACTS_DIR.exists():
        return set()
    return {d.name for d in EXTRACTS_DIR.iterdir() if d.is_dir()}


def _dir_excluded(dir_name: str) -> bool:
    """True when any level of the directory path matches an excluded directory (the hand-written area at the notes root)."""
    return any(p in SUMMARY_EXCLUDE_DIRS for p in Path(dir_name).parts)


def _file_topic_feature(rel_path: str) -> str:
    """File topic feature = filename + all H1 headings + head content (before the first #).

    The matching basis for topical-attribution filtering: only the "topic a file declares
    about itself" (filename/headings/opening) counts; body hits do not -- incidental
    keyword appearances in the body are exactly the source of misplaced merges
    (e.g. a SCHEME_PANEL_DEBRIEF keyword hitting the PanelManager text in a waza file's body).
    """
    fp = EXTRACTS_DIR / rel_path
    try:
        text = fp.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return rel_path
    h1s = re.findall(r"(?m)^#\s+(.+)$", text)
    head = re.split(r"(?m)^#", text)[
        0
    ]  # before the first # (file header note / preface)
    return " ".join([rel_path, *h1s, head[:500]])


def _hit_topic_relevant(group: dict, hit: dict, keywords: list[str]) -> bool:
    """Group keywords: >=1 hit on the file topic feature -> allowed as a merge-candidate target.

    Same idea as _topical_related (shared topic words means same family), but the object
    being judged is the "file topic feature" rather than another group's keywords. When
    keyword extraction fails ([]), treat everything as related and do not block.
    """
    kws = [k for k in keywords if k]
    if not kws:
        return True
    feature = _file_topic_feature(hit["rel_path"]).lower()
    return any(k.lower() in feature for k in kws)


def _decide_merge(group: dict, hits: list[dict]) -> dict | None:
    """Decide whether the group should be merged into an existing note or created new.

    No hits returns None (create new directly); with hits returns {"action", "target" (relative to Extracts), "reason"}.
    Judgment JSON failure (still None after downgrade) -> fall back to merge into hits[0] and write a REFINE_JUDGE_JSON log.
    """
    if not hits:
        return None

    facts = str(group.get("facts", ""))[:SUMMARY_MERGE_CONTEXT_CHARS]
    candidates = "\n".join(
        f"- [{i}] {h['rel_path']}：{h['snippet'][:120]}" for i, h in enumerate(hits)
    )
    prompt = prompt_loader.prompt(
        "decide_merge",
        topic=group.get("topic", ""),
        facts=facts,
        candidates=candidates,
    )
    parsed = _llm_json(
        prompt, max_tokens=SUMMARY_JUDGE_MAX_TOKENS, feature="decide_merge"
    )
    if parsed:
        action = str(parsed.get("action", "")).strip().lower()
        if action == "merge":
            target = str(parsed.get("target", "")).strip()
            # Validate using resolved paths (so symlink environments like /tmp->/private/tmp don't make relative_to raise)
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
            logger.warning(
                f"merge target {target!r} invalid/does not exist, falling back to new"
            )
            return {"action": "new", "target": "", "reason": "judge target 非法"}
        return {"action": "new", "target": "", "reason": str(parsed.get("reason", ""))}

    # Judgment failure (still None after downgrade) -> fall back to merge into the first
    # non-excluded hit, better than creating blindly
    # (defect 2 fix: hits[0] may be in an excluded directory, so skip to the first valid
    # hit; if none, fall back to new)
    fallback = next((h for h in hits if not _dir_excluded(h["rel_path"])), None)
    if fallback is None:
        write_error_log(
            f"merge judgment JSON failed and no valid fallback hit (topic={group.get('topic', '')!r}), falling back to new",
            code="REFINE_JUDGE_JSON",
        )
        return {"action": "new", "target": "", "reason": "judge 失败且无合法兜底"}
    write_error_log(
        f"merge judgment JSON failed, falling back to merge into {fallback['rel_path']}"
        f" (topic={group.get('topic', '')!r})",
        code="REFINE_JUDGE_JSON",
    )
    return {
        "action": "merge",
        "target": fallback["rel_path"],
        "reason": "judge 失败兜底",
    }


def _gen_new(group: dict, dir_tree: str, existing_tops: set[str]) -> dict | None:
    """think enabled, generate a new article: {"dir", "title", "content"}. Returns None on failure."""
    facts = str(group.get("facts", ""))
    tops_block = (
        t("mcp.summary.list_separator").join(sorted(existing_tops))
        if existing_tops
        else t("mcp.summary.empty_tops")
    )
    prompt = prompt_loader.prompt(
        "gen_new",
        topic=group.get("topic", ""),
        facts=facts,
        dir_tree=dir_tree,
        tops_block=tops_block,
        exclude_dirs=sorted(SUMMARY_EXCLUDE_DIRS),
    )
    parsed = _llm_json(
        prompt, max_tokens=SUMMARY_GEN_MAX_TOKENS, temperature=0.2, feature="gen_new"
    )
    if not parsed:
        return None
    dir_name = str(parsed.get("dir", "")).strip().strip("/")
    title = str(parsed.get("title", "")).strip()
    content = str(parsed.get("content", "")).strip()
    if not dir_name or not title or not content:
        return None
    return {"dir": dir_name, "title": title, "content": content}


def _gen_merge(group: dict, target_file: Path, existing_text: str) -> dict | None:
    """think enabled, generate merge content: writes only new information not already covered by existing content. Returns None on failure.

    no_increment semantic judgment: the LLM compares "relevant facts" with the "target note's
    relevant sections"; when every point is already covered it returns
    {"action":"no_increment",...}, which refine recognizes and skips (added 2026-08-07).
    Only no_increment carries an action field; normal merge does not, avoiding **item's action
    overwriting refine's local action on results.append (fallback_merge polluted into merge).
    Context is taken from _relevant_segments rather than the first N characters -- for a large
    file the first 2K cannot see the existing sections at the end of the file, leaving the LLM
    unable to judge duplication (2026-08-07 root-cause fix).
    """
    facts = str(group.get("facts", ""))
    context = _relevant_segments(existing_text, facts, SUMMARY_MERGE_LOOKBACK_CHARS)
    prompt = prompt_loader.prompt(
        "gen_merge",
        topic=group.get("topic", ""),
        facts=facts,
        target=target_file.relative_to(EXTRACTS_DIR),
        context=context,
    )
    parsed = _llm_json(
        prompt, max_tokens=SUMMARY_GEN_MAX_TOKENS, temperature=0.2, feature="gen_merge"
    )
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
    """Pre-aggregation merge decision: shared topic keywords + Jaccard >= SUMMARY_TOPIC_JACCARD (purely deterministic, 0 LLM).

    Measured calibration (2026-08-06, real 20 unprocessed memories -> 12 groups -> 4 hit targets):
    - same-family groups (e.g. the summarize.py quality-gate scheme / pendulum / 5bd2e21 /
      placeholder list, all hitting the same RSS note): keyword sets share >=1 topic word, Jaccard 0.07-0.15;
    - unrelated groups with the same target (e.g. the RSS daily read-marker convention vs the
      summarize family): 0 shared words, Jaccard=0;
    - whole-text SequenceMatcher ratio / char-bigram Jaccard overlap between within-family
      (0.06-0.17) and cross-family (0.06-0.16) ranges, **no static threshold can separate
      them** -- the old `_max_segment_similarity > 0.6` gate judged every group unrelated
      (measured topic_merged=0, topic_blocked=22, the 5bd2e21 fragment root cause never converged).
    So relevance is decided by "keyword sharing + Jaccard >= 0.05 (>=1 shared topic word)";
    sharing a project/topic word is the same-family signal. The ffe8857 over-merge guard does
    not degrade from loosening this gate: pre-aggregated groups still go through LLM final
    review; and the count gate (a single target allows 1 merge per round) + after pre-aggregation
    groups with the same target are mutually unrelated -> at most 1 merge write per target per
    round, structurally preventing "6 sections at once" pileups.
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
    """Pre-resolve each group's "keywords + search hits + top1 valid target", returns {index: {...}}.

    target is the top1 hit passing validity checks (.md / is_file / inside EXTRACTS /
    !_dir_excluded), reused by pre-aggregation and refine, eliminating repeated keyword
    extraction/search inside the loop (0 new LLM).
    Failure/no hits -> {"keywords": [], "hits": [], "target": None}.
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
    """Pre-aggregation: merge groups that hit the same target and are topically related into one group, curing same-family fragmentation.

    Background: the root cause of 5bd2e21 over-splitting was "the 2nd+ group of a same-topic
    family hits the same target and gets forced to new by merge_counts". Here, groups that hit
    the same target and are _topical_related are merged into a single group **before** the count
    decision -> a single merge write -> count never triggers; after pre-aggregation the groups in
    a bucket are mutually unrelated, so count's semantics automatically degrade to "limit 1
    unrelated merge", keeping the ffe8857 guard as-is.

    Merge: facts joined by newline, tags unioned (deduplicated, order preserved), target keeps
    the cache of the group merged in.
    Returns (new_groups, new_resolved, stats); new_resolved index aligns with the new groups.
    stats: {"topic_merged": actual merge count, "topic_blocked": count of same-target unrelated judgments}
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
        # Greedy within a bucket: try to fold each group into an already-selected representative (merge if related), otherwise make it its own group
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
                blocked += 1  # judged unrelated: record one topic_blocked
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
    """Phase 2: per group "extract keywords -> search Extracts -> decide merge/new -> think enable generate".

    A failure in any step of a single group does not interrupt the whole: write_error_log +
    stats count + skip that group.
    Returns (results, stats); results are the write units (with action: new/merge).
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
        "topic_merged": 0,  # pre-aggregation merged group count (same target, same family)
        "topic_blocked": 0,  # count of same-target unrelated judgments (keeps the ffe8857 guard)
        "fallback_merge": 0,  # micro-fragment fallback merge count
        "fallback_dropped": 0,  # micro-fragment fallback failure / no-target count
        "hit_files": set(),
    }
    merge_counts: dict[
        str, int
    ] = {}  # merge count per target file within a single run (limited to 1 topic)
    results: list[dict] = []
    existing_tops = _existing_extract_tops()
    # Pre-resolve all groups' keywords/search/target + same-target same-family pre-aggregation (scheme A+C fusion)
    resolved_all = _resolve_group_targets(groups)
    groups, resolved_all, pre_stats = _pre_aggregate_same_target(groups, resolved_all)
    stats["topic_merged"] = pre_stats["topic_merged"]
    stats["topic_blocked"] = pre_stats["topic_blocked"]
    if pre_stats["topic_merged"]:
        logger.info(
            f"pre-aggregation: merged {pre_stats['topic_merged']} same-target same-family groups, "
            f"{pre_stats['topic_blocked']} same-target unrelated times"
        )
    for gi, group in enumerate(groups):
        topic = str(group.get("topic", "")) or f"group{gi}"
        logger.info(f"Refine [{gi}] {topic} ...")
        try:
            keywords = (resolved_all.get(gi) or {}).get("keywords", [])
            if not keywords:
                stats["kw_fail"] += 1
                write_error_log(
                    f"topic {topic!r} keyword extraction failed, skipping",
                    code="REFINE_KEYWORD",
                )
                continue
            hits = (resolved_all.get(gi) or {}).get("hits", []) or []
            if hits:
                stats["hit_files"].add(hits[0]["rel_path"])

            # P0 topical-attribution filter: only hits whose "keywords hit the file topic
            # feature (filename/H1/first section)" can be merge candidates. search_extracts is
            # a body substring match, and an incidental body hit drags topic-irrelevant files
            # into the candidates, causing misplaced merges (a SCHEME_PANEL_DEBRIEF hit on the
            # PanelManager text in a waza file's body is one such case) -- this layer intercepts
            # deterministically; with no relevant candidate ->
            # _decide_merge returns None -> go to new.
            if keywords and hits:
                cands = [h for h in hits if _hit_topic_relevant(group, h, keywords)]
                dropped = [h["rel_path"] for h in hits if h not in cands]
                if dropped:
                    logger.info(
                        f"topic {topic!r} topical-attribution filter removed {len(dropped)} candidates"
                        f" (body-only hits, not filename/heading/first section): {dropped}"
                    )
                hits = cands

            try:
                decision = _decide_merge(group, hits)
            except Exception as e:
                stats["gen_fail"] += 1
                write_error_log(
                    f"topic {topic!r} merge judgment exception: {e}",
                    code="REFINE_JUDGE",
                )
                continue

            # At most 1 merge into the same target file per run: separate topics are split into their own files (prevents the "6 sections at once" counterexample)
            if (
                decision is not None
                and decision["action"] == "merge"
                and merge_counts.get(decision["target"], 0) >= 1
            ):
                logger.warning(
                    f"topic {topic!r} target {decision['target']} already merged, switching to new this time"
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
                        # _gen_merge returns {action, title, content, ...}; add target so the write layer can locate it
                        item["target"] = decision["target"]
                        # LLM no-increment judgment (rewrite-style duplication: different
                        # wording but the information is already covered by an existing
                        # section; mechanical similarity thresholds can't catch it -- 2026-08-07 root-cause fix)
                        if item.get("action") == "no_increment":
                            stats["dup_skip"] += 1
                            logger.warning(
                                f"topic {topic!r} judged no increment (LLM): "
                                f"{item.get('reason', '')}"
                            )
                            continue
                        # Pre-write increment judgment: if the generated section's match coverage against some existing section is too high, treat it as no addition and skip writing
                        sim = _max_segment_similarity(
                            item.get("content", ""), existing_text
                        )
                        if sim > SUMMARY_DUP_SIM_THRESHOLD:
                            stats["dup_skip"] += 1
                            logger.warning(
                                f"topic {topic!r} existing-content coverage against {decision['target']}"
                                f" is {sim:.2f}, too high, judged no increment and skipped"
                            )
                            continue
                        # Note: merge_counts used to increment right after dup_skip -- the QC
                        # placeholder/too-short rejections come after it, so "merge content
                        # rejected by QC" still occupied that file's merge slot, falsely
                        # blocking later legitimate merges (measured: after groups [0]/[1] were
                        # placeholder-rejected, group [3] was wrongly blocked). Moved to count
                        # after a successful write (see before results.append), counting only
                        # real persisted merges.
                else:
                    item = _gen_new(group, dir_tree, existing_tops)
                    action = "new"
                    target_label = item["dir"] if item else ""
                    # Micro-fragment fallback (C): a new product <10 lines -> fall back to
                    # merging into the first non-excluded hit. If the merge product passes the
                    # similarity gate, merge normally; with no usable target / merge failure,
                    # keep the new write (prevents information loss).
                    if (
                        item
                        and len(str(item.get("content", "")).splitlines())
                        < SUMMARY_FRAGMENT_LINE_MIN
                    ):
                        fb = next(
                            (
                                h
                                for h in hits  # local hits have passed the P0 topical-attribution filter
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
                                            f"topic {topic!r} fragment fallback merge judged no increment"
                                            f" (LLM): {fb_item.get('reason', '')}"
                                        )
                                        continue
                                    fb_sim = _max_segment_similarity(
                                        fb_item.get("content", ""), fb_text
                                    )
                                    if fb_sim > SUMMARY_DUP_SIM_THRESHOLD:
                                        stats["dup_skip"] += 1
                                        logger.warning(
                                            f"topic {topic!r} fragment fallback merge into "
                                            f"{fb['rel_path']} coverage {fb_sim:.2f} "
                                            f"no increment, skipping"
                                        )
                                        continue
                                    item = fb_item
                                    action = "fallback_merge"
                                    target_label = fb["rel_path"]
                                    # Counting is accumulated uniformly by stats[action] at the end; do not add again here
                                else:
                                    stats["fallback_dropped"] += 1
                                    logger.warning(
                                        f"topic {topic!r} fragment fallback merge generation failed, keeping new"
                                    )
                            except Exception as e:
                                stats["fallback_dropped"] += 1
                                write_error_log(
                                    f"topic {topic!r} fragment fallback merge exception: {e}",
                                    code="REFINE_FALLBACK",
                                )
                        else:
                            stats["fallback_dropped"] += 1
                            logger.warning(
                                f"topic {topic!r} fragment has no usable fallback target, keeping the new write"
                            )
            except Exception as e:
                stats["gen_fail"] += 1
                write_error_log(
                    f"topic {topic!r} generation exception: {e}", code="REFINE_GEN"
                )
                continue

            if not item:
                stats["gen_fail"] += 1
                write_error_log(
                    f"topic {topic!r} generation failed, skipping", code="REFINE_GEN"
                )
                continue
            content_text = str(item.get("content", ""))
            if len(content_text) < SUMMARY_MIN_CONTENT_LEN:
                stats["too_short"] += 1
                logger.warning(f"topic {topic!r} content too short, skipping")
                continue
            # QC placeholder detection: content containing placeholder wording like 「未详述/待补全」 is treated as low quality and not written
            content_lower = content_text.lower()
            ph = next(
                (p for p in SUMMARY_PLACEHOLDER_PATTERNS if p.lower() in content_lower),
                None,
            )
            if ph:
                stats["too_low_quality"] += 1
                logger.warning(
                    f"topic {topic!r} contains placeholder wording 「{ph}」, judged low quality and skipped"
                )
                continue

            if action == "merge":
                # Only a directly merged, successfully persisted article takes the slot (QC
                # rejections do not); fallback_merge is a fragment fallback and is not subject
                # to the count limit (<10-line micro-fragments cannot form the ffe8857 pileup of many unrelated sections)
                merge_counts[item["target"]] = merge_counts.get(item["target"], 0) + 1

            results.append({"topic": topic, "action": action, **item})
            stats["ok"] += 1
            stats[action] += 1
            logger.info(f"  -> {action} {target_label} ({topic})")
        except Exception as e:
            stats["gen_fail"] += 1
            write_error_log(f"topic {topic!r} refine exception: {e}", code="REFINE_GEN")
            continue
    stats["hit_files"] = sorted(stats["hit_files"])
    return results, stats


def _collect_tags(memories: list[dict]) -> list[str]:
    return list(
        set(t for m in memories for t in (m.get("metadata") or {}).get("tags", []))
    )


def _max_segment_similarity(new_content: str, existing_text: str) -> float:
    """Max "match coverage" of the merge content against existing sections of the target file (difflib, zero external dependencies).

    Semantics: the fraction of characters in new_content that are matched
    character-for-character by an existing section, directly measuring the amount of new
    information -- coverage approaching 1 -> the generated section is basically a
    restatement of existing sections -> judged no addition and skipped.
    ratio is disturbed by length differences (long sections dilute, short sections
    inflate), while coverage distinguishes "rewrite-style duplication" better (measured:
    ScanTextUtil duplicate coverage 0.767 vs typical increment 0.595).
    Sections are split on multi-level headings (#{1,6}) rather than H1 only: for a file
    organized with multi-level headings (##/###), splitting by H1 degrades into one
    whole-file section, diluting similarity with unrelated content (2026-08-07 root-cause fix).
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
    """Slice the existing sections most relevant to facts out of the target note, for the LLM's increment judgment during merge generation.

    The original implementation took the first N characters of existing_text: for a large
    file the target section is at the file's end (e.g. existing sections appended at the
    tail), so the LLM could not see the existing content and had no way to judge
    duplication, directly restating relevant facts -> duplicate sections (2026-08-07
    root-cause fix). Now it splits on multi-level headings, sorts sections by similarity to
    facts, and takes the top relevant sections, capped at max_chars. With no relevant
    section (empty facts / no sections), it falls back to the file head.
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
    """Strip a leading # heading from the body, so it does not duplicate the file title written by the script."""
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
    """Write the file. Creates it when new; on append, merges by H1 section: a same-named
    H1 section is replaced (deduplicated), otherwise a new section is added at the end
    (history preserved). Returns whether the write succeeded."""
    content = _strip_leading_h1(content)
    supplement = t("mcp.summary.supplement_header", date=today_str)
    block = f"# {title}\n\n{supplement}\n\n{content}\n"
    if not is_append:
        filepath.write_text(
            f"# {title}\n\n{t('mcp.summary.auto_summary_header', date=today_str)}\n\n{content}\n",
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
            # Same-named H1 section: keep the old content, append the new content as a
            # sub-section (prevents overwriting history). content has had its leading H1
            # stripped by _strip_leading_h1, so the added section needs # {title} to avoid a title-less block.
            old = seg.rstrip()
            if supersedes:
                # Correction type: mark the old section as deprecated at its end, to avoid old and new conclusions coexisting and contradicting each other
                old += "\n\n" + t("mcp.summary.deprecated_note")
            out.append(
                old
                + "\n\n---\n\n# "
                + title
                + "\n\n"
                + supplement
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
    """Sanitize the new directory given by the LLM: remove excluded directories; keep
    multi-level nesting only when its top level is an existing top level, otherwise fall
    back to a single level (defends against the LLM creating deep paths); when a new top
    level is in the same topic domain as an existing top level, fall back to folding into
    the existing directory (prevents cross-directory scattering + casually creating duplicate directories)."""
    raw = str(dir_name or "").strip().strip("/")
    parts = [p for p in Path(raw).parts if p and p not in SUMMARY_EXCLUDE_DIRS]
    if not parts:
        return ""
    existing_tops = _existing_extract_tops()
    if len(parts) > 1 and parts[0] not in existing_tops:
        logger.warning(
            f"new multi-level directory {raw}, falling back to single-level directory {parts[0]}"
        )
        return parts[0]
    # Shared-topic-word fallback: a new top-level directory name and some existing
    # top-level directory contain each other ("面板系统" vs "面板", "工具集" vs
    # "Utility工具集") -> same topic domain, fall back to folding into the existing
    # directory. The 3-character floor filters out generic short words like "技术/笔记";
    # matching in descending length order prefers the longer (more specific) existing
    # directory ("Utility工具集" matched before "工具集", picking the closest topic).
    if len(parts) == 1:
        new_top = parts[0]
        for top in sorted(existing_tops, key=len, reverse=True):
            if top == new_top:
                break
            if (
                len(new_top) >= 3
                and len(top) >= 3
                and (new_top in top or top in new_top)
            ):
                logger.warning(
                    f"new directory {new_top} shares a topic domain with existing directory {top}, folding into {top}"
                )
                return top
    return "/".join(parts)


def _write_articles_v2(
    results: list[dict],
    today_str: str,
    all_tags: list[str],
    source_memory_ids: list | None = None,
) -> dict[str, str]:
    """Phase 2 write: merge/fallback_merge write directly to the judged target; new goes
    through resolve_target_file's fallback to prevent collisions.
    Write exceptions are caught per item with try/except and logged as WRITE errors,
    without interrupting the remaining writes.
    Batch-write blind-spot fix: _run_refine's dup_skip reads the file "before batch
    write", so it cannot see earlier pending writes in the same run (same target, merge
    then fallback_merge); the write layer re-checks against the on-disk content before persisting."""
    updated = {}
    for item in results:
        try:
            if item["action"] in ("merge", "fallback_merge"):
                filepath = EXTRACTS_DIR / item["target"]
                filepath.parent.mkdir(parents=True, exist_ok=True)
                is_append = True
                # Batch-write blind-spot fix (a): when the same run already wrote this file
                # earlier, re-read the current on-disk content for a similarity re-check,
                # catching fallback_merge re-appending something highly similar to an earlier
                # section (measured sim 0.919).
                if str(filepath) in updated:
                    cur_text = filepath.read_text(encoding="utf-8")
                    sim = _max_segment_similarity(item.get("content", ""), cur_text)
                    if sim > SUMMARY_DUP_SIM_THRESHOLD:
                        logger.warning(
                            f"batch-write re-check: {item['target']} similarity {sim:.2f} to an"
                            f" earlier write in the same run too high, skipping"
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
            # Lightweight QC: warn on abnormal file size (does not block)
            try:
                size = filepath.stat().st_size
                if size > 500_000:
                    logger.warning(f"QC: {filepath} abnormal size ({size // 1024}KB)")
            except OSError:
                pass
            updated[str(filepath)] = "append" if is_append else "new"
            write_to_cold_layer(
                content=item["content"],
                source_file=str(filepath),
                category=filepath.parent.name or "Extracts",
                tags=all_tags,
                confidence=1.0,
                source_memory_ids=source_memory_ids,
            )
        except Exception as e:
            write_error_log(
                f"write failed {item.get('topic', '')!r}: {e}", code="WRITE"
            )
            continue
    return updated


def main():
    if not _acquire_single_instance():
        print("⚠️ A summarize instance is already running, skipping this run")
        return

    if not AI_API_KEY:
        write_error_log("AI_API_KEY not set", code="CONFIG")
        print("❌ AI_API_KEY not set")
        return

    if not _throttle_ai_run():
        return

    today = date.today()
    today_str = today.isoformat()
    EXTRACTS_DIR.mkdir(parents=True, exist_ok=True)

    logger.info("Fetching memories from past 3 days via REST API...")
    recent_memories = fetch_memories(today)
    if recent_memories is None:
        print("❌ Failed to fetch memories")
        return
    if not recent_memories:
        print("No new memories in the past 3 days, skipping summary")
        return

    # Input filtering: skip processed + excluded tags + quality gate (better none than a bad one); collect only the ids of passing memories
    skipped_processed = len(recent_memories)
    recent_memories = _filter_processed(recent_memories)
    skipped_processed -= len(recent_memories)
    skipped_tags = len(recent_memories)
    recent_memories = _filter_by_tags(recent_memories)
    skipped_tags -= len(recent_memories)
    skipped_quality = len(recent_memories)
    recent_memories = _filter_memory_quality(recent_memories)
    skipped_quality -= len(recent_memories)
    if skipped_processed or skipped_tags or skipped_quality:
        logger.info(
            f"input filtering: processed skipped {skipped_processed}, tag filter skipped {skipped_tags}, low-quality dropped {skipped_quality}, "
            f"{len(recent_memories)} remaining"
        )
    consumed_ids = [m["id"] for m in recent_memories if m.get("id")]
    if not recent_memories:
        print(
            "No processable new memories (all processed or failing quality), skipping summary"
        )
        return

    logger.info("Scanning notes directory structure...")
    dir_tree = scan_notes_structure(NOTES_DIR)

    # Phase 1: memory aggregation (classify / merge / dedupe / timeline, recursive convergence)
    logger.info(f"Aggregating {len(recent_memories)} memories into groups...")
    groups, agg_rounds = _run_aggregate_v2(recent_memories)
    if groups is None:
        print("⚠️ Memory aggregation failed, skipping this summary")
        return
    if not groups:
        return

    # Phase 2: per group "keywords -> search Extracts -> decide merge/new -> think enable generate"
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
        print(
            "All article generation failed or content was too short, skipping summary"
        )
        return

    all_tags = _collect_tags(recent_memories)
    updated_files = _write_articles_v2(
        writes, today_str, all_tags, source_memory_ids=consumed_ids
    )

    # Mark as processed only when something was written: set bit0 on successfully consumed
    # memories to avoid reprocessing next round. Without any write (this round everything was
    # judged by the LLM to have no sedimentation value), do not mark; re-evaluate next round.
    if updated_files and consumed_ids:
        _mark_processed(consumed_ids)

    # Phase 3: rules extraction (rule/convention memories -> MCP/Rules/*.md)
    phase3 = _run_phase3(groups, today_str)
    rules_updates = phase3.get("updated", "")
    if rules_updates:
        git_commit(t("mcp.summary.commit_rules", files=rules_updates), stage="rules")

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
    overview = t(
        "mcp.summary.commit_overview",
        time=now_str,
        facts=len(recent_memories),
        files=len(updated_files),
    )
    git_commit(overview, stage="after write")

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
