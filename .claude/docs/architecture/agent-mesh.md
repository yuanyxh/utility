# Agent Mesh（服务间通信）

> 网关侧实现在 `agent-gateway` 仓 `src/agent_gateway/services/mesh/`；本文件记录宿主侧接线与两仓共用的协议约定。

## 分层

```
agent（Claude 等） ──MCP/HTTP──▶ agent-gateway（唯一入口 + 代理）
                                    │
                      ┌─────────────┼─────────────┐
                      ▼             ▼             ▼
                  本机注册表    目录投递     peers（跨机转发）
                      ▲             ▲
                      └── utility 工作区服务卡 ──┘
```

- 网关是网络层：服务注册、存活探测、本地投递、跨机转发都在网关内完成
- utility 只做适配：每个工作区 = 一张服务卡，`kind=workspace`，进程内多 Agent 由工作区承载
- agent 始终连一个网关；网关同时担任代理，不存在「直连绕过网关」的路径

## 数据模型

`ServiceCard`（schema `utility.mesh/service-card/v1`）：

| 字段 | 说明 |
|---|---|
| `id` | `^[A-Za-z0-9._-]{1,64}$`；工作区卡等于 workspace id |
| `kind` | `workspace` / `agent` / `gateway` / `custom` |
| `transport` | `directory`（本机 inbox）/ `http`（跨机） |
| `endpoint` | directory 时是 inbox 目录，绝对路径或相对 `<dataDir>/inbox` |
| `status` | `offline/starting/ready/pending/busy/blocked` |
| `start_command` / `startable` | 工作区可被 `service_start` 拉起 |
| `heartbeat_at` / `ttl_seconds` | 默认 TTL 120s，心跳 30s |

`MeshMessage`：`id`、`sender`、`recipient`、`kind`（`notify/task/reply/control`）、`payload`（≤ 64 KB）、`reply_to`、`sent_at`。

注册表为**文件目录**（每个服务一个 JSON），原子写（临时文件 + `os.replace`，权限 0600），上限 500：

```
<dataDir>/services/<id>.json
<dataDir>/services/.trash/<id>.json     # deregister 移入，不硬删
<dataDir>/inbox/<service_id>/<sent_at_ms>-<msg_id>.json
```

## HTTP 接口

