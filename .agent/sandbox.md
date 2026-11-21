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

## 2026-11-20 1.2.35 部署后隔离验证（计划）

- Level: process。`~/.local/bin/lume` 可用但 VM 均 stopped；被测为 CLI 与 gateway 常驻进程，不涉 GUI，临时 HOME + 临时项目 + 临时端口足够，省去 VM 开机与 SSH。出现 GUI 项再升级 virtual-machine 复用 `utility-env`。
- 被测：已部署 `/Applications/Utility.app`（1.2.35）与其 `~/.config/utility/mcp-venv` wheel（已确认含 `core/trace_context.py`）。
- 变更边界：`2a4be85` Watcher 白名单、`be1a30c` 预热移除、`441b639` notice 移除、`76190cd` 仅文档；gateway `f63702e` trace_id。

### 隔离对象

| 对象 | 处理 |
|---|---|
| 数据 | 临时 HOME（`HOME` + `CFFIXED_USER_HOME`）+ 临时项目；生产 `~/.config/utility` 只取 mtime/size 快照 |
| venv | `cp -cR` 克隆生产 `mcp-venv` 到临时 HOME，避免向生产写 `__pycache__` |
| 端口 | MCP 19003；shell 继承的 `MCP_PORT=9001` 必须覆盖；生产 9001 / 8613 不触达 |
| 网络 | 仅 loopback；trace E2E 用 fake upstream 与 ephemeral 端口，无外联 |
| 凭据 | 不注入任何 key，provider `apiKey` 为空 |
| cache | `GATEWAY_CACHE` / `QDRANT_PATH` / `UTILITY_DATA_DIR` 全指临时目录 |

### 用例

- A1 CLI 面：deployed `--help` 无 notice；`utility notice` 返回非 0。
- A2 归档：隔离 HOME 下 `archive-check --roundtrip` 通过，归档范围不再含 notices。
- A3 Watcher：临时项目首扫断言 4 符号 / 2 边；新增 `gamma.swift`、`sub/delta.swift`、`notes.txt`、`image.png` 与目录事件，断言仅支持的源码入库、日志无 no-parser 报错；删除文件断言节点移除。
- A4 预热：隔离 config `mcp.port=19003` + 本地记录桩；`utility -a` 全程断言 0 次 `/api/project/notes/prewarm`。
- A5 Gateway trace：以生产 venv python 跑 `agent-gateway/tests/eval/trace_id/2026-11-20/run.sh`，断言 `RESULT PASS`、`X-Trace-Id`、`mcp.ids.join` 相等。

### 校验

- 生产 `token_usage.sqlite` mtime/size 不变；9001/8613 仍为原 PID 27487/27488；生产 debug.log 不新增本次记录。
- 临时目录与子进程清理；19003 等端口无监听。

### 限制

- 不验 GUI 面板与系统通知（notice 移除后的菜单/通知行为）。
- trace 使用真实 socket 但 fake upstream，不代表真实上游链路。

### 运行记录（2026-11-20）

- 被测：`/Applications/Utility.app` 1.2.35（deployed binary）+ 克隆自生产 `mcp-venv` 的临时 venv；临时 HOME `/tmp/utility-e2e.*`。
- A1：`--help` 无 notice；`utility notice` exit 64。A2：`archive-check --roundtrip` exit 0。
- A3：首扫 4 符号 / 2 边；新增 `gamma.swift`、`sub/delta.swift`、`notes.txt`、`image.png`、`emptydir/` 后仅 2 个源码入库（`Scan result: 2 updated, 0 deleted`），txt/png 未入图，`graph.log` 无 no-parser/unsupported；删除 `alpha.swift` 后 1 符号移除（`remove_file`）。graph ops：`index_file×2`、`remove_file×1`。
- A4：19003 记录桩全程 0 请求；二进制 `notes/prewarm` 字符串 0 次。
- A5：生产 venv python 跑 trace E2E（E2E_MCP_PORT=19004）`RESULT PASS`，代理 JSON/SSE/413 均带 `X-Trace-Id`，`mcp.ids.join` 两侧相等；已部署 wheel 含 `core/trace_context.py`。
- 隔离：生产 token_usage mtime 变化来自运行中 App 的正常流量；生产 PIDs 27487/27488 未变，生产 debug.log 无临时路径（0 次）。临时目录已移入废纸篓，19003/19004 无监听、无残留进程。
- 未覆盖：GUI 菜单/系统通知；notice 移除后的真实通知行为。

