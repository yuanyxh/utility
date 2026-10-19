# LLM 调用与提示词（llm_client / prompt_loader / tool_text）

> 从 `.claude/CLAUDE.md` 分层迁出（2026-10-18），内容逐字保留。
> 修改对应模块前先读本文件；CLAUDE.md 只保留必须遵守的不变量。

### Python LLM 调用统一入口（llm_client.py）
- Python 侧**唯一 LLM 出口**。此前三处各自实现「读配置 → 拼 body/头 → POST → 取 content → 异常吞掉」：`summary_llm._llm_chat`（同步 httpx）、`server._check_contradiction`（异步 httpx）、`proxy_usage.UsageFieldResolver._ask_model`（异步 aiohttp）
- **不统一调用风格**：`chat`（同步 httpx）/ `achat`（异步，每次新建 `AsyncClient`——连接池绑定 event loop，本模块被两个进程导入，共享实例是偶发故障源）。强行同步化会卡死事件循环，强行异步化要改 summarize 全部调用链
- **配置唯一来源 `config.py`**，本模块不读 env、不持默认值。`proxy_usage` 的 `LLM_API_URL/LLM_API_KEY/LLM_MODEL` 三个别名已删除（同一份配置读第二遍 + 守卫条件散落）
- **`LLMTarget` 两个判据别混**：`ready`（endpoint+model 齐备＝可发请求）+ `configured`（再要求 api_key）。**api_key 为空是合法的**——provider 的 `apiKey` 留空表示透传客户端 key，把它并进「可发请求」会让所有这些 provider 的分类直接失效
- **协议差异按 `api_format` 分派**：鉴权头（`Bearer` ↔ `x-api-key` + `anthropic-version`）、响应取文本（`choices[0].message.content` ↔ `content[0].text`）。取文本的失败语义**有意不一致**：openai 缺 `choices` → `None`（失败），anthropic 缺 `content` → `""`（分类器既有语义：空答案）
- **关思考分两层**：`disable_thinking` 管协议层（anthropic 注入 `thinking:disabled` + 删 `reasoning_effort/output_config`；openai 无标准字段故只删推理参数）；provider **私有**扩展走 `extra_body`（如 deepseek 的 OpenAI 兼容端点接受 `thinking`）——写进公共层会让其他 openai provider 收到未知字段而 400
- **503 重试策略是单一权威**：`DEFAULT_RETRY_503_MAX/DELAY` 定义在此，`token_proxy` 主转发路径 import 同一对常量（同类故障两处都要处理）。缺省 `retry_503=0` 即不重试——**自带重试环的调用方必须保持 0**（分类器按 `maxRetries` + 总预算重试，两层叠加会把打转型上游放大成 N×M 次调用）
- 失败日志统一到 `~/.cache/utility/llm_client.log`（`msg=llm_call_failed` + `label` 保留各调用点原判定名，按旧名 grep 仍可命中）
- **超时单一来源**：`config.yaml ai.llmTimeout` → Swift `EnvKeys.aiLLMTimeout` 注入 `AI_LLM_TIMEOUT` → `config.llm_timeout()` → `llm_client.DEFAULT_SYNC_TIMEOUT` → 三处 summarize 侧常量（`summary_llm.SUMMARY_LLM_TIMEOUT` / `summary_rules.RULES_LLM_TIMEOUT` / `summarize.AGGREGATE_LLM_TIMEOUT`）全部引用它。原先三处各写死 90/120/120——换个慢模型要改三处、漏一处就在长上下文上超时失败，且没人知道哪个值在生效。**缺省/非数字/非正值一律回退默认 120**（与 Swift `OpenAIClient.init` 的 `timeout > 0` 约定一致；**不要**套用 `general.httpTimeout` 那套「0 = 不限制」，同一个 0 在两处含义相反）。分类器/resolver 仍传自己的超时（分类器按总预算、resolver 用更短的探测值）——调用方显式传 `timeout=` 时以调用方为准
- **⚠️ 两个 `aiTimeout` 别混**：`general.aiTimeout`（`ConfigDefaults.defaultAITimeout`）= agent/HTTP 调用超时，注入 `AGENT_TIMEOUT`；`ai.llmTimeout`（`ConfigDefaults.llmTimeout`）= Python 侧 LLM 单次推理超时，注入 `AI_LLM_TIMEOUT`。两者默认值恰好都是 120，合并会让「调大 agent 超时」意外改动 LLM 调用行为
- ⚠️ **坑：类内同名方法会静默覆盖**——新写的 `_classify` 覆盖了已有的 `_classify(turns)`，调用方拿到的是 `TypeError: missing 3 required positional arguments`，且只在运行到该路径时才暴露。新方法命名要避开既有名（现为 `_classify_with_provider`）
- ⚠️ `scripts/check-router-config-contract.py` 现在 import 链会拉到 `httpx`，用系统 `python3` 跑会在 import 阶段失败（报错与契约无关、易误导）——脚本已加 **venv 自举**（`os.execv` 到 `~/.config/utility/mcp-venv/bin/python3`），用法不变

