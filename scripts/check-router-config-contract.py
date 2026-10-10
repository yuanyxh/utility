#!/usr/bin/env python3
"""校验 Swift ↔ Python 之间的跨语言契约是否一致。

**文件名保留历史名**（最初只覆盖 router，该特性已移除）；实际覆盖范围已扩展到
全部跨语言契约面，共六组，每组都由「Swift 侧真实源码」与「Python 侧真实源码」
交叉断言：

  1. providers —— `MODEL_PROXY_PROVIDERS` ←→ `proxy_provider.KEY_*`
  2. client    —— `MODEL_PROXY_CLIENT_ACCEL` / `MODEL_PROXY_CLIENT_TEXT`
                  ←→ `proxy_client.ACCEL_CONTRACT_KEYS` / `ACCEL_CLIENT_KEYS` /
                     `CLIENT_TEXT_CONTRACT_KEYS`
  3. env 名     —— Swift 侧**实际注入点**（`env["NAME"] = …` / `env[EnvKeys.xxx] = …`）
                  ⊇ `config.py` 读取的环境变量名；反向断言 `EnvKeys` 声明的常量都有注入点
  4. 进程/约定 —— 服务名（server.py ↔ MCPProcessManager.swift）、脚本名
                  （`PythonScripts` ↔ `Sources/MCPScripts/*.py` 实际文件）、
                  同义词表 env 名（`synonyms.SYNONYMS_ENV_KEY` ↔ `synonymsEnvKey`）、
                  工具默认值 env 名（`tool_defaults.TOOL_DEFAULTS_ENV_KEY` ↔ `toolDefaultsEnvKey`）、
                  输出瘦身 env 名（`proxy_output_filter.OUTPUT_FILTER_ENV_KEY` ↔ `outputFilterEnvKey`）、
                  响应注记 env 名（`proxy_response_note.RESPONSE_NOTE_ENV_KEY` ↔ `responseNoteEnvKey`）
  5. 提示词     —— `MCPScripts/prompts/<lang>/<feature>.md` 可被**生产解析器**
                  （`prompt_loader.parse_template`）接受、占位符与基线登记一致、
                  翻译版的 `json_keys` 与基线一致；Swift 侧有 L10n 兜底的 feature
                  还要求正文与 `Resources/<lang>.json` 逐字一致；基线语言两侧同值
  6. 参数描述   —— `server.py` 的 `handle_list_tools()` 里每个参数描述都必须经
                  `tool_text.param_text(...)` 取（无裸字面量）、引用的键存在于
                  `PARAM_TEXT`、表中无孤儿键、各键语言集合一致且含基线；
                  基线语言与第 5 组同值

背景：两侧一旦不同步，Python 只会静默回退到兜底值——功能看起来正常，
实际配置没生效。历史上 `max_retries` 等 4 个键就这样失效了很久，因为兜底值
恰好等于文档值所以没人发现；providers 侧同样有 `api_format` 读不到就退回
anthropic 的静默路径，而那个默认值会让协议转换方向直接错掉。env 名与脚本名
同理：Swift 改了名而 Python 没跟，读到的是空值，报错要等到下次定时任务才看得见。

本脚本从**两侧的真实源码**提取(不读运行时、不依赖已构建产物)：
  - Swift：解析 `TokenProxyManager.swift` 的 `*Payload: Encodable` 字段（providers
    的 `Payload` 另按 `CodingKeys` 映射，才是最终写进 JSON 的键）、`Constants.swift`
    的 `EnvKeys`/`PythonScripts`、`MCPProcessManager.swift` 的服务名。
  - Python：导入 `proxy_provider` / `proxy_client` 的契约常量，
    并正则读取 `config.py` 的环境变量名、`server.py` 的服务名。

不满足即退出码 1。用法（仓库根目录）：
    python3 scripts/check-router-config-contract.py
    python3 scripts/check-router-config-contract.py --selftest
"""

from __future__ import annotations

import ast
import copy
import json
import os
import pathlib
import re
import sys
from dataclasses import dataclass, replace

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources")
SWIFT = os.path.join(SOURCES, "MCP", "TokenProxyManager.swift")
SCRIPTS = os.path.join(SOURCES, "MCPScripts")
CONSTANTS = os.path.join(SOURCES, "Core", "Constants.swift")
MCP_MANAGER = os.path.join(SOURCES, "MCP", "MCPProcessManager.swift")
CONFIG_PY = os.path.join(SCRIPTS, "config.py")
SERVER_PY = os.path.join(SCRIPTS, "server.py")
SYNONYMS_PY = os.path.join(SCRIPTS, "synonyms.py")
TOOL_DEFAULTS_PY = os.path.join(SCRIPTS, "tool_defaults.py")
OUTPUT_FILTER_PY = os.path.join(SCRIPTS, "proxy_output_filter.py")
RESPONSE_NOTE_PY = os.path.join(SCRIPTS, "proxy_response_note.py")
TOOL_TEXT_PY = os.path.join(SCRIPTS, "tool_text.py")
RESOURCES = os.path.join(SOURCES, "Resources")
PROMPTS = os.path.join(SCRIPTS, "prompts")
PROMPT_MANAGER = os.path.join(SOURCES, "Core", "PromptManager.swift")

#: 已外置成文件的提示词 feature → 声明占位符（**基线语言**的权威值）。
#: Swift（`PromptManager`）与 Python（`prompt_loader`）共用这批文件。
PROMPT_FEATURES = {
    # Swift 侧（Translator）
    "translate": ("source", "target"),
    "translate_auto": ("first", "second"),
    # Python 侧（summarize / summary_rules / server）
    "quality_judge": (),
    "quality_judge_user": ("text",),
    "aggregate": ("label", "facts_text"),
    "merge_cross_batch": ("entries",),
    "extract_keywords": (
        "SUMMARY_KEYWORD_COUNT",
        "topic",
        "facts",
        "SEARCH_MIN_TOKEN_LEN",
    ),
    "decide_merge": ("topic", "facts", "candidates"),
    "gen_new": ("topic", "facts", "dir_tree", "tops_block", "exclude_dirs"),
    "gen_merge": ("topic", "facts", "target", "context"),
    "extract_rules": ("facts_text", "level_labels", "titles_block"),
    "contradiction": ("items_text", "content"),
}
#: 基线语言：所有 feature 都必须有它（它是任何语言的回退目标，缺了就是普遍性损坏）
PROMPT_BASELINE_LANG = "zh-Hans"
#: 其它已提供的语言。这些**按存在性**校验：渐进补译是正常节奏，
#: 强制齐全会让「先写中文、稍后补英文」这类正常流程无法通过校验。
PROMPT_OTHER_LANGS = ("en",)
#: 有 L10n JSON 兜底的 feature——只有它们要求 `Resources/<lang>.json` 里
#: 有同文正文（Swift 侧文件缺失时回退该文案；Python 侧无此路径）。
L10N_BACKED_FEATURES = ("translate", "translate_auto")

#: providers 的 Payload 结构体名（定义在 `providersJSON()` 内层作用域）
PROVIDER_STRUCT = "Payload"

#: clientAccel / clientText 的 Payload 结构体名（同样定义在方法内层作用域）。
#: 字段名直接是 snake_case（无需 CodingKeys），与 Python 契约键同名。
CLIENT_STRUCTS = ("AccelPayload", "MatcherPayload", "TextPayload")

