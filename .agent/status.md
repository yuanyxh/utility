# 项目状态

## 当前目标

1.1.42 基线整理：RSS 解析与去重、配置键对齐、基座按 agent-vibe 1.4.0 对齐。

## 进行中

- 无

## 最近完成（2026-11-03）

- RSS：解析失败返回 nil 并记录 feed/原始串；落库统一 `RSSItem.unknownDate`；迁移 v3 清理 17 组重复链接
- 配置：用户 `config.yaml` 与 `default-config.yaml` 键集合对齐（121/121），删除 `project_search.limit`、`terminal.backend`
- 基座：`seed_version: 1.4.0`、`.githooks/{pre-commit,commit-msg}`、backlog/upgrades/plans 模板、`memory/INDEX.md`、4 条 `.claude/rules` 补 `paths:`、`AGENTS.md` 收缩到 116 行
- 清理：7 个 `.DS_Store` 与 0 B `deps.sqlite` 已移废纸篓

## 最近完成（2026-11-04）

- 解耦：项目图库改由 gateway 写入 `.agent-gateway/graph.sqlite`，Swift 删除 `GraphDatabase`，`GraphScanner` 只发 `sync` 与文件事件
- 配置：`GatewayConfigWriter` 生成 `agent-gateway.yaml`；env 改为 `GATEWAY_*`，旧 `UTILITY_*` 保留一个发布周期；`skillDedupEnabled` → `toolOutputDedup`
- 新增 `scripts/e2e-isolated.sh`：临时 HOME 跑真实 `utility -a`，断言首建 4 符号 / 2 边、watcher 增量到 6 符号、lookup / impact 命中

## 验证（2026-11-04）

- `swift build` 通过；`bash scripts/run-tests.sh` 全过；`bash scripts/e2e-isolated.sh` 连续两次通过
- 1.1.45 部署验证：wheel 安装、MCP/代理健康、`agent-gateway.yaml` 生成、查询链路均正常；全量 `sync` 因压缩 JS 重复 `sym_key` 失败
- 1.1.46 部署复验：wheel 含去重修复，含 `marked.umd.js` 的项目全量 sync 成功（248 符号/47 边）；MCP 查询正常；旧 `utility -a claude` 会话（4760/4766）仍待退出
- 重启新会话后：旧 4760/4766 已退出，新 `utility -a claude --resume`（18693）拉起索引器 18700，环境无 `PYTHONPATH`（wheel 模式）；图库 4546 符号，watcher 已产生 `index_file`，服务健康
- 本机遗留迁移：`config.yaml` 的 `skillDedupEnabled` 改为 `toolOutputDedup`；`deps.sqlite` 移入废纸篓；agent-gateway（210 文件/2970 符号）与 agent-vibe（空图）完成图库迁移；agent-gateway / yuanyxh.github.io / generate-app 的 note 缓存已复制，旧 `.utility` 全部保留
- 审查修复：`GatewayConfigWriter` 保留 `search` 段（隔离 HOME 验证 `parallel=true` 不丢）；gateway 侧修 WAL 迁移、扫描链合并、idle env、契约；两仓 526 例 + run-tests + e2e 全过
- 1.1.47 部署复验：生成配置含 `search.parallel=true` 与 idle=600；含 `build/` 的临时项目全量 sync 只收 2 文件；旧会话 18693/18700 仍在跑旧索引器（日志可见扫描 `Utility.app/`），重启会话后由新 SKIP_DIRS 排除
- 13:53 重启复验：新会话 30624 + 索引器 30631（wheel 模式），旧进程已退出；图库 118 文件/4547 符号；新 `ping` 之后无 `Utility.app/` 或 `build/` 索引记录
- 证据级别：L3（真实二进制 + 隔离 HOME，含 watcher 增量）；GUI 面板未验证

## 阻塞

- 无

## 验证（2026-11-03）

- `swift build` 通过；`bash scripts/run-tests.sh` 全过；`verify-instantiation.sh` 0 errors / 0 warnings
- 已部署 `/Applications/Utility.app` 1.1.42，二进制含新日志串
- 迁移 v3 已执行：`rss_item` 4795→4778，重复链接组 0
- `rss --fetch` 实测：新增 32 条；31 条 `GitHub Trending Weekly` 无日期条目按预期记日志并使用哨兵；重复组仍为 0
- 证据级别：L2（真实库迁移 + 抓取日志断言）；配置热重载与日报渲染待下次定时任务验证（L3 待验）
