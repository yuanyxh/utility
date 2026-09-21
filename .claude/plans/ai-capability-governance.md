# AI/Agent 能力治理方案

> 版本 v4 · 2026-09-18
> v1：事实层成立、方案层大面积不成立。v2：按判据重做，但把「prompt 外置」判为不做（被否定）。v3：判据加「内容资产性」，prompt 改为「外置 + 声明式契约校验」，补「统一入口」章节。
> **v4（本版）：确立前提——本工具面向通用 agent，不预设任何单一客户端；OpenAI 与 Anthropic 两种协议对等。**据此重做审查，新增阶段 0「协议中立性」；原 1.2 升级为「客户端文案表」。
>
> 已实施状态：阶段 1 的 1.1（host 统一）、1.3（脚本名集中）已落盘并通过 `swift build`；1.2（`SUMMARY_PREFIX` 去重）已落盘并被阶段 0.4 取代扩展；**阶段 0.1–0.4 已实施完成**（0.1/0.2 端到端冒烟通过；含实施中发现的两处语义修正，见该节末尾「实施记录」）。

---

## 一、判据

对每个候选项问五个问题，答案决定归属：

| 判据 | 问题 | 归属 |
|------|------|------|
| **用户可及性** | 终端用户是否需要在不重新构建的前提下改它？ | `config.yaml`（唯一用户可配置面） |
| **契约性** | 它是跨进程/跨语言约定吗（Swift ↔ Python、parser ↔ 输出格式）？ | 单点常量 + 契约校验 |
| **内容资产性** | 它是面向用户/agent 的**内容**（提示词、工具描述、术语表）吗？ | **必须可外部化 + 语言可变**；用「声明式契约 + 加载校验」抵住静默失效 |
| **客户端中立性**（v4 新增） | 它是否预设了某个具体客户端（Claude Code 等）的行为？ | **判据必须来自协议契约**（路径、标准请求头、消息结构），客户端身份只能作**可配置白名单**，不得写死 |
| **静默失效** | 改错后是否无异常、无日志、行为悄悄改变？ | 先补可观测信号，再决定能否外部化 |

五条推论：

1. **utility 是 launchd 启动的 GUI app，终端用户无法设置环境变量**。裸 `os.environ.get` 不构成可配置面。既有正确链路是单向的：`config.yaml → ConfigTypes → Swift 注入 env → Python 读取 → 代码内 FALLBACK 仅兜底`（样板：`general.aiTimeout` → `PythonScriptRunner.swift:126` → `agent_call.py:32`）。
2. 逻辑契约常量（服务名、协议版本）配置化 = 把同一约定拆成两处维护，不做。
3. prompt 的**产地**可以外置，prompt 的**输出契约**必须由代码侧校验——以「外置会静默失效」为由拒绝外置，等于用「不许用户碰」掩盖「没有校验」。
4. 客户端身份不是协议事实。项目既有原则「判据只允许来自协议契约」在 v1–v3 中未被贯彻到代理层：`_is_claude_code` 用 UA/私有 header 做指纹，其余客户端在同一结构下的行为与 Claude Code 不同。
5. 协议对等 = **两个规范入口都存在 + 每条判据两协议等价**。已经做对的样板是 `proxy_model_tag.py`（`AnthropicSSETagger` / `OpenAITagInserter` 双路覆盖）与 `agent_call.py`（零参数假设的命令模板）。

---

## 二、v1 核实结果（事实层，保留）

| v1 章节 | 断言 | 核实 | 证据 |
|---|---|---|---|
| 一 | env 名绑死 provider | 真 | `AppDelegate.swift:144`、`PythonScriptRunner.swift:141`、`config.py:38`、`summary_llm.py:26`、`server.py:150` |
| 二.1 | Swift 120s 三处重复 | 真 | `ConfigTypes.swift:110/121`、`OpenAIClient.swift:112` |
| 二.2 | 8 处 Python 超时写死 | 真 | 行号全对：`summary_llm.py:32/33`、`summary_rules.py:29`、`summarize.py:68/76`、`proxy_usage.py:411`、`ast_extractor.py:335/356` |
| 二.3 | classifier 已有 config 覆盖 | 真 | `proxy_router.py:110-114`、`310-321`；`ConfigTypes.swift:309-334`（v1 自判「保持现状」） |
| 三 | `localhost` 不一致 | 真 | 已修（阶段 1.1） |
| 四 | Python 绑定地址写死 | 真 | `token_proxy.py:1015`、`server.py:1850`（v1 表格要加 env，注释却写「不需要」） |
| 五/六 | `SERVER_NAME`／`EMBEDDER_DIMS` 写死 | 真 | `server.py:183`、`server_embed.py:29` |
| 七/八 | 协议常量 | 真 | `proxy_router.py:1318`、`OpenAIClient.swift:119` |
| 九.2 | `TOOL_DEFAULTS` 12 条 | 真 | 实测 12 条；但 **v1 描述的格式错误**——真实格式是 `### tool_name` + 段落文本（`server.py:525-545`） |
| 九.3 | prompt 全硬编码 | 真 | `summarize.py:546/578`、`summary_rules.py:202`、`proxy_router.py:78-85` |
| 十 | 续接提示词耦合客户端文案 | 真 | `proxy_usage.py:618`；`"Summary:"` 另在 `736`、`751`（v4 中并入阶段 0.4） |
| 十一 | 脚本名散落 | 真 | 已修（阶段 1.3） |
| 十二 | 中文消息硬编码 | 部分 | 多为日志/CLI 输出（`summarize.py:1771`），非用户可见 UI |

v1 漏列：`summarize.py:36` import、`summarize.py:1769-1771` 判空与文案、`server.py:238` 复用为 embedding key、`default-config.yaml:25`（120s 第三落点）。

---

## 三、AI/Agent 能力盘点

### 3.1 已做对的统一入口（对齐目标）

| 能力 | 统一入口 | 形态 |
|------|---------|------|
| Agent CLI 调用 | `agent_call.py:49 call_agent(agent_template, system, user, cwd)` | 命令模板 + 占位符，零参数假设（不假设其他 agent 有 `-p`）；`AGENT_TIMEOUT`（`:32`）由 config.yaml `aiTimeout` 注入 |
| Swift 侧 LLM 调用 | `OpenAIClient.swift:183 chat()` + `HTTP.swift:36 request()` | 单一 client + RequestConfig |
| Swift 侧提示词 | `PromptManager.swift:14 prompt(for:variables:)` | `config.prompts.templates[feature]` → fallback `L10n.Prompt.*` → 变量替换 |
| 响应侧模型名回显 | `proxy_model_tag.py` | `AnthropicSSETagger` / `OpenAITagInserter` 双协议覆盖（含 `content-length` 剔除、`end_turn` 门控） |
| 协议/密钥字段解析 | `proxy_provider.py`（`api_format_of`/`api_key_of`） | 单一入口 + `scripts/check-router-config-contract.py` 契约校验 |

### 3.2 仍散落（v3 已识别，未变）

| # | 散落点 | 证据 | 后果 |
|---|--------|------|------|
| 1 | Python 侧 **4 套独立 LLM 调用** | ① `summary_llm.py:37,81-91` httpx 同步；② `server.py:630-643` httpx AsyncClient 内联；③ `proxy_usage.py:41-43,406-419` aiohttp（同一批 env 换成别名 `LLM_API_URL`/`LLM_API_KEY`/`LLM_MODEL`，超时内联 15s）；④ `proxy_router.py:1312/1338` aiohttp ×2 | HTTP 库、别名、超时来源、错误处理、重试策略各不相同 |
| 2 | Python 侧无提示词注册表 | 全内联（§二 九.3） | 无法覆盖、无语言变体，与 Swift `PromptManager` 割裂 |
| 3 | 语言链路断层 | grep 三处 Manager + 全部 `.py` **零命中** | `general.language`（`ConfigTypes.swift:91`）只管 Swift UI |
| 4 | 内容资产只有中文单版本 | `DESCRIPTIONS.md`、`TOOL_DEFAULTS`（12 条）、`synonyms.py` | 非中文用户与 agent 不友好 |

### 3.3 协议中立性盘点（v4 新增，本次审查结论）

