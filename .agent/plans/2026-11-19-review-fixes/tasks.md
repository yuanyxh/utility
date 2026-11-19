# 2026-11-19 审查修复任务清单

- [x] T1 记忆 project 归属取证与修复（代码与 dry-run 完成；`--apply` 待用户批准）
- [x] T2 冷层 importance 透传（依赖：T1，规模：S）
- [x] T3 强化路径时区统一（依赖：无，规模：S）
- [x] T4 测试日志隔离与采集器指纹（依赖：无，规模：S）
- [x] T5 dangling activation 清理与产生源拦截（存量 7 条待 daily 清理）
- [x] T6 read_url 失败写入 trace（依赖：无，规模：S）
- [x] T7 graph.log 统一 JSONL（依赖：无，规模：S）
- [x] T8 Qdrant 脏数据清理（依赖：无，规模：XS）
- [x] T9 零调用工具评估清单（依赖：无，规模：S）

## 检查点 A（T3-T4）

- [x] 全量 unittest 865 项通过，`ruff check` 通过
- [x] 跑测试后生产日志新增 `__boom__` 为 0

## 检查点 B（T1-T2）

- [x] 备份后执行回填：792 条，缺失率 86.6% → 76.3%；备份见 11:09:10
- [x] 新写入 project 推断单测通过；冷层 importance 透传单测通过

## 检查点 C（T5-T8）

- [x] 孤儿 activation 计数 0（清理 7 条；生产 recall 后仍为 0）
- [x] read_url 失败 trace 有 `error`
- [x] graph.log 100% 行含 `ts`
- [x] Qdrant 脏数据移入废纸篓，health 仍 ok

## 检查点 D（T9）

- [x] 零调用工具清单逐项有用途、替代与建议（实际注册与 06 报告的差异已注明）

## T1 记忆 project 归属

**文件**

- 修改：`agent-gateway/src/agent_gateway/services/mcp/server_memory.py`（写入路径取 project）
- 新建：`agent-gateway/scripts/backfill_project.py`（只补空值，默认 dry-run）
- 测试：`agent-gateway/tests/test_memory_project.py`

**接口**

- 产出：`infer_project(source_files: list[str]) -> str`，从路径首段匹配已知项目名；无法判断返回空串。
- 产出：`python scripts/backfill_project.py --dry-run|--apply --db <path>`。

**验收**

- [ ] 新写入记忆在显式 project 为空时，能从 source_files 推断出 project 或保持空。
- [ ] `--apply` 前强制生成 `VACUUM INTO` 备份，只更新空 project。
- [ ] 抽检 50 条回填结果，错误归属 ≤2 条。

**验证**

```bash
cd agent-gateway && pytest tests/test_memory_project.py -q
python scripts/backfill_project.py --dry-run --db ~/.config/utility/memory_graph.sqlite
```

**依赖 / 规模**：无 / M

- [ ] 步骤 1：写失败测试，断言 source_files 可推断与不可推断两类。
- [ ] 步骤 2：实现 `infer_project` 并接入写入路径。
- [ ] 步骤 3：实现 dry-run 报告与 `--apply` 备份。
- [ ] 步骤 4：副本演练并抽检 50 条。
- [ ] 步骤 5：用户二次批准后执行 `--apply`，复测缺失率。

## T2 冷层 importance 透传

**文件**

- 修改：`agent-gateway/src/agent_gateway/services/mcp/server_memory.py:796`（`record_cold_memory` 调用点）
- 修改：`agent-gateway/src/agent_gateway/services/mcp/server_tool_schema.py`（如缺参数则补）
- 测试：`agent-gateway/tests/test_memory_graph.py`

**接口**

- 消费：`_int_arg(arguments, "importance", 5)` 与 `record_cold_memory(..., importance=?)`。

**验收**

- [ ] 调用方传 importance 时冷层节点非 5；未传时仍为 5。
- [ ] 新增测试断言冷层 metadata 含传入值。

**验证**

```bash
cd agent-gateway && pytest tests/test_memory_graph.py -q
```

**依赖 / 规模**：T1 / S

- [ ] 步骤 1：写失败测试，断言冷层 importance 等于入参。
- [ ] 步骤 2：在调用点取值并透传。
- [ ] 步骤 3：跑测试确认通过。

## T3 强化路径时区统一

**文件**

- 修改：`agent-gateway/src/agent_gateway/services/memory/strength.py:92-135`（`reinforce_memory`）
- 修改：`agent-gateway/src/agent_gateway/services/memory/forgetting.py`（`days_between` 兼容 naive/aware）
- 测试：`agent-gateway/tests/test_associative_recall.py`

**接口**