_FIELD_RE = re.compile(r"\blet\s+(\w+)\s*:")
_CASE_MAP_RE = re.compile(r'case\s+(\w+)\s*=\s*"([^"]+)"')
#: `static let 名称 = "字面量"`（`EnvKeys` / `PythonScripts` 的值提取）
_STATIC_LET_RE = re.compile(r'static\s+let\s+(\w+)\s*=\s*"([^"]+)"')
#: Swift 里**把 env 名送进子进程环境**的写法：`env["NAME"] = …` / `env[EnvKeys.xxx] = …`
#: （方括号前的标识符任意：env / overrides / 局部变量都算，已核对本仓无其它形态）。
#: 刻意**不**匹配「任意 `"UPPER_SNAKE"` 字面量」——`EnvKeys` 的声明本身就是一串这种字面量，
#: 按「出现过」收集会让第 3 组恒真，详见 `collect_swift_env_injections`。
_SWIFT_ENV_ASSIGN_RE = re.compile(
    r'\b\w+\[\s*(?:"([A-Z][A-Z0-9_]{2,})"|EnvKeys\.(\w+))\s*\]\s*='
)
#: Python `get("NAME", ...)`。`config.py` 是公共 env 层的唯一读取入口
_PY_ENV_READ_RE = re.compile(r'\bget\(\s*"([A-Z][A-Z0-9_]+)"')
#: Python 脚本**直读**的 env（`os.environ.get("NAME"`）。脚本专属 env 不进 `config.py`
#: 公共层，故第 3 组原先看不到它们——`MODEL_PROXY_CLIENT_ACCEL` / `MODEL_PROXY_CLIENT_TEXT`
#: 这类两侧各写一份字面量的名字因此长期无断言：Swift 改名而 Python 没跟时，配置静默回退
#: 内置默认，零报错（`MCP_SYNONYMS` 曾被单独兜住，正是同一个问题）。
_PY_SCRIPT_ENV_READ_RE = re.compile(r'os\.environ\.get\(\s*"([A-Z][A-Z0-9_]+)"')
#: Python 脚本**自设**的 env（`os.environ["NAME"] = …`）。这些不需要 Swift 注入——
#: 断言时必须从「读了就必须有人注入」里剔除，否则 `POSTHOG_DISABLED` / `MEM0_TELEMETRY`
#: 这类自给自足的名字会恒报错（它们由 server.py 在 import 前自己设，正是为了绕开外部依赖）。
_PY_SCRIPT_ENV_SET_RE = re.compile(r'os\.environ\[\s*"([A-Z][A-Z0-9_]+)"\s*\]\s*=')

#: 脚本直读、但**不需要** Swift 注入的 env —— 断言时的显式豁免。
#: 每一条都必须写明理由：白名单是「读了就必须有人注入」这条闸门唯一的漏口，加错的代价
#: 比不加更大（真缺口会被永久静默，而且看起来像已经检查过）。
_SCRIPT_ENV_EXEMPT: dict[str, str] = {
    # 系统/解释器提供，由 shell、launchd 或 CPython 自己给出
    "PATH": "系统提供（ast_extractor 用它定位外部解析器，不来自 Swift 注入）",
    # 内部调优旋钮：有内置默认、不进 config.yaml 的配置面，只在手动设 env / 测试时用。
    # 若将来要做成用户可配项，必须同时补 Swift 注入点——那时应把它从本表里删掉。
    "EMBED_QUERY_CACHE_SIZE": "内部调优值，有内置默认（server_embed），非用户配置面",
}
#: 服务名两侧的写法
_PY_SERVER_NAME_RE = re.compile(r'SERVER_NAME\s*=\s*"([^"]+)"')
_SWIFT_SERVICE_RE = re.compile(r'service:\s*"([^"]+)"')
#: `PromptManager.fallbackLanguage = "zh-Hans"`
_SWIFT_FALLBACK_LANG_RE = re.compile(r'fallbackLanguage\s*=\s*"([^"]+)"')
#: 同义词表 env 名两侧的写法（该 env 不进 config.py，故不在第 3 组的覆盖范围内，
#: 单独交叉断言——否则 Swift 改了名而 Python 没跟，表现是「内置表照常工作、
#: 我配的同义词静默失效」）
_PY_SYNONYMS_ENV_RE = re.compile(r'SYNONYMS_ENV_KEY\s*=\s*"([^"]+)"')
_SWIFT_SYNONYMS_ENV_RE = re.compile(r'synonymsEnvKey\s*=\s*"([^"]+)"')
#: 工具默认值 env 名两侧的写法（同上，脚本专属 env 不走 config.py）
_PY_TOOL_DEFAULTS_ENV_RE = re.compile(r'TOOL_DEFAULTS_ENV_KEY\s*=\s*"([^"]+)"')
_SWIFT_TOOL_DEFAULTS_ENV_RE = re.compile(r'toolDefaultsEnvKey\s*=\s*"([^"]+)"')
#: 输出瘦身 env 名两侧的写法（同上，脚本专属 env 不走 config.py）
_PY_OUTPUT_FILTER_ENV_RE = re.compile(r'OUTPUT_FILTER_ENV_KEY\s*=\s*"([^"]+)"')
_SWIFT_OUTPUT_FILTER_ENV_RE = re.compile(r'outputFilterEnvKey\s*=\s*"([^"]+)"')
#: 响应注记开关 env 名两侧的写法（同上，脚本专属 env 不走 config.py）
_PY_RESPONSE_NOTE_ENV_RE = re.compile(r'RESPONSE_NOTE_ENV_KEY\s*=\s*"([^"]+)"')
_SWIFT_RESPONSE_NOTE_ENV_RE = re.compile(r'responseNoteEnvKey\s*=\s*"([^"]+)"')


def _read(path: str) -> str | None:
    try:
        return open(path, encoding="utf-8").read()
    except OSError:
        return None


def _extract_block(src: str, header: re.Pattern[str]) -> str | None:
    """按花括号配平提取 `header` 匹配到的块的体。

    不能沿用非贪婪的 `struct … \\{ (.*?) \\n\\s*\\}`：providers 的 Payload 里嵌了
    一个 CodingKeys，非贪婪匹配会提前截断在这里，把后面的字段全漏掉。
    `EnvKeys` / `PythonScripts` 等 enum 与 struct 通用，故提出为公共函数。
    """
    m = header.search(src)
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


def _extract_struct_body(src: str, struct_name: str) -> str | None:
    """按花括号配平提取 `struct <name>: Encodable` 的体。"""
    return _extract_block(
        src, re.compile(rf"struct\s+{re.escape(struct_name)}\s*:\s*Encodable\s*\{{")
    )


def _extract_enum_body(src: str, enum_name: str) -> str | None:
    """按花括号配平提取 `enum <name> { … }` 的体（体后有 `: String` 也兼容）。"""
    return _extract_block(src, re.compile(rf"enum\s+{re.escape(enum_name)}\b[^{{]*\{{"))


