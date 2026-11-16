# 2026-11-16 审查后续行动任务清单

两仓路径：utility 为 `/Users/yuanyxh/Documents/selfdata/projects/utility`，gateway 为 `/Users/yuanyxh/Documents/selfdata/projects/agent-gateway`。验证命令默认在 gateway 仓根执行时写 `cd gateway`，在 utility 仓根执行时省略。

## 批次 A：gateway 运行时与索引

- [ ] T1 热层初始化退避与锁诊断（依赖：无，规模：S）

**文件**

- 修改：`src/agent_gateway/services/mcp/server_memory.py:206-230`（`_init_hot_memory`）
- 修改：`src/agent_gateway/services/mcp/server_memory.py:236-261`（`ensure_hot_memory`）
- 修改：`src/agent_gateway/services/mcp/constants.py`（`HOT_INIT_RETRY_DELAY` 改为退避基数常量）
- 测试：`tests/test_memory_write.py` 或新增 `tests/test_hot_init_backoff.py`

**接口**

- 产出：`_init_hot_memory() -> bool` 不变；新增 `_hot_retry_delay(attempt: int) -> float`
- 消费：`HOT_INIT_MAX_RETRIES`（3）、`HOT_INIT_RUNTIME_COOLDOWN`

**验收**

- [ ] 退避序列为 0.5 / 1 / 2 s，总等待 3.5 s，不超过 30 s 上限
- [ ] 初始化失败日志包含 `MEM0_CONFIG["vector_store"]["config"]["path"]`（`server_memory.py:179`）与实际异常文本
- [ ] 连续失败达到 `HOT_INIT_MAX_RUNTIME_FAILURES` 时仍保留现有 `sys.exit(1)` 行为

**验证**

- 命令：`cd gateway && PYTHONPATH=src .venv/bin/python -m pytest tests/test_memory_write.py -q`
- 期望：全部通过；新增用例断言 `_hot_retry_delay` 返回值序列

- [ ] 步骤 1：写测试 `test_hot_retry_delay_sequence`，断言 `(0.5, 1.0, 2.0)`
- [ ] 步骤 2：运行验证命令，确认新测试失败
- [ ] 步骤 3：实现 `_hot_retry_delay` 并把 `time.sleep(HOT_INIT_RETRY_DELAY)` 替换为退避值
- [ ] 步骤 4：失败日志追加 `qdrant_path`
- [ ] 步骤 5：运行验证命令，确认通过
- [ ] 步骤 6：`git add` 后等检查点 A 统一提交

- [ ] T2 图索引 external 分类（依赖：T1，规模：M）

**文件**

- 修改：`src/agent_gateway/services/graph/resolver.py:375`（`_unresolved`）、`:405-585`（`resolve_file`）
- 修改：`src/agent_gateway/services/graph/constants.py`（补 Python 内置与 Foundation 类型集合）
- 修改：`src/agent_gateway/services/graph/store.py:39-43`（`unresolved` 表注释与统计口径）
- 测试：`tests/graph/test_resolver.py`

**接口**

- 产出：`_external_reason(reference: Reference, analysis: FileAnalysis) -> str | None`
- 消费：`Reference.raw_name`、`Reference.receiver`、`Reference.kind`、`FileAnalysis.lang`

**验收**

- [ ] `reason='external'` 覆盖「接收者未知的方法调用」与语言内置类型，不覆盖同文件内可绑定符号
- [ ] 统计口径改为 `reason NOT IN ('external')` 计算未解析率，`unresolved` 表仍保留 external 行
- [ ] `project_lookup ConfigManager`、`project_lookup armFileWatch` 仍返回原位置

**验证**

- 命令：`cd gateway && PYTHONPATH=src .venv/bin/python -m pytest tests/graph/test_resolver.py -q`
- 期望：通过；新增用例构造 `foo.append()` 断言 `external`，构造同文件调用断言 `no_binding`

- [ ] 步骤 1：写 `test_external_method_call` 与 `test_local_call_stays_no_binding`，确认失败
- [ ] 步骤 2：实现 `_external_reason`，只在 `resolve_file:495` 与 `:567` 的 `no_binding` 分支前调用
- [ ] 步骤 3：重建两仓图库，统计 `select reason, count(*) from unresolved group by reason`
- [ ] 步骤 4：运行 `project_lookup` 复核命中
- [ ] 步骤 5：记录迁移前后未解析率到检查点 A

- [ ] T3 记忆边类型 v4 schema 与写入改造（依赖：T2，规模：M）