| # | 偏差 | 证据 | 触发与后果 |
|---|------|------|-----------|
| P1 | **格式检测的兜底是 anthropic，且用启发式而非权威信号** | `proxy_protocol.py:531-547`：四条判据全不命中 → 返回 `"anthropic"` | OpenAI 协议客户端发无 system、无 tools 的单轮请求 → 判成 anthropic → 与 provider 格式不符时走错误转换，**静默产出错误请求体**。入口路径本身即协议声明，却被浪费 |
| P2 | **classifier 加速只对 Claude Code 生效** | `token_proxy.py:251` → `_is_claude_code`（`proxy_protocol.py:550-559`，UA 含 claude 或 `x-anthropic-billing-header`） | 非 Claude 客户端发出的「stream=false + tools 空 + messages ≤ 2」短请求（`_is_classifier_candidate` 的结构特征与客户端无关）拿不到 thinking disabled；上游为默认 thinking 模型时响应 28–32s → 撞客户端超时 → 该 agent 的关键操作被拦。**同一结构、不同客户端、不同结果**，与通用 agent 前提冲突 |
| P3 | **客户端文案与标签硬编码 Claude Code** | `proxy_usage.py:618` `CONTINUATION_PREFIX`、`622` `SUMMARY_PREFIX`、`580-590` `CLIENT_INJECTED_TAGS`（6 个标签） | 其他 agent 用自己的续接/摘要文案 → 被判为真实用户输入写入 `actual_user_input`；更重的是 `compute_session_key` 以首条用户输入为锚，锚到摘要文本 → **路由会话身份漂移**。命中失败无任何告警 |
| P4 | **模型发现端点恒定返回 Anthropic schema** | `token_proxy.py:737-771` `_handle_models()`；路径判定在 `:192`（`path == "v1/models"`，两协议客户端都命中） | OpenAI 客户端调 `GET /v1/models` 期望 `{"object":"list","data":[{"id","object":"model"}]}`，实际拿到 `{"type":"model","display_name":...}` → SDK 解析失败 |
| P5 | **转发入口只有 `/open/{path}` 一种形态** | `token_proxy.py:961` 仅注册 `add_route("*", "/open/{path:.*}", handle_proxy)` | 能改 base_url 的客户端可用；端点硬编码或默认拼接标准路径的框架直接 404。`/open` 前缀本身偏 OpenAI 语义，却同时承载 Anthropic 流量 |
| P6 | **Swift 侧只有 `OpenAIClient`** | `Sources/Core/OpenAIClient.swift` 是 Swift 层唯一 AI 客户端 | 应用层功能（翻译/摘要）接 Anthropic 原生上游只能经 OpenAI 兼容网关。**本版不做，见 §五** |

**判定分级（按本次审查的证据强度）**：P1、P2 为设计级确定性缺陷（触发条件明确、现有防护不拦）；P3、P4、P5 为协议对等性缺口（证据充分，影响面取决于实际客户端）；P2 对非 Claude 客户端的实际影响未经实测——**PLAUSIBLE 而非 CONFIRMED**，确认方式是用任一带 OpenAI/Anthropic 协议的第三方 agent 发一次短请求并观察是否注入。

---

## 四、执行项

各阶段独立可合并——合入后系统可用，不必等后续阶段。

### 阶段 0：协议中立性（实施阶段，调研已在本审查完成）

> 触及约 8 个文件（`ConfigTypes.swift`、`TokenProxyManager.swift`、`default-config.yaml`、`token_proxy.py`、`proxy_protocol.py`、`proxy_usage.py`、新增 `proxy_client.py`、`scripts/check-router-config-contract.py`），**是本次改动面最大的一阶段**。可分 4 次独立合并（0.1–0.4 互不依赖）。

**0.1 入口对等 + 路径作权威协议判据（对应 P1、P5）**
- `token_proxy.py:958-961` 路由表新增：`POST /v1/messages`（Anthropic 原生，同时覆盖 `v1/messages/count_tokens`）、`POST /v1/chat/completions`（OpenAI 原生）；保留 `/open/{path:.*}` 作为兼容别名（现有用户配置 `ANTHROPIC_BASE_URL=.../open/v1` 不受影响）。
- 新增 `_api_format_from_path(path) -> str | None`：`v1/messages*` → `anthropic`；`v1/chat/completions` → `openai`；其他 → `None`。
- `handle_proxy` 判定顺序改为：**路径判据优先**（`token_proxy.py:203` 的 `api_format = _detect_api_format(request_body)` 之前插入），仅当路径无法判定时回退启发式；两者不一致时记 `format_mismatch` 告警（含 path、两条判据结果），**不静默采信**。
- 边缘情况：`/open/v1/messages` 走前缀解析同样落到 `v1/messages` ✅；第三方客户端调 `v1/messages/count_tokens` 时上游若无该端点，透传上游错误（正确行为，不吞）。

**0.2 模型发现端点双 schema（对应 P4）**
- 判据用**协议级请求头**（符合「判据来自协议契约」）：新增 `_models_schema_for(request) -> str`——存在 `anthropic-version` 头或用 `x-api-key` 鉴权 → `anthropic`；否则 → `openai`。
- Anthropic schema 保持现状（`type`/`display_name`，Claude Code 的 `/model` 选择器依赖它）；OpenAI schema 返回 `{"object":"list","data":[{"id","object":"model","created","owned_by"}]}`。
- 两者都缺时按路径兜底（`/open/*` → anthropic），并记 `models_schema_fallback` debug 日志。

**0.3 classifier 加速白名单化（对应 P2，采纳保守方案）**
- `config.yaml` 新增：

```yaml
modelProxy:
  clientAccel:                       # 哪些客户端享受 classifier thinking disabled 加速
    enabled: true
    clients:
      - name: claude-code
        userAgentContains: ["claude"]     # UA 子串
        headerPresent: ["x-anthropic-billing-header"]
```

- Swift：`ConfigTypes.swift` 新增 `ClientAccelConfig`，`TokenProxyManager` 序列化为 `MODEL_PROXY_CLIENT_ACCEL`（**JSON 侧 snake_case**，与 providers/router 同规范）。
- Python：新增 `Sources/MCPScripts/proxy_client.py`，唯一出口 `matches_accel_client(headers, cfg) -> str | None`（返回命中的 client name，供日志）。`_is_claude_code`（`proxy_protocol.py:550-559`）**删除**，调用点 `token_proxy.py:251` 改用它。
- 行为不变性：默认配置含 claude-code 一条 → 对 Claude Code 行为与今天完全一致；未命中白名单的客户端保持「不注入」（现状）。
- 日志区分三类返回点（沿用项目「reason 必须能区分返回点」教训）：`classifier_thinking_disabled`（命中白名单 + candidate）、`classifier_check_skip`（命中白名单但非 candidate）、`classifier_client_not_allowed`（未命中白名单，debug，含 UA 摘要以便发现新客户端）。
- 重评触发条件：若出现「第三方 agent 因超时被拦」的实测故障，再把该客户端加入默认白名单（配置即可，无需改码）。

**0.4 客户端文案与标签表（对应 P3，取代并扩展原 1.2）**
- `config.yaml` 新增：

```yaml
modelProxy:
  clientText:
    continuationPrefixes: ["This session is being continued from a previous conversation"]
    summaryPrefixes: ["Summary:"]
    injectedTags: ["system-reminder", "local-command-caveat", "local-command-stdout",
                   "command-name", "command-message", "command-args"]
```

- 默认值 = 现有 Claude Code 取值的**逐字等价**（零行为变化）；用户可增补其他客户端的文案/标签，无需改码。
- Python：`proxy_usage.py:618/622/580-590` 改为读配置（Swift 注入 `MODEL_PROXY_CLIENT_TEXT`）；`CONTINUATION_PREFIX`/`SUMMARY_PREFIX` 保留为模块常量但由配置初始化（多处引用点不改签名）。
- **可观测**：多处匹配失败时记 `client_text_miss`（debug，含前 80 字符样本），用于发现未登记的客户端文案——这是「静默失效先补信号」判据的落点。
- 已落盘的 1.2（`SUMMARY_PREFIX` 去重）保留为该项的内置默认。

**实施记录（2026-09-18，0.1–0.4 已完成）**

*0.1 / 0.2：*
- `token_proxy.py` 新增 `_upstream_path(request_path)`（两种入口归一）与 `_api_format_from_path(upstream_path)`（Anthropic `v1/messages*` / OpenAI `v1/chat/completions`｜`v1/completions`）；`handle_proxy` 改为**路径判据优先**、启发式降为兜底，两者不一致记 `format_mismatch`（含 path / by_path / by_body / effect）。
- 路由新增 `add_route("*", "/v1/{path:.*}", handle_proxy)`，与既有 `/open/{path:.*}` 并存（注册在 `/usage/*`、`/health` 之后，不遮蔽它们）。
- `_handle_models(request)` 支持双 schema：新增 `_models_schema_for(request)`（`anthropic-version` → Anthropic；`Authorization: Bearer` → OpenAI；都无则按兼容入口兜底为 Anthropic 并记 `models_schema_fallback`）与常量 `_MODEL_CREATED_EPOCH = 1767225600`（固定值，保证 `created` 稳定、客户端缓存不反复失效）。
- 三处日志原写 `f"/open/{path}"`，会把原生入口误报成兼容入口 → 改为 `request.path`（客户端实际路径）。