def parse_swift_payloads(path: str) -> dict[str, set[str]]:
    src = _read(path)
    if src is None:
        print(f"[contract] 无法读取 {path}")
        sys.exit(2)

    out: dict[str, set[str]] = {}
    for name in (PROVIDER_STRUCT, *CLIENT_STRUCTS):
        body = _extract_struct_body(src, name)
        if body is not None:
            out[name] = set(_FIELD_RE.findall(body))
    if not out:
        print(
            f"[contract] 未在 {path} 中解析到任何 *Payload 结构体——正则失配，请更新本脚本"
        )
        sys.exit(2)
    return out


def parse_provider_json_keys(path: str) -> set[str]:
    """providers 的 Payload 最终写进 JSON 的键集合。

    Swift 属性名要先经 `CodingKeys` 映射（`apiFormat` → `api_format`），
    没有映射的用属性名本身。只认属性名会把校验对准错误的字符串。
    """
    src = _read(path)
    if src is None:
        return set()
    body = _extract_struct_body(src, PROVIDER_STRUCT)
    if body is None:
        return set()

    props = set(_FIELD_RE.findall(body))
    ck = re.search(
        r"enum\s+CodingKeys\s*:\s*String\s*,\s*CodingKey\s*\{(.*?)\}", body, re.S
    )
    mapped = dict(_CASE_MAP_RE.findall(ck.group(1))) if ck else {}
    # JSONEncoder 默认把属性名原样写出；只有 CodingKeys 里显式给出的才改写
    return {mapped.get(p, p) for p in props}


def find_provider_violations(
    json_keys: set[str], contract: tuple[str, ...]
) -> list[str]:
    """纯函数：providers 契约的违反清单（同样可被反向测试）。"""
    if not json_keys:
        return ["Swift 侧解析不到 providers 的 Payload 结构体（providersJSON）"]
    return [
        f"providers.{key} 缺失 —— Python 读取该键失败后会静默退回默认值"
        for key in contract
        if key not in json_keys
    ]


def parse_static_lets(path: str, enum_name: str) -> dict[str, str]:
    """`enum <name>` 体内的 `static let 常量名 = "字面量"` → {常量名: 字面量}。"""
    src = _read(path)
    if src is None:
        return {}
    body = _extract_enum_body(src, enum_name)
    return dict(_STATIC_LET_RE.findall(body)) if body else {}


def collect_swift_env_injections(
    sources_dir: str, env_keys: dict[str, str]
) -> set[str]:
    """Swift 侧**实际注入**的 env 名集合——而不是「源码里出现过这个名字」。

    两者的差别就是这条判据的全部意义。`EnvKeys` 的声明本身就是一串 `"UPPER_SNAKE"`
    字面量，按「出现过」来收集时它自己就满足了「Python 读了必须有人注入」，第 3 组于是
    **恒真**：它抓不到真正要防的那类漏加。`AI_LLM_TIMEOUT` 与 `UTILITY_LANG` 只加进了
    `baseEnvironment()`、没加进内部 `.sh` 任务的白名单，就是这样溜过去的——配了超时和
    语言的用户，在定时总结链路上拿到的是默认 120s 与中文提示词，且没有任何报错。

    认两种写法（本仓全部注入点，已核对无其它形态）：
      `env["NAME"] = …` / `overrides["NAME"] = …`          字面量键
      `env[EnvKeys.xxx] = …`                              常量键，按 `env_keys` 展开
    """
    out: set[str] = set()
    for dirpath, _dirnames, filenames in os.walk(sources_dir):
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            src = _read(os.path.join(dirpath, name))
            if not src:
                continue
            for literal, const in _SWIFT_ENV_ASSIGN_RE.findall(src):
                if literal:
                    out.add(literal)
                elif const:
                    value = env_keys.get(const)
                    if value:
                        out.add(value)
    return out


def parse_python_env_reads(path: str) -> set[str]:
    """`config.py` 里 `get("NAME")` 读到的环境变量名（公共 env 层的契约面）。"""
    return set(_PY_ENV_READ_RE.findall(_read(path) or ""))


def parse_python_script_envs(scripts_dir: str) -> tuple[set[str], set[str]]:
    """全部 `MCPScripts/**.py` 里直读与自设的 env 名：`(reads, self_set)`。

    公共层（`config.py`）之外还有一类**脚本专属 env**：`MODEL_PROXY_*`、`MCP_SYNONYMS`、
    `QDRANT_PATH` 等由 Swift 直接注入、脚本 `os.environ.get` 直接读。它们原先只在
    `config.py` 的采集范围外，于是「Swift 改名而 Python 没跟」这类漂移没有任何断言
    （只有 `MCP_SYNONYMS` 曾被单独兜住）。

    自设的那类要单独收集：它们由脚本自己在 import 前设（`POSTHOG_DISABLED` 是为了阻止
    mem0 的遥测在建连阶段卡死），本就不该有 Swift 注入点，混进断言会恒报错。
    """
    reads: set[str] = set()
    self_set: set[str] = set()
    for dirpath, _dirnames, filenames in os.walk(scripts_dir):
        for name in filenames:
            if not name.endswith(".py"):
                continue
            src = _read(os.path.join(dirpath, name))
            if not src:
                continue
            reads |= set(_PY_SCRIPT_ENV_READ_RE.findall(src))
            self_set |= set(_PY_SCRIPT_ENV_SET_RE.findall(src))
    return reads, self_set


def find_env_violations(
    python_reads: set[str], swift_injections: set[str]
) -> list[str]:
    """纯函数：Python 读了、但 Swift 侧没有任何**注入点**的 env 名。

    这类名字在运行期恒为空——访问器返回默认值，功能静默停摆（如 AI key 读不到时
    总结直接 return）。方向是单向的：Swift 注入而 Python 不读的名字不断言，
    有些 env 是给子进程/第三方客户端用的，反向断言会误报。

    ⚠️ 这里必须传「实际注入」而不是「源码里出现过」：后者会被 `EnvKeys` 的声明本身满足，
    判据恒真。**本组防的是「漏了一个注入点」**——但那属于集合覆盖问题，「出现过」型判据
    永远看不见它（`collect_swift_env_injections` 的 docstring 记着具体事故）。
    """
    if not python_reads:
        return [
            f"未从 {os.path.relpath(CONFIG_PY, ROOT)} 解析到任何 env 读取"
            "——正则失配，请更新本脚本"
        ]
    return [
        f"env {name} —— Python 在 config.py 读取它，但 Swift 侧没有任何注入点，运行期恒为空"
        for name in sorted(python_reads)
        if name not in swift_injections
    ]


def find_script_env_violations(
    script_reads: set[str],
    script_self_set: set[str],
    swift_injections: set[str],
) -> list[str]:
    """纯函数：脚本**直读**、但 Swift 侧没有任何注入点的专属 env。

    公共层那条（`find_env_violations`）只看 `config.py`，覆盖不到脚本直读的那批：
    `MODEL_PROXY_PORT` / `MODEL_PROXY_PROVIDERS` /
    `MODEL_PROXY_CLIENT_ACCEL` / `MODEL_PROXY_CLIENT_TEXT` 等。它们的名字在两侧各写一份
    字面量，改名只改一侧时配置**静默回退内置默认**——与 `MCP_SYNONYMS` 是同一类问题，
    区别只是后者曾被单独兜住。

    自设的那批（`script_self_set`）必须剔除：那是脚本自己为绕开外部依赖而设的
    （`POSTHOG_DISABLED` 等），本就没有 Swift 注入点。
    """
    if not script_reads:
        return [
            f"未从 {os.path.relpath(SCRIPTS, ROOT)} 解析到任何 os.environ 直读"
            "——正则失配，请更新本脚本"
        ]
    return [
        f"env {name} —— Python 脚本直读它，但 Swift 侧没有任何注入点，运行期恒为空"
        for name in sorted(script_reads - script_self_set - set(_SCRIPT_ENV_EXEMPT))
        if name not in swift_injections
    ]