**文件**

- 修改：`src/agent_gateway/services/memory/store.py:26`（`SCHEMA_VERSION = 4`）
- 修改：`src/agent_gateway/services/memory/store.py:44-57`（`memory_edges` 建表加 `predicate`）
- 修改：`src/agent_gateway/services/memory/store.py:261-285`（`V3_COLUMNS` 加 `memory_edges.predicate`）
- 修改：`src/agent_gateway/services/memory/entities.py:153-201`（`merge_fact` 写 `type='fact'`）
- 修改：`src/agent_gateway/services/memory/entities.py:204-219`（`current_facts` 读 `predicate`）
- 修改：`src/agent_gateway/services/memory/graph.py:19-31`（`EDGE_TYPES` 增 `fact`）
- 测试：`tests/test_memory_graph.py`、`tests/test_memory_brain_schema.py`

**接口**

- 产出：`merge_fact(connection, fact, evidence_memory_id, *, now=None) -> str` 签名不变，写入语义变为 `(type='fact', predicate=fact["predicate"])`
- 产出：`current_facts(connection, subject) -> list[dict]` 返回键 `predicate` 取自新列
- 消费：`graph.add_edges` 只接受 `EDGE_TYPES`，事实边统一走 `entities.merge_fact`

**验收**

- [ ] 新旧库建表都含 `predicate` 列，`user_version` 升到 4
- [ ] `merge_fact` 写入 `type='fact'` 且 `predicate` 保留原谓词
- [ ] `current_facts` 返回的 `predicate` 取自新列

**验证**

- 命令：`cd gateway && PYTHONPATH=src .venv/bin/python -m pytest tests/test_memory_graph.py tests/test_memory_brain_schema.py -q`
- 期望：通过；新增用例断言 `type='fact'` 与 `predicate` 列

- [ ] 步骤 1：写 `test_merge_fact_uses_predicate_column`，断言 `type='fact'` 且 `predicate` 原文
- [ ] 步骤 2：运行测试确认失败
- [ ] 步骤 3：改 schema、`V3_COLUMNS`、`merge_fact`、`current_facts`、`EDGE_TYPES`
- [ ] 步骤 4：运行测试，确认通过

- [ ] T3b v4 迁移、重复清理与 importance 回填（依赖：T3，规模：M）

**文件**

- 新建：`scripts/memory_edges_v4.py`
- 产出：`~/.config/utility/memory_graph.pre-v4-<ts>.sqlite`
- 测试：`tests/test_memory_graph.py`

**接口**

- 产出：`memory_edges_v4.py --dry-run|--apply [--db <path>]`，退出码 0 表示成功
- 消费：`store.SCHEMA_VERSION`、`entities.current_facts`

**验收**

- [ ] 迁移后 `select count(distinct type) from memory_edges` ≤ 8
- [ ] 48,492 条事实边的 `predicate` 等于迁移前 `type`，结构边 53,297 条不变
- [ ] 清理 3 组重复 `content_hash`，回填 5,816 条缺失 `importance=5`

**验证**

- 命令：`cd gateway && PYTHONPATH=src .venv/bin/python scripts/memory_edges_v4.py --dry-run`
- 期望：输出 `facts=48492 structural=53297`，不写库

- [ ] 步骤 1：写脚本：`VACUUM INTO` → 新表 → 复制 → 改名 → `PRAGMA user_version=4`
- [ ] 步骤 2：副本上跑 `--apply`，比对行数与 `quick_check`
- [ ] 步骤 3：清理重复 `content_hash` 与回填 `importance`
- [ ] 步骤 4：记录迁移前后统计到检查点 A

- [ ] T4 进度上报 future 异常处理（依赖：无，规模：XS）

**文件**

- 修改：`src/agent_gateway/services/mcp/server.py:624-632`

**接口**

- 产出：`on_progress` 内部持有 `concurrent.futures.Future`，`add_done_callback` 中 `future.exception()` 吞掉异常

**验收**

- [ ] `ctx.report_progress` 抛异常时不再出现 `Task exception was never retrieved`
- [ ] `websearch_engine` 正常返回不受影响

**验证**

- 命令：`cd gateway && PYTHONPATH=src .venv/bin/python -m pytest tests/test_web_layers.py -q`
- 期望：通过

- [ ] 步骤 1：把 `run_coroutine_threadsafe(...)` 返回值存入变量并加回调
- [ ] 步骤 2：运行验证命令

## 批次 B：utility 修复

