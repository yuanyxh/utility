# 项目依赖图（graph.sqlite）

`utility -a` 在项目根写 `.utility/graph.sqlite`，MCP 工具 `project_lookup` / `project_impact` 读它。
两个工具与 `project_notes` 一样必传项目根 `path`，图库由 `<path>/.utility/graph.sqlite` 派生，不读环境变量，因此可查询任意已扫描项目。
旧 `.utility/deps.sqlite` 扫描链已于 2026-11-02 移除，图库是唯一的项目索引。

## 组件

| 层 | 位置 | 职责 |
|---|---|---|
| 宿主 | `Sources/Scanner/Graph/` | 收集文件、原子替换、增量写入、生命周期 |
| 服务 | agent-gateway `services/graph/indexer.py` | 常驻 JSON-Lines 进程，解析与名称绑定 |
| 解析 | `services/graph/parsers/` | tree-sitter：py/swift/ts/js/java/kotlin；Vue 拆 script+template；ObjC 正则兜底 |
| 绑定 | `services/graph/resolver.py` | local → import_scoped → module_scoped → global_unique |
| 查询 | `services/mcp/graph_tools.py` | 只读 SQLite，返回 provenance |

## 数据流

1. `GraphScanner.collectSourceFiles()` 按 `ScannerConfig` 的 includes/excludes 收集文件。
2. `GraphIndexerClient.prepare(paths:)` 把**宿主文件集**下发给常驻进程；python 不自行 walk。
3. 全量：分批 `index_batch`（每批 50），宿主单事务 `replaceGraph`。
4. 增量：watcher 调 `indexFile`，宿主 `replaceFile`；删除请求仍走 `remove_file`，语义为**路径子树**，目录删除会清掉其下全部文件。
5. 启动对账 `syncScan`：先按 `size + mtime` 快速跳过未变文件；仅 stat 变化的文件读到 hash 后只刷新元数据；真正变化的文件分批 `index_batch`，统一建名称索引后再逐个 `replaceFile`。

## 检索层接入（2026-11-02）

`project_lookup` 走 `Pipeline("project_lookup")`：单臂 `ProjectLookupArm` + `MaxScoreFusion` + `PassThroughGate`。

- 打分是**位次分** `1/(rank+1)`（`score_kind="rank"`），不引入拟合权重；图查询本身已按精确/路径优先级排序
- `kind` / `file_path` 固定在 arm 构造器，不走 filters
- 空 query overview、目录缺失、图库缺失在 handler 短路，保持原响应
- 响应条目仍是 `name/kind/file/startLine/endLine/callerCount/topCallers/resolver`；`trace_id` 前缀由 `gl_` 变为 Pipeline 的 `rt_`
- `project_impact` 仍是确定性图遍历，不接 Pipeline

## 不变量

- **符号 key 含行号**：`sym_key = sha1(path|name|kind|signature|start_line)`。`replaceFile` 必须按 `(name,kind,signature)` 把旧 key 的入边重绑到新 key，否则编辑任意上方一行就让该符号的 impact 永久失效。
- **stale 可恢复**：删除文件时同时把 `file:<path>` 入边标 stale；`syncScan` 回填 unresolved 只解决新增符号。
- **stale 回收**：`syncScan` 前后各执行一次 `deleteDanglingStaleEdges()`，删除目标符号/文件已不存在的 stale 边；仍存在的目标保持可恢复。
- **增量失败可观测**：`indexFile` / `removeFile` 与批量解析失败写 `diagnostics.last_incremental_error`、`last_incremental_error_at`；全量不可读文件进 `failed_files`。
- **引擎版本一致**：Swift `GraphProtocol.engineVersion` 与 python `indexer.ENGINE_VERSION` 必须相等；`isUpToDate()` 通过 `ping` 校验，不一致强制全量重建。
- **扩展名唯一源**：python `services/graph/constants.py` 是扩展名/语言族唯一表，`parsers`、`resolver`、`graph_tools` 均从它派生；Swift 侧对应 `GraphProtocol.languagesByExtension`。
- **解析器独立降级**：`parsers/__init__.py` 逐语言 try-import，缺一个 grammar 只禁用该语言，ping 仍可用。
- **常驻进程单线程**：stdin 请求串行处理；新增并发入口前必须给 `ProjectIndex` 加锁。
- **退出**：`Darwin.exit` 跳过 defer，`AgentRunner` 必须显式 `watcher.stop()` → `graph.stop()`；PID 由 `onProcessChange` 回填供信号处理使用。

## 验证

```bash
# agent-gateway
.venv/bin/python -m pytest tests/graph -q
.venv/bin/python -m ruff check src/agent_gateway/services/graph tests/graph
# utility
swift build
python3 scripts/check-gateway-entries.py
```
