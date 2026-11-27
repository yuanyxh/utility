# 启动命令配置项（workspace.agentCli）验证（2026-11-26）

## 变更

- `config.yaml` 新增 `workspace.agentCli`：远程拉起工作区时使用的启动命令
- 解析顺序：工作区 `protocol.startCommand` → 全局 `workspace.agentCli` → 无
- 解析结果用于服务卡 `start_command` / `startable`，以及 `control start` 新建会话时的命令
- 2026-11-26 修正：本地点击工作区改为打开普通 shell，不再执行 `agentCli`；只有 `service_start` 新建会话才使用启动命令（`pendingStartCommand` 仅在 `handleMeshMessage` 的 control start 分支设置）

## L2（单测）

- utility `run-tests.sh`：55 tests 0 failures（新增 6 例：解析优先级、空白回退、配置解码、卡片使用外部命令、命令变化重新注册）

## L3（隔离 HOME + 真实应用 + 真实 tmux）

环境：`/tmp/agentcli-manual.*`，`HOME`/`CFFIXED_USER_HOME` 隔离，`TMUX_TMPDIR` 隔离，dev 构建 `.build/debug/utility`，网关自动端口 9004。

配置：

```yaml
mcp:
  enabled: true
workspace:
  agentCli: 'echo AGENT_CLI_OK > <work>/proof.txt'
```

工作区：`ws-main`（`protocol.startCommand = echo MAIN_OK > main.txt`，选中）、`ws-agent`（无自身命令，路径不同）。

| 观测点 | 结果 |
|---|---|
| 卡片解析 | `ws-main.start_command = echo MAIN_OK ...`；`ws-agent.start_command = echo AGENT_CLI_OK ...`，两者 `startable=true` |
| 优先级 | `ws-main` 使用自身命令，未继承全局值 |
| 启动即执行 | 应用启动挂载 `ws-main` 后 `main.txt = MAIN_OK` |
| control 拉起 | `POST /mesh/send`（`kind=control, action=start`）→ `{"ok":true,"started":true}`；日志 `[Mesh] start request for ws-agent` |
| 命令执行 | `proof.txt = AGENT_CLI_OK`，来自全局 `workspace.agentCli` |

## 未覆盖

- 未把生产 `config.yaml` 改成非空 `agentCli`；生产仍是空值（行为不变）
- 启动命令执行完即退出时，tmux 会话随之结束、卡片回到 `offline`（预期行为）
