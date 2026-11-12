# 记忆神经网（memory brain v3）

本文说明记忆神经网的存储、建边、检索与运维不变量，回答「哪些改动会破坏图、换模型后要重算什么」。
源码在 `agent-gateway` 仓（`services/memory/`），本仓只做宿主接入与打包。修改前读本文件与
> `agent-gateway/.agent/plans/2026-11-11-memory-brain/plan.md`。

## 数据流

原始记忆（`memory_nodes`，hot/cold 两层）→ episode 分组为神经元（`neurons`）→ 每日建边
（`synapses`）→ 检索时按 CSR 图扩散/吸引子 → 召回强化与夜间重放调整权重。

- 图存储：`memory_graph.sqlite`（v3 schema，`PRAGMA user_version=3`）。
- 关键表：`neurons`（质心、稀疏码、层级）、`synapses`（权重、kind、inferred）、
  `neuron_members`、`memory_nodes`、`entities`/`entity_mentions`、`memory_edges`（事实边）、
  `replay_runs`（重放审计）、`activation_buffer`。
- 图索引：`GraphIndex` 是内存 CSR，30 秒 TTL 重建；扩展开销亚毫秒级，禁止在检索路径回到 SQL。

## v3 建边

- 候选：每个神经元与其它神经元的向量近邻；分数仅用于排序，**写入权重用原始余弦**，
  门槛 `MIN_SYNAPSE_WEIGHT=0.62`；同分时用稀疏码 Jaccard 排序（`sparse_floor` 默认 0）。
- LLM 复核：每次构建最多复核 `memory.neuron.llmPairs` 对，**未复核候选不落库**；
  全量回填时曾用「高置信自动接受」临时策略，已按用户要求回滚，不得恢复为默认。
- 桥接：每个非主连通分量补 1 条 `kind='bridge'` 边（权重=最高余弦，绕过 0.62），
  已归档的桥在下次桥接时恢复为 active。
- 稀疏码：2048 维、k=64、带 `context_key`；同一模型空间内可比。

## 嵌入模型不变量（严重，已踩坑）

- `neurons.centroid` 是**派生物**，必须与生成它的 `EMBEDDER_MODEL` 同源同维。
  模型切换后不会自动重算，混维会让图按维度分裂（2026-11-12 生产事故：384/768 混算，
  孤立率 51.6%）。
- 换模型步骤：`scripts/memory_centroids.py`（先 `VACUUM INTO` 备份再写）→
  `memory_brain_backfill.py --sparse --force` → 重建边 → `memory_brain_eval.py` 复核。
- 建边入口发现混维会告警；批量向量查询失败会降级为逐条查询，不再整批丢候选。
- 冷层向量与热层质心只有在同一模型下才可比较；跨模型禁止直接算余弦。

## 检索与维护

- 扩散/吸引子走 `GraphIndex`，SQL 仅作回退；扩展需带预算（`memory_expand` 默认 500 节点）。
- 日常巩固：`consolidate.py` 在建边后做桥接；`llm_skipped` 时必须告警。
- 日重放：预算 40 次 LLM 调用/天、20 分钟；推断边 `inferred=1`、权重 0.35、14 天未采纳撤销。
- 实体/事实：`entities`/`entity_mentions`/`memory_edges`；事实写入按 evidence 幂等，
  同一 evidence 不重复计 support；`polarity`/`confidence` 存在边的 metadata。

## 运维脚本（agent-gateway 仓 `scripts/`）

| 脚本 | 用途 |
| --- | --- |
| `memory_brain_migrate.py` | v1→v3 迁移（幂等，自动备份） |
| `memory_brain_backfill.py` | 稀疏码 / 实体事实回填（`--sparse --force`、`--entities --batch/--concurrency`） |
| `memory_network_backfill.py` | 全量建边（`--pair-mode v3 --llm-pairs/--concurrency`） |
| `memory_network_rollback.py` | 从备份整库恢复（先 DELETE 再导入） |
| `memory_centroids.py` | 用现役嵌入模型重算质心（`VACUUM INTO` 备份，`--dry-run`） |
| `memory_brain_eval.py` | 拓扑评估（孤立率、分量、直径、检索延迟） |

跑脚本必须显式注入 `QDRANT_PATH`、`GATEWAY_HOME`、`EMBEDDER_MODEL`；否则会回退到
MiniLM 384，产生新的混维数据。

## 生产基线（2026-11-12）

4301 神经元、21682 活跃边、孤立率 4.77%、平均度 10.08、1 个连通分量、直径 15；
实体覆盖 99.6%；5 跳 expand 0.76 ms。历史 facts 的 support 计数含重跑膨胀，暂无消费方。

## 打包与契约

- 提示词：`agent-gateway/src/agent_gateway/prompts/` 是唯一事实源，`package-utility.sh`
  会先删后拷到 `Sources/Gateway/prompts/`；仓内副本必须与源一致（含 `entity_extract.md`、
  `replay_sequence.md`）。
- 契约：`Sources/Gateway/{env,entries,graph}.json` 由打包脚本从 gateway 仓导出，
  `scripts/check-gateway-entries.py` 校验入口一致。
- 配置：`mcp.neuron.*` 与 `mcp.brain.*` 都由宿主写入 `agent-gateway.yaml`；
  `brain` 键（`pairMode`/`sparseFloor`/`attractor`/`forgetting`/`buffer`/`replay`/`semantic`）
  默认即生产推荐值，改用户 `config.yaml` 的 `mcp.brain` 后重启生效。
