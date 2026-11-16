# lume VM 端到端验证报告

2026-11-16 在 `utility-env`（macOS，4 CPU / 8 GB，IP 192.168.64.14）验证本期 gateway 修复与 utility 打包 CLI。数据为宿主记忆库脱敏副本。

## 环境

| 项 | 值 |
|---|---|
| VM | `utility-env`，用户 `lume` |
| Python | `.config/utility/mcp-venv` 3.12.16 |
| 依赖 | tree-sitter、mem0 可用；pytest 缺失，改用 unittest |
| 网络 | Clash 代理未运行，仅回环可用 |

## 结果

| 验证项 | 结果 | 证据 |
|---|---|---|
| 全量单测 | 834 通过，1 失败 1 错误 | 两项均为 proxy 端口健康检查，宿主同测试全过，属 VM 网络限制 |
| 边类型迁移 | 通过 | `facts=48600 structural=53326`，迁移后 `distinct type=6`、`user_version=4` |
| importance 回填 | 通过 | 回填 5,816 条 |
| external 分类 | 通过 | external 9,090 / no_binding 2,688 / ambiguous 167 |
| 热层退避 | 通过 | 10:25:41.008 → 41.530 → 42.557，间隔 0.52 s / 1.03 s |
| 失败诊断 | 通过 | 日志含 `qdrant_path=/Users/lume/e2e/qdrant/mem0` |
| 工具清单 | 通过 | 15 个，`proj_init`/`proj_mem`/`skill_creator`/`token_analysis` 已消失 |
| 符号查询 | 通过 | `project_lookup merge_fact` 返回 `entities.py:153-202`，3 个调用方 |
| 配置迁移 CLI | 通过 | `missing=18` 与 8 处科学计数法行 |
| 图同步 CLI | 通过（修正后） | `--root` 生效，`files=281 symbols=4125` |

## 发现的问题

`utility graph --sync --dir` 与顶层 `--dir` 冲突，参数被吞，图库写到了 `$HOME/.agent-gateway`。改为 `--root` 后重新打包 1.2.17，VM 验证落点正确。

## 未覆盖

- 真实锁竞争未复现：第二实例正常初始化，失败原因只有缺 API key。锁竞争只在重启重叠期出现，退避由单测覆盖。
- Clash 代理未运行，未验证模型下载与 LLM 路径。
- 打包 app 的 GUI 行为未验证。

## 清理

VM 内删除 `~/gateway-v4`、`~/e2e`、脱敏库与 DMG；`$HOME/.agent-gateway` 误生成目录一并删除。VM 保留供后续复用。

## 审查修复复验（2026-11-16 12:32）

针对审查的 P1（迁移非原子）与 P2 复验：

| 验证项 | 结果 |
|---|---|
| 原子迁移 | 新脚本单事务 `RENAME` → 重建 → 复制 → `DROP`，失败回滚 |
| 自动备份 | `connect` 自动迁移前 `VACUUM INTO`，同一库只保留一份 |
| 失败注入 | `EdgeUpgradeFailureTest` 与全量 34 例通过，旧表保留 |
| 新输出口径 | `free_text=0 facts=48836 structural=53430` |
| 进度 future | `test_progress_future` 2 例通过 |
| 配置备份 | 1.2.18 实跑生成 `config.yaml.bak`，`missing=18 → 0` |
| 全量 | 840 例，仅上轮两个网络/端口检查失败，无新增 |

迁移后 `user_version=4`、`distinct type=6`、备份文件 1 份。
