#!/usr/bin/env python3
"""用于 /check Ship 模式的确定性发布闸门信号。

以带标签的块输出 Release Gate 2.0 矩阵中可机器校验的那一半，
每块以 `status: PASS|WARN|FAIL|N/A` 结束，便于评审者直接粘贴证据、
而无需自行推导。需要判断的面（分发通道、包内容、发布资产、registry
状态）仍由 skill 负责。

纯标准库。只读。无网络。即使 WARN/FAIL 也以 0 退出，以免运行框架把
「发现了问题」误当成「脚本坏了」。

用法: python3 skills/check/scripts/release_gate.py --root <path>
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from pathlib import Path


SEMVER_RE = re.compile(
    r"^[vV]?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
INPUT_LIMITS = {
    "VERSION": 4_096,
    "package.json": 1_000_000,
    "Cargo.toml": 1_000_000,
    "pyproject.toml": 1_000_000,
    "CHANGELOG.md": 5_000_000,
    "CHANGELOG": 5_000_000,
    "CHANGES.md": 5_000_000,
    "HISTORY.md": 5_000_000,
}


def run_git(root: Path, *args: str) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, str(exc)
    return proc.returncode, (proc.stdout or "").strip()


def block(name: str, lines: list[str], status: str) -> None:
    print(f"=== {name} ===")
    for line in lines:
        print(line)
    print(f"status: {status}")
    print()


def is_git_repo(root: Path) -> bool:
    code, out = run_git(root, "rev-parse", "--is-inside-work-tree")
    return code == 0 and out == "true"


def repo_file(root: Path, name: str) -> tuple[Path | None, str | None]:
    """解析一个仓库输入，且不跟随它到根之外。"""
    candidate = root / name
    if not candidate.exists() and not candidate.is_symlink():
        return None, None
    if candidate.is_symlink():
        return None, f"{name} 不能是 symlink"
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root)
    except (OSError, ValueError):
        return None, f"{name} 未解析到仓库内的某个文件"
    if not resolved.is_file():
        return None, f"{name} 不是常规文件"
    return resolved, None


def read_repo_text(path: Path, name: str) -> tuple[str | None, str | None]:
    """读取一个已校验的仓库输入，不跟随 symlink，并限制大小。"""
    limit = INPUT_LIMITS[name]
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return None, f"{name} 在校验之后变得不可读"
    try:
        chunks: list[bytes] = []
        total = 0
        while total <= limit:
            chunk = os.read(descriptor, min(65_536, limit + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
    except OSError:
        return None, f"{name} 无法被完整读取"
    finally:
        os.close(descriptor)
    if total > limit:
        return None, f"{name} 超过了 {limit} 字节的发布闸门上限"
    return b"".join(chunks).decode("utf-8", errors="replace"), None


def parse_semver(value: str) -> tuple[tuple[int, int, int], str | None] | None:
    match = SEMVER_RE.fullmatch(value.strip())
    if not match:
        return None
    core = tuple(int(match.group(index)) for index in (1, 2, 3))
    prerelease = match.group(4)
    if prerelease and any(
        part.isdigit() and len(part) > 1 and part.startswith("0")
        for part in prerelease.split(".")
    ):
        return None
    return core, prerelease


def evidence_value(value: str) -> str:
    """把仓库可控的文本渲染成一行有界证据。"""
    has_controls = any(ord(char) < 32 or ord(char) == 127 for char in value)
    rendered = json.dumps(value, ensure_ascii=True) if has_controls else value
    return rendered if len(rendered) <= 160 else f"{rendered[:157]}..."


def worktree_state(root: Path) -> None:
    code, out = run_git(root, "status", "--porcelain", "-uall")
    if code != 0:
        block("WORKTREE STATE", [f"git status 失败: {out}"], "N/A")
        return
    staged = modified = untracked = 0
    for line in out.splitlines():
        if line.startswith("??"):
            untracked += 1
            continue
        if line[:1].strip():
            staged += 1
        if line[1:2].strip():
            modified += 1
    lines = [f"staged: {staged}", f"modified: {modified}", f"untracked: {untracked}"]
    status = "PASS" if staged == modified == untracked == 0 else "WARN"
    if status == "WARN":
        lines.append("工作区脏: 在声称可发布之前，先交代每一个文件")
    block("WORKTREE STATE", lines, status)


def remote_sync(root: Path) -> None:
    code, out = run_git(
        root, "rev-list", "--left-right", "--count", "@{upstream}...HEAD"
    )
    if code != 0:
        block("REMOTE SYNC", ["当前分支未配置 upstream"], "N/A")
        return
    try:
        behind, ahead = (int(n) for n in out.split())
    except (TypeError, ValueError):
        block("REMOTE SYNC", [f"意外的 git rev-list 输出: {out!r}"], "N/A")
        return
    lines = [f"ahead of upstream: {ahead}", f"behind upstream: {behind}"]
    if behind:
        lines.append("分支落后于 upstream: 发布前先同步")
        status = "FAIL"
    elif ahead:
        lines.append("存在未推送的提交: 远端还没有这个状态")
        status = "WARN"
    else:
        lines.append("本地跟踪引用与 HEAD 一致；仍需要 fetch 或 ls-remote 的证据")
        status = "WARN"
    block("REMOTE SYNC", lines, status)


def latest_stable_reachable_tag(root: Path) -> str | None:
    code, out = run_git(root, "tag", "--merged", "HEAD", "--sort=-version:refname")
    if code != 0 or not out:
        return None
    for line in out.splitlines():
        tag = line.strip()
        parsed = parse_semver(tag)
        if parsed and parsed[1] is None:
            return tag
    return None


def tag_baseline(root: Path) -> str | None:
    tag = latest_stable_reachable_tag(root)
    if tag is None:
        block("TAG BASELINE", ["从 HEAD 无法到达任何 stable tag"], "N/A")
        return None
    code, count = run_git(root, "rev-list", "--count", f"{tag}..HEAD")
    lines = [f"latest stable reachable tag: {tag}"]
    if code == 0:
        lines.append(f"commits since tag: {count}")
        if count == "0":
            lines.append("HEAD 就是被打 tag 的提交")
    lines.append("仅本地可达性；请确认这个 tag 就是最新已发布版本")
    block("TAG BASELINE", lines, "WARN")
    return tag


def toml_version(text: str, sections: tuple[str, ...]) -> str | None:
    current = ""
    for line in text.splitlines():
        header = re.match(r"\s*\[([^\]]+)\]", line)
        if header:
            current = header.group(1).strip()
            continue
        if current in sections:
            m = re.match(r"\s*version\s*=\s*[\"']([^\"']+)[\"']", line)
            if m:
                return m.group(1)
    return None


def collect_versions(root: Path) -> tuple[dict[str, str], list[str]]:
    found: dict[str, str] = {}
    errors: list[str] = []
    version_file, error = repo_file(root, "VERSION")
    if error:
        errors.append(error)
    if version_file:
        text, read_error = read_repo_text(version_file, "VERSION")
        if read_error:
            errors.append(read_error)
        elif text:
            first = text.strip()
            if first:
                found["VERSION"] = first.splitlines()[0].strip()
    pkg, error = repo_file(root, "package.json")
    if error:
        errors.append(error)
    if pkg:
        text, read_error = read_repo_text(pkg, "package.json")
        if read_error:
            errors.append(read_error)
        else:
            try:
                data = json.loads(text or "")
            except json.JSONDecodeError:
                found["package.json"] = "(unparseable)"
            else:
                if isinstance(data, dict) and isinstance(data.get("version"), str):
                    found["package.json"] = data["version"]
    cargo, error = repo_file(root, "Cargo.toml")
    if error:
        errors.append(error)
    if cargo:
        text, read_error = read_repo_text(cargo, "Cargo.toml")
        if read_error:
            errors.append(read_error)
        elif text:
            v = toml_version(text, ("package",))
            if v:
                found["Cargo.toml"] = v
    pyproject, error = repo_file(root, "pyproject.toml")
    if error:
        errors.append(error)
    if pyproject:
        text, read_error = read_repo_text(pyproject, "pyproject.toml")
        if read_error:
            errors.append(read_error)
        elif text:
            v = toml_version(text, ("project", "tool.poetry"))
            if v:
                found["pyproject.toml"] = v
    return found, errors


def version_sync(root: Path, tag: str | None) -> str | None:
    found, errors = collect_versions(root)
    if not found and not errors:
        block(
            "VERSION FIELD SYNC",
            ["未找到 VERSION / package.json / Cargo.toml / pyproject.toml 版本"],
            "N/A",
        )
        return None
    lines = [
        f"{name}: {evidence_value(value)}" for name, value in sorted(found.items())
    ]
    status = "FAIL" if errors else "PASS"
    lines.extend(f"不安全的仓库输入: {error}" for error in errors)
    invalid_evidence = [
        name
        for name, value in found.items()
        if len(value) > 128 or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ]
    if invalid_evidence:
        lines.append(
            "版本字段包含控制字符或超过 128 个字符: "
            + ", ".join(sorted(invalid_evidence))
        )
        status = "FAIL"
    if "(unparseable)" in found.values():
        lines.append("无法解析的清单: 在信任版本同步之前先修好它")
        status = "FAIL"
    normalized = {
        v[1:] if v.startswith(("v", "V")) else v
        for v in found.values()
        if v != "(unparseable)"
    }
    if len(normalized) > 1:
        lines.append("版本字段不一致: 发布前先对齐它们")
        status = "FAIL"
    manifest = next(iter(normalized)) if len(normalized) == 1 else None
    raw_manifest = (
        next(iter(found.values())) if len(normalized) == 1 and found else None
    )
    parsed_manifest = parse_semver(raw_manifest) if raw_manifest else None
    if manifest and parsed_manifest is None:
        lines.append("清单版本不是精确的 SemVer")
        status = "FAIL"
    if parsed_manifest and parsed_manifest[1] is not None:
        lines.append("清单是一个预发布版本；不要把它当作 stable tag 的对等物")
        if status == "PASS":
            status = "WARN"
    if parsed_manifest and tag:
        lines.append(f"stable reachable tag: {tag}")
        parsed_tag = parse_semver(tag)
        if parsed_tag:
            manifest_core, manifest_pre = parsed_manifest
            tag_core, tag_pre = parsed_tag
            if parsed_manifest == parsed_tag:
                lines.append("清单与可达的 stable tag 完全一致")
            elif manifest_core < tag_core or (
                manifest_core == tag_core
                and manifest_pre is not None
                and tag_pre is None
            ):
                lines.append("清单落后于可达的 stable tag: 版本回退了")
                status = "FAIL"
            elif manifest_core > tag_core:
                lines.append("清单领先于可达的 stable tag（有未发布的版本在进行中）")
            else:
                lines.append("清单与可达的 stable tag 并不完全一致")
                if status == "PASS":
                    status = "WARN"
    block("VERSION FIELD SYNC", lines, status)
    return manifest


def changelog_mentions(root: Path, manifest: str | None) -> None:
    changelog = None
    for name in ("CHANGELOG.md", "CHANGELOG", "CHANGES.md", "HISTORY.md"):
        candidate, error = repo_file(root, name)
        if error:
            block("CHANGELOG VERSION", [f"不安全的仓库输入: {error}"], "FAIL")
            return
        if candidate:
            changelog = candidate
            break
    if changelog is None or not manifest:
        reason = "没有 changelog 文件" if changelog is None else "没有唯一的清单版本"
        block("CHANGELOG VERSION", [reason], "N/A")
        return
    text, error = read_repo_text(changelog, changelog.name)
    if error:
        block("CHANGELOG VERSION", [error], "FAIL")
        return
    assert text is not None
    version_pattern = re.compile(
        rf"(?<![0-9A-Za-z.+-])(?:v|V)?{re.escape(manifest)}"
        rf"(?![0-9A-Za-z.+-])"
    )
    if version_pattern.search(text):
        block(
            "CHANGELOG VERSION",
            [f"{changelog.name} 提到了 {manifest}"],
            "PASS",
        )
    else:
        block(
            "CHANGELOG VERSION",
            [f"{changelog.name} 没有提到 {manifest}"],
            "WARN",
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="要检查的项目根")
    args = parser.parse_args()
    root = Path(args.root).resolve()

    if not root.is_dir():
        block("RELEASE GATE", [f"根不存在: {root}"], "N/A")
        return 0

    if not is_git_repo(root):
        block("WORKTREE STATE", ["不是 git 仓库"], "N/A")
        block("REMOTE SYNC", ["不是 git 仓库"], "N/A")
        block("TAG BASELINE", ["不是 git 仓库"], "N/A")
        manifest = version_sync(root, None)
        changelog_mentions(root, manifest)
        return 0

    worktree_state(root)
    remote_sync(root)
    tag = tag_baseline(root)
    manifest = version_sync(root, tag)
    changelog_mentions(root, manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