*0.3 / 0.4：*
- 新增 `Sources/MCPScripts/proxy_client.py`（客户端特征唯一入口）：`load_client_accel` / `matches_accel_client` / `load_client_text`，契约键元组 `ACCEL_CONTRACT_KEYS` / `ACCEL_CLIENT_KEYS` / `CLIENT_TEXT_CONTRACT_KEYS`（供阶段 2.4 的校验脚本断言）。
- 删除 `proxy_protocol._is_claude_code`；`token_proxy.py` 改走 `matches_accel_client(request.headers, CLIENT_ACCEL)`，日志三类返回点可区分（`classifier_thinking_disabled` 含 `client` / `classifier_check_skip` / `classifier_client_not_allowed` 含 UA 摘要）。
- `proxy_usage.py`：`CLIENT_TEXT` 由 `MODEL_PROXY_CLIENT_TEXT` 初始化，`CONTINUATION_PREFIXES` / `SUMMARY_PREFIXES` / `CLIENT_INJECTED_TAGS` 全部取自该表；新增 `_observe_unregistered_blob` 与 `UNREGISTERED_BLOB_MIN_CHARS = 2000` 的 `client_text_miss` 观测。
- Swift：`ConfigTypes.swift` 新增 `ClientMatcherConfig` / `ClientAccelConfig` / `ClientTextConfig`（一律走 `decodeAny`，兼容 camel/snake）；`TokenProxyManager` 新增 `clientAccelJSON()` / `clientTextJSON()` 并注入两个新 env；`default-config.yaml` 增加两段模板（默认空 = 用内置默认）。
- **实施中发现并修正的两处语义**（已写入代码注释与 `CLAUDE.md`）：
  1. **默认白名单必须表达 OR**：历史 `_is_claude_code` 是「billing header 或 UA 含 claude」的 **OR**。把两个条件写进同一个匹配器会变成 AND（匹配器内部是 AND），只带单一信号的 Claude Code 请求会**静默失去加速**。故默认拆成两条：`claude-code:billing-header` / `claude-code:user-agent`。规则：匹配器内部 AND、OR 由多条表达。
  2. **配置为「增量补充」而非覆盖**：覆盖语义下只写一个字段会把其余默认静默清空（只加续接前缀 → 摘要前缀与标签表双双失效、摘要文本混进 `actual_user_input`）。现语义：内置默认在前 + 配置追加，同名覆盖；`enabled=false` 是唯一关闭开关。
- 验证（本会话实测）：`swift build` EXIT=0（MCPScripts 已重新拷贝进 bundle）；`py_compile` 四个脚本通过；`scripts/check-router-config-contract.py --selftest` 通过（6 种变异全检出）；`proxy_client` 功能冒烟 11 项全符合设计（默认两条目、单信号命中、`enabled=false`、增量追加、同名覆盖、非法 JSON 回退、大小写不敏感头、文案增量）。
- **0.1/0.2 端到端冒烟**（桩上游 :18999 + 真实代理 :18998，provider `apiFormat=openai`）：`POST /v1/messages`（Anthropic 入口 + `anthropic-version`）→ 200 且响应转回 Anthropic schema；`POST /open/v1/messages` → 200；`POST /v1/chat/completions` → 200；上游收到的路径全部为 `v1/messages`／`v1/chat/completions`（**无 `/open` 前缀**）；`GET /v1/models` 带 `anthropic-version` → Anthropic schema、`GET /open/v1/models` 带 `Bearer` → OpenAI schema（`object:"list"`、`created:1767225600`）；`format_mismatch` 精确命中 **2 次**（即那两个「路径说 openai、body 无 system 无 tools 被启发式判成 anthropic」的请求——旧实现下它们会被错误转换）。冒烟数据落在 `/tmp/utility-smoke`，未污染真实库；桩与代理进程已清理（用户正在运行的 Utility 代理进程未受影响）。
- 同步更新 `.claude/CLAUDE.md` 两处失真描述（输入过滤文案表、classifier 加速白名单与日志名）。

### 阶段 1：不变量收敛（1.1、1.3 已实施；1.2 已并入 0.4）

**1.1 host 构造统一** ✅ 已实施：`HTTP.swift:14-25` 新增 `localHost`/`localBaseURL(port:)`/`localURL(port:path:)`，7 处改为调用（`AppDelegate.swift:138`、`MCPProcessManager.swift:75`、`TokenProxyManager.swift:261`、`MCPClient.swift:18`、`PythonDaemon.swift:92/295`、`PortProbe.swift:36`）。
**1.2 `"Summary:"` 去重** ✅ 已实施（`proxy_usage.py:622` 定义、`740/755` 使用）→ 在 0.4 中升级为可配置表。
**1.3 脚本名集中** ✅ 已实施：`Constants.swift` 新增 `enum PythonScripts`，收敛 7 个调用点 + 2 处日志插值。

### 阶段 2：env 名与 provider 解绑（2.1–2.4 已实施）✅

**2.1 `EnvKeys` 单一来源** ✅：`Constants.swift` 新增 `enum EnvKeys`（`aiAPIKey = "AI_API_KEY"`），2 处注入字面量（`PythonScriptRunner.baseEnvironment()`、`AppDelegate.updateMCPSummaryTask` 的内联 cmd）改为引用常量。理由：两个注入点分属不同路径（Runner 拼公共环境 / 内部任务自己拼 cmd，因 `TaskExecConfig.toProcess()` 不设环境），改名漏一处即静默读空。
**2.2 改名落地** ✅ `DEEPSEEK_API_KEY` → `AI_API_KEY`，`config.py` 访问器 `deepseek_api_key()` → `ai_api_key()`；共 **17 处引用 / 7 个文件**（Swift 2 + Python 15），`grep` 确认零残留（仅 `EnvKeys` 注释保留旧名，作为「为何改名」的说明）。
**2.3 不保留旧名 fallback** ✅（用户已确认）：env 名是 Swift ↔ Python 内部契约，同仓同发无兼容窗口；保留双名违反单一权威。实测 `DEEPSEEK_API_KEY=sk-old` 时 `ai_api_key()` 返回 `""`。
**2.4 契约校验扩展** ✅：`scripts/check-router-config-contract.py` 覆盖扩到 5 组——router / providers / client（`clientAccel`+`clientText`，含 `MatcherPayload`）/ env 名 / 进程约定（服务名、脚本名）。**文件名保留历史名**（改名会牵动 AGENTS.md / CLAUDE.md / `proxy_router.py` / 计划共 4 处引用），覆盖范围写进 docstring 与输出首行。
重构点：花括号配平（`_extract_block`）与 `_read` 提为公共函数（struct 与 enum 通用）；新增 `ContractInputs` 一次性采集口，使 `check_all` 与 `--selftest` 走**同一份判据**（自检若自己重拼输入，就能在真实路径之外自证清白）；自检新增「**变异无效果**」判定——变异未改变任何输入同样算失败，否则字段改名后自检会静默变成空转。自检变异数 6 → **12**，全检出。

**2.4 的直接产出（检查器首次运行即抓到真问题）**：`PythonScripts.prepareArticle` / `genArticle` 指向的两个脚本**在仓库中不存在**——`8031dcb chore: 移除文章生成管线相关代码`（HEAD 祖先）已删 `prepare_article_source.py` / `gen_article_generic.py` / `article_pipeline.py` / `llm_judge.py`，Swift 侧残留未清。运行期无故障（`article.enabled` 默认 `false`，且 config.yaml 与 default-config.yaml 均无 `article` 段，任务在第一个 guard 即退出），属**死代码**。经用户确认按「清理残留」处理，本次一并删除：`updateArticleTask()` 及其 2 处调用、`ArticleConfig`（含 `AppConfig.article` 属性与解码分支）、`PythonScripts` 两常量、`MenuBarManager` 的 gen-article 专用 debug 分支、`CLAUDE.md` 的「gen-article 文章管线」整节；`.claude/rules/internal-task-registration.md` 的**全路径坑保留**（坑与任务无关），仅去掉已不存在的任务名。

**验证（本轮实测）**：契约正向 EXIT=0（router+providers+client 41 键 / env 1 个 / 脚本 4 个 / 服务名 `mino-brain`）；`--selftest` 12/12；`swift build` Build complete；`py_compile` 五脚本通过；venv Python 实测导入链 `config.ai_api_key()` → `summary_llm.AI_API_KEY` / `proxy_usage.LLM_API_KEY` 均取到值；`strings .build/debug/utility | grep -c AI_API_KEY` = 1、`DEEPSEEK_API_KEY` = 0。
**⚠️ 生效前提**：新 env 名随**新二进制**注入；用户当前运行的 Utility 是旧二进制（注入旧名），而 `.build` bundle 里的 Python 已换成读新名的版本——此窗口内若 Python 子进程重启（配置重载触发 `forceRestart`），会读到空 key（总结/用量解析降级，不崩溃）。**需重启 Utility.app**。
**未验证项**：`server.py` 未做导入实测——其模块级 `_cleanup_qdrant_locks()` 会删运行中 Qdrant 的锁文件，故只做静态校验（`py_compile` + 改名 grep + 契约校验）；计划中的「触发一次真实 mcp-summary」未执行（会写知识库），待用户确认后再跑。

### 阶段 3：超时（3.1–3.2 已实施）✅

