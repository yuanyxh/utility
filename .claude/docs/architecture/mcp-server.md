# MCP 服务（server.py）

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
- `websearch_engine` 是内置工具（`web_search.py`），不再走 Skill 层：多引擎级联（Bing/搜狗/360/百度/Marginalia/Brave/DDG）、按查询语言选顺序、按引擎限流 + 连续失败冷却；可选抓取前 N 页并转 Markdown、按页与总量限长。旧 `websearch-fallback` skill 已移除，页面内容不再以 HTML 返回
- `_scan_skills` 递归 os.walk：目录含 SKILL.md（Waza 式目录 skill）→ 跳过 `_SKILL_SKIP_DIRS` 子目录且只注册 SKILL.md 本身；无 SKILL.md 的普通目录 → 其内所有 .md（含附属子目录）照常注册
- `_find_skill_dir` 按 normalize 后注册名定位 skill 目录；扁平 .md skill 不在目录注册表，定位失败返回 None → `"skill not found"`（设计使然非 bug）
- **检索同义词表 = 内置默认 + 用户增量**：`synonyms.py` 的 `SYNONYM_MAP` 是内置，`config.yaml` 的 `mcp.synonyms` 是用户增量（**同名覆盖、异名追加**，只写要加的、不必抄回整张表）。Swift `MCPProcessManager.synonymsJSON()` 把用户表序列化后按 `synonymsEnvKey`（`MCP_SYNONYMS`）注入，Python 侧 `load_synonyms()` 合并并缓存（env 在进程启动时固定，改配置要重启服务）。**该 env 不进 `config.py`**（脚本专属 env 的既有约定），故契约第 3 组的「Python 读了 Swift 必须注入」覆盖不到它——脚本单独交叉断言两侧常量同值（`find_synonym_env_violations`），否则改名后内置表照常工作、**用户配的同义词静默失效**（无任何报错）。**不迁入 notes**：检索质量不该成为可被静默改坏的变量，改坏了的表现是「搜不到」，与「这条记录本来就不存在」无法区分
- **工具参数默认值 = 内置默认 + 用户增量**（2026-10-10）：`tool_defaults.py` 的 `TOOL_ARG_DEFAULTS` 是内置，`config.yaml` 的 `mcp.toolDefaults` 是用户增量（**同名覆盖**，键结构 **tool name → args name → 值**）。Swift `MCPProcessManager.toolDefaultsJSON()` 序列化后按 `toolDefaultsEnvKey`（`MCP_TOOL_DEFAULTS`）注入，Python `load_defaults()` 合并缓存。**该 env 不进 `config.py`**，契约第 3 组同样覆盖不到——单独交叉断言（`find_tool_defaults_env_violations`）。默认值直接决定每次调用的**返回量即 token 消耗**，故做成配置面：`recall.limit=6`、`project_search.limit=15`、`project_structure.limit=15`、`websearch_engine.limit=5` / `fetch_top=1` / `max_chars=6000`
  - **schema 的 `default` 与 handler 兜底必须同源**：`DEFAULT_RECALL_LIMIT` / `DEFAULT_PROJECT_SEARCH_LIMIT` / `DEFAULT_PROJECT_STRUCTURE_LIMIT` 全部取自 `arg_default()`，两处各写一份字面量会漂移成「schema 声明 6、实际取 8」（recall 上次 10→8 踩过这个坑）
  - **`project_search` / `project_structure` 原先没有 limit 参数**：内部分别硬编码 `[:15]`/`[:10]`/全量 与 `MAX_ITEMS=200`，本次新增 `limit` 形参接入配置面。**`project_search` 的 exact 分支此前返回全量 `all_found`**（可达数百条），是输出膨胀的主因
  - **整数参数一律经 `_int_arg`**：客户端显式传 `null` 时 `arguments.get` 返回 None，直接切片 `all_found[:None]` 是**不截断**——静默把 token 治理关掉
- **MCP 层文案统一英文，重复的收敛为常量**：这一层（工具返回、HTTP 端点、`logger.*`）面向**模型与开发者**，不与 `UTILITY_LANG` 联动——面向终端用户的文案在 Swift 侧由 `L10n` 覆盖。盘点时发现 `'Hot layer not initialized'` 硬编码了 **6 处**，`set_memory_processed` 的 3 条参数校验在 MCP handler 与 HTTP 端点**各写一份**且是中文（与其余英文错误混着）——现收敛为 `ERR_*` 常量与 `err_bit_out_of_range()` 共用。判定口径：**重复出现的文案必须走常量**（单处出现的抽常量没有收益，重复的才有漂移风险；同一状态在两条入口提示不同，调用方无从归纳怎么改参数）
- `pyproject.toml` 未知，依赖见 `requirements.txt`