def find_env_injection_violations(
    env_keys: dict[str, str], swift_injections: set[str]
) -> list[str]:
    """纯函数：`EnvKeys` 声明了、却没有任何注入点使用它的常量。

    与上一条互补：那条防「配置读不到」（Python 读了没人注入），这条防「登记了却没人用」
    ——后者正是改名只改一半的形态（声明改了、`env[EnvKeys.xxx] = …` 那行漏改），
    表现同样是运行期拿到空值。
    """
    if not env_keys:
        return ["未从 Constants.swift 解析到 EnvKeys——正则失配，请更新本脚本"]
    return [
        f"EnvKeys.{const} = {value!r} 已声明，但 Swift 侧没有任何注入点使用它"
        for const, value in sorted(env_keys.items())
        if value not in swift_injections
    ]


def find_env_key_violations(
    env_keys: dict[str, str], python_reads: set[str]
) -> list[str]:
    """纯函数：`EnvKeys` 声明的名字与 Python 实际读取的名字不一致。

    `EnvKeys` 是这些 env 名的**单一来源**，正反两个方向都断言：Swift 注入了没人读
    =死配置；Python 读了没人注入=恒空。改名的典型故障正是二者只改了一侧。
    """
    if not env_keys:
        return ["未从 Constants.swift 解析到 EnvKeys——正则失配，请更新本脚本"]
    return [
        f"EnvKeys.{const} = {value!r} 已由 Swift 注入，但 Python（config.py）从未读取该名字"
        for const, value in sorted(env_keys.items())
        if value not in python_reads
    ]


def find_script_violations(scripts: dict[str, str], script_dir: str) -> list[str]:
    """纯函数：`PythonScripts` 声明的文件名必须真实存在。

    找错文件的表现是子进程秒退/功能整体不可用，但错误发生在子进程里，主进程只看到
    「任务失败」；在这里断言能把定位成本降到零。反向（目录里有 .py 未登记）不断言：
    大量 .py 是被其他 .py import 的模块，不是 Swift 的调用目标。
    """
    if not scripts:
        return ["未从 Constants.swift 解析到 PythonScripts——正则失配，请更新本脚本"]
    return [
        f"PythonScripts.{const} = {name!r} 在 {os.path.relpath(script_dir, ROOT)} 下不存在"
        for const, name in sorted(scripts.items())
        if not os.path.isfile(os.path.join(script_dir, name))
    ]


def find_cross_language_const_violations(
    py_value: str | None,
    swift_value: str | None,
    *,
    label: str,
    py_hint: str,
    swift_hint: str,
) -> list[str]:
    """纯函数：同一常量在两侧源码里必须同值。

    「两侧各写一份字面量、只改了一处」是本项目反复出现的静默失效模式——读到空值后走
    兜底，表现为完全无关的症状。判据收在这里，新增这类常量时只需给一组标签与出处。
    """
    if not py_value or not swift_value:
        return [f"未解析到{label}（{py_hint} 或 {swift_hint}）——正则失配，请更新本脚本"]
    if py_value != swift_value:
        return [
            f"{label}不一致：{py_hint} = {py_value!r}，{swift_hint} = {swift_value!r}"
        ]
    return []


def find_service_name_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """纯函数：端口复用探测的服务名两侧必须一致。

    探测靠 `service` 字段校验「同端口的服务是不是自己人」；名字写岔会判定为他人服务
    而放弃复用，于是另起进程/端口——表现为端口漂移与重复拉起。
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="服务名",
        py_hint="server.py 的 SERVER_NAME",
        swift_hint="MCPProcessManager.swift 的 service:",
    )


def find_synonym_env_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """纯函数：同义词表 env 名两侧必须一致。

    该 env 不由 `config.py` 读取（脚本专属 env 不进公共层），故第 3 组的「Python 读了
    Swift 必须注入」覆盖不到它：Swift 改了名而 Python 没跟时，内置表照常工作、**用户配的
    同义词静默失效**——没有任何报错。
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="同义词表 env 名",
        py_hint="synonyms.py 的 SYNONYMS_ENV_KEY",
        swift_hint="MCPProcessManager.swift 的 synonymsEnvKey",
    )


def find_tool_defaults_env_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """纯函数：工具默认值 env 名两侧必须一致。

    与同义词表同理——该 env 不进 `config.py`，第 3 组覆盖不到；Swift 改了名而
    Python 没跟时，内置默认照常生效、**用户配的默认值静默失效**，表现为
    「我调小了返回条数但用量没降」。
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="工具默认值 env 名",
        py_hint="tool_defaults.py 的 TOOL_DEFAULTS_ENV_KEY",
        swift_hint="MCPProcessManager.swift 的 toolDefaultsEnvKey",
    )


def find_output_filter_env_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """纯函数：输出瘦身的配置 env 名两侧必须一致。

    该 env 同样不进 `config.py`（脚本专属 env 的既有约定），第 3 组覆盖不到。
    两侧不一致时 Python 读到空串、退回内置默认，表现为「我改了 maxBytes
    但截断阈值没变」——没有任何报错。
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="输出瘦身 env 名",
        py_hint="proxy_output_filter.py 的 OUTPUT_FILTER_ENV_KEY",
        swift_hint="TokenProxyManager.swift 的 outputFilterEnvKey",
    )


def find_response_note_env_violations(
    py_name: str | None, swift_name: str | None
) -> list[str]:
    """纯函数：响应注记开关的 env 名两侧必须一致。

    同样是脚本专属 env，第 3 组覆盖不到。两侧不一致时 Python 读到缺省值、
    开关配置静默失效——表现是「关了开关可那行还在」或反之。
    """
    return find_cross_language_const_violations(
        py_name,
        swift_name,
        label="响应注记 env 名",
        py_hint="proxy_response_note.py 的 RESPONSE_NOTE_ENV_KEY",
        swift_hint="TokenProxyManager.swift 的 responseNoteEnvKey",
    )


def find_client_violations(
    payloads: dict[str, set[str]], groups: dict[str, tuple[str, tuple[str, ...]]]
) -> list[str]:
    """纯函数：clientAccel / clientText 的 Swift payload 字段 ⊇ Python 契约键。"""
    violations: list[str] = []
    for label, (struct, keys) in groups.items():
        fields = payloads.get(struct)
        if fields is None:
            violations.append(f"Swift 侧找不到结构体 {struct}（{label}）")
            continue
        for key in keys:
            if key not in fields:
                violations.append(
                    f"{struct}.{key} 缺失 —— Python 的 {label}.{key} 会静默走兜底值"
                )
    return violations


