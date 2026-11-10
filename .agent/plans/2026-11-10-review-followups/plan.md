# 2026-11-10 审查操作项执行计划

## 目标

把 `notes/Review/2026-11-10/` 的 P3 代码项落到两个仓的工作区，补齐上期计划的未勾检查点。不打包、不提交、不推送；基座初始化只做 `tms-app` 与 `yjzt-wms-app`。

## 范围与约束

- 用户已排除：重新打包安装 1.2.7（`/Applications` 覆盖动作）。
- 用户已限定：基座只处理 `tms-app`、`yjzt-wms-app`。
- 硬规则：禁止提交；代码内注释、日志、测试名用英文；不改检索排序阈值（`retrieval-no-fitted-thresholds`）。
- 生产数据写入（RSS 472 条回填、记忆维度回填）只产出脚本与预览，实际执行需再次授权。
- MCP server 重启需单独授权，计划内只记录为待执行。

## 现状证据

| 项 | 事实 | 位置 |
|---|---|---|
| P2-1 | 工作区已实现软过滤回填，52 测试通过，未提交 | `agent-gateway` 7 个文件 |
| 11-09 计划 | T1-T10 全部勾选，检查点 A/B/C 未勾 | `.agent/plans/2026-11-09-review-followups/` |
| P3-1 | docstring 仍写 `reads only, never applies` | `group_governance.py:1` |
| P3-4 | `entries.json` 有 6 项，`Constants.swift` 只有 5 项 | `Constants.swift:89-95` |
| P3-3 | Yams `Double.represented()` 固定用 `.scientific` 格式 | `Yams/Representer.swift:178-182` |
| P3-9 | `sync` 只比较文件 size/mtime，不比较 git HEAD | `project_scan.py:253-267` |
| P3-10 | 日报 `Article` 无日期字段，未知日期无处标注 | `RSSDigestRender.swift:5-10` |

## 任务索引

完整可勾选清单与验收见 `tasks.md`，分四批：

| 批次 | 内容 | 任务 |
|---|---|---|
| A 代码确定性改动 | 文档、契约、治理补偿、配置浮点、图库 HEAD、日报标注 | T1-T6 |
| B 观测与策略 | 补货基线、recall 阶段计时、trace 关联、mimo 核实 | T7-T10 |
| C 数据与运维 | RSS 回填脚本、retention 确认、pip-audit、冷层复核 | T11-T14 |
| D 基座与验证 | 两个项目基座、上期检查点、构建与测试 | T15-T18 |

## 关键设计

### T2 治理补偿

`_apply_decisions` 当前先逐条 `_sync_mem0`，循环结束才 `batch_update_metadata`。本地写失败时 mem0 已改且无补偿。

改为：`queue()` 成功时把原 `episode_id` / `episode_prev` / `episode_source` / `governance_run` 记入 `compensation` 字典；`batch_update_metadata` 抛异常时遍历该字典调用 `_sync_mem0` 写回原值，补偿失败单独计数并 `logger.error`。不改变正常路径顺序。

### T4 配置浮点

Yams 对 `Double` 固定输出科学计数法（`3e-1`、`1.2e+2`），PyYAML 会把 `3e-1` 当字符串。在 `ConfigManager.apply` 编码后、写盘前对纯标量行做十进制转换：只匹配 `^\s*[^:#]+:\s*[-+]?\d+(?:\.\d+)?[eE][-+]?\d+\s*$`，用 `NumberFormatter(.decimal, 15 位有效数字)` 重写。注释、字符串、列表行不动。解析失败保持原行。

### T5 图库 HEAD

`sync` 在 meta 写入 `git_head`；重建前比较 meta 的 `git_head` 与当前 `git rev-parse HEAD`。两者不同即视为需重建，即使文件 mtime 未变。HEAD 读取失败（非 git 目录、git 不可用）返回空串，退回现有 mtime 判断，不阻断索引。

### T6 日报未知日期

`RSSDigestRender.Article` 增加 `dateKnown: Bool = true`；`RSSDigestService` 构建 Article 时从 `RSSItem.dateKnown` 透传。渲染时未知日期条目标题后追加 ` (date unknown)`，并在文章列表末尾不加任何全局说明，避免影响已有归档的解析。`parseArticles` 忽略该后缀，保证同日重跑幂等。

### T9 trace 关联

只做 retrieval 工具返回结构统一：`recall`、`project_lookup`、`project_notes`、`websearch_engine`、`read_url` 的返回 payload 若缺 `trace_id`，从当前 trace 上下文补空值；不改采纳分析脚本。范围超出时拆到下一计划。

### T10 mimo

只核实上游是否声明 prompt cache，不改变路由。核实结论写回报告目录，不改代码。

## 不做项

| 项 | 原因 | 谁定的 |
|---|---|---|
| 重新打包安装 1.2.8 | 用户明确不现在打包 | 用户 |
| 基座初始化其余 8 个项目 | 用户限定只做活跃 2 个 | 用户 |
| 修改检索权重或阈值 | 项目硬规则禁止拟合阈值 | 项目规则 |
| 提交、推送 | 未获授权 | 硬规则 |
| RSS 472 条回填 | 用户明确不处理，只记录为遗留 | 用户 |
| 生产数据回填直接执行 | 写生产库需再次授权 | 本计划约束 |

## 风险与回滚

| 风险 | 触发 | 回滚 |
|---|---|---|
| 配置后处理误伤字符串 | 配置出现形如 `3e-1` 的字符串值 | 还原 `ConfigManager.apply` 的调用点，保留原编码输出 |
| 图库 HEAD 判断导致全量重建 | meta 无 `git_head` 时误判 | 首次比较把缺失值视为「未知」，只写入不触发重建 |
| 日报标题后缀污染归档解析 | 旧归档被重新解析 | `parseArticles` 剥离后缀；后缀只加在标题文本，不进 URL |
| 治理补偿写回失败 | mem0 不可用 | 记录错误日志，不回滚本地，返回 `errors` 计数 |

## 验证

```bash
cd /Users/yuanyxh/Documents/selfdata/projects/agent-gateway
.venv/bin/python -m pytest tests/ -q
cd /Users/yuanyxh/Documents/selfdata/projects/utility
swift build
swift test
python3 scripts/check-gateway-entries.py
```

验收以 tasks.md 每项的「验收」列与上述命令退出码为准。
