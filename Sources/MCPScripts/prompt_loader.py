"""Python 侧提示词统一入口：内置默认 + 用户覆盖 + 声明式契约。

提示词原先散落在 10 个函数/常量里写死（f-string 或长常量），后果有三个：想改一句
提示词得翻源码；用的人不一定用中文；改错了既不报错也没有回退。本模块把「取提示词」
收敛成一件事。

目录与优先级（同名 feature 只取最优先的那份）：

    <配置域>/prompts/<feature>.md                用户覆盖，优先级最高，**与语言无关**
    <MCPScripts>/prompts/<lang>/<feature>.md    内置默认，随包分发（.copy 保留目录结构）

两处的语言维度是**有意不同**的：内置模板面向「使用者可能是不同母语的人」，故按语言
分目录、缺该语言时回退基线；用户覆盖是**用户自己控制**的一份文件——写 prompt 的人只有
一种母语，让他「放哪个目录」取决于界面语言既无意义、又会因切换语言而失效。

配置域复用**既有** env 契约：Swift 注入的 `UTILITY_DATA_DIR` 就是 `~/.config/utility`
（`AppPaths.configDir`），故不新增 env 项。

语言取 `UTILITY_LANG`（Swift 按 `general.language`，空则系统首选注入），缺省 `zh-Hans`；
该语言没有该文件时**回退 `zh-Hans` 基线**并记 warning——某个 feature 还没翻译不该让
功能停摆，但也不能静默（否则「翻译没生效」将无从发现）。

声明式契约（front-matter，扁平键，不引入 YAML 依赖）：

    ---
    name: aggregate
    placeholders: [label, facts_text]
    json_keys: []
    ---

- `name` 必须与 feature 名一致：文件放错位置（如把 a.md 的内容写进 b.md）会立即暴露，
  而不是静默用错提示词。
- `placeholders` 与正文实际出现的占位符必须一致（文件自校验）；调用时实参必须覆盖声明
  （缺 → 抛 `PromptLoadError`，否则会把 `{topic}` 原样发给模型）；多余实参只记 warning。
- `json_keys` 是**期望模型输出的键**，供调用后校验（`missing_json_keys`）；空 = 未声明。

渲染**不用 `str.format`**：提示词里大量出现 JSON 花括号（`{"action": "merge"}`），
format 会把它们当占位符。改为「按名字一次性替换」——未登记的 `{...}` 原样保留，
替换进来的值也不会被二次替换（否则值里含 `{x}` 时会被后续替换误伤）。
这与 Swift `PromptManager.applyVariables` 是同一模式。

加载失败的处理链：用户覆盖文件不合法 → error 日志 + **继续找内置默认**（用户改坏了
不该让功能停摆）；内置默认也读不到 → 抛 `PromptLoadError`（安装损坏属开发期错误，
静默给一个空提示词去调模型比直接失败更糟）。
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from config import data_dir, ui_language
from log_utils import setup_logging

logger = setup_logging("prompt_loader")

#: 基线语言。任何语言缺失该 feature 时回退到它；内置默认必须保证该语言齐全。
FALLBACK_LANG = "zh-Hans"

# 语言经 `config.ui_language()` 读（`UTILITY_LANG`，Swift 按 `general.language` 注入）——
# env 名的权威在 Swift `EnvKeys.utilityLang`，Python 侧配置读取的唯一入口在 config.py。

#: feature 名允许的字符（用于文件名拼接，防目录穿越）
_FEATURE_RE = re.compile(r"^[a-z][a-z0-9_]*$")

#: front-matter：文件必须以 `---` 开头、`---` 结束
_FRONTMATTER_RE = re.compile(r"\A---\r?\n(.*?)\r?\n---\r?\n", re.DOTALL)
_KEY_RE = re.compile(r"^([a-zA-Z_]+)\s*:\s*(.*)$")
_LIST_RE = re.compile(r"^\[(.*)\]$")

#: 正文里的占位符：只认「字母数字下划线」形态，故 JSON 的 `{"action": ...}` 不会被误判
_PLACEHOLDER_RE = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}")


class PromptLoadError(RuntimeError):
    """提示词不可用（内置默认缺失、调用实参与声明不符等）。"""


@dataclass(frozen=True)
class PromptTemplate:
    feature: str
    lang: str
    path: str
    text: str
    placeholders: tuple[str, ...]
    json_keys: tuple[str, ...]


_cache: dict[str, PromptTemplate] = {}


# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------


def _builtin_root() -> Path:
    return Path(__file__).resolve().parent / "prompts"


def _override_root() -> Path | None:
    """用户覆盖根目录（配置域）。`UTILITY_DATA_DIR` 未注入时为 None。"""
    base = data_dir()
    return Path(base) / "prompts" if base else None


def current_lang() -> str:
    return ui_language().strip() or FALLBACK_LANG


# ---------------------------------------------------------------------------
# 解析与校验
# ---------------------------------------------------------------------------


def _parse_list(raw: str) -> tuple[str, ...]:
    m = _LIST_RE.match(raw.strip())
    if not m:
        return ()
    items = [item.strip().strip("\"'") for item in m.group(1).split(",")]
    return tuple(item for item in items if item)


def parse_template(raw: str, feature: str, path: Path | str) -> PromptTemplate:
    """解析并自校验一段模板文本；任何契约违反抛 `PromptLoadError`。

    与「读文件」解耦：`_parse_file` 是它的文件形态，而契约校验脚本需要直接喂文本——
    它要断言的是「假设的坏文件会不会被拒绝」，不该为此真往磁盘写临时文件。
    两侧共用同一个解析函数，校验器断言的才是运行期真正会跑的那条路。
    """
    path = Path(path)
    m = _FRONTMATTER_RE.match(raw)
    if not m:
        raise PromptLoadError(
            f"{path}: 缺少 front-matter（--- name/placeholders/json_keys ---）"
        )
    meta: dict[str, str] = {}
    for line in m.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        km = _KEY_RE.match(line.strip())
        if not km:
            raise PromptLoadError(f"{path}: front-matter 行无法解析 {line!r}")
        meta[km.group(1)] = km.group(2)

    name = meta.get("name", "").strip()
    if name != feature:
        raise PromptLoadError(
            f"{path}: name={name!r} 与请求的 feature={feature!r} 不一致"
        )

    text = raw[m.end() :]
    declared = _parse_list(meta.get("placeholders", ""))
    found = tuple(dict.fromkeys(_PLACEHOLDER_RE.findall(text)))
    if set(declared) != set(found):
        raise PromptLoadError(
            f"{path}: placeholders 声明与实际不符（声明 {sorted(declared)} / 实际 {sorted(found)}）"
        )
    return PromptTemplate(
        feature=feature,
        lang=path.parent.name,
        path=str(path),
        text=text,
        placeholders=declared,
        json_keys=_parse_list(meta.get("json_keys", "")),
    )


def _parse_file(path: Path, feature: str) -> PromptTemplate:
    """解析并自校验一个模板文件；任何契约违反抛 `PromptLoadError`。"""
    return parse_template(path.read_text(encoding="utf-8"), feature, path)


def _candidate_paths(feature: str) -> list[tuple[Path, str | None]]:
    """按优先级给出候选文件：(路径, 语言)；语言为 `None` 表示**与语言无关**。

    用户覆盖（`_override_root()`）不按语言分目录：写 prompt 的人只有一种母语，那份文件
    就是给自己用的，让它「放哪个目录」取决于界面语言既无意义、又会因切换语言而失效。
    内置模板相反——使用者可能是不同母语的人，故按语言分目录并回退基线。
    """
    langs = [current_lang()]
    if langs[0] != FALLBACK_LANG:
        langs.append(FALLBACK_LANG)

    paths: list[tuple[Path, str | None]] = []
    override = _override_root()
    if override is not None:
        paths.append((override / f"{feature}.md", None))
    paths.extend((_builtin_root() / lang / f"{feature}.md", lang) for lang in langs)
    return paths


def template(feature: str) -> PromptTemplate:
    """按优先级取模板（进程内缓存）。"""
    if feature in _cache:
        return _cache[feature]
    if not _FEATURE_RE.match(feature):
        raise PromptLoadError(f"feature 名非法: {feature!r}")

    errors: list[str] = []
    for path, lang in _candidate_paths(feature):
        if not path.is_file():
            continue
        try:
            tpl = _parse_file(path, feature)
        except (PromptLoadError, OSError, UnicodeDecodeError) as e:
            # 用户覆盖文件坏了要能继续跑（回退内置），但绝不能静默——否则「我改的提示词
            # 没生效」将无从发现。内置文件坏了则记下来，最终一并抛出。
            #
            # 捕获范围必须**同时覆盖读取失败**：只捕 PromptLoadError 时，`read_text` 的
            # OSError（被外部删掉 / 权限不足）与 UnicodeDecodeError（非 UTF-8 存回）会直接
            # 穿透，上面那句「用户改坏了不该让功能停摆」就变成空话——summarize 的首阶段
            # 链路上没有 try，一个 GBK 存回的覆盖文件足以中断整条流水线。Swift 侧
            # `PromptManager.loadTemplate` 用 `try?` 换下一个候选，两侧行为必须一致。
            errors.append(str(e))
            logger.error(str(e))
            continue
        # 只有内置模板才有「语言回退」一说；用户覆盖与语言无关，不该被报成回退
        if lang is not None and lang != current_lang():
            logger.warning(
                f"{feature}: 语言 {current_lang()!r} 无该模板，回退 {FALLBACK_LANG!r}（{path}）"
            )
        _cache[feature] = tpl
        return tpl

    raise PromptLoadError(
        f"提示词不可用 feature={feature!r}: {'; '.join(errors) or '未找到任何候选文件'}"
    )


# ---------------------------------------------------------------------------
# 渲染
# ---------------------------------------------------------------------------


def render(tpl: PromptTemplate, variables: dict) -> str:
    """按名字一次性替换占位符；未登记的 `{...}` 原样保留。"""
    missing = [p for p in tpl.placeholders if p not in variables]
    if missing:
        raise PromptLoadError(
            f"{tpl.feature}: 调用缺少实参 {missing}（声明 {list(tpl.placeholders)}）——"
            "缺参会把 {占位符} 原样发给模型"
        )
    extra = [k for k in variables if k not in tpl.placeholders]
    if extra:
        logger.warning(
            f"{tpl.feature}: 调用多传实参 {extra}（模板未使用，通常是调用点改名后遗留）"
        )

    def _sub(match: re.Match[str]) -> str:
        name = match.group(1)
        return str(variables[name]) if name in variables else match.group(0)

    return _PLACEHOLDER_RE.sub(_sub, tpl.text)


def prompt(feature: str, **variables) -> str:
    """取并渲染提示词（Python 侧提示词的唯一入口）。"""
    return render(template(feature), variables)


def missing_json_keys(feature: str, parsed: dict | None) -> tuple[str, ...]:
    """按模板声明的 `json_keys` 校验模型输出缺了哪些键（未声明/非 dict → 空）。"""
    if not isinstance(parsed, dict):
        return ()
    return tuple(k for k in template(feature).json_keys if k not in parsed)
