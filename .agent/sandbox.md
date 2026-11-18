# Sandbox

## 本次运行（2026-11-09 至 11-10）

- Level: virtual-machine。
- Reason: utility 的配置与数据全部由 `homeDirectoryForCurrentUser` 派生，不读 `HOME`；进程级隔离无法覆盖首启向导与真实导入。
- Isolated: 操作系统、用户数据、端口（8613 / 9001）、凭据、Qdrant 向量库。
- Tool: Lume（`cua.ai/lume/install.sh`），安装到 `~/.local/bin`，不需要 sudo。
- 导出端: 用户在本机完成导出，归档 ZIP 作为输入传入 VM。

### 工具安装副作用

| 项 | 默认行为 | 本计划处理 |
|---|---|---|
| LaunchAgent `com.trycua.lume_daemon` | 登录时运行 lume daemon | 安装时加 `--no-background-service` |
| Telemetry | 默认开启，可用 `lume config telemetry disable` | 安装后立即关闭 |
| Shell 配置 | 只打印 PATH 提示，不写 rc | 无需回滚 |
| 安装目录 | `~/.local/bin/lume`、`~/.local/share/lume` | 验证后按需保留或移废纸篓 |

### 创建物

| 对象 | 内容 | 预计占用 |
|---|---|---|
| VM `utility-sandbox` | macOS Tahoe 预设，用于导入验证 | 约 50 GB |
| SSH 传输 | 主机 `scp` 传入 `Utility.app` 与归档 ZIP | 无持久占用 |

实际 VM 用户为 `yuanyxh`，密码由用户手动设置；VM 内已启用 Remote Login，宿主用 `expect` 走密码认证。

### 输入

- `Utility.app`：本机打包产物。
- 归档 ZIP：`/Users/yuanyxh/Downloads/Utility-1.1.109-20261109-2151.zip`，由用户在本机导出。
- 用户显式要求保留生产密钥（`includesSecrets: true`），理由是导入后需要真实 LLM 才能跑通。
- 风险缓解：VM 一次性、验证后立即删除；VM 内不登录账号、不装其他软件；密钥只存在于 VM 磁盘。
- VM 内路径与主机不同，导入时正好验证「目标路径缺失 → 改选新路径」分支。

### 网络

- VM 走 Lume 默认共享网络（`192.168.64.11`）。
- VM 内需代理才能访问 Homebrew / HuggingFace：传入 Clash Verge 与宿主配置，系统代理 `127.0.0.1:7897`。
- 导入与向导检测不依赖 LLM，VM 内不发起 LLM 调用。

### 步骤

1. 下载并审计 `lume/install.sh`，以 `--no-background-service` 安装，关闭 telemetry。
2. `lume create utility-sandbox --ipsw latest --unattended tahoe`。
3. 用户在本机导出 ZIP，提供路径。
4. 主机通过 `scp` 传入 `Utility.app` 与 ZIP（HTTP 服务方案被权限策略否决，改用 SSH）。
5. VM 内启动 app，首启向导选择 ZIP，按提示改选外部目录到 VM 内路径。
6. 记录备份目录、表行数、外部文件数，复跑 `setup-check` 与 `archive-check --roundtrip`。

### 校验

- 导入后 `~/.config/utility.backup-<时间戳>` 存在且含 config 与 data。
- 归档内各 SQLite 关键表行数与 VM 内导入结果一致。
- 外部文件数与 manifest 记录一致。
- `setup-check` 七项无新增 missing。

### 拆除与残留检查

- `lume stop` + `lume delete utility-sandbox`，确认 `lume ls` 为空。
- 删除 `/tmp` 下安装脚本、审计文件与 expect 脚本。
- 检查 `~/Library/LaunchAgents` 无 lume 相关项、无残留进程。
- Lume 本体保留（2026-11-10 用户决定），如需移除：`~/.local/bin/lume`、`~/.local/share/lume`、`~/.lume` 移入废纸篓。

### 限制

- VM 内的 GUI 交互（向导点击、路径选择）需人工完成或截图确认；Claude 通过 `lume ssh` 驱动 CLI 部分。
- 辅助功能与屏幕录制权限在 VM 内同样需要人工授权。
- 首次 IPSW 下载约 10 到 20 GB，耗时取决于网络。

## 运行记录

