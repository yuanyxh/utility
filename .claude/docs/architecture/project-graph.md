# 项目依赖图（graph.sqlite）

`utility -a` 触发 gateway 在项目根写 `.agent-gateway/graph.sqlite`，MCP 工具 `project_lookup` / `project_impact` 读它。
两个工具与 `project_notes` 一样必传项目根 `path`，图库由 `<path>/.agent-gateway/graph.sqlite` 派生；旧项目的 `.utility/graph.sqlite` 只读回退并在首次写入时复制到新路径。
旧 `.utility/deps.sqlite` 扫描链已于 2026-11-02 移除，图库是唯一的项目索引。

## 组件

| 层 | 位置 | 职责 |
|---|---|---|
| 宿主 | `Sources/Scanner/Graph/` | 常驻进程生命周期、文件事件、启动对账触发 |
| 服务 | agent-gateway `services/graph/indexer.py` | JSON-Lines 协议；解析、绑定、写库 |
| 扫描 | `services/graph/project_scan.py` | walk、include/exclude、stat/hash 对账、全量重建 |
| 存储 | `services/graph/store.py` | 唯一 schema 所有者；原子替换、增量写、stale 回收 |
| 刷新 | `services/graph/refresh.py` | 查询触发 30 秒后台重建；每项目一个任务 |
| 查询 | `services/mcp/graph_tools.py` | 只读 SQLite，返回 provenance |

## 数据流

1. 宿主 watcher 只发文件事件；`GraphScanner` 不再收集文件或写库。
2. 启动时 `GraphScanner.syncScan()` 发 `sync`；gateway 自己 walk、按 `size + mtime + hash` 判断变化。
3. 有任何变化或版本不一致时，gateway 全量解析并单事务 `replaceGraph`；无变化直接返回 stats。
4. 增量：watcher 调 `indexFile`，gateway 读文件、校验 hash、解析并 `replaceFile`；`force=false` 且 hash 未变时返回 `unchanged`。
5. 删除走 `remove_file`，语义为**路径子树**，目录删除会清掉其下全部文件并把入边标 stale。

## 查询触发刷新（2026-11-04）

索引器启动时把 PID、进程启动时间和项目根写入 `<root>/.agent-gateway/indexer.json`；索引器正常退出时从列表移除自己，崩溃留下的条目由下一次查询用 `ps` 状态和启动时间清理。

`project_lookup` / `project_impact` 先读登记表。有活索引器直接返回当前结果；没有则安排一个 30 秒后执行的后台任务。任务再查一次登记表，拿不到 `<root>/.agent-gateway/refresh.lock` 就说明另一个 gateway 进程正在刷新，直接结束；拿到锁后调用 `project_scan.sync()`。`sync` 自己判断图库版本、根目录、文件增删和 `size + mtime`，没有变化时立即返回。

查询不等待扫描：第一次仍是旧结果，下一次查询才是新结果。刷新与索引器启动的短窗口不加跨进程图库写锁，依靠 SQLite 写事务串行和下一次扫描纠正。

## 检索层接入（2026-11-02）

`project_lookup` 走 `Pipeline("project_lookup")`：单臂 `ProjectLookupArm` + `MaxScoreFusion` + `PassThroughGate`。

- 打分是**位次分** `1/(rank+1)`（`score_kind="rank"`），不引入拟合权重；图查询本身已按精确/路径优先级排序
- `kind` / `file_path` 固定在 arm 构造器，不走 filters
- 空 query overview、目录缺失、图库缺失在 handler 短路，保持原响应
- 响应条目仍是 `name/kind/file/startLine/endLine/callerCount/topCallers/resolver`；`trace_id` 前缀由 `gl_` 变为 Pipeline 的 `rt_`
- `project_impact` 仍是确定性图遍历，不接 Pipeline

## 不变量

- **符号 key 含行号**：`sym_key = sha1(path|name|kind|signature|start_line)`。`replace_file` 必须按 `(name,kind,signature)` 把旧 key 的入边重绑到新 key，否则编辑任意上方一行就让该符号的 impact 永久失效。
- **写入前按 key 去重**：压缩 JS（如 `marked.umd.js`）会重复产出同 `sym_key` 的符号，`replace_graph` / `replace_file` 必须先 `unique_symbols()`，否则全量 `sync` 触发 `UNIQUE constraint failed: symbols.sym_key`。
- **stale 可恢复**：删除文件时同时把 `file:<path>` 入边标 stale；重建同路径文件时复活这些入边。
- **stale 回收**：`sync` 前后各执行一次 `delete_dangling_stale_edges()`，删除目标符号/文件已不存在的 stale 边；仍存在的目标保持可恢复。
- **引擎版本一致**：`services/graph/constants.py` 的 `ENGINE_VERSION` / `SCHEMA_VERSION` 是唯一源，导出到 `contracts/graph.json`；Swift `GraphProtocol` 由 `check-graph-contract.py` 校验。
- **扩展名唯一源**：python `services/graph/constants.py` 是扩展名/语言族唯一表；Swift 侧对应 `GraphProtocol.languagesByExtension`，只用于 watcher 事件过滤，并由契约脚本断言一致。
- **解析器独立降级**：`parsers/__init__.py` 逐语言 try-import，缺一个 grammar 只禁用该语言，ping 仍可用。
- **常驻进程单线程**：stdin 请求串行处理；DB 写与解析在同一线程。
- **退出**：`Darwin.exit` 跳过 defer，`AgentRunner` 必须显式 `watcher.stop()` → `graph.stop()`；PID 由 `onProcessChange` 回填供信号处理使用。索引器 `main()` 的 `finally` 把自己从 `indexer.json` 移除。

## 验证

```bash
# agent-gateway
PYTHONPATH=src .venv/bin/python -m unittest discover -s tests -t .
.venv/bin/ruff check src/agent_gateway/services/graph tests/graph
PYTHONPATH=src .venv/bin/python -m agent_gateway.cli.minod graph index --root /tmp/demo --json
# utility
swift build
python3 scripts/check-gateway-entries.py --entries Sources/Gateway/entries.json
python3 scripts/check-graph-contract.py --contract Sources/Gateway/graph.json
bash scripts/e2e-isolated.sh   # 临时 HOME：首建 + watcher 增量 + lookup/impact
```