- [ ] T5 编辑器删除重建监听重试（依赖：无，规模：S）

**文件**

- 修改：`Sources/Workspace/FileEditorPane.swift:363-382`（`armFileWatch`）、`:395-400`（`restartFileWatch`）
- 测试：`Tests/UtilityTests/FileEditorWatchTests.swift`

**接口**

- 产出：`armFileWatch(_ url: URL, attempt: Int = 0) -> Bool`，失败时调度 0.5 s 后重试，最多 3 次

**验收**

- [ ] 删除后 1 s 内重建同路径文件，监听恢复且编辑器自动刷新
- [ ] 重试 3 次仍失败时停止并写 debug 日志，不无限重试
- [ ] 原子替换（临时文件 rename）路径行为不变

**验证**

- 命令：`swift build && bash scripts/run-tests.sh`
- 期望：构建通过；`FileEditorWatchTests` 新增用例通过

- [ ] 步骤 1：写 `testWatchRecoversAfterDeleteAndRecreate`，确认失败
- [ ] 步骤 2：改 `armFileWatch` 返回 Bool，失败时 `DispatchQueue.main.asyncAfter(0.5)` 重试
- [ ] 步骤 3：`restartFileWatch` 记录 `attempt` 并传回
- [ ] 步骤 4：运行验证命令，确认通过

- [ ] T6 配置写入备份与 `config --migrate`（依赖：T5，规模：M）

**文件**

- 修改：`Sources/Core/ConfigManager.swift:123-142`（`apply(rawText:)` 与 `save()`）
- 新建：`Sources/CLI/ConfigCommand.swift`
- 修改：`Sources/CLI/UtilityCLI.swift:13-20`（注册子命令）
- 修改：`Sources/Resources/en.json`、`Sources/Resources/zh-Hans.json`
- 生成：`Sources/Resources/L10nKeys.swift`（禁止手改）
- 测试：`Tests/UtilityTests/ConfigDefaultsTests.swift`

**接口**

- 产出：`ConfigManager.backupExisting() throws`，三处写入路径调用
- 产出：`utility config --migrate [--dry-run]`，退出码 0 表示成功、1 表示校验失败
- 消费：`Bundle.module` 的 `default-config.yaml`；`Self.decimalized`

**验收**

- [ ] `save()`、`apply(_:)`、`apply(rawText:)` 写前都生成 `config.yaml.bak`
- [ ] `--dry-run` 输出缺失键 18 个、浮点 2 处，不写文件
- [ ] 实跑后 `pollInterval=0.3`、`httpTimeout=30`、缺失键 0

**验证**

- 命令：`swift build && .build/debug/utility config --migrate --dry-run`
- 命令：`python3 scripts/gen-l10n.py --check && python3 scripts/check-l10n-contract.py`
- 期望：输出 `missing=18`、`clipboard.pollInterval 3e-1 -> 0.3`、`general.httpTimeout 3e+1 -> 30`；l10n 双检查通过

- [ ] 步骤 1：写 `testSaveCreatesBackup` 与 `testMigrateDryRunReportsMissing`
- [ ] 步骤 2：抽出 `backupExisting()`，三处写入路径复用
- [ ] 步骤 3：新增 `ConfigCommand`：读用户配置 → 合并默认键 → `decimalized` → 校验 → 备份 → 原子写
- [ ] 步骤 4：注册子命令，运行验证命令

- [ ] T7 `graph --sync` 增量索引入口（依赖：T6，规模：S）

**文件**

- 新建：`Sources/CLI/GraphCommand.swift`
- 修改：`Sources/CLI/UtilityCLI.swift:13-20`（注册）
- 修改：`Sources/Resources/en.json`、`Sources/Resources/zh-Hans.json`
- 生成：`Sources/Resources/L10nKeys.swift`
- 测试：`scripts/e2e-isolated.sh`（增加未提交文件断言）

**接口**

- 产出：`utility graph --sync [--dir <path>]`，调用 `GraphScanner(projectPath:).syncScan()`
- 消费：`GraphScanner.init(projectPath:languages:maxRestarts:)`

**验收**

- [ ] 对 utility 仓执行后，工作区未提交文件符号进入图库
- [ ] `project_lookup FileTreeScanner` 命中 `Sources/Workspace/FileTreeModel.swift` 相关符号
- [ ] 非 git 目录不报错，按目录扫描

**验证**