- 2026-11-09：计划调整为「本机导出 + 单 VM 导入」，等待确认，尚未创建任何环境。
- 2026-11-09：Lume 0.7.0 安装（`--no-background-service`，telemetry 已关）；VM `utility-sandbox` 创建完成，用户手动走过 Setup Assistant 并开启 Remote Login；Clash Verge 与宿主配置传入 VM，系统代理可用。
- 2026-11-10：用户本机导出 `Utility-1.1.109-20261109-2151.zip`（含密钥），经 `scp` 传入 VM。
- 导入验证（L3）：`~/.config/utility.backup-<时间戳>` 生成，各 SQLite 关键表行数与归档一致，external notes 1655 个文件一致。
- 本轮暴露并修复的向导缺陷：安装页内容被裁剪且日志区过大/贴边、选目录后冲突状态不刷新、模型缺失时「下一步」可点、日志区空置、Homebrew 卡住无后续指引、嵌入模型下载无外部超时、`mcp.qdrantPath` 缺失不检测。修复见于 1.2.4 至 1.2.7。
- 2026-11-10 拆除：`lume delete utility-sandbox --force` 成功，`lume ls` 为空；无 LaunchAgent、无残留进程；`/tmp` 无安装或审计文件。用户选择保留 Lume（21M，无守护进程、telemetry 关闭），供后续端到端测试复用。

## 2026-11-12 MCP progress 端到端

- Level: virtual-machine，复用既有 `utility-env`（内含 Utility.app、mcp-venv 3.12.16、agent-gateway wheel 0.1.0）。
- 被测代码：宿主 `src` 的 3 个改动文件覆盖到 VM `~/gateway-src/src`，以 `PYTHONPATH` 指向源码启动 server（9001）。
- 网络：VM 系统代理 `127.0.0.1:7897` 未运行，server 以 `no_proxy=*` 直连；仅测试环境，不代表宿主配置。
- 结论：`json_response=True` 时服务端 on_progress 已触发但客户端收不到（SDK 无 SSE sink）；改 `json_response=False` 后 progress 1/2/3 单调、total 一致。
- 稳定性：顺序 5 次、同 session 并发 3 次全部通过，无 `-32000`、无断连。
- 脚本：`/tmp/lume-e2e/e2e_progress.py`（宿主临时目录，验证后清理）。
- 残留：VM 内 `~/gateway-src/src` 为新源码，旧版在 `agent_gateway.bak`；VM 已停止。
- 未覆盖：真实 Claude Code UI 渲染（客户端用官方 SDK 2.3.0）。

## 2026-11-16 审查后续计划端到端

- Level: virtual-machine，优先复用 `utility-env`；本轮不创建新 VM。
- 被测：计划 `.agent/plans/2026-11-16-review-followups/` 的 T1-T4 与 T3b（gateway），T5-T7（utility）。
- 分两轮：先验 gateway（源码进 VM，`PYTHONPATH` 启动 9001），再验 utility（打包 app 进 VM）。

### 隔离对象

| 对象 | 处理 |
|---|---|
| 数据 | VM 内合成 `memory_graph.sqlite`，禁止复制宿主生产库 |
| 端口 | 只用 VM 内 8613 / 9001，宿主端口不监听 |
| 凭据 | 不注入任何生产密钥；LLM 相关路径用本地桩 |
| Qdrant | VM 内独立目录，不复用宿主 `~/.config/utility/data` |
| 网络 | 默认拒绝；仅模型下载与本地回环按需放行 |

### 合成数据规格

- 节点 300 条，`content_hash` 含 2 组重复。
- 边 1,000 条：结构边 6 类各 50 条，事实边 700 条，谓词覆盖中英文各 50 种。
- `metadata.importance` 在 70% 节点上缺失，验证回填口径。

### 步骤

1. 启动 `utility-env`，确认 SSH 可用。
2. 用 `git archive` 打包 gateway 工作区，`scp` 解压到 `~/gateway-src`。
3. VM 内生成合成库，跑 `memory_edges_v4.py --dry-run` 与 `--apply`。
4. 启动 server（`PYTHONPATH=src`，9001），调用 `/health`、`project_lookup`、`recall`。
5. 制造 Qdrant 锁占用，观察热层退避日志与重试次数。
6. 重建图库，统计 `external` 分类与未解析率。
7. 打包 utility 1.2.15，传入 VM，验证 `config --migrate` 与 `graph --sync`。
8. 记录命令、日志、退出码与统计值。

### 校验

- 迁移后 `distinct type` ≤ 8，事实边 `predicate` 与原 `type` 一一对应。
- 退避日志出现 0.5 / 1 / 2 s 三次尝试，进程未退出。
- `project_lookup ConfigManager` 命中，`external` 占比有数值。
- `config --migrate --dry-run` 输出 18 键与 2 处浮点。

### 拆除与残留

- `lume stop utility-env`；不删除 VM（复用资产）。
- 删除 VM 内 `~/gateway-src` 与合成库，保留旧版备份目录。
- 主机侧清理 `/tmp/lume-e2e-*`，检查无 lume 进程与 LaunchAgent。

### 限制

- 真实 Claude Code UI 渲染不验证。
- 热层初始化依赖 VM 内嵌入模型；模型缺失时只验证退避与错误日志，不验证成功路径。

