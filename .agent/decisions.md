# 决策记录

## 2026-10-29 终端后端只保留 tmux

**背景**：screen 4.00.03 缺少 bracketed paste、真彩与鼠标 copy-mode，为其维护了日志 tap、
0700 目录、`-X` 竞态处理与附着看门狗等补丁。

**决策**：删除 `ScreenBackend` / `LocalBackend` / `TerminalNotificationTap`，只保留 `TmuxBackend`；
tmux 未安装时窗口内提示 + 一次系统通知，不降级。

**理由**：补丁数量已超过底座本身的价值；tmux 原生覆盖滚轮、多行粘贴、真彩与 OSC 转发。

**影响**：`terminal.backend` 配置项删除；`terminal-sessions.json` 的 `backend` 字段保留并固定写 `tmux`。

## 2026-10-29 抽象随实现数量收缩

**决策**：删除 `TerminalBackend` 协议、`TerminalBackendKind` 枚举与 `TerminalBackends` 工厂，
`TmuxBackend` 成为唯一具体类型；`TerminalSession` 不再持有 backend。

**理由**：单实现抽象没有注入点，测试也无法替换，属于负债。

## 2026-10-29 验证证据分级

**决策**：采用 TST-07 三级证据（存在性 / 行为 / 端到端），汇报必须标注级别。

**理由**：当天曾把 `swift build` 通过、`strings` 命中与日志关键字当作「验证通过」，
但 UI 行为从未实测，导致用户承担了全部测试成本。

## 2026-10-29 基座补齐

**决策**：为 utility 生成 `.agent/` 基座，`quality.test_level = basic`。

**理由**：此前只有 `.claude/`，没有 lessons/status/environment 可沉淀，验证能力也无处声明。

## 2026-10-29 MCP 工具面收敛

**决策**：移除 `project_dependencies` / `project_exports` / `summarize` 三个 MCP 工具；`summarize` 只保留 REST；项目扫描完成后 best-effort 调用 `/api/project/notes/prewarm` 预热文档向量。

**理由**：前两者低频且可被 `project_search` / 读取替代；`summarize` 模型可直答，宿主业务仍走 REST；`project_notes` 首查冷启动曾达 58.5s，需要扫描后预热。

## 2026-10-29 project_notes 缓存陈旧与短段落丢失

**问题**：增量缓存只增不删，项目迁移后旧绝对路径残留 133 个文件、2728/5332 个分块（51%）；`_chunk_md_text` 逐段丢弃 <50 字段落，规则清单类文档 0 分块且每次重扫。

**决策**：扫描后删除不在当前扫描集合或不在项目根内的缓存行；连续短段落累积到阈值再成块，块索引统一重排。

**验证**：unittest 189 通过；真实缓存预热后 5332→2630 分块、173 文件、0 越界路径，`.agent/rules/engineering.md` 可被检索命中。