**实施记录**：
- **3.1 默认值单一化**：`ConfigTypes.swift` 新增 `enum ConfigDefaults`（`defaultAITimeout = 120`、`llmTimeout = 120`），`GeneralConfig.aiTimeout` 的属性初值与解码兜底、`OpenAIClient.init` 的 `timeout > 0 ? … : 120` 三处一律引用常量。原先同一条默认值写三遍，改一处漏一处就会出现「YAML 写了走一个默认、没写走另一个默认」的分裂。`default-config.yaml` 的 `general.aiTimeout` 注释指向常量名。
- **新配置 `ai.llmTimeout`**（默认 `ConfigDefaults.llmTimeout`，`0`/负值 = 用默认，与 `OpenAIClient.init` 既有约定一致）→ Swift 注入 `AI_LLM_TIMEOUT`（经 `EnvKeys.aiLLMTimeout`，非正值不注入）。**不复用 `general.aiTimeout`**：那是 agent/HTTP 调用超时（`AGENT_TIMEOUT`），量级与语义都不同，合并会让「调大 agent 超时」意外改动 LLM 调用行为。
- **3.2 Python 侧单一来源链**：`config.llm_timeout()`（缺省/非数字/非正值回退 120）→ `llm_client.DEFAULT_SYNC_TIMEOUT` → `summary_llm.SUMMARY_LLM_TIMEOUT` → `summary_rules.RULES_LLM_TIMEOUT` / `summarize.AGGREGATE_LLM_TIMEOUT` 全部引用同一来源。**行为变化（有意）**：单次摘要超时由写死的 **90 放宽到 120**（与聚合/规则提炼对齐，取既有值中最宽松的一个——收紧另两处会误杀大输出）。另两个方向保留：分类器仍按 `classifier.totalBudgetMs` 传剩余时间、resolver 仍用 15s 探测超时（调用方显式 `timeout=` 优先）。
- **不做（判据同原计划）**：`summary_llm` 的记忆服务客户端 10s、`summarize` 的 git 30s、`ast_extractor` 的 60s/30s 属实现细节；AST 误杀的正确改进方向是失败可观测（`failed_files` 3-strike 已具备），不是加配置项。
- **验证（本轮实测）**：单元 11/11（未注入→120、45→45、小数 1.5 生效、`0`/负数/非数字/空串全部回退 120、**注入 45 后四处常量同时为 45**、`EnvKeys.aiLLMTimeout` 与 `config.py` 读名一致）；**真实行为 2/2**（桩上游延迟 2s：`AI_LLM_TIMEOUT=1` → 调用失败返回 `None`，`=5` → 成功）；契约校验 env 名 1 → **2 个**且自检 12/12；`swift build` Build complete；`strings .build/debug/utility | grep -c AI_LLM_TIMEOUT` = 1。未验证：Swift 侧 YAML→注入 的实际运行（只编译，未启动 App 实测）。

**原计划（3.1）**：`ConfigTypes.swift` 提 `static let defaultAITimeout: TimeInterval = 120`，`ConfigTypes.swift:110/121`、`OpenAIClient.swift:112` 三处引用；`default-config.yaml:25` 注释指向常量名。
**原计划（3.2）**：

| 常量 | 改动 |
|------|------|
| `summary_llm.py:32`(90)、`summary_rules.py:29`(120)、`summarize.py:76`(120) | **配置化**：`config.yaml` 新增 `ai.llmTimeout` → 注入 `AI_LLM_TIMEOUT` → 三处读取。理由：换慢模型/大上下文会真撞到；`general.aiTimeout` 已被 `AGENT_TIMEOUT`（agent 子进程，1500s 量级）占用，语义不同不可复用 |
| `summary_llm.py:33`(10)、`summarize.py:68`(30)、`proxy_usage.py:411`(15)、`ast_extractor.py:335`(60)/`356`(30) | **不做**：API 探测、git、npm install、node 解析属实现细节。若日后出现 AST 超时误杀，改进方向是失败可观测（`failed_files` 3-strike 已具备），不是加配置项 |

### 阶段 4：embedder 维度跟随模型（4.1–4.3 已实施）✅

**实施记录**：
- `server_embed.py`：新增 `resolve_embedder_dims(model_name, *, fallback=384)`——遍历 `TextEmbedding.list_supported_models()` 按 `model` 匹配取 `dim`；查不到 / 字段不可用 / 查询异常一律回退 `fallback` + warning。`EMBEDDER_DIMS` 由它在 import 时求值（**默认路径零行为变化**：`all-MiniLM-L6-v2` → 384 = 原写死值）。元数据字段名提为常量 `_META_MODEL_FIELD`/`_META_DIM_FIELD`，理由：那是外部库的字段名，库改名时要一处红，而不是各处静默取不到值、全体回退兜底。纯元数据读取（30 条目，不加载 ONNX、不走网络）。
- 新增纯函数 `describe_dim_mismatch(existing_dims, expected_dims) -> str | None`（建议文本可测），`server.py` 新增 `_collection_vector_size(client, name)`（单向量 + 命名向量 dict 两种形态都兼容，读不到返回 None = 跳过校验）。
- `server.py` 冷层初始化：集合已存在时校验维度，不一致 → `logger.error` + 处置建议 + **禁用冷层**（`qdrant = None`）。选降级而非拒绝启动：`grep` 确认所有 qdrant 使用点都有 `if qdrant` / `if not qdrant` 守卫（354/355、561、744、1268、1554、1659），故禁用是既有且安全的降级路径；而 MCP 服务还承载热层记忆与项目检索，为一个冷层维度不符让整体不可用，损失大于收益。「不静默」由 error 日志 + 功能禁用保证（原实现是照常启动、直到查询时才失败，且异常被吞成 warning）。
- **4.3 未让 Swift 注入 dims**（判据同原计划）：维度是模型固有属性。
- **验证（本轮实测）17/17**：单元 10 项（默认模型→384、未知模型→兜底 384、`fallback` 参数可覆盖、写了 warning、**另一支持模型 `BAAI/bge-base-en` 解析出 768**（证明不是硬编码）、一致/读不到均无建议、不符时建议含「维度不一致 + 全量重扫」）；集成 7 项（真实 Qdrant，`QDRANT_PATH` 与 `HOME` 均隔离到 `/tmp`）：首次启动建集合且冷层可用 → 同维度重启校验通过且无报错 → 换 768 维模型启动 **冷层被禁用（`server.qdrant is None`）+ 日志给出处置建议** → 换回原模型冷层恢复可用。
- 附带修掉一个测试脚本自身的 bug：为隔离日志把 `HOME` 指向临时目录后，脚本里 `os.path.expanduser("~")` 解析出的 venv 路径不存在——测试脚本不能用 `~` 展开（产品代码不受影响）。

**4.1 已验证**：本机 fastembed `0.8.0` 的 `TextEmbedding.list_supported_models()` 条目含 `dim` 字段（`all-MiniLM-L6-v2` → `384`）。
**4.2 实现（Python 侧单一权威，Swift 不参与）**：`server_embed.py` 由 fastembed 元数据解析 `EMBEDDER_DIMS`；模型不在支持列表时回退 `384` + warning 日志；启动时校验与现有 Qdrant 集合维度是否一致，不一致**显式报错并给出处置建议**（改回原模型或删集合全量重扫），不得静默继续——集合维度在首次创建时固定（`server.py:295`）。
**4.3 不让 Swift 注入 dims**：维度是模型固有属性，交给 Swift 等于新建一份「模型名→维度」映射，与 Python 侧必然漂移。

### 阶段 5：Python 侧统一 LLM 入口（5.1–5.2 已实施）✅

**实施记录**：
- 新增 `Sources/MCPScripts/llm_client.py`：`chat`（同步 httpx，模块级共享客户端）/ `achat`（异步，每次新建 `AsyncClient`——连接池绑定 event loop，本模块被两个进程导入，共享实例属偶发故障源）/ `parse_json`（自 `summary_llm._parse_json_any` 迁移，`_escape_inline_quotes` 随迁）/ `LLMTarget` / `is_configured`。
- 四处调用点全部迁移：`summary_llm._llm_chat` → thin wrapper（6 个调用点不动）；`server._check_contradiction` → `achat` + `parse_json`（顺带删掉 `import httpx`）；`proxy_usage._ask_model` → `achat`，**删掉 `LLM_API_URL/LLM_API_KEY/LLM_MODEL` 三个别名**与 `import aiohttp`；`proxy_router` 的 `_classify_anthropic/_classify_openai` 合并为 `_classify_with_provider`，调用点的 if/else 分派一并消失。
- **实施中确定的三处判据（都已落进代码注释）**：
  1. **`LLMTarget` 两个判据别混**：`ready`（endpoint+model）/`configured`（+api_key）。**api_key 为空合法**——provider 的 `apiKey` 留空 = 透传客户端 key，把它并进「可发请求」会让这些 provider 的分类**全部失效**（分类器正是从 providers 表取目标）。
  2. **响应取文本的失败语义有意不一致**：openai 缺 `choices` → `None`（失败），anthropic 缺 `content` → `""`（分类器既有语义：空答案 → 外层按无效结果重试）。统一成同一个值会改变其中一条链路的判定。
  3. **关思考分两层**：`disable_thinking` 只管协议层；deepseek 的 `thinking` 字段是 **provider 私有扩展**，走 `extra_body` 由 summary 显式传入——写进公共层会让其他 openai provider 收到未知字段而 400。实测两者都在时 body 与迁移前逐字一致。
