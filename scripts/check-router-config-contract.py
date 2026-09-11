#!/usr/bin/env python3
"""校验「Swift 序列化的路由配置字段」是否覆盖「Python 读取的契约键」。

背景：`MODEL_PROXY_ROUTER` 的 JSON 由 Swift `TokenProxyManager.routerJSON()` 生成，
Python `proxy_router.RouterConfig` 读取。两侧字段一旦不同步，Python 只会静默回退到
兜底值——功能看起来正常，实际配置没生效（历史上 `max_retries` 等 4 个键就这样失效
了很久，因为兜底值恰好等于文档值所以没人发现）。

本脚本从**两侧的真实源码**提取字段：
  - Swift：解析 `TokenProxyManager.swift` 里 `*Payload: Encodable` 的 `let` 字段名
  - Python：导入 `proxy_router.CONTRACT_KEYS`

断言 Swift 的字段集合 ⊇ Python 的契约键集合。不覆盖 → 退出码 1。

用法（仓库根目录）：  python3 scripts/check-router-config-contract.py
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(ROOT, "Sources", "MCP", "TokenProxyManager.swift")
SCRIPTS = os.path.join(ROOT, "Sources", "MCPScripts")

#: JSON 分组 → Swift 中承载该分组的 Payload 结构体名
GROUP_STRUCT = {
    "root": "RouterPayload",
    "classifier": "ClassifierPayload",
    "policy": "PolicyPayload",
    "conversation": "ConversationPayload",
    "profile": "ProfilePayload",
}

_STRUCT_RE = re.compile(r"struct\s+(\w+)\s*:\s*Encodable\s*\{(.*?)\n\s*\}", re.S)
_FIELD_RE = re.compile(r"\blet\s+(\w+)\s*:")


def parse_swift_payloads(path: str) -> dict[str, set[str]]:
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"[contract] 无法读取 {path}: {e}")
        sys.exit(2)
    out: dict[str, set[str]] = {}
    for name, body in _STRUCT_RE.findall(src):
        out[name] = set(_FIELD_RE.findall(body))
    if not out:
        print(f"[contract] 未在 {path} 中解析到任何 *Payload 结构体——正则失配，请更新本脚本")
        sys.exit(2)
    return out


def find_violations(
    payloads: dict[str, set[str]], contract: dict[str, tuple[str, ...]]
) -> list[str]:
    """纯函数：给定两侧字段集合，返回契约违反清单。

    抽成纯函数是为了能被反向测试——一个永远为空的检查器和没有检查器是一回事。
    `scripts/check-router-config-contract.py --selftest` 用变异的输入验证它确实会报错。
    """
    violations: list[str] = []
    for group, keys in contract.items():
        struct = GROUP_STRUCT.get(group)
        if struct is None:
            violations.append(f"分组 {group!r} 在脚本的 GROUP_STRUCT 里没有对应结构体")
            continue
        fields = payloads.get(struct)
        if fields is None:
            violations.append(f"Swift 侧找不到结构体 {struct}（分组 {group}）")
            continue
        for key in keys:
            if key not in fields:
                violations.append(
                    f"{struct}.{key} 缺失 —— Python 的 {group}.{key} 会静默走兜底值"
                )
    return violations


def selftest(contract: dict[str, tuple[str, ...]]) -> int:
    """反向验证：删字段 / 改结构体名 / 删整个分组，必须都被抓到。"""
    import copy

    base = parse_swift_payloads(SWIFT)
    cases = {
        "删掉 PolicyPayload.checkpoint_interval": lambda p: p["PolicyPayload"].discard(
            "checkpoint_interval"
        ),
        "删掉 ClassifierPayload.total_budget_ms": lambda p: p["ClassifierPayload"].discard(
            "total_budget_ms"
        ),
        "删掉整个 ProfilePayload": lambda p: p.pop("ProfilePayload"),
    }
    failed = []
    for name, mutate in cases.items():
        mutated = copy.deepcopy(base)
        mutate(mutated)
        if not find_violations(mutated, contract):
            failed.append(name)
    if failed:
        print("[contract] ✗ 自检失败：以下变异未被检出 ——", "; ".join(failed))
        return 2
    print(f"[contract] ✓ 自检通过：{len(cases)} 种变异全部被检出")
    return 0


def main() -> int:
    sys.path.insert(0, SCRIPTS)
    try:
        from proxy_router import CONTRACT_KEYS
    except Exception as e:  # 导入失败说明 Python 侧已经坏了，同样不该静默
        print(f"[contract] 导入 proxy_router.CONTRACT_KEYS 失败: {type(e).__name__}: {e}")
        return 2

    if "--selftest" in sys.argv[1:]:
        return selftest(CONTRACT_KEYS)

    violations = find_violations(parse_swift_payloads(SWIFT), CONTRACT_KEYS)

    if violations:
        print("[contract] ✗ 路由配置契约不一致：")
        for v in violations:
            print("  -", v)
        print(
            f"\n修复：在 {os.path.relpath(SWIFT, ROOT)} 的对应 Payload 结构体与赋值处补上字段，"
            "并同步 default-config.yaml。"
        )
        return 1

    total = sum(len(v) for v in CONTRACT_KEYS.values())
    print(f"[contract] ✓ Swift 序列化字段完整覆盖 Python 契约键（{total} 个）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