def collect_prompt_files() -> dict[tuple[str, str], str | None]:
    """内置提示词模板文件原文；(lang, feature) → 文本，缺失为 None。"""
    return {
        (lang, feature): _read(os.path.join(PROMPTS, lang, f"{feature}.md"))
        for lang in (PROMPT_BASELINE_LANG, *PROMPT_OTHER_LANGS)
        for feature in PROMPT_FEATURES
    }


def collect_l10n_prompts() -> dict[tuple[str, str], str | None]:
    """L10n JSON 里的兜底文案；只覆盖有兜底的 feature。读不到即整组 None。"""
    out: dict[tuple[str, str], str | None] = {}
    for lang in (PROMPT_BASELINE_LANG, *PROMPT_OTHER_LANGS):
        raw = _read(os.path.join(RESOURCES, f"{lang}.json"))
        data: dict = {}
        if raw is None:
            print(f"[contract] 读不到 Resources/{lang}.json")
        else:
            try:
                data = json.loads(raw)
            except ValueError as e:
                print(f"[contract] Resources/{lang}.json 不是合法 JSON: {e}")
        for feature in L10N_BACKED_FEATURES:
            out[(lang, feature)] = data.get(f"prompt.{feature}")
    return out


def find_prompt_violations(
    prompt_files: dict[tuple[str, str], str | None],
    l10n_prompts: dict[tuple[str, str], str | None],
    parse_template,
) -> list[str]:
    """纯函数：提示词模板文件的契约违反清单。

    用**生产解析器**（`prompt_loader.parse_template`）而不是这里另写一份——校验器与运行期
    解析器不同源时，本条断言只能证明「文件的写法合校验器的口味」，与真正跑的那条路无关。
    解析取自入参文本而非重读磁盘，这样「假设的坏文件」也能被断言（自检依赖这一点）。

    遍历的是**期望集合**（语言 × feature）而不是入参字典的键：文件缺失时字典里根本没有
    这一项，按字典遍历会把它静静漏掉——而「模板漏发了」正是最常见的故障形态。

    四类断言各自对应一类真实故障：
    - 基线语言缺文件 / 文件不被解析器接受 → 所有语言都回退兜底，表现为「改的提示词没生效」
    - 声明的占位符与登记不符 → 文件自校验拒绝它，同样静默回退；且调用点传的实参是对着
      基线写的，翻译版改名会让渲染缺参
    - 翻译版的 `json_keys` 与基线不一致 → 键名是**代码解析**的契约（`missing_json_keys`
      据此校验模型输出），译错一处会让「模型没按契约输出」变得检测不出来
    - 正文与 L10n 不一致 → Swift 兜底路径下发另一套文案，且只在出问题的那台机器上出现
    """
    violations: list[str] = []
    parsed: dict[tuple[str, str], object] = {}

    for lang in (PROMPT_BASELINE_LANG, *PROMPT_OTHER_LANGS):
        required = lang == PROMPT_BASELINE_LANG
        for feature in PROMPT_FEATURES:
            rel = f"prompts/{lang}/{feature}.md"
            raw = prompt_files.get((lang, feature))
            if raw is None:
                if required:
                    violations.append(
                        f"{rel} 不存在 —— 基线语言必须齐全，缺了会让所有语言回退到兜底文案"
                    )
                continue  # 非基线语言缺失属正常（未翻译，运行时回退基线）

            try:
                tpl = parse_template(
                    raw, feature, pathlib.Path(PROMPTS) / lang / f"{feature}.md"
                )
            except Exception as e:  # PromptLoadError 或任何解析异常都算契约破坏
                violations.append(f"{rel} 不被生产解析器接受: {type(e).__name__}: {e}")
                continue
            parsed[(lang, feature)] = tpl

            if set(tpl.placeholders) != set(PROMPT_FEATURES[feature]):
                violations.append(
                    f"{rel} placeholders={sorted(tpl.placeholders)} 与基线登记的"
                    f" {sorted(PROMPT_FEATURES[feature])} 不符"
                )

    # 跨语言：json_keys 是代码解析的契约键，翻译时误改不会报错、只会让校验失效
    for feature in PROMPT_FEATURES:
        base = parsed.get((PROMPT_BASELINE_LANG, feature))
        if base is None:
            continue
        for lang in PROMPT_OTHER_LANGS:
            other = parsed.get((lang, feature))
            if other is None:
                continue
            if tuple(other.json_keys) != tuple(base.json_keys):
                violations.append(
                    f"prompts/{lang}/{feature}.md 的 json_keys={list(other.json_keys)}"
                    f" 与基线 {list(base.json_keys)} 不一致 —— 键名是代码解析的契约"
                )

    # L10n 兜底文案（仅 Swift 侧有这条路径的 feature）
    for feature in L10N_BACKED_FEATURES:
        for lang in (PROMPT_BASELINE_LANG, *PROMPT_OTHER_LANGS):
            tpl = parsed.get((lang, feature))
            if tpl is None:
                continue  # 缺失已在上面的循环里报告（基线）或属正常回退（其它语言）
            l10n = l10n_prompts.get((lang, feature))
            if l10n is None:
                violations.append(
                    f"Resources/{lang}.json 缺少 prompt.{feature}（Swift 的兜底文案）"
                )
            elif tpl.text.strip() != l10n.strip():
                violations.append(
                    f"prompts/{lang}/{feature}.md 正文与 Resources/{lang}.json 的"
                    f" prompt.{feature} 不一致 —— 兜底路径下发的是另一套文案"
                )
    return violations


def _param_text_key(node: ast.AST) -> str | None:
    """`param_text("x")`（或 `tool_text.param_text("x")`）→ `"x"`；其它形式 → None。"""
    if not isinstance(node, ast.Call) or len(node.args) != 1:
        return None
    func = node.func
    is_param_text = (isinstance(func, ast.Name) and func.id == "param_text") or (
        isinstance(func, ast.Attribute) and func.attr == "param_text"
    )
    if not is_param_text:
        return None
    arg = node.args[0]
    if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
        return arg.value
    return None


def collect_param_descriptions(path: str) -> tuple[set[str], list[str]]:
    """`handle_list_tools()` 里参数描述的使用情况：`(引用的键集合, 未走 i18n 的清单)`。

    用 AST 而非正则：`description` 这个词在 server.py 里另有多处含义（`DESCRIPTIONS.md`
    的解析、工具级 `Tool(description=...)`），正则扫全文件会把它们一起算进来，而本条
    契约的适用范围**只有** `inputSchema` 里的参数描述。

    只看函数内部、且只认 dict 的 `"description"` 键：工具级描述走 `Tool(description=...)`
    关键字参数，天然落在范围外——它由用户可覆盖的 `DESCRIPTIONS.md` 决定，不做内置多语种。
    """
    src = _read(path)
    if src is None:
        return set(), [f"无法读取 {os.path.relpath(path, ROOT)}"]
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        return set(), [f"{os.path.relpath(path, ROOT)} 语法错误: {e}"]

    func = next(
        (
            n
            for n in ast.walk(tree)
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
            and n.name == "handle_list_tools"
        ),
        None,
    )
    if func is None:
        return set(), ["server.py 里找不到 handle_list_tools——函数改名，请更新本脚本"]

    refs: set[str] = set()
    problems: list[str] = []
    for node in ast.walk(func):
        if not isinstance(node, ast.Dict):
            continue
        for key_node, value_node in zip(node.keys, node.values):
            if not (
                isinstance(key_node, ast.Constant) and key_node.value == "description"
            ):
                continue
            key = _param_text_key(value_node)
            if key is not None:
                refs.add(key)
            elif isinstance(value_node, ast.Constant) and isinstance(
                value_node.value, str
            ):
                problems.append(
                    f"line {node.lineno}: 裸字面量 {value_node.value[:40]!r}（未经 param_text）"
                )
            else:
                problems.append(
                    f"line {node.lineno}: 无法判定的 description 形式 {type(value_node).__name__}"
                )
    return refs, problems


