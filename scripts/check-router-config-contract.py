#!/usr/bin/env python3
"""校验「Swift 序列化的模型代理配置」是否覆盖「Python 侧的契约键」。

覆盖两块配置，二者都是 Swift 生成 JSON env、Python 解析：

  1. router    —— `MODEL_PROXY_ROUTER`   ←→ `proxy_router.CONTRACT_KEYS`
  2. providers —— `MODEL_PROXY_PROVIDERS` ←→ `proxy_provider.KEY_*`

背景：两侧字段一旦不同步，Python 只会静默回退到兜底值——功能看起来正常，
实际配置没生效。历史上 `max_retries` 等 4 个键就这样失效了很久，因为兜底值
恰好等于文档值所以没人发现；providers 侧同样有 `api_format` 读不到就退回
anthropic 的静默路径，而那个默认值会让协议转换方向直接错掉。

本脚本从**两侧的真实源码**提取字段：
  - Swift：解析 `TokenProxyManager.swift` 里 `*Payload: Encodable` 的 `let` 字段名。
    providers 的 `Payload` 另需按 `CodingKeys` 映射，才是最终写进 JSON 的键。
  - Python：导入 `proxy_router.CONTRACT_KEYS` 与 `proxy_provider.KEY_*`

断言 Swift 的字段集合 ⊇ Python 的契约键集合。不覆盖 → 退出码 1。

用法（仓库根目录）：
    python3 scripts/check-router-config-contract.py
    python3 scripts/check-router-config-contract.py --selftest
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

#: providers 的 Payload 结构体名（定义在 `providersJSON()` 内层作用域）
PROVIDER_STRUCT = "Payload"

_FIELD_RE = re.compile(r"\blet\s+(\w+)\s*:")
_CASE_MAP_RE = re.compile(r'case\s+(\w+)\s*=\s*"([^"]+)"')


def _extract_struct_body(src: str, struct_name: str) -> str | None:
    """按花括号配平提取 `struct <name>: Encodable` 的体。

    不能沿用非贪婪的 `struct … { (.*?) \\n\\s*\\}`：providers 的 Payload 里嵌了
    一个 CodingKeys，非贪婪匹配会提前截断在这里，把后面的字段全漏掉。
    """
    m = re.search(rf"struct\s+{re.escape(struct_name)}\s*:\s*Encodable\s*\{{", src)
    if not m:
        return None
    depth = 1
    i = start = m.end()
    while i < len(src) and depth > 0:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return src[start : i - 1] if depth == 0 else None


def parse_swift_payloads(path: str) -> dict[str, set[str]]:
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"[contract] 无法读取 {path}: {e}")
        sys.exit(2)

    out: dict[str, set[str]] = {}
    for name in (*GROUP_STRUCT.values(), PROVIDER_STRUCT):
        body = _extract_struct_body(src, name)
        if body is not None:
            out[name] = set(_FIELD_RE.findall(body))
    if not out:
        print(f"[contract] 未在 {path} 中解析到任何 *Payload 结构体——正则失配，请更新本脚本")
        sys.exit(2)
    return out


def parse_provider_json_keys(path: str) -> set[str]:
    """providers 的 Payload 最终写进 JSON 的键集合。

    Swift 属性名要先经 `CodingKeys` 映射（`apiFormat` → `api_format`），
    没有映射的用属性名本身。只认属性名会把校验对准错误的字符串。
    """
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        return set()
    body = _extract_struct_body(src, PROVIDER_STRUCT)
    if body is None:
        return set()

    props = set(_FIELD_RE.findall(body))
    ck = re.search(r"enum\s+CodingKeys\s*:\s*String\s*,\s*CodingKey\s*\{(.*?)\}", body, re.S)
    mapped = dict(_CASE_MAP_RE.findall(ck.group(1))) if ck else {}
    # JSONEncoder 默认把属性名原样写出；只有 CodingKeys 里显式给出的才改写
    return {mapped.get(p, p) for p in props}


def find_violations(
    payloads: dict[str, set[str]], contract: dict[str, tuple[str, ...]]
) -> list[str]:
    """纯函数：router 分组的契约违反清单。

    抽成纯函数是为了能被反向测试——一个永远为空的检查器和没有检查器是一回事。
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


def find_provider_violations(json_keys: set[str], contract: tuple[str, ...]) -> list[str]:
    """纯函数：providers 契约的违反清单（同样可被反向测试）。"""
    if not json_keys:
        return ["Swift 侧解析不到 providers 的 Payload 结构体（providersJSON）"]
    return [
        f"providers.{key} 缺失 —— Python 读取该键失败后会静默退回默认值"
        for key in contract
        if key not in json_keys
    ]


def selftest(
    contract: dict[str, tuple[str, ...]],
    provider_contract: tuple[str, ...],
    provider_keys: set[str],
) -> int:
    """反向验证：删字段 / 改结构体名 / 删整个分组 / 键名写回 camelCase，必须都被抓到。"""
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

    provider_cases = {
        "providers 删掉 api_format": lambda k: k.discard("api_format"),
        "providers 键名退回 camelCase（CodingKeys 失效）": lambda k: (
            k.discard("api_format"),
            k.add("apiFormat"),
        ),
        "providers Payload 整个消失": lambda k: k.clear(),
    }
    for name, mutate in provider_cases.items():
        mutated = set(provider_keys)
        mutate(mutated)
        if not find_provider_violations(mutated, provider_contract):
            failed.append(name)

    if failed:
        print("[contract] ✗ 自检失败：以下变异未被检出 ——", "; ".join(failed))
        return 2
    total = len(cases) + len(provider_cases)
    print(f"[contract] ✓ 自检通过：{total} 种变异全部被检出")
    return 0


def main() -> int:
    sys.path.insert(0, SCRIPTS)
    try:
        from proxy_router import CONTRACT_KEYS
        from proxy_provider import (
            KEY_API_FORMAT,
            KEY_API_KEY,
            KEY_MODELS,
            KEY_NAME,
            KEY_URL,
        )
    except Exception as e:  # 导入失败说明 Python 侧已经坏了，同样不该静默
        print(f"[contract] 导入 Python 契约失败: {type(e).__name__}: {e}")
        return 2

    provider_contract = (KEY_NAME, KEY_URL, KEY_API_FORMAT, KEY_API_KEY, KEY_MODELS)
    provider_keys = parse_provider_json_keys(SWIFT)

    if "--selftest" in sys.argv[1:]:
        return selftest(CONTRACT_KEYS, provider_contract, provider_keys)

    violations = find_violations(parse_swift_payloads(SWIFT), CONTRACT_KEYS)
    violations += find_provider_violations(provider_keys, provider_contract)

    if violations:
        print("[contract] ✗ 模型代理配置契约不一致：")
        for v in violations:
            print("  -", v)
        print(
            f"\n修复：在 {os.path.relpath(SWIFT, ROOT)} 的对应 Payload 结构体与赋值处补上字段，"
            "并同步 default-config.yaml。"
        )
        return 1

    total = sum(len(v) for v in CONTRACT_KEYS.values()) + len(provider_contract)
    print(f"[contract] ✓ Swift 序列化字段完整覆盖 Python 契约键（router + providers 共 {total} 个）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