### 运行记录（2026-11-16）

- 复用 `utility-env`（用户 `lume`，IP 192.168.64.14），VM 内无 pytest，改用 unittest。
- 迁移：脱敏库 101,926 条边，`facts=48600 structural=53326`，迁移后 `distinct type=6`、`user_version=4`，importance 回填 5,816。
- external 分类：9,090 external / 2,688 no_binding；`project_lookup merge_fact` 命中。
- 热层退避：0.52 s / 1.03 s 两次间隔，失败日志含 `qdrant_path`；真实锁竞争未复现。
- 工具清单 15 个，四个历史工具已消失。
- 发现并修复：`utility graph --sync --dir` 与顶层 `--dir` 冲突，改 `--root` 后重打包 1.2.17。
- 宿主单测 834 通过；VM 内 2 项网络/端口检查失败，属环境限制。
- 清理：VM 内产物移入 `~/.Trash`，VM 已停；`gateway-src` 旧版保留。

## 2026-11-18 graph 日志落项目目录

- Level: process。`lume` 已不在 PATH，VM 级不可用；被测对象是 stdin/stdout 常驻进程，不监听端口、不联网、无凭据，VM 级不必要。
- 被测：`log_utils.setup_logging` 加 `path` 参数、`indexer` 按 root 解析日志路径、`_log()` 补 `ts`、CLI 按 `--root` 写项目目录。

### 隔离对象

| 对象 | 处理 |
|---|---|
| 数据 | 临时 git 仓库 A/B，各 3 个合成 `.py` 文件，不碰真实项目目录 |
| cache | `GATEWAY_CACHE` 指向临时目录，禁止写 `~/.cache/utility` |
| 项目状态 | 临时根下的 `.agent-gateway/` |
| 网络 | 全程不联网 |
| 凭据 | 不注入任何密钥 |

### 步骤

1. 改 `log_utils.py`、`indexer.py` 四处。
2. 建临时仓库 A/B，各写 3 个互相引用的 `.py`。
3. 用 stdin 驱动 indexer 分别索引 A/B，检查日志落位与内容互不交叉。
4. 检查每行含 `ts`，且 `ts` 可解析。
5. CLI 验证 `graph index --root` 写项目目录。
6. 用 `GATEWAY_LOG_MAX_SIZE` 调小上限，验证 `.1` 出现且时间序单调。
7. 拆除临时目录，检查无残留。

### 校验

- `<tmp>/A/.agent-gateway/graph.log` 存在，每行含可解析 `ts`。
- B 的日志不含 A 的项目路径，反之亦然。
- 临时 cache 目录下无 `graph.log`。
- CLI 执行后 A 的日志行数增长。
- 小上限下出现 `.1`，`rotation_order.monotonic=true`。

### 限制

- 不验证 GUI 侧 `GraphIndexerClient` 的缓冲与重启逻辑。
- 不验证真实 Swift 侧的并发多项目索引，只用两个独立进程模拟。

### 运行记录（2026-11-18）

首轮失败：日志仍写 cache。根因是 `analysis.py:13` 也创建 `"graph"` logger，它在 `indexer.py` 之前被 import，`setup_logging` 的 `if root.handlers: return root` 把后设的路径吞掉。抽出 `logging_setup.py` 作为唯一起点后通过。

| 项 | 结果 |
|---|---|
| E1 落位 | projA/projB 各自 `.agent-gateway/graph.log` 698 B，cache 目录为空 |
| E2 隔离 | 两文件互不含对方项目路径（0/0），每行 `ts` 可解析且单调 |
| E3 CLI | `--root` 下 `log_file` 指向项目；无 root 返回 `None` 回退 cache；`graph index` 走 `project_scan.sync`，本就不写 index 日志 |
| E4 轮转 | `GATEWAY_LOG_MAX_SIZE=600` 下产生 `.1/.2/.3`，`ts` 严格递增（`.3`→`.2`→`.1`→base） |
| 单测 | 844 tests OK |
| 生产隔离 | `~/.cache/utility/graph.log` mtime 保持 21:55 未变 |

- 部署（2026-11-18 22:53）：用户完成部署，安装副本与源码一致，旧 indexer 句柄释放；新进程 85459 启动后日志落 `<repo>/.agent-gateway/graph.log`，6 行全部含 `ts`。
- 迁移：5 个旧日志（`~/.cache/utility/graph.log{,.1,.2,.3}`、`~/.cache/agent-gateway/graph.log`）移入废纸篓，cache 目录已无 graph.log。
- 残留：`/tmp` 已无沙箱目录；`~/.Trash` 受 TCC 保护（`Operation not permitted`），`mv` 返回成功但无法读取确认落位。