- **503 重试**：策略常量 `DEFAULT_RETRY_503_MAX/DELAY` 收进 `llm_client` 作单一权威，`token_proxy` 主转发路径 import 同一对常量（**未**把转发路径的重试环搬进本层：那里重试的是「流式转发」而非 LLM 调用，形态不同）。缺省 `retry_503=0`；**分类器保持 0**（它自带 `maxRetries` + 总预算重试环，两层叠加会把打转型上游放大成 N×M 次调用）。
- **新增失败日志面** `~/.cache/utility/llm_client.log`（`msg=llm_call_failed` + `label` 保留各调用点原判定名如 `usage_resolver_ask_failed`，按旧名 grep 仍命中）。观察面变化：LLM 传输层失败从 `token_proxy.log`/`server.log` 集中到此文件；分类器的 `classify_retry`/`classify_failed` 仍留在 `token_proxy.log`（那是代理自身的判定，不属于传输层）。
- ⚠️ **实测抓到的真 bug（桩上游冒烟发现）**：新写的 `_classify` **覆盖了已存在的 `_classify(turns)`**（Python 后定义静默覆盖），线上表现是 `router_exception: TypeError: _classify() missing 3 required positional arguments`，且只在走会话新建分类的路径上暴露。已改名 `_classify_with_provider`，并加了一条 AST 重复定义检查扫全部 MCPScripts。
- ⚠️ **契约脚本 import 链变化**：`check-router-config-contract.py` 现在会经 `proxy_router → llm_client → httpx`，用系统 `python3` 跑会在 import 阶段失败且报错与契约无关。已加 **venv 自举**（`os.execv` 到 `~/.config/utility/mcp-venv/bin/python3`），文档里的用法不变；直接用 venv 跑亦通过。
- **验证（本轮实测）**：
  - 逐调用点套件 **35/35 通过**（桩上游 :18997；覆盖：四种目标/协议、Bearer 与 x-api-key 分派、anthropic-version 头、body 字段（model/temperature/max_tokens）、开思考与关思考两层注入、空 key 透传目标可调用、openai 缺 choices→None 与 anthropic 缺 content→""、503 重试 2 次成功与 `retry_503=0` 直败、`parse_json` 围栏/尾逗号/None、`_parse_json_any` 别名、resolver 解析、分类器归一为小写、矛盾检测解析、失败日志落 `llm_client.log`）。
  - **代理端到端**（真实 `token_proxy` 进程 + 桩上游，`HOME` 重定向到 `/tmp` 以免污染真实日志）：`POST /v1/messages` → 200 且回传桩内容；日志出现 `classify_result: strong` 与 `route_decision: session_new_classified`；桩收到的分类请求路径 `/messages`、body 含 `thinking`（关思考注入在真实链路上生效）；进程存活（证明 import 链无环、无崩溃）。
  - `python3 scripts/check-router-config-contract.py`（自举）与 `--selftest` 全绿；`swift build` Build complete；`llm_client.py` 已随 `.build/.../utility_utility.bundle/MCPScripts/` 分发；`^LLM_API_URL|^LLM_API_KEY|^LLM_MODEL` 归零。
  - 未覆盖：`server.py` 的完整启动链路（只到 `_check_contradiction` 调用级）；真实上游的 thinking 语义（桩无条件回显）。

**5.1 新增 `Sources/MCPScripts/llm_client.py`**，成为 Python 侧唯一 LLM 出口：

```python
def chat(prompt, *, system=None, temperature=None, max_tokens=None,
         timeout=None, disable_thinking=False) -> str | None      # 同步（httpx）
async def achat(prompt, *, ...) -> str | None                     # 异步（httpx.AsyncClient）
def parse_json(raw) -> dict | None                                # 迁移 _parse_json_any
```

- **配置唯一来源**：只从 `config.py` 读 url/key/model，调用方不再各自读 env（删除 `proxy_usage.py:41-43` 的 `LLM_*` 别名）。
- **不强行统一调用风格**：`summarize` 同步、`server`/`proxy` asyncio，故保留两个薄接口；统一的是**配置解析、请求构造、鉴权头、超时默认、thinking 注入、错误日志**。
- 重试策略（proxy 侧 503 重试）收进本层复用。

**5.2 四处调用点迁移**：`summary_llm._llm_chat` 保留 thin wrapper（不改 20+ 调用点）；`server.py:_check_contradiction` 内联 httpx 段改 `achat`；`proxy_usage.UsageFieldResolver._ask_model` 改 `achat`；`proxy_router._classify_anthropic/_classify_openai` 改 `achat`，仅保留协议差异（`anthropic-version` 头）。

### 阶段 6：提示词外部化 + 语言变体（6.1–6.5 + `en` 变体 + user 前缀，全部已实施）

**实施记录**：
- **迁移脚手架用 AST 逐字提取**（`/tmp` 下，未入库）：提示词差一个标点不会报错、只会静默改变模型行为，故不能手工转抄。关键事实：`ast.Constant.value` 是**已解码**字符串——f-string 源码里的 `{{` 在 AST 里已经是 `{`，所以展平结果天然就是「渲染后的真实文本 + `{占位符}`」，无需再做转义处理。复杂插值（`group.get('topic','')`、`sorted(SUMMARY_EXCLUDE_DIRS)`、`target_file.relative_to(...)`）登记进映射表转成语义占位符（`topic`/`exclude_dirs`/`target`），**未登记则脚手架直接失败**（不静默漏掉一处插值）。迁移前留快照，迁移后断言两者逐字相等。
- **新增 `prompt_loader.py`**：目录优先级（用户覆盖 `UTILITY_DATA_DIR/prompts/<lang>/` → 内置 `MCPScripts/prompts/<lang>/`，复用既有 env 契约，不新增 env 项）、front-matter 契约（`name`/`placeholders`/`json_keys`，扁平键、零 YAML 依赖）、按名一次性替换渲染、加载失败回退链、语言回退基线。
- **10 个 feature 全部迁移**：`quality_judge`（system 常量，最长的纯静态）、`aggregate`、`merge_cross_batch`、`extract_keywords`、`decide_merge`、`gen_new`、`gen_merge`、`extract_rules`、`contradiction`、`classify_tier`。原常量/ f-string 一并删除，调用点改为 `prompt_loader.prompt(feature, **vars)`。
- **渲染方式**：**禁用 `str.format`**——提示词里大量 JSON 花括号（`{"action": "merge"}`）会被 format 当占位符；改为按名字一次性正则替换（未登记 `{...}` 原样保留、替换值不被二次替换），与 Swift `PromptManager.applyVariables` 同模式。
- **分类器两条路严格程度有意不同**：`config.yaml router.classifier.promptTemplate` 仍是用户手写 → 宽松 `replace`（保留 `{lastUserMessage}` 拼写容忍）；文件模板走 loader 严格契约校验（改名遗漏必须报错，而不是渲染出缺了用户消息的 prompt）。
- **解析失败可观测**（原计划的 6.2 尾段）：`_llm_json(..., feature=...)` → 两次解析不出 JSON 记 `PROMPT_JSON_PARSE`；解析成功但缺 `json_keys` 记 `PROMPT_JSON_MISS`（不改返回值）。
- **6.5 语言单一来源**：Swift 侧把语言判据提为 `L10n.normalize()` / `L10n.resolvedLanguage(configured:)`，`_ready` 与 `setup()` 改走它（原先判据在 `_ready`、`setup`、`preferredLanguage` 三处各推导一遍）；`PythonScriptRunner.baseEnvironment()` 注入 `EnvKeys.utilityLang`（`UTILITY_LANG`）→ Python `config.ui_language()`（配置读取唯一入口）→ `prompt_loader.current_lang()`。`resolvedLanguage` 的默认参数**不读 ConfigManager**——`_ready` 可能在配置加载前触发。
- **验证（本轮实测）15/15**：**10 个提示词与迁移前逐字一致**（快照比对）；真实调用路径抽查（`Router._build_classify_prompt` 走模板且替换两个占位符、config 模板仍优先、`_check_contradiction` 取 `contradiction` 模板并传对实参）；契约（缺实参抛错、多传只 warning、`json_keys` 缺失报出/齐全为空/未声明不校验）；优先级与回退（用户覆盖优先、name 不符回退内置、placeholders 声明不符回退内置、`UTILITY_LANG=en` 无 en 目录回退 zh-Hans、feature 名含 `../` 被拒）。另有：`py_compile` 全通过；契约校验 env 名 2 → **3 个**（`AI_API_KEY`/`AI_LLM_TIMEOUT`/`UTILITY_LANG`）且自检 12/12；`swift build` 通过；bundle 内 `MCPScripts/prompts/zh-Hans/` 10 个模板随包分发；`UTILITY_LANG=en` 实测 `current_lang()` 返回 `en` 而模板回退 `zh-Hans`。
- **6.4 Swift 侧接入（本轮实施）**：`translate`/`translate_auto` 从 `Resources/<lang>.json` 外置为 `prompts/<lang>/<feature>.md`（各 2 份：`zh-Hans` + `en`）。迁移由脚本从 JSON 取值生成、并**回读断言正文逐字一致**——这是既有文本的搬迁而非重写，不得借机改动措辞。`PromptManager` 改为「配置内联模板 → 文件（用户覆盖 → 内置，当前语言 → 基线）→ `L10n` 兜底」三级；新增 `parseTemplate` 与 `prompt_loader` **逐条同契约**（front-matter 键、`name` 校验、`placeholders` 双向自校验）；`applyVariables` 改为按名**一次性**替换（原逐 key `replacingOccurrences` 会让替换值里的 `{target}` 被后续轮次二次替换）。资源定位提炼为 `MCPScriptsResources.path(relative:)`（bundle → dev 两种布局），`PythonScriptRunner.findScript` 委托它。**`L10n` JSON 键保留**：它不是第二份文案，而是 `MCPScripts/prompts/` 缺失（安装不完整）时的兜底——那时发一段空 system prompt 会表现为「模型答非所问」而非「翻译报错」，更难排查；两者内容由契约脚本逐字断言，不会漂移。
- **6.4 验证（本轮实测）**：契约 6 组全绿（含 6 份模板被**生产解析器**接受、正文与 L10n 逐字一致、基线语言两侧同值）；反向自检 **16/16**（新增 4 个变异：正文与 L10n 不一致 / 某语言模板缺失 / front-matter 的 `name` 写错 / 基线语言不一致）。**自检首轮失败暴露了真实缺陷**：`find_prompt_violations` 拿着变异后的文本却从磁盘重读文件（变异静默无效、检查器形同虚设），且遍历入参字典而非期望集合（模板缺失时 key 直接消失、无从检测）。修法是把 `prompt_loader._parse_file` 拆成 `parse_template(raw, feature, path)`（生产解析器直接吃文本）+ 文件形态薄封装，脚本改为遍历 `语言 × feature` 期望集合。`swift build` 通过；bundle 内 `MCPScripts/prompts/{zh-Hans,en}/translate*.md` 4 份随包分发；`default-config.yaml` 新增 `prompts` 段并附覆盖方式说明（YAML 语法已验）。

