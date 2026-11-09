# MCP 服务（server.py）

> Python 源码在独立仓 `agent-gateway`（`src/agent_gateway/`）；本仓只有 Swift 宿主与打包时的 wheel。

> 从 `.claude/CLAUDE.md` 分层迁出（2026-10-18），内容逐字保留。
> 修改对应模块前先读本文件；CLAUDE.md 只保留必须遵守的不变量。

### server.py（MCP Python 服务）
- mem0 热层（`Memory.from_config`）使用 Qdrant 本地存储 + fastembed 嵌入
- Qdrant 冷层独立集合 `knowledge_base`
- **embedder 维度由 fastembed 元数据解析**（`server_embed.resolve_embedder_dims()` 读 `TextEmbedding.list_supported_models()` 条目的 `dim` 字段；实测 `all-MiniLM-L6-v2` → 384、`BAAI/bge-base-en` → 768），查不到/字段不可用才回退 `384` + warning。**Swift 不参与注入维度**：维度是模型固有属性，另建一份「模型名 → 维度」映射必然与真实值漂移。元数据字段名（`model`/`dim`）提为常量——那是**外部库的字段名**，库改名时要一处红，而不是各处静默取不到、全体回退兜底
- **启动时校验冷层集合维度**：集合维度**首次创建即固定**，换模型后旧向量与新查询向量不可比，Qdrant 报 dimension 错误，而 `search_cold_layer` 把异常吞成一条 warning → 表现为「冷层检索静默失效、用户只觉得结果变少」。现在不一致即 `logger.error` + 处置建议（改回原模型 / 删集合按新维度重建并全量重扫）并**禁用冷层**（`qdrant = None`；其余 qdrant 用法均有 `if qdrant` 守卫，热层与项目检索照常）。降级而非拒绝启动：MCP 服务还承载热层记忆与项目检索，为一个冷层维度不符让整体不可用，损失大于收益
- 热层初始化含 PostHog 遥测 SSL 握手，双重禁用：模块级 `posthog.disabled = True` + 环境变量 `MEM0_TELEMETRY=False`（后者更关键——mem0 的 `AnonymousTelemetry` 创建独立 PostHog 实例，不受 `posthog.disabled` 影响）
- 热层惰性初始化：不在模块加载阶段执行，由 `_ensure_hot_memory()` 在首次工具调用时触发
- `FASTEMBED_CACHE_PATH`（注意不是 `FASTEMBED_CACHE_DIR`）是 fastembed 读取的环境变量名，两处设置此变量：server.py 模块级 + Swift `MCPProcessManager.serverEnvironment`（经 `PythonScriptRunner.environment(overrides:)` 注入）
- `MEM0_CONFIG["embedder"]["config"]` 不支持 `cache_dir` 参数（`BaseEmbedderConfig` 不接受），依靠 `FASTEMBED_CACHE_PATH` 环境变量让 mem0 内部 fastembed 找到已有缓存
- `tool_resource` 工具返回已注册 skill 的附属资源：path 必须位于 `references`/`agents`/`scripts` 之下，双重校验——normpath 语法层挡 `../` 穿越 + realpath 语义层解析 symlink 后仍须位于 skill 目录真实路径内（防附属目录内 symlink 指向外部文件泄露），读取用 realpath 结果避免 TOCTOU
- `websearch_engine` 是内置工具（`web_search.py`），不再走 Skill 层：多引擎级联（Bing/Google/搜狗/360/百度/Marginalia/Brave/DDG）、按查询语言选顺序、按引擎限流 + 连续失败冷却；可选抓取前 N 页并转 Markdown、按页与总量限长。旧 `websearch-fallback` skill 已移除，页面内容不再以 HTML 返回
- **级联硬超时与并行是通用配置**（`search.runtime`，env 覆盖 `GATEWAY_SEARCH_RUNTIME`）：`timeoutSeconds` 是整轮搜索的硬上限，每次 HTTP/subprocess 调用的 timeout 都 clamp 到剩余预算，超时引擎记 `skipped_budget`；`parallel` 打开后按 `concurrency` 并发调度全部引擎。规则对所有引擎与外部 provider 一视同仁，代码里不得按 provider 名特判（`all_failed` 的 known 集合也走 `_PARSERS`/`_PROVIDERS`）
- **Google 不走 HTTP 传输**：`_search_google` 调 app 内的 `utility websearch` 子命令（`Sources/CLI/WebSearchCommand.swift`，离屏 WKWebView 执行页面 JS 抽取结果），二进制由 `UTILITY_BIN` 定位，缺省再按 `Contents/MacOS/utility`、`.build/debug/utility` 推导。子命令输出单行 JSON（`ok/status/results/final_url`），失败状态含 `captcha` / `enablejs` / `render_timeout` / `network_error`。`google.com/url?q=` 跳转由 `_resolve_google_jump` 解析：先取 `q`，否则发一个不跟随重定向的 GET 读 `Location`
- CJK 查询按 bigram 匹配，覆盖本就低于 ASCII 词，故阈值单列 `_CJK_MIN_SCORE`(0.15)，与 `_MIN_SCORE`(0.25) 并用
- **三层拆分**：`services/search/engines.py`（引擎与排序）→ `services/fetch/http.py`（UA/代理/限流/重试/解压）→ `services/markdown/html.py`（纯 HTML→Markdown）。`web_search.py` 只保留兼容 facade，旧调用方与 gateway 仓 `scripts/check-web-search.py` 的 monkeypatch 点不变；新增调用应直接依赖具体层
- **`read_url` 内置工具**（取代已移除的 `read` skill）：本地抓取 + 转换优先，`use_proxy=true` 才依次尝试 defuddle.md / r.jina.ai；GitHub blob 自动改写 raw。失败返回 `{ok:false, error_code, message, attempts[], hint}`，成功返回 `{ok:true, markdown, tier, truncated, warnings?}`——错误必须让 agent 能区分「网络失败 / 登录壳 / 空页 / 不支持格式」。PDF（`unsupported_format`）与飞书（`unsupported_site`）显式拒绝，不静默返回二进制
- **引擎挑战页与普通页面分开判定**：`http.get_text(detect_challenge=True)` 给搜索引擎用（命中 marker 即 `Blocked`）；页面读取传 `false`，否则 Wikipedia 的 `<noscript>Enable JavaScript</noscript>` 会让整篇文章被判成挑战页。登录壳由 `read_service._assess()` 在**转换后的 Markdown** 上判断
- Markdown 转换器不得跳过 `html/body/main/article` 这类结构容器：Wikipedia 的 `main-menu-disabled` 类名曾命中 boilerplate 正则，导致整页输出为空
- 百度广告位在解析层整块丢弃（标题链接含 `baidu.php`，或 `mu` 指向 `e.baidu.com` / `nourl.ubs` / `recommend_list`）；自然结果优先用 `mu` 真实地址，跳过 `baidu.com/link` 跳转解析。块内嵌广告不影响该自然结果保留
- 百度新版卡片的摘要位于 `<!--s-data:{...}-->` 注释的 `summaryData.generalLines[].data[].text`，`_baidu_summary` 优先解析它；`_text` 统一剔除 HTML 注释，避免 JSON 混入摘要。找不到容器时返回空摘要，不用整块文本兜底
- 搜狗摘要容器实际是 `div.space-txt`（旧正则只认 `p`，导致摘要全空）；`_text` 同时剔除 `script`/`style` 内容，避免 CSS 文本混入摘要
- 相关性改为「候选合并 + 打分排序」：各引擎解析结果全部进入候选池（仅过滤广告/空标题），按查询 token（ASCII 词 + 中文 bigram，无需分词/词表）的 IDF 加权覆盖率排序，分数 <`_MIN_SCORE`(0.25) 丢弃，取 top N。**不再做 matched 二元过滤**——同义/词序/繁简等变体只影响排名，不会被直接删除。旧 `_matches` 的连续子串判据会让「网络NAT」因结果写成「网络地址转换（NAT）」而全灭
- 解析后过滤搜索引擎自身的搜索结果页（`_is_engine_page`：`sogou.com/sogou`、`baidu.com/s`、`so.com/s`、`bing.com/search` 等）；`baike.baidu.com` 等内容页与 `baidu.com/link?url=` 跳转链接不受影响
- `_scan_skills` 递归 os.walk：目录含 SKILL.md（Waza 式目录 skill）→ 跳过 `_SKILL_SKIP_DIRS` 子目录且只注册 SKILL.md 本身；无 SKILL.md 的普通目录 → 其内所有 .md（含附属子目录）照常注册
- `_find_skill_dir` 按 normalize 后注册名定位 skill 目录；扁平 .md skill 不在目录注册表，定位失败返回 None → `"skill not found"`（设计使然非 bug）
- **检索同义词表 = 内置默认 + 用户增量**：`synonyms.py` 的 `SYNONYM_MAP` 是内置，`config.yaml` 的 `mcp.synonyms` 是用户增量（**同名覆盖、异名追加**，只写要加的、不必抄回整张表）。Swift `MCPProcessManager.synonymsJSON()` 把用户表序列化后按 `synonymsEnvKey`（`MCP_SYNONYMS`）注入，Python 侧 `load_synonyms()` 合并并缓存（env 在进程启动时固定，改配置要重启服务）。**该 env 不进 `config.py`**（脚本专属 env 的既有约定），故契约第 3 组的「Python 读了 Swift 必须注入」覆盖不到它——脚本单独交叉断言两侧常量同值（`find_synonym_env_violations`），否则改名后内置表照常工作、**用户配的同义词静默失效**（无任何报错）。**不迁入 notes**：检索质量不该成为可被静默改坏的变量，改坏了的表现是「搜不到」，与「这条记录本来就不存在」无法区分
- **工具参数默认值 = 内置默认 + 用户增量**（2026-10-10）：`tool_defaults.py` 的 `TOOL_ARG_DEFAULTS` 是内置，`config.yaml` 的 `mcp.toolDefaults` 是用户增量（**同名覆盖**，键结构 **tool name → args name → 值**）。Swift `MCPProcessManager.toolDefaultsJSON()` 序列化后按 `toolDefaultsEnvKey`（`MCP_TOOL_DEFAULTS`）注入，Python `load_defaults()` 合并缓存。**该 env 不进 `config.py`**，契约第 3 组同样覆盖不到——单独交叉断言（`find_tool_defaults_env_violations`）。默认值直接决定每次调用的**返回量即 token 消耗**，故做成配置面：`recall.limit=6`、`project_lookup.limit=50`、`project_impact.limit=30` / `depth=2`、`project_notes.limit=5`、`websearch_engine.limit=5` / `fetch_top=0` / `max_chars=6000`、`read_url.max_chars=6000`
  - **schema 的 `default` 与 handler 兜底必须同源**：`DEFAULT_RECALL_LIMIT` / `LOOKUP_DEFAULT_LIMIT` / `IMPACT_DEFAULT_LIMIT` / `IMPACT_DEFAULT_DEPTH` 全部取自 `arg_default()`，两处各写一份字面量会漂移成「schema 声明 6、实际取 8」（recall 上次 10→8 踩过这个坑）
  - **项目图工具取代 `project_search`**：`project_lookup` / `project_impact` 必传项目根 `path`，读 `<path>/.agent-gateway/graph.sqlite`（不读环境变量，可查任意已扫描项目）；`project_search` 的 MCP/REST 入口、retrieval arm 与底层实现已于 2026-11-02 全部移除
  - `project_lookup` 已接入通用检索层：`Pipeline("project_lookup")` 单臂 + 位次分 + `PassThroughGate`，详见 `project-graph.md`
  - **整数参数一律经 `_int_arg`**：客户端显式传 `null` 时 `arguments.get` 返回 None，直接切片 `all_found[:None]` 是**不截断**——静默把 token 治理关掉