### 提示词外置（prompt_loader.py + PromptManager.swift + prompts/）
- 提示词**不再写死在代码里**：Python 侧 11 个模板（`quality_judge` 判定 system、`quality_judge_user` 判定 user 前缀、`aggregate`/`merge_cross_batch`/`extract_keywords`/`decide_merge`/`gen_new`/`gen_merge`/`extract_rules`/`contradiction`/`classify_tier`）与 Swift 侧 2 个（`translate`/`translate_auto`）都在 `Sources/MCPScripts/prompts/<lang>/<feature>.md`，随 `.copy("MCPScripts")` 分发（bundle 内 `MCPScripts/prompts/...`）。**system 与 user 各占一份文件**——`quality_judge` 的 user 前缀原先硬编码为 `f"记忆内容：\n{text}"`，英文环境下会变成「中文前缀 + 英文 system」
- **两侧共用同一目录、同一契约**：改一句提示词、加一个语言，在 Swift 与 Python 是同一件事。Swift `PromptManager.parseTemplate` 与 `prompt_loader.parse_template` 逐条对齐（front-matter 键、name 校验、placeholders 双向自校验、渲染规则）
- **目录优先级**：`<配置域>/prompts/<feature>.md`（用户覆盖，**与语言无关**）→ 内置 `MCPScripts/prompts/<lang>/<feature>.md`（按当前语言 → `zh-Hans` 基线）。两处的语言维度**有意不同**：内置面向「使用者可能是不同母语的人」，用户覆盖是**用户自己控制**的一份文件——写 prompt 的人只有一种母语，让它「放哪个目录」取决于界面语言既无意义、又会因切换语言而失效。配置域复用**既有** env 契约：Swift 注入的 `UTILITY_DATA_DIR` 就是 `~/.config/utility`，故不新增 env 项。Swift 侧同序（`PromptManager.candidatePaths`，候选元组第二项 `nil` = 语言无关、不报语言回退），两侧顺序必须一致——否则会出现「Python 用了用户覆盖、Swift 用了内置」这种没法解释的组合
- **资源定位唯一来源**：`MCPScriptsResources.path(relative:)`（bundle → dev 目录）。`PythonScriptRunner.findScript` 与 `PromptManager` 都走它——两处各写一份 bundle 路径推导时，改了布局只改一处、另一处**静默读不到文件**（脚本表现为功能不可用，提示词表现为悄悄回退成兜底文案）
- **契约**（front-matter，扁平键、无 YAML 依赖）：`name`（必须与 feature 同名，防文件放错位置静默生效）、`placeholders`（与正文实际占位符**双向**自校验；Python 缺实参 → 抛 `PromptLoadError`，Swift → error 日志 + `{占位符}` 原样保留，多传只 warning）、`json_keys`（期望模型输出的键，空=未声明；Swift 侧无消费方，仅登记）
- **渲染禁用 `str.format` / 逐 key 替换**：提示词里大量出现 JSON 花括号（`{"action": "merge"}`），format 会当成占位符。两侧统一为「按名字**一次性**替换」——未登记的 `{...}` 原样保留，且替换进来的值不会被后续轮次误伤（逐 key `replacingOccurrences` 会让值里的 `{target}` 被二次替换）
- **加载失败链**：用户覆盖文件不合法（name 不符 / placeholders 声明与实际不符）→ error 日志 + **继续找下一个候选**（用户改坏了不该让功能停摆）；Python 侧内置也读不到 → 抛 `PromptLoadError`（安装损坏属开发期错误，静默给空提示词更糟）；Swift 侧最后回退 `L10n`（见下条）
- **Swift 的 L10n 兜底不是第二份文案**：`Resources/<lang>.json` 的 `prompt.translate` / `prompt.translate_auto` 只在 `MCPScripts/prompts/` 缺失（安装不完整）时启用——那时发一段空 system prompt 比直接失败更难排查（表现为「模型答非所问」而非「翻译报错」）。两层内容由契约脚本**逐字断言**（strip 后相等），不会漂移
- **语言**：`general.language` → `L10n.resolvedLanguage()`（**唯一判据**，Swift `L10n.setup()` 与注入 Python 的 `UTILITY_LANG` 同源）→ 选目录；该语言缺该文件 → 回退 `zh-Hans` 基线 + warning（未翻译不该让功能停摆，但不能静默）。基线常量两侧同值（`PromptManager.fallbackLanguage` / `prompt_loader.FALLBACK_LANG`）由契约脚本断言。**现状**：12 个 feature 均有 `zh-Hans` + `en`（未翻译的语言如 `ja` 回退中文基线并记 warning）
- **迁移方式是 AST 逐字提取**（脚手架在 /tmp，未入库）：提示词差一个标点不会报错、只会静默改变模型行为，故用 `ast.Constant.value`（**已解码**，f-string 里的 `{{` 在 AST 里就是 `{`）展平出「渲染后文本 + {占位符}」，并留快照做逐字比对。复杂插值（`group.get('topic','')` 等）登记进映射表转为语义占位符，未登记则脚手架直接失败。Swift 2 个由 `Resources/<lang>.json` 直接迁移（既有文本，非重写），生成脚本回读断言正文逐字一致
- **解析失败可观测**：`_llm_json(..., feature=...)` 在两次都解析不出 JSON 时记 `PROMPT_JSON_PARSE`；解析成功但缺模板声明的 `json_keys` 时记 `PROMPT_JSON_MISS`（**不改返回值**——缺键是「模型没按契约输出」，是否当失败由调用方定）
- **契约校验脚本第 5 组**：断言 24 份模板（12 feature × 2 语言）都被**生产解析器**（`prompt_loader.parse_template`）接受、占位符与基线登记一致、翻译版的 `json_keys` 与基线一致；Swift 侧有 L10n 兜底的两个 feature 还要求正文与 `Resources/<lang>.json` 逐字一致；基线语言两侧同值。基线语言**强制齐全**（它是其它语言的回退目标），`en` 按存在性校验——渐进补译是正常节奏。两个设计要点：解析取自**入参文本**而非重读磁盘（否则自检喂不进「假设的坏文件」，变异会静默无效）；遍历**期望集合**（语言 × feature）而非入参字典的键（否则「模板漏发」会因 key 消失而被静静漏掉）
- **翻译不能改结构**：占位符名、JSON 契约键（`"judge":`、`"relation":` 这些会被代码解析的键）在译文里必须原样保留——译文改名不会报错，只会在运行期表现为「渲染缺参」或「模型没按契约输出却检测不出来」。故 `json_keys` 有跨语言一致性断言，占位符有「与基线登记一致」断言

