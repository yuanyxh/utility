# 2026-11-10 审查操作项任务清单

## 批次 A：代码确定性改动

- [x] T1 `group_governance.py:1` docstring 改为 `LLM review plus apply of memory episode groups`，并在 `_apply_decisions` 注明回滚入口（规模：XS）
  - 验收：docstring 与 `:579` 行为一致；无测试影响
- [x] T2 `_apply_decisions` 本地写失败补偿 mem0（规模：M）
  - 文件：`src/agent_gateway/services/memory/group_governance.py`
  - 验收：新增测试模拟 `batch_update_metadata` 抛异常，断言 `_sync_mem0` 收到原值；现有分组测试全过
- [x] T3 `Constants.swift` 补 `GatewayEntry.astExtractor`（规模：XS）
  - 验收：`scripts/check-gateway-entries.py` 输出 6/6
- [x] T4 `ConfigManager.apply` 科学计数法浮点转十进制（规模：S）
  - 验收：新增测试输入 `pollInterval: 3e-1`，输出 `0.3`；`1.2e+2` 输出 `120`；字符串与注释不变
- [x] T5 `project_scan.sync` 比较 git HEAD（规模：S）
  - 验收：新增测试在临时 git 仓库改提交后调用 `sync`，图库重建；非 git 目录不报错
- [x] T6 RSS 日报标注未知日期（规模：S）
  - 验收：`dateKnown=false` 的条目标题带 `(date unknown)`；同日重跑不重复追加；`swift test` 通过

## 批次 B：观测与策略

- [x] T7 补货日志补 `feature/topic/attempt/result` 计数（规模：S）
  - 验收：`knowledge_refill.log` 每次尝试有一行结构化结果；现有测试通过
- [x] T8 recall 增加 rerank 与两臂耗时字段（已存在：`latency["rerank"]` 与 trace `latency_ms`，本次验证）（规模：S，不改排序）
  - 验收：trace payload 出现分阶段耗时；排序结果与改动前一致
- [x] T9 检索类工具返回统一带 `trace_id`（websearch_engine/read_url 结果带 `url_id`，handler 写 returned/lead/latency 并返回 `trace_id`）
  - 验收：5 个工具返回 payload 均含 `trace_id`；契约测试通过
- [x] T10 核实 mimo prompt cache 支持（结论：上游支持缓存计费，Flash 命中 ¥0.02、未命中 ¥1；本地 8929 次命中为 0，属请求未触发缓存）
  - 验收：报告目录新增结论；不改路由代码

## 批次 C：数据与运维

- [ ] T11 写 RSS 未知日期回填脚本并 dry-run（用户决定不处理，仅记录为遗留）
  - 验收：脚本只读预览 472 条；实际写库需再次授权
- [x] T12 确认 usage retention 清理是否被调度（结论：仅 `init_db()` 启动时清理三个月数据，长驻进程不周期清理）
  - 验收：给出调度点 `file:line` 与最近执行记录；没有则列为缺口
- [x] T13 在独立开发 venv 安装 `pip-audit`（已在 `agent-gateway/.venv` 安装 2.10.1，扫描无已知漏洞）
  - 验收：`pip-audit --version` 可用；不写入 `~/.config/utility/mcp-venv`
- [x] T14 复核冷层 `source_memory_ids` 与 `search: 0.35` 消费方（结论：冷层有 `_cold_episode_id` 内部读取入口；`search` 键未被 `config_loader` 读取，消费方仍未定位）
  - 验收：两项各有「有消费方 / 无消费方」结论与位置

## 批次 D：基座与验证

- [x] T15 `tms-app` 初始化 `.agent` 基座到 1.5.0（检测结果 aligned，缺失 0、告警 0）
  - 验收：`check_agent_vibe.py` 该状态从 `unversioned` 变为 `aligned` 或 `aligned_with_warnings`
- [x] T16 `yjzt-wms-app` 压缩契约到 200 行内并清理 `{{`（CLAUDE.md 92 行、无占位符；检测 aligned）
  - 验收：`CLAUDE.md` ≤200 行；无 `{{`；内容迁入 `.agent/rules/` 或既有 `.claude/rules/`
- [ ] T17 补齐上期检查点 A/B/C 与 P3-8 评测隔离验证（本轮只验证：`episode_sandbox.py` 仍请求运行中服务，未设独立缓存）
  - 验收：三项检查点有实跑证据；`episode_sandbox.py` 写独立缓存目录
- [x] T18 跑构建、测试与契约脚本（646 gateway tests、13 Swift tests、entries 6/6 全过）
  - 验收：`swift build`、`swift test`、`pytest tests/`、`check-gateway-entries.py` 全部通过

## 检查点

- 检查点 A（T1-T6）：两仓测试通过，`swift build` 通过，配置输出无科学计数法
- 检查点 B（T7-T10）：trace payload 有分阶段耗时，工具返回含 `trace_id`
- 检查点 C（T11-T14）：数据脚本只 dry-run，运维结论有位置
- 检查点 D（T15-T18）：两个项目基座检测通过，构建与测试全绿