- **检索行为固定在代码中（2026-10-31）**：不再有 `retrieval.*` 配置段。调用方与部署都不需要调阈值——代码里**没有任何模型专属数字**，地板由自动标定写入数据目录；分层、`min_hits`、融合权重、门控类型都是代码常量。实测表明这些旋钮除了让行为可漂移之外没有带来质量收益：相对门控未被启用、heat 权重必须为 0 才不退步、`run_all` 每次只增加延迟
- **分数地板自动标定（2026-10-31）**：内置标定表已删除，所有模型都走自动标定。启动后台任务采样热/冷层各 100 条记忆，用自身开头 20 字当查询，取「命中自己」的语义分**中位数**作为地板，写入 `<数据目录>/retrieval_thresholds.json`。实测 jinazh768：hot 0.616（原人工表 0.62）、cold 0.569（原人工表 0.55），耗时 23 秒；同一批 25 条 known-item 上 hit@1 0.80、hit@5 0.96，与原手工覆盖值（hot 0.55）持平。取 5% 分位会低约 0.2（hot 0.321），放行大量无关记录。标定完成前用 `PROVISIONAL_FLOORS` 临时值，不阻塞调用；`POST /api/retrieval/calibrate` 可手动触发（`{"write": false}` 只试算）
  - 笔记层的 `notes_semantic` 按冷层地板 × 0.65 推导（两个模型的实测比值 0.64–0.71）；`notes_coverage` 是词项占比而非相似度，固定 0.50
