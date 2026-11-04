# AGENTS.md — Utility Project

> 启动契约：只放常驻约束、加载策略与入口索引；实现细节在链接文档里，不在此复制。
> **必须基于事实而不是猜测**

## 项目概述

**utility** — macOS 菜单栏工具，Swift + AppKit + SPM，Python 子进程扩展。

- LSUIElement（无 Dock 图标），NSStatusItem 菜单栏入口
- NSPanel floating 面板：剪贴板、翻译、Stage 暂存、知识卡片、终端
- Carbon EventHotKey 全局快捷键
- GRDB 本地 SQLite 存储；Vision OCR 屏幕区域识别
- MCP 记忆服务：Mem0 + Qdrant 冷热双层，Python 侧在 `agent-gateway` 仓
- 项目索引：`GraphScanner` 写入 `.agent-gateway/graph.sqlite`

## 开始任何任务前

1. 读一次 `.agent/status.md` 的当前目标与阻塞；有链接计划时先读该计划。不要遍历 `.agent/`。
2. 按下方加载策略取用本次任务命中的内容，未命中的不读。
3. 技术选型、升级或引入依赖前，读 `.agent/research.md` 与 `.agent/upgrades.md`。
4. 修改某个模块前，先读「模块文档索引」里对应的架构文档。

## 常驻约束

<!-- core:start -->
1. **提交时机**：用户明确功能正常后才提交；只提交暂存区（`git commit` 不加 `-a`）。提交前检查 `default-config.yaml`、`README.md`、`AGENTS.md` 是否需同步；如需更新，改后等用户确认，不继续提交动作。
2. **授权边界**：提交、推送、发布、删除、产生费用或外发数据前必须取得明确授权；所有删除改为移动到废纸篓。
3. **事实优先**：代码、测试、日志与官方资料高于记忆和猜测；问题先排查事实，方案必须可验证。
4. **排查策略**：2-3 轮对话后仍无解，搜索网络资料；Bug 修复依赖现实调试信息，禁止靠猜测修改。
5. **拒绝猜测**：看不懂代码为何那样写时先查 `git log`；仍看不出来就问用户，不要假设。
6. **大改动审批**：代码改动过大时先询问，确认后再修改。
7. **文件操作**：一律绝对路径；一次读足所需范围；改前先 `git diff` 看现状；禁止整文件重读。
8. **注释**：只写必要信息，禁止无用、一次性、大段注释；超过 80 字即禁止写入。
9. **语言与时区**：对话与输出用中文，以上海时区为准；代码内非用户可感知文本用英文。
10. **设计原则**：最小暴露（private 优先）、视图与逻辑解耦、跨模块走 EventBus、核心逻辑可无头调用、复用优先于重复。
11. **用户修正优先**：记忆内容不得覆盖用户后续修正；冲突时立即停止并确认。
12. **阶段自检**：阶段完成不重复执行；阶段失败先排查原因再重试，禁止无排查直接重试。
<!-- core:end -->

## 加载策略

| 内容 | 触发 | 位置 |
| --- | --- | --- |
| 本契约与常驻约束 | 每次会话 | 平台自动加载 |
| 模块架构与实现细节 | 修改对应模块 | `.claude/docs/architecture/` |
| 领域关注点 | 涉及该领域 | `.agent/domains/` |
| 工程/测试/设计/协作规则 | 交付与审查 | `.agent/rules/` |
| 路径规则 | 触及相关文件 | `.claude/rules/` |
| 当前目标与阻塞 | 每次任务开始 | `.agent/status.md` |
| 任务计划 | 恢复当前任务 | `.agent/plans/` |
| 未排期工作 | 选择下一项任务 | `.agent/backlog.md` |
| 依赖升级 | 升级或发布 | `.agent/upgrades.md` |
| 历史依据与复盘 | 需要历史或教训 | `.agent/decisions.md`、`.agent/lessons.md` |
| 环境与验证入口 | 安装、构建失败 | `.agent/environment.md` |
| 技术选型结论 | 选型、升级、新依赖 | `.agent/research.md` |
| 跨会话结论 | 需要长期事实 | `.agent/memory/INDEX.md` |