- **`en` 变体（本轮实施）**：13 个 feature 的英文模板全部补齐（`prompts/` 共 26 份 = 13 × 2）。翻译的硬约束是**结构不变**——占位符名、JSON 契约键、front-matter 声明一律原样保留，只译正文；凡原中文版指定输出语言的表述（如 `"reason": "一句中文理由"`）在译文里改为不指定语言，让模型跟随输入材料语言，而不是让中文记忆产出英文笔记。契约脚本随之扩展：`PROMPT_FEATURES` 登记全部 13 个 feature 的占位符、基线语言**强制齐全**（它是所有语言的回退目标）、其它语言按存在性校验（渐进补译是正常节奏，强制齐全会让「先中文、后补英文」无法通过校验）、新增「翻译版 `json_keys` 与基线一致」断言——键名是**代码解析**的契约，译错一处会让 `missing_json_keys` 再也检测不出「模型没按契约输出」。自检 **17/17**：原「某语言目录缺模板」变异因 en 变为非必需而失效（自检正确地判为「变异未生效」），已改写为「基线语言缺文件」，并新增「翻译版 json_keys 不一致」。
- **`quality_judge` 的 user 前缀外置（本轮实施）**：新增 `prompts/<lang>/quality_judge_user.md`（占位符 `{text}`），`summarize.py` 里硬编码的 `f"记忆内容：\n{text}"` 改走 `prompt_loader.prompt("quality_judge_user", text=text)`。此前 system 已外置而 user 前缀留在代码里，英文环境下会「中文前缀 + 英文 system」。system 与 user **各占一份文件**，`quality_judge.md` 保持「不含占位符」的形态（不必为一个前缀把两种语义塞进同一模板）。
- **本轮验证**：多语言结构对齐 **8/8**（13 个 feature 双语渲染无残留占位符；en 版全部命中而非回退；占位符**出现顺序**与 JSON 契约键两语言一致；`json_keys` 跨语言一致；`quality_judge_user` 渲染与旧硬编码逐字等价；`ja` 等未翻译语言回退中文基线）；阶段 6 回归 **16/16**（原「`UTILITY_LANG=en` 且无 en 模板 → 回退」用例因 en 已补齐而失效，改写为「en 命中」+「ja 回退」两条）；契约 **26 份模板全绿**、自检 **17/17**；`swift build` 通过，bundle 内 `prompts/{zh-Hans,en}/` 各 13 份。

- **自定义覆盖改为语言无关（用户修正，本轮实施）**：原设计里用户覆盖目录与内置同构，也是 `prompts/<lang>/<feature>.md`。用户指出「内置是系统内置、使用者可能是不同母语的人，内置多语种是正常的，但自定义没必要，因为是用户控制的」——写 prompt 的人只有一种母语，那份文件就是给自己用的，让它「放哪个目录」取决于界面语言既无意义、又会因切换界面语言而失效。现改为 `<配置域>/prompts/<feature>.md`（一份对所有界面语言生效），**内置仍按语言分目录**（面向不同母语的使用者）。Swift 侧候选元组第二项改为可选（`nil` = 语言无关，不再被报成语言回退）。本机无既有覆盖目录，无兼容负担。验证：新增「用户覆盖在 en 界面下同样优先」回归用例 → 阶段 6 测试 **17/17**、契约与自检 **17/17**、多语言验证 **8/8**。

**6.1 目录与优先级**（单一权威，两侧共用）：

```
Sources/MCPScripts/prompts/<lang>/<feature>.md    ← 内置默认，随包分发（按语言，缺则回退 zh-Hans）
~/.config/utility/prompts/<feature>.md            ← 用户覆盖，优先级更高（与语言无关）
```

依据：`Package.swift` 对 `MCPScripts` 用的是 `.copy(...)`，新增子目录自动随包分发；覆盖目录落在**配置域**（与 `config.yaml` 同域），不进 `notes/` 知识库。

**6.2 声明式契约 + 加载校验**：

```markdown
---
name: quality_judge
placeholders: [text]
output: {json_keys: [judge]}
---
```

加载时校验 `placeholders` 与调用实参是否匹配、`output.json_keys` 是否与解析逻辑一致；**不匹配 → 拒绝加载 + error 日志 + 回退内置默认**。调用后解析失败时，除现有 fail-open 外补一次 `write_error_log`（当前 `summarize.py:583` 失败返回 `ERR` 无外部信号）。

**6.3 迁移顺序**：逐 feature 迁移，内置默认值与现值**逐字一致**（零行为变化），全部迁完后补 `en` 变体。清单（10 个）：`server.py:612-628` 矛盾检测、`summarize.py` 的 `quality_judge`(546)/`aggregate`(694)/`merge_cross_batch`(823)/`extract_keywords`(882)/`decide_merge`(1024)/`gen_new`(1090)/`gen_merge`(1137)、`summary_rules.py:202`、`proxy_router.py:78-85`。
**6.4 Swift 侧接入**（✅ 已实施，见上面实施记录）：`PromptManager.defaultPrompt` 改为优先读同一目录，`L10n` 退为最终兜底（只在模板文件缺失的安装损坏场景启用，内容与文件的一致性由契约脚本断言）。
**6.5 语言选择单一来源**：跟随 `general.language`（空则系统首选，判据同 `L10n.swift:18-28`），Swift 注入 `UTILITY_LANG`。

### 阶段 7：内容资产 i18n 扩面（全部已实施；7.1 由用户收窄为「参数描述」）

**实施记录（7.2 同义词表，2026-09-18）**：
- `synonyms.py` 拆成「内置默认 `SYNONYM_MAP` + 用户增量」：新增 `load_synonyms()` 合并并缓存；`config.yaml` 的 `mcp.synonyms` 经 Swift `MCPProcessManager.synonymsJSON()` 序列化 → `synonymsEnvKey`（`MCP_SYNONYMS`）注入。语义与项目里其它「增量补充」配置一致（**同名覆盖、异名追加**），用户只写要加的、不必抄回整张内置表。
- 坏输入（非法 JSON / 非对象）→ **忽略用户词、保留内置** + error 日志：表现是「我配的词没生效」，而它与「这个词本来就没配」行为完全一致，不留痕就无从排查。
- `server_search.expand_query()` 改为经 `load_synonyms()` 取表（全项目唯一消费点，已无 `SYNONYM_MAP` 直接引用）。
- 契约脚本新增 `find_synonym_env_violations`，并把「两侧常量同值」判据抽成 `find_cross_language_const_violations`（服务名与 env 名共用一份判据）。该 env **不进 `config.py`**（脚本专属 env 的既有约定），第 4 组覆盖不到它——Swift 改名而 Python 没跟时，内置表照常工作、**用户配的同义词静默失效**。自检 **18/18**。
- 验证：`test_synonyms.py` **14/14**（内置 / 追加 / 覆盖 / 空对象 / 非法 JSON / 非对象 / 字符串 JSON / 非字符串值 / 缓存 / 三条端到端）；`swift build` 通过；契约全绿；`default-config.yaml` 的 `mcp.synonyms` 段 YAML 语法已验。
- ⚠️ 过程记录：改 `expand_query` 时曾把 `" " in t` 误写成 `" in t`（丢一个空格 → 语法错误），`py_compile` 立即暴露并修复——这类改动必须过编译验证，不能只靠肉眼。

**7.3 盘点结论（2026-09-18，待定）**：原计划设想「MCP 工具返回的错误提示按 `UTILITY_LANG` 选语言」，实测盘点与设想不符——
- 各 `_handle_*` 的返回**几乎全是结构化数据与技术标识**（`"success"` / `"memory_id"` / `"layer"` 这类 JSON 键），没有面向用户的固定句子；
- 现存的固定文案是**英文技术错误**（`Database not found: {path}`、`project directory not found`、`skill not found`、`resource not found`），且它们返回给**模型**、不是终端用户；
- 唯一的中文固定文案是 4 条 HTTP 端点错误（`bit/value 必须为整数`、`memory_ids 不能为空`、`bit 超出范围 0-…`、`value 只能为 0(重置)或 1(设置)`）。
真正的用户可见文案在 Swift 侧、已由 `L10n` 覆盖。故「按语言选文案」在 MCP 工具层价值有限；现状的**中英混杂**更值得处理，方向倾向统一为英文（与「内部日志保持英文」一致），而非增加 i18n 分支。待用户定。