- **检索分阶段下探**：`recall` 两层——`memory`（hot + cold 同层并行、按分数竞争）→ `notes`（`only_if_empty`）。`Stage` 只有 `name` / `arms` / `only_if_empty` 三个字段，**没有任何数字阈值**：数量下限就是调用方传入的 `limit`，质量下限是各臂自己的 `min_score`（`floors_for(tag)` 自动标定）
  - **hot/cold 不能拆成两层**：实测拆开后 hot 几乎总能凑满 limit（21 次查询里 hot 命中 21 次、cold 仅 1 次），而 cold 里躺着 0.764 的精确记忆，hot 用 0.56 的次要记忆把它挡住了。两者打同一个嵌入、分数同尺度，必须同层竞争
  - 教训：分层门槛曾设计成 `min_count` / `min_score` 常量，那是拿本机数据拟合出来的个人参数，换模型或换库就失效；能自动推断的只有两样——调用方的 `limit` 和自动标定的地板
- **关键词参数回归（2026-10-31 二次修订）**：`recall` 的 `keywords`（字符串数组，**必填**）成为主查询，`query` 改为**可选**的语义化描述；两者都传时双跑 + RRF 融合，只传 keywords 则单跑。推翻同日「关键词已移除」的结论，依据是新的 146 条真实样本对比：关键词 0.336 > 语义化描述 0.267 > 用户原话 0.199，双跑 RRF 0.377 高于关键词单跑 0.356
  - 两次结论冲突的原因：上一次把关键词当作「用户原话之外的第二次检索」，短标识符单独做向量查询召回极差；这一次关键词由模型从用户原话构造，本身就承担了改写职责
  - 未变的教训：schema 文案必须与实际行为一致（文案写 “each is searched separately” 会让模型过度传参）；`Stage` 若允许自带 `subqueries`/`fusion`/`scope`，就必须保证融合能读到过滤后的结果