- 命令：`swift build && .build/debug/utility graph --sync --dir /Users/yuanyxh/Documents/selfdata/projects/utility`
- 命令：`python3 scripts/gen-l10n.py --check && python3 scripts/check-l10n-contract.py`
- 期望：退出码 0，输出 `files`、`symbols`、`elapsedMs`；l10n 双检查通过

- [ ] 步骤 1：新增 `GraphCommand`（`--dir` 默认当前目录，`--sync` 必选）
- [ ] 步骤 2：注册子命令并构建
- [ ] 步骤 3：运行命令，统计图库 `files` 是否包含工作区文件
- [ ] 步骤 4：跑 `project_lookup` 复核

## 批次 C：提交、打包与配置迁移

- [ ] T8 两仓按主题提交工作区改动（依赖：T5-T7，规模：M）

**文件**

- utility：`Sources/Workspace/{FileDocument,FileEditorPane,FileExplorerPane,FileTreeModel}.swift`、`Tests/UtilityTests/{FileEditorWatch,FileTreeScanner}Tests.swift`、`.claude/docs/architecture/workspace.md`
- utility：`VERSION`、`.agent/{status,lessons}.md`
- gateway：`src/agent_gateway/prompts/{en,zh-Hans}/knowledge_card.md`、`tests/test_knowledge_engine.py`

**交互**

- 消费：无
- 产出：两仓干净工作区，utility HEAD 含 `1.2.15`

**验收**

- [ ] utility 至少 3 个提交：workspace 软链与监听、版本 1.2.15、agent 文档
- [ ] gateway 1 个提交：knowledge_card 提示词与测试
- [ ] 提交前逐项复核 `git status`，无 `-a`，无未暂存混入

**验证**

- 命令：`git status --short && git log --oneline -5`
- 期望：两仓输出为空；utility 最新提交信息含 `1.2.15`

- [ ] 步骤 1：`git add` workspace 4 个 Swift 与 2 个测试、workspace.md，检查 `git diff --cached` 后提交
- [ ] 步骤 2：`git add VERSION` 提交版本
- [ ] 步骤 3：`git add .agent/status.md .agent/lessons.md` 提交文档
- [ ] 步骤 4：gateway 暂存 3 个文件并提交
- [ ] 步骤 5：检查 `default-config.yaml`、`README.md`、`AGENTS.md` 是否需要同步

- [ ] T9 重新打包并校验资源（依赖：T8，规模：S）

**文件**

- 修改：无
- 产出：`dist/Utility-1.2.15.dmg`

**验收**

- [ ] `Info.plist` 版本 `1.2.15`，二进制含本期新符号
- [ ] 资源 bundle 大小与提交前一致，无缺失
- [ ] `scripts/check-gateway-entries.py` 输出 6/6

**验证**

- 命令：`SIGNING_IDENTITY=<证书> ./scripts/package-utility.sh`
- 期望：退出码 0；DMG 卷根为 `Utility.app` 与 `Applications` 软链

- [ ] 步骤 1：运行打包脚本
- [ ] 步骤 2：挂载 DMG 校验版本、bundle、二进制符号
- [ ] 步骤 3：记录产物路径到检查点 C

- [ ] T10 执行配置迁移（依赖：T6、T8，规模：XS）

**文件**

- 修改：`~/.config/utility/config.yaml`
- 产出：`~/.config/utility/config.yaml.bak`

**验收**

- [ ] 用户配置键 145 / 缺失 0
- [ ] `clipboard.pollInterval=0.3`、`general.httpTimeout=30`
- [ ] `.bak` 存在且内容为迁移前版本

**验证**

- 命令：`.build/debug/utility config --migrate`
- 期望：退出码 0，输出 `missing=0`、`backup=config.yaml.bak`

- [ ] 步骤 1：实跑 `--migrate`
- [ ] 步骤 2：用 YAML 解析复核键数与浮点
- [ ] 步骤 3：确认 app 重启后配置加载正常

## 批次 D：数据清理与文档

- [ ] T11 旧 Qdrant 与记忆快照移废纸篓（依赖：T10，规模：XS）

**文件**

- 移动：`~/.config/utility/data/qdrant` → `~/.Trash/utility-qdrant-20261116`
- 移动：`~/.config/utility/memory_graph.pre-v3-20261111-2216.sqlite*` → `~/.Trash/`
- 移动：`~/.config/utility/memory_graph.sqlite.bak-20261108225909` → `~/.Trash/`

**验收**

- [ ] `mcp.qdrantPath` 指向 `~/Documents/selfdata/database/qdrant_data`
- [ ] 迁移后 MCP `/health` 返回 `ok`
- [ ] 配置目录体积从 1.3 GB 下降