## 模块文档索引

| 模块 | 文档 |
|---|---|
| 组件总览 / 并发 / 内存基线 | `.claude/docs/architecture/overview.md` |
| 面板 / EventBus / 热键 / Stage / OCR | `.claude/docs/architecture/panel-ui.md` |
| 多终端（tmux / SwiftTerm） | `.claude/docs/architecture/terminal.md` |
| 配置加载（Yams / decodeIfPresent） | `.claude/docs/architecture/config.md` |
| 构建、验证与 scripts 目录 | `.claude/docs/architecture/build.md` |
| Python 运行时 / 守护 / 日志 | `.claude/docs/architecture/python-runtime.md` |
| Python 层位置 / 模块入口 / wheel | `.claude/docs/architecture/python-layout.md` |
| Token Proxy | `.claude/docs/architecture/token-proxy.md` |
| LLM 调用与提示词 | `.claude/docs/architecture/llm-and-prompts.md` |
| 知识面板 | `.claude/docs/architecture/knowledge-panel.md` |
| MCP 服务 server.py | `.claude/docs/architecture/mcp-server.md` |
| RSS 采集 / 解析 / 日报 | `.claude/docs/architecture/rss.md` |
| 项目依赖图 graph.sqlite | `.claude/docs/architecture/project-graph.md` |
| 检索性能约定 | `.claude/docs/architecture/retrieval.md` |
| Orchestrate 设计沉淀 | `.claude/docs/architecture/design-notes.md` |

## 技能索引

| 技能 | 触发 |
| --- | --- |
| `build` | 实现需求、继续开发、修复小问题 |
| `review` | 审查变更、合并前检查 |
| `hunt` | 报错、崩溃、回归 |
| `learn` | 沉淀经验、复盘 |
| `upgrade` | 依赖与运行时升级 |

## 工作循环

计划 → 实现 → 自测 → 审查 → 对账 → 更新状态 → 发布 → 观察。多步骤任务写入 `.agent/plans/`，逐步更新证据；未排期工作写入 `.agent/backlog.md`。

## 提交规范

- 一个提交只做一件事；信息格式 `类型(范围): 摘要`，类型限定 feat / fix / refactor / test / docs / chore / perf / build。
- 提交、推送、合并与改写历史均需用户明确授权；未授权时只给建议与命令。
- 不提交生成物、依赖目录、本地配置、凭据与验证数据。

## 断点规则

只有四种情况暂停等待用户：不可逆操作、产生费用、涉及隐私或合规、目标之间冲突。其余按默认值推进并记入 `.agent/decisions.md`。

## 验证命令

| 用途 | 命令 |
| --- | --- |
| 构建 | `swift build` |
| 格式化 / 静态检查 | `xcrun swift-format lint --recursive --configuration .swift-format Sources` |
| 测试与契约 | `bash scripts/run-tests.sh` |
| i18n | `python3 scripts/gen-l10n.py --check` + `python3 scripts/check-l10n-contract.py` |
| 示例一致性 | `python3 scripts/check-examples-parity.py` |
| 入口契约 | `python3 scripts/check-gateway-entries.py --entries ../agent-gateway/contracts/entries.json` |
| 隔离 E2E | `bash scripts/e2e-isolated.sh`（临时 HOME，不碰真实配置与运行中实例） |
| 打包 | `SIGNING_IDENTITY=<sha1> bash scripts/package-utility.sh` |
| 基座校验 | `bash ../agent-vibe/scripts/verify-instantiation.sh .` |

完整命令与踩坑见 `.claude/docs/architecture/build.md`。Python 侧（unittest / 向量缓存 / web-search）在 `agent-gateway` 仓内验证，本仓已无 Python 源码。