- **交叉编码器重排（2026-11-09 起 recall 默认启用）**：`Pipeline(reranker=...)` 是可选钩子，`rerank.py` 的 `get_reranker()` 懒加载 `bge-reranker-base-int8`（`RERANK_MODEL_DIR` 可覆盖，缺模型返回 `None` 即不重排，60 秒后重试，不阻断检索）。`project_notes` 与 `recall` 均启用，`RECALL_RERANK=0` 可关闭。100 条 known-item 隔离评测（生产 embedder jinazh768）：hit@1 0.90→0.97、mrr 0.932→0.975、返回条数 393→305、字符/查询 1621.5→1238.7、p95 458→2552 ms；首次 ONNX 加载约 600 ms，recall 的构建与运行统一放在 `asyncio.to_thread`
  - 重排后**丢弃非正分**：交叉编码器输出的是相关性 logit，负分即「不是这条查询的段落」，留着只烧 token
- **笔记向量缓存带模型身份（2026-10-31）**：`note_vectors.sqlite` 的 `chunks` 表配 `meta` 表存 `embedder_tag` / `embedder_dims`。但**判定以向量 blob 长度为准**，不信 meta——换模型后旧向量不会失效（`_ensure_note_cache` 只重嵌 mtime/size 变了的文件），混维矩阵会让 `np.array` 直接抛错。实测三项目全中：agent-gateway 405 条 384 维 + 3133 条 768 维、utility 2287 + 476、generate-app 全 384 维，向量检索全部静默降级成关键词。发现混维即整表作废重嵌
  - 向量阶段失败现在记 `logger.error` 并写明「本次查询降级为关键词」，不再是容易被忽略的 warning