**实施记录（7.3 文案统一，2026-09-18；用户裁定「统一为英文」）**：
- 放弃「按 `UTILITY_LANG` 选语言」的原设想：这一层文案的受众是模型/开发者，i18n 收益低，而**中英混杂**才是真问题。
- `set_memory_processed` 的 3 条参数校验在 MCP handler 与 HTTP 端点**各写一份且为中文** → 收敛为 `ERR_MEMORY_IDS_EMPTY` / `ERR_VALUE_INVALID` / `ERR_BIT_VALUE_NOT_INT` 常量 + `err_bit_out_of_range()`（带实际 bit 值，内部异常用），两条入口共用；`bit 超出范围` 的 `raise` 同步改用该函数。
- `'Hot layer not initialized'` 原本**硬编码 6 处**（各工具 handler + HTTP 端点），收敛为 `ERR_HOT_LAYER_NOT_READY`。
- 2 条中文日志（`读取集合 … 维度失败`、`设置 processed 位失败 …`）改英文——这一层统一英文，不与 `UTILITY_LANG` 联动。
- **判定口径**：重复出现的 error 文案必须走常量（单处出现抽常量无收益，重复的才有漂移风险）。验证脚本按此断言，并把「error 文案总量」也纳入，防口径悄悄膨胀。
- 验证：`test_error_messages.py` **9/9**；阶段 6 回归 **17/17**；`py_compile` 通过。
- ⚠️ 顺带修掉的测试缺陷：新加的「用户覆盖与语言无关」用例把覆盖文件写进了**主配置域**，下一轮跑测试时它遮住内置模板（`decide_merge` 读到覆盖版 31 字符、快照 407 字符，另有 2 条语言用例连带失败）。修法是**按用例组切配置域**（干净域 / 覆盖域），并让该用例改用其它用例不触碰的 feature。连跑两次均 17/17，幂等恢复。

**实施记录（7.1 工具参数描述国际化，2026-09-18）**：范围经用户两次收窄后定稿——**只做工具参数描述**。
- 用户裁定：`DESCRIPTIONS.md` 是用户自定义、不用管（故 `DESCRIPTIONS.<lang>.md` 方案作废）；工具**描述**（`TOOL_DEFAULTS`）与它同类——有覆盖渠道的长文案，同样不做；**参数描述可以加内置国际化**（这一项原计划里没有，由用户提出）。
- 新增 `Sources/MCPScripts/tool_text.py`：`PARAM_TEXT[key][lang]` + `param_text(key)`。**18 条唯一文案在 schema 里出现 23 处**（`param.db_path` 被 4 个 `project_*` 工具引用、`param.max_results` ×2、`param.memory_content` ×2）——键取**语义名**而非「工具.参数」路径，否则同一句文案在翻译时分叉成几份，「改一处忘三处」随翻译放大。
- 语言判据与提示词**同源**（`config.ui_language()` ← `UTILITY_LANG`），缺该语言回退基线；基线**三处同值**（`tool_text.FALLBACK_LANG` / `prompt_loader.FALLBACK_LANG` / `PromptManager.fallbackLanguage`）由契约脚本断言。
- 未登记的键抛 `MissingParamText`，**不回退成键名**——那会把内部标识当文案发给模型。
- 契约脚本**第 7 组**（静态 AST，不 import server.py——它导入即拉起 mem0/qdrant）：`handle_list_tools()` 内的 `"description"` 必须经 `param_text(...)` 取（裸字面量与「无法判定的形式」都算违反）、引用的键必须存在、表中无孤儿键、各键语言集合**一致且含基线**（schema 一次性整体呈现，混语言比统一未翻译更糟）。`find_fallback_lang_violations` 同时升级为 N 方同值判据 `find_baseline_lang_violations`。
- 验证：`test_tool_text.py` **13/13**（含「23 条 zh-Hans 文案与迁移前逐字一致」，判据取自 `git show HEAD:Sources/MCPScripts/server.py` 而非手抄）；契约 **18 条对齐**；自检 **24/24**（新增 6 个变异）；回归 阶段6 **17/17**、同义词 **14/14**、错误文案 **9/9**。
- ⚠️ 口径修正：本条先按「20 处」口头盘点，AST 实测为 **23 处**——人工数会漏，判据应以 AST 为准（同理，测试里也用 AST 抽取而非正则）。
- **要素口径统一（用户裁定「三要素为主」）**：`param.memory_content` 原为**五要素**（与用户自定义的 `DESCRIPTIONS.md` 同口径），而内置 `TOOL_DEFAULTS["remember"]` 是**三要素**——同一段模型行为被两套说法描述，模型读到的是两套要求。现改齐为三要素（`TOOL_DEFAULTS` 侧本就是三要素，未动）；`DESCRIPTIONS.md` 是用户自有文案（notes 目录、不随包分发），不受此约束、也不去改。测试新增「参数描述与 `TOOL_DEFAULTS` 逐字一致」+「不含被弃用的五要素用词」两条断言，判据取自 server.py 的 AST。⚠️ 过程中踩到：`TOOL_DEFAULTS` 是**带注解**的赋值，AST 节点是 `AnnAssign` 而非 `Assign`，只认后者会静默取空——「先断言取到了、再比对」的两段式写法把它暴露了出来。**16/16**。

**原始计划条目与最终实施的差异（收尾记录）**：
- ~~**工具描述**：`TOOL_DEFAULTS` 与 `DESCRIPTIONS.md` 支持语言变体——`DESCRIPTIONS.<lang>.md`~~ → **不做**（用户裁定：两者都有用户自己的覆盖渠道，长文案内置译文本无人维护）；改为**参数描述**内置 i18n（原计划未列）✅
- **术语表**：`synonyms.py` 改为「内置默认 + `config.yaml` 增量合并」；**不迁入 notes** ✅ 按计划实施
- ~~**用户可见文案**：MCP 工具返回的错误提示按 `UTILITY_LANG` 选语言~~ → 改为**统一英文**（受众是模型/开发者）✅

**收尾：deep code review + 修复（2026-09-20）**：对全部暂存改动（64 文件，+4412/−876）跑了 deep 级审查（2 specialist + 4 对抗视角 + 3 独立 skeptic，均由 subagent 并行执行，每条 HIGH 都经独立 skeptic 亲读代码反驳）。
- **[HIGH，已修] 两个新配置项到不了它们最该生效的链路**：`AI_LLM_TIMEOUT` / `UTILITY_LANG` 只进了 `baseEnvironment()`，没进 `mcp-summary` 的 `.sh` 白名单 → ①`ai.llmTimeout` 100% 不生效（它的消费方恰好全在 summarize，恒回退 120s）；②`general.language: en` 时 summarize 的 9 个 feature 走中文提示词且**连 warning 都不记**。修法**不是补两个键**而是抽 `aiEnvironment()` / `resolvedNotesDir()` / `taskEnvironmentOverrides()` 让两个注入点**同源**（补键只是治这一处，同源才防下一处）。
- **[根因，已修] 契约脚本第 4 组判据恒真**：`collect_swift_env_literals` 扫「任意 `"UPPER_SNAKE"` 字面量」，`EnvKeys` 的声明本身即满足 → 「Python 读了必须有人注入」形同虚设，看不见「漏了一个注入点」。改为只认**实际注入点**（`env[…]=` / `env[EnvKeys.xxx]=`，按 EnvKeys 展开），并加反向断言「EnvKeys 声明的常量必须有注入点」。
- **[MEDIUM，已修] 新增观测点永不落盘**：`client_text_miss` / `classifier_check_skip` / `classifier_client_not_allowed` / `models_schema_fallback` 全是 `logger.debug`，而 18 处 `setup_logging` 无一传 level、全仓无 `setLevel(DEBUG)` → 本 diff 承诺的「补登记通道」在默认配置下不存在。已升为 info。
- **[MEDIUM，已修] `prompt_loader` 异常捕获范围窄**：只 `except PromptLoadError`，覆盖文件的 `UnicodeDecodeError`/`OSError` 会穿透并中断 summarize 首阶段（Swift 侧用 `try?` 容错，两侧分叉）。已放宽为三元组。
- **[LOW，已修] 超时注入取整**：`String(Int(ai.llmTimeout))` 把 0.5 变成 `"0"`，Python 视 0 为「未配置」→ 静默回退 120（同一个 0 在两处含义相反）。改为 `String(ai.llmTimeout)`。
- **[已修] 脚本专属 env 无断言**：`MODEL_PROXY_*` 等 6 个名字两侧各写一份字面量、无任何交叉断言（`MCP_SYNONYMS` 曾被单独兜住）。新增「脚本直读 env」断言 + 显式豁免表（`PATH`、`EMBED_QUERY_CACHE_SIZE`，各附理由）。
- **用户裁定不修**：`summary_rules` 把 norms 产出目录移到 `MCP/Rules` 从而不再注册为 MCP 工具——**有意为之**（skeptic 核实：不是本 diff 引入，生产 bundle 早已如此，旧目录已人工迁移）。
- 验证：契约 EXIT=0（**注入点 28 个**）、自检 **27/27**（新增 3 个变异，其中「某个注入点漏加」正是上述 HIGH 的形态）、`swift build` pass、`swiftformat --swift-version 6.3 --lint` 0/72、四个测试套件 16/16、9/9、14/14、17/17。