### 工具参数描述国际化（catalog + tool_text.py）
- **只做参数描述**（`inputSchema` 里的 `description`）。工具**描述**不在此列：`TOOL_DEFAULTS` 更长、改动更频繁，内置一份译文本只会多出一份没人维护的副本
- **键是语义名而非「工具.参数」路径**：18 条唯一文案在 schema 里出现 **23 处**（`param.db_path` 被 4 个 `project_*` 工具引用、`param.max_results` ×2、`param.memory_content` ×2）。按路径命名会让同一句文案在翻译时分叉成几份，「改一处忘三处」会随翻译一起放大
- 文案已并入共享目录 `Sources/Resources/<lang>.json`（key 前缀 `mcp.param.*`），由 `gen-l10n.py` 生成 `l10n_catalog.py`；`tool_text.param_text("param.x")` 只是 `l10n.t("mcp.param.x")` 的薄别名，server.py 调用点不变
- `param_text(key)` 的语言判据与提示词**同源**（`l10n.resolved_language()` ← `config.ui_language()` ← `UTILITY_LANG` ← `general.language`），缺该语言回退 `zh-Hans`；`l10n.BASELINE_LANG` / `prompt_loader.FALLBACK_LANG` / `PromptManager.fallbackLanguage` **三处同值**由契约脚本断言（漂移会让同一份缺失在两条路径上得到不同结果，且都不报错）
- **未登记的键抛 `MissingText`（`MissingParamText` 是其别名），不回退成键名**：静默回退会把 `param.xxx` 这样的内部标识当文案发给模型；这类错误在静态层就被契约脚本拦下，运行期再兜底只会掩盖它
- **契约第 6 组**（静态 AST，不 import server.py——它导入即拉起 mem0/qdrant）：`handle_list_tools()` 内所有 `"description"` 必须经 `param_text(...)` 取，裸字面量与「无法判定的形式」都算违反；引用的键必须存在、表中不得有孤儿键、各键语言集合**一致且含基线**。看的是 dict 的 `"description"` 键，工具级 `Tool(description=...)` 是关键字参数、天然在范围外
- **混语言比统一未翻译更糟**：schema 是一次性整体呈现的，故断言「各键语言集合一致」而非「每键有基线即可」——后者允许一部分参数中文、一部分英文
- **`param.memory_content` 与 `TOOL_DEFAULTS["remember"]` 必须同为三要素口径**（场景/决策/演进）：两处描述的是同一段模型行为，分叉时模型收到两套要求（曾一处三要素、一处五要素，2026-09-18 用户裁定「三要素为主」后改齐）
- 迁移**逐字一致**的判据取自 `git show HEAD:Sources/MCPScripts/server.py`（迁移前那一版）而非手抄：手抄的比对只能证明「我抄对了自己」（脚本在 /tmp，未入库）