- **MCP 层文案统一英文，重复的收敛为常量**：这一层（工具返回、HTTP 端点、`logger.*`）面向**模型与开发者**，不与 `GATEWAY_LANG` 联动——面向终端用户的文案在 Swift 侧由 `L10n` 覆盖。盘点时发现 `'Hot layer not initialized'` 硬编码了 **6 处**，`set_memory_processed` 的 3 条参数校验在 MCP handler 与 HTTP 端点**各写一份**且是中文（与其余英文错误混着）——现收敛为 `ERR_*` 常量与 `err_bit_out_of_range()` 共用。判定口径：**重复出现的文案必须走常量**（单处出现的抽常量没有收益，重复的才有漂移风险；同一状态在两条入口提示不同，调用方无从归纳怎么改参数）
### 记忆生命周期（2026-10-23）

- `status` 是生命周期的唯一来源：`active` / `superseded` / `deleted`，缺省视为 `active`；`disputed` 仍只表达事实矛盾，不复用为生命周期
- 覆盖必须「add 成功后再 update 旧条 metadata」，禁止先 delete；**禁止原地 update 记忆正文**（若将来必须原地更新，`processed` 置 0 且 `revision+1`，否则摘要流程会跳过演进后的内容）
- `processed`：bit0=已摘要、bit1=已作废；覆盖时只置 bit1 并保留 bit0，消费方用 `processed & (bit0|bit1)` 跳过
- 写入前对 active 热层做判重：≥0.97 幂等返回已有 id；0.90–0.97 正常落库并在返回里给出 `similar`
- `recall` / `catch_up` / `/api/memories/recent` 默认过滤非 active，`include_superseded` 才返回历史版本；`/api/memories/status` 是手工纠错入口
- 冷层摘要 payload 写 `source_memory_ids`；覆盖时对应点标 `stale`，检索默认过滤
- 超期清理：`superseded`/`deleted` 30 天，`active` 180 天

- 依赖清单唯一来源是 gateway 仓 `pyproject.toml` 的 extras（`proxy`/`memory`/`server`），不再有 `requirements.txt`

## 宿主侧接入补充（2026-11-03 从 AGENTS.md 迁入）