**验证**

- 命令：`du -sh ~/.config/utility && curl -s http://127.0.0.1:9001/health`
- 期望：体积下降；`{"status":"ok"}`

- [ ] 步骤 1：确认配置路径与最近迁移成功
- [ ] 步骤 2：`mkdir -p ~/.Trash` 后 `mv` 三个目标
- [ ] 步骤 3：重启 MCP 并检查 health

- [ ] T12 两仓 `.agent/status.md` 更新（依赖：T8，规模：XS）

**文件**

- 修改：`/Users/yuanyxh/Documents/selfdata/projects/utility/.agent/status.md`（当前目标改为 1.2.15 与本期计划）
- 修改：`/Users/yuanyxh/Documents/selfdata/projects/agent-gateway/.agent/status.md`（当前目标与进行中补 v3）

**验收**

- [ ] utility 当前目标不再写 1.2.7
- [ ] gateway 进行中列表包含 v3 与本期计划

**验证**

- 命令：`head -12 /Users/yuanyxh/Documents/selfdata/projects/{utility,agent-gateway}/.agent/status.md`
- 期望：两仓目标段落与当前版本一致

- [ ] T13 8 个零调用工具评估（依赖：无，规模：S）

**文件**

- 产出：`.agent/plans/2026-11-16-review-followups/tool-review.md`
- 只读：`src/agent_gateway/services/mcp/server_tool_schema.py:385-500`、`server_tools.py:437-570`

**验收**

- [ ] 8 个工具各给「保留 / 下线 / 观察」结论与证据
- [ ] `memory_expand` 写明观察截止 2026-12-09
- [ ] 下线动作不在本任务执行，等用户单独批准

**验证**

- 命令：`grep -n "name=\"catch_up\\|name=\"forget\\|name=\"memory_expand\\|name=\"set_memory_processed" gateway/src/agent_gateway/services/mcp/server_tool_schema.py`
- 期望：输出对应行号，评估表逐项对应

- [ ] 步骤 1：读 8 个工具的 schema 与 handler
- [ ] 步骤 2：对照 06 域调用统计写结论
- [ ] 步骤 3：落盘 `tool-review.md`

- [ ] T14 上期 T17 合并项（依赖：无，规模：XS）

**文件**

- 只读：`agent-gateway/tests/__init__.py:20-31`、`agent-gateway/scripts/episode_sandbox.py`
- 产出：`.agent/plans/2026-11-16-review-followups/t17-merge.md`

**验收**

- [ ] 给出 pytest 入口已隔离 `GATEWAY_CACHE` 的位置与结论
- [ ] 给出 `episode_sandbox.py` 是否直接写缓存的结论与位置
- [ ] 若确认服务端日志是唯一来源，写明「不改造」依据

**验证**

- 命令：`sed -n '20,31p' gateway/tests/__init__.py && grep -n "GATEWAY_CACHE" gateway/scripts/episode_sandbox.py`
- 期望：前者显示 `tempfile.mkdtemp`；后者无输出

- [ ] 步骤 1：核对 pytest 入口隔离
- [ ] 步骤 2：核对脚本入口
- [ ] 步骤 3：落盘结论，关闭上期 T17

## 检查点

### 检查点 A（T1-T4 后）

- [ ] `cd gateway && PYTHONPATH=src .venv/bin/python -m pytest tests/ -q` 全过
- [ ] `cd gateway && .venv/bin/ruff check src tests` 通过
- [ ] `memory_edges` distinct type ≤ 8，备份 `quick_check=ok`
- [ ] 两仓图库重建后 `external` 分类生效，`project_lookup ConfigManager` 仍命中

### 检查点 B（T5-T7 后）

- [ ] `swift build` 通过
- [ ] `bash scripts/run-tests.sh` 全过
- [ ] `utility config --migrate --dry-run` 输出 18 缺键与 2 处浮点
- [ ] `utility graph --sync` 后工作区符号进图库

### 检查点 C（T8-T10 后）

- [ ] 两仓 `git status` 干净
- [ ] DMG 版本与二进制一致
- [ ] `config.yaml` 缺键 0、浮点十进制、`.bak` 存在

### 检查点 D（T11-T14 后）

- [ ] 配置目录体积下降，MCP `/health` 为 `ok`
- [ ] 两仓状态文档已更新
- [ ] `tool-review.md` 与 `t17-merge.md` 已落盘