def find_param_text_violations(
    refs: set[str],
    problems: list[str],
    table: dict[str, dict[str, str]],
    baseline_lang: str | None,
) -> list[str]:
    """纯函数：工具参数描述 i18n 的契约违反清单。

    五类断言各自对应一类真实故障：
    - schema 里出现未经 `param_text` 的描述 → 该参数永远只有一种语言（漏改一处就是这样
      发生的），混语言时才会被看见，而没人会去看每个参数；
    - 引用了表中不存在的键 → 运行期抛 `MissingParamText`，**整个工具列表不可用**
      （不是某条描述降级成兜底文案，是客户端一个工具都拿不到）；
    - 表中有没人引用的键 → 改名后遗留，后人以为改一处就够；
    - 某键缺基线语言 → 该键在任何语言下都取不到值，而其它键正常，最难被注意到；
    - 各键语言集合不一致 → schema 是一次性整体呈现的，一部分参数中文、一部分英文，
      比「全部未翻译」更糟。
    """
    violations = [
        f"server.py 的参数描述未经 param_text（i18n 未覆盖）: {p}" for p in problems
    ]
    if not table:
        violations.append(
            f"未从 {os.path.relpath(TOOL_TEXT_PY, ROOT)} 导入到 PARAM_TEXT——常量改名，请更新本脚本"
        )
        return violations

    violations += [
        f"参数描述引用了未登记的键 {key!r} —— 运行期抛 MissingParamText，工具列表整体不可用"
        for key in sorted(refs - set(table))
    ]
    violations += [
        f"PARAM_TEXT 中的 {key!r} 没有任何 schema 引用（改名后遗留？）"
        for key in sorted(set(table) - refs)
    ]

    if not baseline_lang:
        violations.append("未解析到 tool_text.FALLBACK_LANG——常量改名，请更新本脚本")
        return violations

    for key in sorted(table):
        if baseline_lang not in table[key]:
            violations.append(
                f"PARAM_TEXT[{key!r}] 缺基线语言 {baseline_lang!r} —— 它在任何语言下都取不到值"
            )

    # 语言集合一致：以「多数派」为基准报出少数派，避免全表报错淹没真正的差异
    lang_sets = {key: frozenset(langs) for key, langs in table.items()}
    distinct = set(lang_sets.values())
    if len(distinct) > 1:
        majority = max(
            distinct, key=lambda s: sum(1 for v in lang_sets.values() if v == s)
        )
        violations += [
            f"PARAM_TEXT[{key!r}] 的语言 {sorted(langs)} 与多数键的 {sorted(majority)} 不一致"
            " —— schema 整体呈现，混语言比统一未翻译更糟"
            for key, langs in sorted(lang_sets.items())
            if langs != majority
        ]
    return violations


def find_baseline_lang_violations(langs: dict[str, str | None]) -> list[str]:
    """纯函数：基线语言在**所有**持有它的模块里必须同值。

    它决定「当前语言缺这套文案时回退到哪一套」——提示词与工具参数描述共用同一个判据。
    任一处漂移，同一份缺失在两条路径上会得到不同结果，且两边都不会报错。
    """
    missing = sorted(source for source, value in langs.items() if not value)
    if missing:
        return [
            f"未解析到基线语言（{'、'.join(missing)}）——常量改名或正则失配，请更新本脚本"
        ]
    if len(set(langs.values())) > 1:
        return [
            "基线语言不一致："
            + "、".join(
                f"{source} = {value!r}" for source, value in sorted(langs.items())
            )
        ]
    return []


@dataclass(frozen=True)
class ContractInputs:
    """从两侧真实源码收集到的一次性输入。

    收成一个对象是为了让 `check_all` 与 `--selftest` 走**同一份判据**：自检若自己
    重新拼一遍输入，就可能在真实路径之外自证清白（改了真实解析而自检仍绿）。
    """

    swift_payloads: dict[str, set[str]]
    provider_keys: set[str]
    client_groups: dict[str, tuple[str, tuple[str, ...]]]
    swift_env_injections: set[str]
    env_keys: dict[str, str]
    python_env_reads: set[str]
    python_script_env_reads: set[str]
    python_script_env_sets: set[str]
    python_scripts: dict[str, str]
    py_server_name: str | None
    swift_service_name: str | None
    prompt_files: dict[tuple[str, str], str | None]
    l10n_prompts: dict[tuple[str, str], str | None]
    swift_fallback_lang: str | None
    python_fallback_lang: str | None
    py_synonyms_env: str | None
    swift_synonyms_env: str | None
    py_tool_defaults_env: str | None
    swift_tool_defaults_env: str | None
    py_output_filter_env: str | None
    swift_output_filter_env: str | None
    py_response_note_env: str | None
    swift_response_note_env: str | None
    param_ref_keys: set[str]
    param_problems: list[str]
    param_table: dict[str, dict[str, str]]
    python_tool_text_lang: str | None


def _first_match(pattern: re.Pattern[str], src: str) -> str | None:
    m = pattern.search(src)
    return m.group(1) if m else None


def _drop_from_payload(
    inp: ContractInputs, struct: str, field: str
) -> dict[str, set[str]]:
    """返回「删掉某结构体某字段」后的 payloads（selftest 造变异用）。"""
    out = {k: set(v) for k, v in inp.swift_payloads.items()}
    out.setdefault(struct, set()).discard(field)
    return out


def _drop_struct(inp: ContractInputs, struct: str) -> dict[str, set[str]]:
    out = {k: set(v) for k, v in inp.swift_payloads.items()}
    out.pop(struct, None)
    return out