- server.py 只保留入口 / HTTP endpoints / 项目与网页工具；记忆子系统在 `server_memory.py`，工具 schema 在 `server_tool_schema.py`，归档在 `server_archive.py`，技能扫描在 `server_skills.py`，共享常量/状态/工具在 `server_constants.py` / `server_state.py` / `server_utils.py`。`hot_memory` / `qdrant` 一律经 `server_state` 存取，禁止再引入模块级全局
- `token_proxy.handle_proxy` 只做编排：`_prepare_request` → `_apply_rewrites` → `_forward`，共享字段放在 `_ProxyState`
- 常驻进程（server.py / token_proxy.py）生命周期统一由 `PythonDaemon` 守护（启动/崩溃重启/健康检查/停止），`MCPProcessManager` / `TokenProxyManager` 负责业务决策（State 语义、EventBus 广播、复用探测、通知）
- 一次性执行走 `PythonScriptRunner.runCaptureOutput`（边读边存避免 pipe buffer 阻塞 + 超时 kill）
- server.py 所有配置从环境变量读取（`PythonScriptRunner.baseEnvironment()` 提供公共 AI/路径配置，脚本专属变量经 `environment(overrides:)` 注入——如 MCP_PORT/QDRANT_PATH/FASTEMBED_CACHE_PATH），实时构建，不解析 sys.argv；`QDRANT_PATH` 必须由 Swift 注入，Python 侧不再提供个人路径默认值
- 端口仅通过 `MCP_PORT` 环境变量传递（config mcp.port → env）
- `MEMORY_SERVER_URL` 从配置 mcp.port 动态计算，确保总结流水线连对端口

## 摘要流水线（Python 侧）

- summarize.py 作为内部任务注册到 TaskScheduler，以 `.sh(cmd)` 方式执行，所有 env 通过内联命令传入
- summarize.py 防重复触发：单实例文件锁 + 距上次完整总结 < 6h 跳过；mcp-summary 注册时 enabled 直接 register（不先 unregister，避免清 last_fire 后 handleMissed 每天重复补触发）
- summarize.py 输入侧质量门（方案 E v5，细节见 notes 分类文章/工具使用/总结流水线审计与质量门方案.md §五）：规则层零 LLM 过滤低质记忆（截断占位/半词/过短等）+ LLM 3 票复核（3 全 drop 才 drop + fail-open），丢弃不标记 processed 保留下轮重评估
- summarize.py 输出侧主题归属过滤（2026-08-18，根治「正文偶然命中导致错位归并」）：`_file_topic_feature`（文件主题特征=相对路径+所有 H1 标题+首段）+ `_hit_topic_relevant`（组关键词 ≥1 命中主题特征才算相关，正文命中不算）→ `_decide_merge` 前过滤 hits，无主题相关候选判定新建；fallback_merge 用过滤后 hits；检索加权 `title_matched`（路径+首段命中优先）+ `_gen_new` 复用目录优先 + `_sanitize_new_dir` 共享主题词回退
- summarize.py 输出侧 merge 去重三层防线（2026-08-07 修复，真实跑 11 处重复段根因）：
  1. **上下文**：`SUMMARY_MERGE_LOOKBACK_CHARS=8000` + `_relevant_segments`（按 facts 与段体 difflib ratio 排序取 top 段，兜底文件头）——防大文件前 2K 截断看不到文件尾既有段，LLM 无从判断重复
  2. **机械兜底**：`_max_segment_similarity` 多级标题 `#{1,6}` 切段 + **覆盖率指标**（SequenceMatcher matched/len(new_content)），`SUMMARY_DUP_SIM_THRESHOLD=0.7` 超值判无增量跳过（0.8 ratio→0.7 覆盖率，实测 ScanTextUtil 重复 0.767）
  3. **LLM 语义判定**：`_gen_merge` prompt 第 8 条 no_increment——改写式重复（措辞不同但信息已被既有段覆盖）拦截
  - 契约：`_gen_merge` 正常返回 `{title,content,supersedes}` **不带 action**，仅 no_increment 带 `{"action":"no_increment","reason":...}`——防 `results.append({..., **item})` 中 action 覆盖局部变量污染 fallback_merge
  - 纯 ratio 阈值不可分：真重复（0.55-0.75）与正常段（README 模板 0.7-1.0）区间重叠 → 覆盖率 + LLM 语义双判定