---

## 五、明确不做（含反证）

- **阶段 0.3 不采用「去掉客户端前置」**：会改变所有短请求的行为（含真实单轮问答），收益不可验证；采用可配置白名单 + 明确的重评触发条件。
- **P6 Swift 侧 Anthropic 原生客户端不做**：Swift 层 AI 功能经 OpenAI 兼容协议已可用；新增客户端需同步改 `ConfigManager` 配置面与 `PromptManager`，且 `CLAUDE.md` 明确「`OpenAIClient`/`CustomClient` 保持不动」。重评触发条件：需要直连 Anthropic 原生上游且无兼容网关可用。
- **`SERVER_NAME` 不配置化**：`MCPProcessManager.swift:248` 用 `service: "mino-brain"` 硬校验做端口复用探测，改则探测永久失败；护栏是 2.4 的契约校验。
- **`DESCRIPTIONS.md` 不换 YAML**：真实格式是 `### name` + 段落（`server.py:525-545`）；本版只加语言变体。
- **工具描述不做参数级覆盖**：参数描述直接决定 agent 是否/如何传参（属触发与执行契约），风险高于收益。
- **v1 §二.3 classifier 超时 env 化**：config.yaml 通路已存在（`ConfigTypes.swift:309-334`），该节整节删除。
- **v1 §四 host env、§十二原样**：host 由 1.1 常量承担；i18n 由阶段 7 承担。
- **v1 §七/§八**：单点使用、无命名冲突，价值极低，可略；若做只提常量不加 env。

---

## 六、验证与回滚

| 阶段 | 验证 | 回滚 |
|------|------|------|
| 0.1 | 用 Anthropic 协议客户端打 `POST /v1/messages`（不改 base_url 前缀）→ 200 且 `route_decision` 日志的 `api_format` 与路径一致；OpenAI 客户端打 `/v1/chat/completions` 同理；构造「路径说 openai、body 像 anthropic」的请求 → 出现 `format_mismatch` 告警 | 保留 `/open/{path}` 别名，删除新路由即回到现状 |
| 0.2 | `curl -H 'anthropic-version: 2023-06-01' /v1/models` → Anthropic schema；`curl -H 'Authorization: Bearer x' /v1/models` → `{"object":"list"}` | 单函数回退旧实现 |
| 0.3 | 默认配置下 Claude Code 请求仍出现 `classifier_thinking_disabled`；用非 claude UA 发同结构请求 → 出现 `classifier_client_not_allowed` 且不注入；在 config 加一条白名单 → 该 UA 立刻获得加速 | 删除 `clientAccel` 段即回默认 |
| 0.4 | 默认配置下 `actual_user_input` 与 `session_key` 与迁移前**逐字一致**；用非 Claude 文案请求 → 出现 `client_text_miss` 且不再污染 `actual_user_input` | 删除 `clientText` 段即回内置默认 |
| 1 | ✅ 已验：`swift build` EXIT=0；`strings .build/debug/utility \| grep -c localhost` = 0；`grep -c '"Summary:"' proxy_usage.py` = 1 | `git revert` |
| 2 | ✅ 已验：契约正向 EXIT=0、`--selftest` 12/12；venv 实测改名后的导入链取到值、旧名无回退；`swift build` 通过 | 同仓同发，还原即恢复 |
| 3 | ✅ 已验：桩上游延迟 2s，`AI_LLM_TIMEOUT=1` → 调用失败、`=5` → 成功；非法值全部回退 120；四处常量同源 | 配置缺省回旧行为（单次摘要回到 90 需改 `ConfigDefaults.llmTimeout`） |
| 4 | ✅ 已验：默认模型 384 无变化；换 `BAAI/bge-base-en`（768）→ 启动即报维度不一致并禁用冷层，换回即恢复 | 还原模型名；若已用新模型建过集合，需删集合全量重扫 |
| 5 | ✅ 已验：逐调用点套件 35/35（桩上游）；真实代理进程端到端 200 + `classify_result` + 关思考注入生效；`^LLM_API_URL` 等三个别名归零 | 逐文件 revert |
| 6 | ✅ 已验：10 个 Python feature 与迁移前**逐字一致**（AST 快照比对）；4 份 Swift 模板由 L10n JSON 生成并回读断言逐字一致；故意写坏覆盖文件（name 不符 / placeholders 声明不符）→ 被拒 + 回退内置 + error 日志；缺实参抛错；**多语言结构对齐 8/8**（渲染无残留占位符、en 全命中、占位符顺序与 JSON 契约键跨语言一致、ja 回退基线）；契约第 6 组覆盖 26 份模板 + 反向自检 **17/17**。待做：翻译面板端到端（需重启 app，见下一步） | 删覆盖文件即回内置 |
| 7 | ✅ 已验：同义词 **14/14**、MCP 错误文案 **9/9**、工具参数描述 **13/13**（含「23 条 zh-Hans 文案与迁移前逐字一致」，判据取自 git HEAD 的 server.py）+ 契约 **18 条对齐** / 自检 **24/24**；阶段 6 回归 **17/17**。待做：实机切 `general.language` 为 `en` 观察工具 schema 与提示词随语言变化（需重启 app） | 删 `config.yaml` 的 `mcp.synonyms` 段、撤 `param_text` 引用即回内置默认 |

---

## 七、文档状态

- 本文件已落位于 `.claude/plans/ai-capability-governance.md`（原 `a.md`，已移入）。
- `c.md`（Token Proxy 输入成本治理头脑风暴）仍在仓库根目录，按用户「不处理」保留原状。
- 工作区未提交：阶段 1 + 阶段 0.1–0.4 + 阶段 2（`EnvKeys`、17 处改名、契约校验扩到 5 组、gen-article 死代码清理）+ 阶段 5（新增 `llm_client.py`；改 `summary_llm.py` / `server.py` / `proxy_usage.py` / `proxy_router.py` / `token_proxy.py` / `scripts/check-router-config-contract.py`）+ 阶段 3（`ConfigDefaults`、`ai.llmTimeout` → `AI_LLM_TIMEOUT`、`config.llm_timeout()` 单一来源链、`default-config.yaml`）+ 阶段 4（`server_embed` 维度解析、`server` 启动维度校验）+ **阶段 6 主体**（新增 `prompt_loader.py` + `prompts/zh-Hans/` 10 个模板；改 `summarize.py` / `summary_rules.py` / `server.py` / `proxy_router.py` / `config.py`；Swift 侧 `L10n` 语言判据收敛 + `EnvKeys.utilityLang` 注入 + `default-config.yaml`）+ `.claude/CLAUDE.md` 同步（七处：输入过滤、classifier 加速、转发入口与模型发现、LLM 统一入口、超时单一来源与两个 aiTimeout 辨析、embedder 维度解析与冷层校验、提示词外置）+ `.claude/rules/internal-task-registration.md`（去掉已移除任务名）+ **阶段 6.4 + `en` 变体**（新增 `Sources/Core/MCPScriptsResources.swift`；重写 `Sources/Core/PromptManager.swift`；`prompts/` 增至 26 份 = 13 feature × {`zh-Hans`,`en`}；`prompt_loader` 拆出 `parse_template`；`summarize.py` 的 `quality_judge` user 前缀改走模板；契约脚本扩到 6 组 / 26 份模板 / 自检 17 项）+ **阶段 7**（新增 `Sources/MCPScripts/tool_text.py`；`synonyms.py` 加 `load_synonyms()` 增量合并；`server.py` 23 处参数描述改走 `param_text`、`ERR_*` 常量收敛、2 条日志改英文；Swift 侧 `ConfigTypes.swift` 加 `mcp.synonyms` + `MCPProcessManager.swift` 注入 `MCP_SYNONYMS`；契约脚本扩到 7 组 / 自检 24 项；`default-config.yaml` 加 `prompts` 与 `mcp.synonyms` 段；`README.md` 重写「自定义提示词模板」段）+ `.claude/CLAUDE.md` 同步（新增「工具参数描述国际化」节、`synonyms` 增量合并条、MCP 层文案英文条）+ 本文件。

**下一步建议顺序**：0.1–0.4 ✅ → 阶段 2 ✅ → 阶段 3 ✅ → 阶段 4 ✅ → 阶段 5 ✅ → 阶段 6 ✅（含 6.4、`en` 变体、`quality_judge` user 前缀）→ 阶段 7 的 **7.2**（同义词表增量合并）✅、**7.3**（MCP 层文案统一英文 + 重复文案收敛）✅ → **7.1 工具参数描述内置 i18n** ✅（`tool_text.py`；工具描述与 `DESCRIPTIONS.md` 经用户裁定不做）。**阶段 7 已全部收口。**另需用户决定两件事：(1) 是否重启 Utility.app 使阶段 2 的新 env 名、新 Python 模块（`llm_client`）与阶段 6 的 `UTILITY_LANG` 注入生效（重启前 Python 子进程若被拉起会读到空 key）；(2) 翻译面板实机验证（外置模板的路径解析只在 app 内可验）。