- 产出：`days_between(a, b)` 接受 naive 或 aware，内部统一为 UTC aware。

**验收**

- [ ] 库中 `last_activated_at` 为 aware ISO 时不再抛异常。
- [ ] 旧 naive 值仍能计算，结果与修复前一致。

**验证**

```bash
cd agent-gateway && pytest tests/test_associative_recall.py tests/test_forgetting.py -q
```

**依赖 / 规模**：无 / S

- [ ] 步骤 1：写测试，插入 aware `last_activated_at` 断言不抛。
- [ ] 步骤 2：`datetime.now(timezone.utc)` 并统一解析。
- [ ] 步骤 3：跑测试确认通过。

## T4 测试日志隔离与采集器指纹

**文件**

- 新建/修改：`agent-gateway/tests/conftest.py`（import 前设置 `GATEWAY_CACHE` 到临时目录）
- 修改：`notes/MCP/Skills/projects_review/scripts/collect_metrics.py`（`test_suspected` 指纹）
- 测试：现有 `tests/test_mcp_server_wiring.py`

**验收**

- [ ] 跑 `test_mcp_server_wiring.py` 后生产日志新增 `__boom__` 为 0。
- [ ] 采集器对 `__boom__`/`Mock` 样本识别率 ≥90%。

**验证**

```bash
cd agent-gateway && pytest tests/test_mcp_server_wiring.py -q
~/.config/utility/mcp-venv/bin/python notes/.../collect_metrics.py --days 6 --output /tmp/pr_t4
```

**依赖 / 规模**：无 / S

- [ ] 步骤 1：conftest 在收集阶段设置临时 cache 根。
- [ ] 步骤 2：扩展采集器指纹并加自测。
- [ ] 步骤 3：重跑测试与采集器，对比生产日志增量。

## T5 dangling activation 清理

**文件**

- 修改：`agent-gateway/src/agent_gateway/services/memory/network_build.py:146`（孤儿清理接入周期路径）
- 测试：`agent-gateway/tests/test_memory_network.py`

**验收**

- [ ] `SELECT COUNT(*) FROM memory_activation a LEFT JOIN memory_nodes n ON ... WHERE n.node_id IS NULL` 为 0。
- [ ] 清理不删除有节点的 activation。

**验证**

```bash
cd agent-gateway && pytest tests/test_memory_network.py -q
```

**依赖 / 规模**：无 / S

- [ ] 步骤 1：查清现有 NOT IN 清理为何未覆盖 5 条。
- [ ] 步骤 2：接入周期任务并补测试。
- [ ] 步骤 3：执行一次清理，复测计数。

## T6 read_url 失败写入 trace

**文件**

- 修改：`agent-gateway/src/agent_gateway/services/read/read_service.py`（返回 error_code 已有）
- 修改：`agent-gateway/src/agent_gateway/services/mcp/server_rest.py` 或 `server_tools.py`（trace payload 映射）

**验收**

- [ ] 构造失败 URL，trace 的 `error` 字段为具体 error_code，不再为 null。
- [ ] 成功路径 trace 结构不变。

**验证**

```bash
cd agent-gateway && pytest tests/test_read_service.py -q
```

**依赖 / 规模**：无 / S

- [ ] 步骤 1：定位 trace 记录点并写失败测试。
- [ ] 步骤 2：映射 `error_code` 到 `error`。
- [ ] 步骤 3：跑测试与一次真实失败请求。

## T7 graph.log 统一 JSONL

**文件**

- 修改：`agent-gateway/src/agent_gateway/services/graph/indexer.py`（`partial parse` 日志）

**验收**

- [ ] 新写入行 100% 含 `ts` 字段。
- [ ] 解析失败信息保留文件名与原因。

**验证**

```bash
cd agent-gateway && pytest tests/graph -q
tail -20 utility/.agent-gateway/graph.log
```

**依赖 / 规模**：无 / S

## T8 Qdrant 脏数据清理

**文件**

- 不涉及源码；移动目标：`qdrant_data/.DS_Store`、`mem0/storage.sqlite`（0 字节）。

**验收**

- [ ] 文件移入废纸篓，未直接删除。
- [ ] MCP `/health` 仍为 ok。

**验证**

```bash
curl -s http://127.0.0.1:9001/health
```

**依赖 / 规模**：无 / XS

## T9 零调用工具评估清单

**文件**

- 新建：`.agent/plans/2026-11-19-review-fixes/zero-call-tools.md`

**验收**

- [ ] 13 个工具逐项列出用途、替代工具、使用建议。
- [ ] 不修改工具注册与契约。

**验证**

```bash
grep -c "^|" .agent/plans/2026-11-19-review-fixes/zero-call-tools.md
```

**依赖 / 规模**：无 / S