## 2026-11-20 recall 分层端到端

- Level: virtual-machine（L3）。复用 `utility-env`，真实记忆副本：Qdrant 140M（热层 `mem0_jinazh768` + 冷层）、图库 128M（5774 神经元 / 18884 突触）、notes 274M、reranker 模型 293M。端口 19001 基线（master `f63702e`）/ 19002 正式版；宿主经 SSH 隧道访问 19002。
- 数据隔离：`~/recall-ab/data` 给基线，`~/recall-ab/data-exp` + `exp-home` 给正式版（embedded Qdrant 不能双开同一目录）；`GATEWAY_CACHE` 分开；LLM key 清空，`AI_API_KEY=sk-dummy` 仅供 mem0 初始化。
- 环境缺陷与修复：首轮两台服务都缺 `GATEWAY_USER_ID`，`dense_hot` 报 `Invalid user_id`（server.log 1017/916 次），hot 行实际来自 SemanticArm。补 `GATEWAY_USER_ID=yuanyxh` 后同一查询 `dense_hot raw=80 kept=17`、top1 命中「记忆神经单元」。**后续 VM 检索测试必须带该 env。**
- A/B（249 条 gold，补齐 `GATEWAY_USER_ID` 后）：anchors precision 8.9% vs 6.7%，入口覆盖 35.7% vs 32.9%（anchors 非空子集 10.0% vs 7.5%、入口覆盖 39.8% vs 36.7%），基线已命中 82 条零丢失，p50 3316ms vs 3978ms；28 条空 anchors 全部有 candidates（基线同批平均 5.43 条、仅 1 条命中）；基线 trace 63.6% 返回行为 rerank 判负后复活。
- 两轮独立审查：首轮 8 条发现，修复 project_notes 结果丢失、project_lookup 状态波及、candidates 绕过 max_chars、trace 与返回 status 不一致；复审发现 candidates 跨尺度排序挤掉 rerank_rejected，改为来源优先级（rerank_rejected > below_floor > filter_miss）。898→901 单测、ruff 全过。
- 真实长任务（3 个独立 agent，非模拟）：①短查询 rerank 评估，判负行约 60% 实际相关，推荐「判定与排序分离」，词面救援精度 0.837/召回 0.947；②治理离线增量落盘方案（run.json + batches.jsonl + 断点键）；③SwiftPM 依赖审计方案（check-deps.py，OSV SwiftURL）。
- 残留：VM 仍在运行，`~/recall-ab` 与报告（report-full/report-formal/report-final.json）保留待复查；宿主 `/tmp/recall-ab`、SSH 隧道进程待清理。生产代码未部署 wheel。

## 2026-11-21 短查询词面救援

- Level: virtual-machine（L3）。同一 VM、同一真实副本；19001 基线 `src-base`，19002 正式版 `src-formal`（含救援）。仅 19002 经宿主隧道。
- 环境坑：VM shell 带 `http_proxy=127.0.0.1:7897`（代理未运行），VM 内跑 `eval.py` 的 urllib 全部 `Connection refused`；必须加 `NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost`。宿主侧跑无此问题。
- 短查询/不存在集（`short_eval.py`）：12/12 短查询 anchors 非空（5~6 条相关）；20 条不存在查询 11 empty、8 candidates_only、1 条 `ok` 是库内真实收录的自引用记录（`zzz-nonexistent-abc`），无词面误报。
- 249 条 gold（`report-tight.json`）：anchors precision 8.9% vs 6.7%，入口覆盖 35.7% vs 32.9%，exp_empty 28，p50 3318ms vs 3909ms。与宽松救援版 `report-rescue.json` 逐条对比：仅 2 条 exp_ids 变化（各多 1 条无关 anchor），相关命中与入口覆盖零丢失。
- 复审后修：CJK bigram 被当词数导致 ≤2 词中文救援失效 → 门限改按空白分词、覆盖率允许缺 1 个词（75% 在 N=3 不可达）；补有效负例（停用词、词边界、CJK 跨词 bigram、boost 混排）与 `rerank_rescued` 契约/trace 断言。912 单测、ruff 全过。
- 清理：19001/19002 已停、宿主 SSH 隧道已关闭；VM 保持运行，`~/recall-ab/eval/report-tight.json`、`tight.log` 与真实副本保留待复查。
- 部署（2026-11-21 23:20/23:27）：`/Applications/Utility.app` 的 wheel 含救援代码，venv 的 `pipeline.py` 与源仓逐字一致，MCP PID 30916 已重启。
