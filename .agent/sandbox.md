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