def collect_inputs(
    client_groups: dict[str, tuple[str, tuple[str, ...]]],
    python_fallback_lang: str | None,
    param_table: dict[str, dict[str, str]],
    python_tool_text_lang: str | None,
) -> ContractInputs:
    """收集两侧真实源码里的契约输入（唯一采集口）。"""
    param_ref_keys, param_problems = collect_param_descriptions(SERVER_PY)
    # EnvKeys 要先解析：注入点的常量键（`env[EnvKeys.xxx] = …`）按它展开成真实 env 名
    env_keys = parse_static_lets(CONSTANTS, "EnvKeys")
    script_env_reads, script_env_sets = parse_python_script_envs(SCRIPTS)
    return ContractInputs(
        swift_payloads=parse_swift_payloads(SWIFT),
        provider_keys=parse_provider_json_keys(SWIFT),
        client_groups=client_groups,
        env_keys=env_keys,
        swift_env_injections=collect_swift_env_injections(SOURCES, env_keys),
        python_env_reads=parse_python_env_reads(CONFIG_PY),
        python_script_env_reads=script_env_reads,
        python_script_env_sets=script_env_sets,
        python_scripts=parse_static_lets(CONSTANTS, "PythonScripts"),
        py_server_name=_first_match(_PY_SERVER_NAME_RE, _read(SERVER_PY) or ""),
        swift_service_name=_first_match(_SWIFT_SERVICE_RE, _read(MCP_MANAGER) or ""),
        prompt_files=collect_prompt_files(),
        l10n_prompts=collect_l10n_prompts(),
        swift_fallback_lang=_first_match(
            _SWIFT_FALLBACK_LANG_RE, _read(PROMPT_MANAGER) or ""
        ),
        python_fallback_lang=python_fallback_lang,
        py_synonyms_env=_first_match(_PY_SYNONYMS_ENV_RE, _read(SYNONYMS_PY) or ""),
        swift_synonyms_env=_first_match(
            _SWIFT_SYNONYMS_ENV_RE, _read(MCP_MANAGER) or ""
        ),
        py_tool_defaults_env=_first_match(
            _PY_TOOL_DEFAULTS_ENV_RE, _read(TOOL_DEFAULTS_PY) or ""
        ),
        swift_tool_defaults_env=_first_match(
            _SWIFT_TOOL_DEFAULTS_ENV_RE, _read(MCP_MANAGER) or ""
        ),
        py_output_filter_env=_first_match(
            _PY_OUTPUT_FILTER_ENV_RE, _read(OUTPUT_FILTER_PY) or ""
        ),
        swift_output_filter_env=_first_match(
            _SWIFT_OUTPUT_FILTER_ENV_RE, _read(SWIFT) or ""
        ),
        py_response_note_env=_first_match(
            _PY_RESPONSE_NOTE_ENV_RE, _read(RESPONSE_NOTE_PY) or ""
        ),
        swift_response_note_env=_first_match(
            _SWIFT_RESPONSE_NOTE_ENV_RE, _read(SWIFT) or ""
        ),
        param_ref_keys=param_ref_keys,
        param_problems=param_problems,
        param_table=param_table,
        python_tool_text_lang=python_tool_text_lang,
    )


def check_all(
    inp: ContractInputs,
    provider_contract: tuple[str, ...],
    parse_template,
) -> list[str]:
    """全部跨语言契约的违反清单（分组顺序同模块 docstring 的编号）。"""
    return (
        find_provider_violations(inp.provider_keys, provider_contract)
        + find_client_violations(inp.swift_payloads, inp.client_groups)
        + find_env_violations(inp.python_env_reads, inp.swift_env_injections)
        + find_script_env_violations(
            inp.python_script_env_reads,
            inp.python_script_env_sets,
            inp.swift_env_injections,
        )
        + find_env_injection_violations(inp.env_keys, inp.swift_env_injections)
        + find_env_key_violations(inp.env_keys, inp.python_env_reads)
        + find_script_violations(inp.python_scripts, SCRIPTS)
        + find_service_name_violations(inp.py_server_name, inp.swift_service_name)
        + find_synonym_env_violations(inp.py_synonyms_env, inp.swift_synonyms_env)
        + find_tool_defaults_env_violations(
            inp.py_tool_defaults_env, inp.swift_tool_defaults_env
        )
        + find_output_filter_env_violations(
            inp.py_output_filter_env, inp.swift_output_filter_env
        )
        + find_response_note_env_violations(
            inp.py_response_note_env, inp.swift_response_note_env
        )
        + find_prompt_violations(inp.prompt_files, inp.l10n_prompts, parse_template)
        + find_param_text_violations(
            inp.param_ref_keys,
            inp.param_problems,
            inp.param_table,
            inp.python_tool_text_lang,
        )
        + find_baseline_lang_violations(
            {
                "PromptManager.fallbackLanguage": inp.swift_fallback_lang,
                "prompt_loader.FALLBACK_LANG": inp.python_fallback_lang,
                "tool_text.FALLBACK_LANG": inp.python_tool_text_lang,
            }
        )
    )


def _rename_frontmatter(raw: str) -> str:
    """把 front-matter 的 `name:` 改成别的值（selftest 造变异用）。"""
    return re.sub(r"^name:\s*\S+", "name: mutated", raw, count=1, flags=re.M)


def _blank_json_keys(raw: str) -> str:
    """清空 front-matter 的 `json_keys:`（selftest 造变异用）。"""
    return re.sub(r"^json_keys:\s*\[.*?\]", "json_keys: []", raw, count=1, flags=re.M)


