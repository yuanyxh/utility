# 研究与资产盘点

查询时间：2026-10-29（本机命令与仓库事实，未做网络检索）

## 版本基线

| 依赖 | 声明 | 来源 | 采纳理由 |
| --- | --- | --- | --- |
| SwiftPM tools | 5.9 | `Package.swift:1` | 既有事实，不改动 |
| macOS 部署目标 | 14.0 | `Package.swift:6` | 既有事实 |
| Yams | from 5.1.0 | `Package.swift:8` | 配置 YAML 解析 |
| GRDB.swift | from 7.0.0 | `Package.swift:9` | SQLite 本地存储 |
| swift-argument-parser | from 1.5.0 | `Package.swift:10` | CLI 子命令 |
| SwiftTerm | from 1.99.1 | `Package.swift:11` | 终端视图 |
| tmux | 3.8 | `tmux -V` | 终端后端唯一依赖 |
| Swift | 6.4 | `swift --version` | 本机工具链 |

## 实践清单

| 实践 | 采纳 | 映射 |
| --- | --- | --- |
| 构建门 `swift build` | 采纳 | `verify.build`，CI 缺失时的唯一编译门 |
| 本地验证 `scripts/run-tests.sh` | 采纳 | `verify.test`（examples parity、i18n 契约、gateway entries） |
| 打包 `scripts/package-utility.sh` | 采纳 | `verify.run`，产物装到 `/Applications` |
| 格式化 | 采纳 | `xcrun swift-format`（Xcode 27 内置），配置见 `.swift-format` |
| 静态检查 | 拒绝 | swiftlint 未安装，`swift-format lint` 作为最低门 |
| 远程 CI | 拒绝 | 仓库无 workflow；本地验证替代 |
| 证据分级（TST-07） | 采纳 | 写入 `.agent/rules/testing.md` 与 `lessons.md` |

## Agent 资产盘点

| 资产 | 位置 | 结论 |
| --- | --- | --- |
| 启动契约 | `CLAUDE.md` | 已存在且内容完整，**不覆盖**；仅追加基座索引 |
| 项目规则 | `.claude/rules/*.md`（code-language、internal-task-registration、no-personal-path-fallbacks、verification-before-completion） | 采纳，保留原样；与种子 testing/engineering 规则互补 |
| 技能 | 无 | 本次生成 `build` / `hunt` / `review` / `learn` / `upgrade` |
| 记忆 | 外部 mino-brain MCP | 采纳为辅助；`.agent/` 文件保证无 MCP 时可恢复 |
| 待生长 | UI 自动化入口、格式化工具、CI | 上下文未定，登记不生成 |

## 与种子默认值的差异

| 项 | 种子默认 | 项目取值 | 理由 |
| --- | --- | --- | --- |
| `quality.test_level` | standard | basic | 无单测 target，以脚本化 SMOKE 为主 |
| `delivery.ci` | github-actions（按 repo_host） | none | 本机私有仓，无远程流水线 |
| `delivery.deploy_target` | 按 type 推荐 | none | 本地打包安装，不走上架/云端 |
| `quality.format/lint` | 按语言推荐 | none | 工具未安装，不生成不可执行的门 |