`/mesh/*` 与 `/.well-known/agent-card.json` 由 `build_mesh_routes` 挂到网关 FastAPI/Starlette 应用：

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/mesh/register` | 注册/覆盖服务卡 |
| POST | `/mesh/deregister` | 移入 `.trash` |
| POST | `/mesh/send` | 投递消息；可带 `sender_card` 触发反向注册 |
| POST | `/mesh/heartbeat` | 续心跳，可带 `status`（agent 自报 busy/blocked） |
| GET | `/mesh/services` | 列表（过期卡标 `offline`，仍返回） |
| GET | `/mesh/services/{id}` | 单卡 |
| GET | `/mesh/health` | `{"ok": true, "gateway": "<id>"}` |
| GET | `/.well-known/agent-card.json` | 网关自身 Card |

鉴权：本机来源（`127.0.0.1` / `::1`）免 token；其余必须 `Authorization: Bearer <server.mesh.token>`，token 为空时一律拒绝。

错误码（`ok:false` + `error_code`）：`invalid_card`、`invalid_message`、`payload_too_large`、`target_unknown`、`target_offline`、`peer_unreachable`、`delivery_failed`、`registry_full`、`unauthorized`。

## MCP 工具面

`service_list`、`service_send`、`service_inbox`、`service_start`、`service_heartbeat`、`service_probe`、`service_register`、`service_deregister`。mesh 未启用时全部返回 `{"ok": false, "error_code": "mesh_disabled"}`。

## 投递与启动语义

- **不保投递**：网关与 utility 都不做持久化重试；失败立即返回错误码，由调用方决定是否重发
- 目标心跳过期 → `target_offline` + `startable`；调用方显式 `service_start`，不自动重试
- `service_start` 在本机与 peers 中查找目标；**以 `status` 判定是否在运行**（`offline` 即拉起），不只看心跳
- control start 消息**绕过存活门槛**，可投递给已过期卡，但目标必须 `startable`
- `service_start` 向目标 inbox 写 `kind=control, payload={"action":"start"}`，本机卡状态置 `starting`
- utility 的 inbox watcher 收到 control → `selectWorkspace(id:)`，随后按主 tmux 会话是否存活回写 `ready/offline`
- 状态可见性：utility 每次刷新按主会话存活派生 `ready/offline` 并随心跳上报；`busy/blocked` 只能由 agent 自报

## 跨机转发

- `server.mesh.peers` 配置兄弟网关（`name/baseUrl/token`）；**`name` 必须等于对方 `gatewayId`**，否则命中卡按 owner 找不到转发端点
- 本地未命中时 `GET /mesh/services/{id}` 查 peers；命中则 `POST {peer}/mesh/send` 转发，不重试
- 列表聚合时向 peers 请求 `GET /mesh/services?remote=0`，避免兄弟网关互相递归
- 转发前探测目标网关存活；不可达返回 `peer_unreachable`
- 接收方把已鉴权 peer 带来的 `sender_card` 反向写入本地注册表（仅 `workspace/agent`，TTL ≤ 300s，不覆盖已有卡）

## utility 侧接线

| 组件 | 职责 |
|---|---|
| `WorkspaceProtocolConfig` | 工作区协议配置，编码在 `workspaces.json` 的 `"protocol"` 键（nil 不写） |
| `MeshGate` | 门控：`mcp.enabled` + `PythonScriptRunner.isGatewayAvailable` 同时为真 |
| `WorkspaceMeshCoordinator` | 注册/注销服务卡，30s 心跳；`endpoint` 用相对 id，由网关归一为绝对 inbox 路径 |
| `WorkspaceInboxWatcher` | 1s 轮询 inbox；control 消息拉起工作区，其余走通知；启动前的旧文件不重复通知 |
| `MeshClient` | `/mesh/*` 的 URLSession 客户端 |
| `WorkspaceManager` | 生命周期编排；启动主会话时注入 `MESH_SERVICE_ID`、`MESH_GATEWAY_URL` |

协议开关只影响服务卡注册与 inbox 监听；`mcp.enabled=false` 时整条链路静默。

## 配置

网关 `agent-gateway.yaml`：

```yaml
server:
  mcp:
    bind: 127.0.0.1
  mesh:
    enabled: true
    gatewayId: gw-local
    dataDir: ~/.config/utility/mesh      # 空 = gateway_home()/mesh
    token: ''                            # 跨机时必须设置
    advertiseUrl: ''                     # agent-card 对外地址；空 = http://<bind>:<port>
    heartbeatTtlSeconds: 120
    peers:
      - name: gw-b                      # 必须等于对方 gatewayId
        baseUrl: http://10.0.0.2:9001
        token: <共享 token>
```

`bind` 非回环时：启动前强制要求 `server.mesh.token`，且 REST/MCP 与 `/mesh/*` 一样校验 Bearer；token 为空直接拒绝启动。

utility 侧：`mcp.enabled: true`（默认）+ gateway 可用 + 网关进程 running；每个工作区的协议配置经 CLI 写入（`disable` 只置 `enabled=false`，卡与 inbox 监听一并停止）：

```bash
utility workspace enable --workspace <id> --start-command 'claude --continue'
utility workspace status        # 服务列表
utility workspace send --to <id> --kind notify --text 'ping'
utility workspace inbox --service <id> --limit 20
utility workspace list --json   # jq 可解析
```

CLI 端口来源：`mcp.port > 0` 优先，否则读 `~/.config/utility/runtime/mcp.json`（应用启动网关时写入）；`UTILITY_GATEWAY_URL` 可覆盖（联合调试）。

## 不变量

- 不保投递、不重试：任何一层都不落重试队列
- 心跳过期只标 `offline`，不删卡；删除只走 `deregister` → `.trash`
- `/mesh/register`、`/mesh/deregister` 只接受本机来源；远端卡只经 `sender_card` 反向注册（不覆盖、kind 受限、TTL ≤ 300s）
- 目录卡 `endpoint` 必须落在网关 inbox 根内，`..` 与外部绝对路径一律 `invalid_card`
- 心跳 `status` 必须是六个合法值之一；非法值不写盘
- 跨机 `/mesh/*` 与 REST/MCP 全部要求 Bearer；`bind` 非回环且无 token 时拒绝启动
- inbox 文件由消费方处理，网关不删除；utility 只在启动时跳过旧文件
- `service_start` 只写 control 消息，不直接执行命令；control start 是唯一允许投递给过期卡的 kind，且需要 `startable`
- 路由层不做阻塞调用：网络转发在 API/MCP 侧经线程池执行，禁止在事件循环里同步 httpx
- 远端投递失败必须保留远端 `error_code`（含 `startable`），不得折叠成 `peer_unreachable`

## 已知坑

- 部署版 Utility.app 里的旧 gateway 没有 `/mesh/*`，CLI 会收到 404；已映射为「工作区协议未启用」提示
- `server.mcp.bind` 默认 `127.0.0.1`；跨机必须显式改 bind、设置 token（REST/MCP 同时受保护）并配置 `advertiseUrl`
- tmux 会话恢复不会重跑 `start_command`；启动命令只在新建会话时执行（control start 命中存活会话时同样不重跑）
- CLI 与运行中的 App 同时写 `workspaces.json`：App 每 2s 合并磁盘上的 protocol 字段，其余字段以 App 为准
- 旧版 utility 读 `workspaces.json` 会丢弃未知字段；带 `protocol` 的文件需新版本写回
- 工作区卡在恢复会话时以 `.build/debug/utility` 自测需隔离 HOME，避免与真实注册表混淆