def selftest(
    inp: ContractInputs,
    provider_contract: tuple[str, ...],
    parse_template,
) -> int:
    """反向验证：每一种「两侧脱钩」的写法都必须被检出。

    一个永远为空的检查器和没有检查器是一回事，故每组契约都造一个变异。
    变异没生效（说明该字段已不存在/已改名）同样算失败——那意味着自检本身
    在骗人，而不是契约没问题。
    """
    base = copy.deepcopy(inp)
    cases: dict[str, ContractInputs] = {
        # providers
        "providers: 删 api_format": replace(
            base, provider_keys=base.provider_keys - {"api_format"}
        ),
        "providers: 键名退回 camelCase（CodingKeys 失效）": replace(
            base, provider_keys=(base.provider_keys - {"api_format"}) | {"apiFormat"}
        ),
        "providers: Payload 整个消失": replace(base, provider_keys=set()),
        # client（阶段 0 新增）
        "client: 删 TextPayload.injected_tags": replace(
            base,
            swift_payloads=_drop_from_payload(base, "TextPayload", "injected_tags"),
        ),
        "client: 删 MatcherPayload 整个结构体": replace(
            base, swift_payloads=_drop_struct(base, "MatcherPayload")
        ),
        # env 名
        "env: Python 读了 Swift 未注入的名字": replace(
            base, python_env_reads=base.python_env_reads | {"SWIFT_NEVER_INJECTS_THIS"}
        ),
        "env: EnvKeys 改名而 Python 未跟": replace(
            base, env_keys={**base.env_keys, "aiAPIKey": "AI_API_KEY_RENAMED"}
        ),
        "env: 某个注入点漏加（只在部分路径注入）": replace(
            base, swift_env_injections=base.swift_env_injections - {"AI_LLM_TIMEOUT"}
        ),
        "env: EnvKeys 声明了却无注入点": replace(
            base,
            env_keys={**base.env_keys, "ghostKey": "SWIFT_DECLARED_NEVER_INJECTED"},
        ),
        "env: 脚本直读的专属 env 无 Swift 注入点": replace(
            base,
            python_script_env_reads=base.python_script_env_reads
            | {"SCRIPT_READS_NEVER_INJECTED"},
        ),
        # 进程约定
        "脚本名: PythonScripts 指向不存在的文件": replace(
            base, python_scripts={**base.python_scripts, "server": "server_v2.py"}
        ),
        "服务名: 两侧不一致": replace(base, swift_service_name="other-service"),
        "同义词 env 名: 两侧不一致": replace(
            base, swift_synonyms_env="MCP_SYNONYM_RENAMED"
        ),
        "工具默认值 env 名: 两侧不一致": replace(
            base, swift_tool_defaults_env="MCP_TOOL_DEFAULT_RENAMED"
        ),
        "输出瘦身 env 名: 两侧不一致": replace(
            base, swift_output_filter_env="MODEL_PROXY_OUTPUT_RENAMED"
        ),
        "响应注记 env 名: 两侧不一致": replace(
            base, swift_response_note_env="MODEL_PROXY_NOTE_RENAMED"
        ),
        # 提示词模板（阶段 6 新增）
        "prompt: md 正文与 L10n 兜底不一致": replace(
            base,
            prompt_files={
                **base.prompt_files,
                ("en", "translate"): (base.prompt_files.get(("en", "translate")) or "")
                + " 变异",
            },
        ),
        "prompt: 基线语言缺模板文件": replace(
            base,
            prompt_files={
                k: v
                for k, v in base.prompt_files.items()
                if k != ("zh-Hans", "aggregate")
            },
        ),
        "prompt: 翻译版 json_keys 与基线不一致": replace(
            base,
            prompt_files={
                **base.prompt_files,
                ("en", "decide_merge"): _blank_json_keys(
                    base.prompt_files.get(("en", "decide_merge")) or ""
                ),
            },
        ),
        "prompt: front-matter 的 name 写错（文件放错位置）": replace(
            base,
            prompt_files={
                **base.prompt_files,
                ("zh-Hans", "translate"): _rename_frontmatter(
                    base.prompt_files.get(("zh-Hans", "translate")) or ""
                ),
            },
        ),
        "prompt: 基线语言两侧不一致": replace(base, swift_fallback_lang="en"),
        # 工具参数描述 i18n（阶段 7 新增）
        "param: schema 里出现未经 param_text 的裸描述": replace(
            base, param_problems=[*base.param_problems, "line 1: 裸字面量 '硬编码描述'"]
        ),
        "param: 引用了未登记的键": replace(
            base, param_ref_keys=base.param_ref_keys | {"param.never_registered"}
        ),
        "param: 表中存在没人引用的键": replace(
            base,
            param_table={
                **base.param_table,
                "param.orphan": {"zh-Hans": "孤儿文案", "en": "orphan"},
            },
        ),
        "param: 某键缺基线语言": replace(
            base,
            param_table={**base.param_table, "param.query": {"en": "Search query"}},
        ),
        "param: 某键语言集合与多数键不一致": replace(
            base,
            param_table={**base.param_table, "param.query": {"zh-Hans": "搜索查询"}},
        ),
        "param: 基线语言与提示词侧不一致": replace(base, python_tool_text_lang="en"),
    }

    ineffective: list[str] = []
    missed: list[str] = []
    for name, mutated in cases.items():
        if mutated == base:
            ineffective.append(name)
        elif not check_all(mutated, provider_contract, parse_template):
            missed.append(name)

    if ineffective:
        print(
            "[contract] ✗ 自检无效：以下变异未改变任何输入（字段可能已改名）——",
            "; ".join(ineffective),
        )
        return 2
    if missed:
        print("[contract] ✗ 自检失败：以下变异未被检出 ——", "; ".join(missed))
        return 2
    print(f"[contract] ✓ 自检通过：{len(cases)} 种变异全部被检出")
    return 0


#: 项目 venv 解释器（脚本需要 import Python 侧契约模块，依赖只装在这里）
VENV_PYTHON = os.path.expanduser("~/.config/utility/mcp-venv/bin/python3")


def _reexec_with_venv() -> None:
    """用项目 venv 的解释器重启自身。

    本脚本要 import `proxy_provider` / `proxy_client` 取契约常量，
    这些模块连带 `httpx` / `aiohttp` / `db` 等依赖——只有 venv 里有。用系统 python3
    跑会在 import 阶段就失败，而报错（`No module named 'httpx'`）看起来与「契约不一致」
    毫无关系，排查者会以为是契约坏了。自举后 `python3 scripts/...` 的用法保持不变。
    """
    if os.environ.get("_CONTRACT_REEXEC") == "1" or not os.path.isfile(VENV_PYTHON):
        return
    if os.path.realpath(sys.executable) == os.path.realpath(VENV_PYTHON):
        return
    os.environ["_CONTRACT_REEXEC"] = "1"
    os.execv(VENV_PYTHON, [VENV_PYTHON, os.path.abspath(__file__), *sys.argv[1:]])


def main() -> int:
    _reexec_with_venv()
    sys.path.insert(0, SCRIPTS)
    try:
        from proxy_client import (
            ACCEL_CLIENT_KEYS,
            ACCEL_CONTRACT_KEYS,
            CLIENT_TEXT_CONTRACT_KEYS,
        )
        from proxy_provider import (
            KEY_API_FORMAT,
            KEY_API_KEY,
            KEY_MODELS,
            KEY_NAME,
            KEY_URL,
        )

        # 提示词组的判据取自生产解析器本体，避免「校验器与运行期解析器不同源」
        from prompt_loader import (
            FALLBACK_LANG as PY_FALLBACK_LANG,
            parse_template as parse_prompt_template,
        )

        # 参数描述组的键表与基线同样取自生产模块本体
        from tool_text import (
            FALLBACK_LANG as PY_TOOL_TEXT_LANG,
            PARAM_TEXT as PY_PARAM_TEXT,
        )
    except Exception as e:  # 导入失败说明 Python 侧已经坏了，同样不该静默
        print(f"[contract] 导入 Python 契约失败: {type(e).__name__}: {e}")
        return 2

    provider_contract = (KEY_NAME, KEY_URL, KEY_API_FORMAT, KEY_API_KEY, KEY_MODELS)
    client_groups = {
        "clientAccel": ("AccelPayload", ACCEL_CONTRACT_KEYS),
        "clientAccel.clients": ("MatcherPayload", ACCEL_CLIENT_KEYS),
        "clientText": ("TextPayload", CLIENT_TEXT_CONTRACT_KEYS),
    }

    try:
        inputs = collect_inputs(
            client_groups, PY_FALLBACK_LANG, PY_PARAM_TEXT, PY_TOOL_TEXT_LANG
        )
    except SystemExit as e:  # parse_swift_payloads 在正则失配时直接退出
        return int(e.code or 2)

    if "--selftest" in sys.argv[1:]:
        return selftest(inputs, provider_contract, parse_prompt_template)

    violations = check_all(inputs, provider_contract, parse_prompt_template)
    if violations:
        print("[contract] ✗ 跨语言契约不一致：")
        for v in violations:
            print("  -", v)
        print(
            "\n修复：同步改 Swift 侧定义（Constants.swift / TokenProxyManager.swift / "
            "MCPProcessManager.swift）与 Python 侧的契约常量、读取点，并同步 default-config.yaml。"
        )
        return 1

    total = len(provider_contract) + sum(
        len(keys) for _, keys in client_groups.values()
    )
    print(
        f"[contract] ✓ 跨语言契约一致（providers + client 共 {total} 个键；"
        f"env 注入点 {len(inputs.swift_env_injections)} 个（EnvKeys {len(inputs.env_keys)}）、"
        f"脚本 {len(inputs.python_scripts)} 个、"
        f"服务名 {inputs.py_server_name!r}、提示词 "
        f"{sum(1 for v in inputs.prompt_files.values() if v is not None)} 份模板、"
        f"参数描述 {len(inputs.param_table)} 条"
        f"（基线 {inputs.swift_fallback_lang!r}）均已对齐）"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
