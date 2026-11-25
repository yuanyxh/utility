# Agent Mesh 任务清单

仓库约定：`G = /Users/yuanyxh/Documents/selfdata/projects/agent-gateway`，`U = /Users/yuanyxh/Documents/selfdata/projects/utility`。

- [x] T1 gateway 模型与校验（依赖：无，规模：S）
- [x] T2 文件注册表（依赖：T1，规模：S）
- [x] T3 目录传输（依赖：T1，规模：S）
- [x] T4 HTTP 传输（依赖：T1，规模：S）
- [x] T5 Router（依赖：T2-T4，规模：S）
- [x] T6 HTTP API 与配置（依赖：T5，规模：M）
- [x] T7 MCP 工具面（依赖：T6，规模：M）
- [x] T8 反向注册（依赖：T6，规模：S）
- [x] T9 utility 协议配置与门控（依赖：T6，规模：M）
- [x] T10 启动命令注入（依赖：T9，规模：S）
- [x] T11 注册与心跳（依赖：T9，规模：M）
- [x] T12 inbox 监听与通知（依赖：T11，规模：M）
- [x] T13 `utility workspace` CLI（依赖：T9，规模：M）
- [x] T14 文档与配置同步（依赖：T7、T12，规模：M）
- [x] T15 端到端验证（VM GUI 项待补）（依赖：T9-T14，规模：L）

## T1 gateway 模型与校验

**文件**：新建 `G/src/agent_gateway/services/mesh/__init__.py`、`models.py`；测试 `G/tests/test_mesh_models.py`

**接口**
- 产出 `ServiceCard`：`schema_version="utility.mesh/service-card/v1"`、`id: str`、`name: str`、`kind: Literal["workspace","agent","gateway","custom"]`、`owner_gateway: str`、`transport: Literal["directory","http"]`、`endpoint: str`、`capabilities: list[str]`、`metadata: dict`、`status: Literal["offline","starting","ready","pending","busy","blocked"]`、`start_command: str | None`、`startable: bool`、`heartbeat_at: datetime`、`ttl_seconds: int = 120`
- 产出 `MeshMessage`：`id`、`sender`、`recipient`、`kind: Literal["notify","task","reply"]`、`payload: dict`、`reply_to: str | None`、`sent_at: datetime`
- 产出 `MeshError`：`invalid_card`、`payload_too_large`、`target_unknown`、`target_offline`、`peer_unreachable`、`registry_full`、`unauthorized`
- 常量 `MAX_PAYLOAD_BYTES = 65536`

**验收**
- [ ] kind 非法、id 为空、endpoint 为空时拒绝
- [ ] payload 序列化后 > 64 KB 时抛 `payload_too_large`
- [ ] 合法 Card 往返 `model_dump_json` / `model_validate_json` 等值

**验证**：`cd G && PYTHONPATH=src python -m unittest tests.test_mesh_models -v` → `OK`

**步骤**
- [ ] 写失败测试：非法 kind 与 65 KB payload
- [ ] 跑测试确认失败
- [ ] 实现 `models.py`
- [ ] 跑测试确认通过

## T2 文件注册表

**文件**：新建 `G/src/agent_gateway/services/mesh/registry.py`；测试 `G/tests/test_mesh_registry.py`

**接口**
- 产出 `FileRegistry(root: Path, gateway_id: str, max_services: int = 500)`
  - `register(card) -> None`：原子写 `<root>/services/<id>.json`，`os.replace` + `chmod 0600`
- `touch(service_id) -> bool`：更新 `heartbeat_at`
- `deregister(service_id) -> bool`：移入 `<root>/services/.trash/`
- `get(service_id, include_expired=False) -> ServiceCard | None`
- `list() -> list[ServiceCard]`
- `is_alive(card, now=None) -> bool`：`now - heartbeat_at <= ttl_seconds`

**验收**
- [ ] 第 501 个服务注册返回 `registry_full`
- [ ] 心跳过期 130 s 的 Card 在 `list()` 中被标记 offline（仍返回，状态字段）
- [ ] 写入采用临时文件 + 原子替换，进程中断不产生半截 JSON

**验证**：`cd G && PYTHONPATH=src python -m unittest tests.test_mesh_registry -v`

**步骤**
- [ ] 写失败测试：上限、过期、原子性（模拟写入异常）
- [ ] 实现 `FileRegistry`
- [ ] 跑测试确认通过

## T3 目录传输

**文件**：新建 `G/src/agent_gateway/services/mesh/transport.py`；测试 `G/tests/test_mesh_transport.py`

**接口**
- 产出 `Transport` 协议：`deliver(card: ServiceCard, message: MeshMessage) -> None`、`probe(card: ServiceCard, timeout: float = 1.5) -> bool`
- 产出 `DirectoryTransport(inbox_root: Path)`
  - 投递路径 `<inbox_root>/<service_id>/<sent_at_ms>-<msg_id>.json`
  - 先写 `.tmp` 再 `os.replace`；目录不存在则创建

**验收**
- [ ] 投递后目标 inbox 出现 1 个 JSON，内容与消息等值
- [ ] 目标目录不可写时抛 `TransportError`，不留半截文件
- [ ] `probe` 对已注册目录返回 True，对不存在目录返回 False

**验证**：`cd G && PYTHONPATH=src python -m unittest tests.test_mesh_transport -v`

**步骤**
- [ ] 写失败测试：投递落点、不可写、probe
- [ ] 实现 `DirectoryTransport`
- [ ] 跑测试确认通过

## T4 HTTP 传输

**文件**：修改 `G/src/agent_gateway/services/mesh/transport.py`；测试 `G/tests/test_mesh_transport.py`

**接口**
- 产出 `Peer(name: str, base_url: str, token: str)`
- 产出 `HTTPTransport(peers: list[Peer], timeout: float = 3.0)`
  - `deliver` → `POST {base_url}/mesh/send`，头 `Authorization: Bearer <token>`
  - `probe` → `GET {base_url}/mesh/health`，2xx 为 True
  - `find(service_id) -> tuple[Peer, ServiceCard] | None`：并行查 peers 的 `GET /mesh/services/{id}`，总超时 2 s

**验收**
- [ ] peers 全部不可达时 `deliver` 抛 `peer_unreachable`，3 s 内返回
- [ ] 命中第二个 peer 时 `find` 返回对应 peer 与 Card

**验证**：`cd G && PYTHONPATH=src python -m unittest tests.test_mesh_transport -v`（用 `httpx.MockTransport`）

**步骤**
- [ ] 写失败测试：不可达、第二 peer 命中
- [ ] 实现 `HTTPTransport`
- [ ] 跑测试确认通过

## T5 Router

**文件**：新建 `G/src/agent_gateway/services/mesh/router.py`；测试 `G/tests/test_mesh_router.py`

**接口**
- 产出 `Router(registry: FileRegistry, local: DirectoryTransport, remote: HTTPTransport | None)`
  - `send(message) -> dict`：`{"ok": bool, "error_code": str | None}`
  - `register(card) -> dict`
  - `probe(service_id) -> dict`：`{"ok", "status": "ready|offline|unknown"}`
  - `list() -> list[dict]`

**验收**
- [ ] 本地命中且存活 → 写 inbox，返回 `ok`
- [ ] 本地命中但心跳过期 → `target_offline` 且返回 `startable`，不写文件
- [ ] 本地未命中且无 remote → `target_unknown`
- [ ] peers 命中 → 经 `HTTPTransport.deliver` 转发，不重试
- [ ] 投递成功后目标状态变 `pending`

**验证**：`cd G && PYTHONPATH=src python -m unittest tests.test_mesh_router -v`

**步骤**
- [ ] 写失败测试：四个分支
- [ ] 实现 `Router`
- [ ] 跑测试确认通过

## 检查点 A（T1-T5）

- [ ] `PYTHONPATH=src python -m unittest discover -s tests -t .` 全绿
- [ ] `ruff check src tests` 与 `ruff format --check src tests` 通过
- [ ] 无网络调用即可覆盖全部单测

## T6 HTTP API 与配置

**文件**：新建 `G/src/agent_gateway/services/mesh/api.py`；修改 `G/src/agent_gateway/services/mcp/server.py:1105-1173`、`G/src/agent_gateway/core/config.py`、`G/src/agent_gateway/core/paths.py`；测试 `G/tests/test_mesh_api.py`

**接口**
- 产出 `build_mesh_routes(router, token) -> list[Route]`
  - `POST /mesh/register`、`POST /mesh/deregister`、`POST /mesh/send`、`POST /mesh/heartbeat`
  - `GET /mesh/services`、`GET /mesh/services/{id}`、`GET /mesh/health`
  - `GET /.well-known/agent-card.json`（gateway 自身 Card）
- 鉴权：非 `127.0.0.1` 来源的 `/mesh/*` 与 `/.well-known/*` 必须 `Authorization: Bearer <config.server.mesh.token>`
- 配置新增：`server.mesh.{enabled,gatewayId,dataDir,token,peers[{name,baseUrl,token}],heartbeatTtlSeconds}`
- `server.mcp.bind` 新增（默认 `127.0.0.1`），替代 `server.py:1168` 硬编码

**验收**
- [ ] `curl` 注册、列表、发送、探测全部返回 2xx
- [ ] 无 token 的非本机请求返回 401
- [ ] `server.mesh.enabled=false` 时 `/mesh/*` 返回 404，MCP 工具不注册

**验证**
- `cd G && PYTHONPATH=src python -m unittest tests.test_mesh_api -v`
- 手工：`curl -s 127.0.0.1:9001/mesh/health`

**步骤**
- [ ] 写失败测试：401、404（disabled）、CRUD
- [ ] 实现 `api.py` 与配置解码
- [ ] 在 `server.py` 追加路由并配置化 bind
- [ ] 跑测试与手工 curl

## T7 MCP 工具面

**文件**：新建 `G/src/agent_gateway/services/mesh/tools.py`；修改 `G/src/agent_gateway/services/mcp/server.py`；测试 `G/tests/test_mesh_tools.py`

**接口**
- 产出 `register_mesh_tools(mcp, router)`：
  - `service_register(name, kind, transport, endpoint, capabilities, metadata)`
  - `service_deregister(service_id)`
  - `service_send(sender, recipient, kind, payload, reply_to=None)`
  - `service_inbox(service_id, limit=20)`
  - `service_start(service_id)`
  - `service_heartbeat(service_id, status)`
  - `service_list()`
  - `service_probe(service_id)`
- 工具与参数描述固定英文；`sender` 必填（调用方从 `MESH_SERVICE_ID` 环境变量取值）

**验收**
- [ ] `tools/list` 出现 5 个工具
- [ ] `service_send` 成功时返回 JSON `{"ok": true, "message_id": ...}`
- [ ] 失败时返回 `{"ok": false, "error_code": ...}`，不抛异常

**验证**：`cd G && PYTHONPATH=src python -m unittest tests.test_mesh_tools -v`

**步骤**
- [ ] 写失败测试：工具清单、成功与失败返回
- [ ] 实现 `tools.py` 并在 `server.py` 注册
- [ ] 跑测试确认通过

## T8 反向注册

**文件**：修改 `G/src/agent_gateway/services/mesh/router.py`、`api.py`；测试 `G/tests/test_mesh_router.py`

**接口**
- `/mesh/send` 请求体可带 `sender_card`
- 接收方注册表无 `sender`、且 `sender_card.kind in {"workspace","agent"}`、且来源为已鉴权 peer 时，写入 Card，`ttl_seconds = min(card.ttl_seconds, 300)`

**验收**
- [ ] 已鉴权 peer 转发的消息使发送方出现在本机 `service_list`
- [ ] 未携带 `sender_card` 时不写入
- [ ] 本机来源任意 kind 不自动注册，需显式 register

**验证**：`cd G && PYTHONPATH=src python -m unittest tests.test_mesh_router tests.test_mesh_api -v`

**步骤**
- [ ] 写失败测试：三种来源
- [ ] 在 Router 与 API 实现
- [ ] 跑测试确认通过

## 检查点 B（T6-T8）

- [ ] 全部 gateway 测试通过
- [ ] `curl` 完成注册 → 查询 → 发送 → 探测闭环
- [ ] `tools/list` 含 5 个 `service_*`

## T9 utility 协议配置与门控

**文件**：新建 `U/Sources/Workspace/Mesh/WorkspaceProtocolConfig.swift`；修改 `U/Sources/Workspace/WorkspaceModel.swift:36-90`、`U/Sources/Workspace/WorkspaceManager.swift`

**接口**
- 产出 `WorkspaceProtocolConfig: Codable, Equatable, Sendable`：`startCommand: String?`、`serviceName: String?`、`capabilities: [String]`、`autoStart: Bool`
- `Workspace` 新增 `var protocol: WorkspaceProtocolConfig?`，`init(from:)` 用 `decodeIfPresent`；为 nil 时按默认配置注册
- 产出 `MeshGate.isEnabled(config) -> Bool`：`config.mcp?.enabled == true && PythonScriptRunner.isGatewayAvailable`

**验收**
- [ ] 旧 workspaces.json 无 `protocol` 字段可正常加载，并按默认配置注册
- [ ] `mcp.enabled=false` 或 gateway 不可用时 `MeshGate.isEnabled` 为 false，不注册
- [ ] 网关启用时新增工作区自动出现在 `service_list`

**验证**：`cd U && swift build && bash scripts/run-tests.sh`

**步骤**
- [ ] 写失败测试：旧文档加载、门控矩阵
- [ ] 实现模型与门控
- [ ] 跑构建与测试

## T10 启动命令注入

**文件**：修改 `U/Sources/Terminal/TerminalBackend.swift:108-134`、`U/Sources/Workspace/WorkspaceManager.swift:445-534`

**接口**
- `TmuxBackend.prepare(id:cwd:shell:initialCommand:environment:)`，`initialCommand: String? = nil`
- 非空时 `new-session` 参数末尾由 `shell` 改为 `shell -lc '<command>'`
- 启动前注入环境变量：`MESH_SERVICE_ID=<workspace id>`、`MESH_GATEWAY_URL=http://127.0.0.1:<mcp.port>`
- 仅在 `tmuxExists == false` 路径传入（`WorkspaceManager.swift:474-481`）

**验收**
- [ ] 首次创建工作区时命令在 pane 内执行
- [ ] 恢复已有 tmux 会话时不重复执行
- [ ] 命令为空时行为与现状一致

**验证**：`cd U && swift build`；隔离 HOME 启动后 `tmux -L utility list-panes -F '#{pane_current_command}'` 显示命令进程

**步骤**
- [ ] 写失败测试或 `workspace-check` 断言
- [ ] 修改 `prepare` 与调用点
- [ ] 隔离环境手工验证一次

## T11 注册与心跳

**文件**：新建 `U/Sources/Workspace/Mesh/MeshClient.swift`、`WorkspaceMeshCoordinator.swift`；修改 `U/Sources/Workspace/WorkspaceManager.swift`、`U/Sources/Core/Constants.swift`

**接口**
- `MeshClient(baseURL: URL)`：`register(card) -> Card`、`touch(id)`、`deregister(id)`、`list() -> [Card]`、`send(message)`、`inbox(id)`
- `WorkspaceMeshCoordinator`：挂载工作区时注册（`kind=workspace`、`owner_gateway` 由 gateway 填），每 30 s `touch`，移除/关闭工作区时 `deregister`
- gateway 不可用或协议关闭时不启动，不弹错误

**验收**
- [ ] 启用 gateway 时工作区出现在 `service_list`
- [ ] 30 s 内至少一次心跳
- [ ] 关闭工作区后从注册表消失

**验证**：`cd U && swift build && bash scripts/run-tests.sh`；本机 `curl 127.0.0.1:9001/mesh/services`

**步骤**
- [ ] 写失败测试：注册/注销调用次数（注入假客户端）
- [ ] 实现客户端与协调器
- [ ] 接入 `WorkspaceManager` 生命周期

## T12 inbox 监听与通知

**文件**：新建 `U/Sources/Workspace/Mesh/WorkspaceInboxWatcher.swift`；修改 `U/Sources/Workspace/WorkspaceManager.swift`

**接口**
- `WorkspaceInboxWatcher(directory: URL, onMessage: (MeshMessage) -> Void)`：FSEvents 400 ms 去抖
- 新消息 → `EventBus.publish(.notify)` + 终端 OSC（复用既有 `handleNotification` 路径）
- 文件不删除；启动时只通知修改时间晚于启动时刻的文件

**验收**
- [ ] 向 inbox 写一条消息后 1 s 内出现系统通知
- [ ] 重启 utility 不会重复通知旧消息
- [ ] inbox 目录被删除后重建，不崩溃

**验证**：隔离 HOME 启动，`echo '{...}' > <inbox>/<id>/<file>.json` 后观察通知与 `debug.log`

**步骤**
- [ ] 写失败测试：去抖、旧文件不通知
- [ ] 实现 watcher 并接线
- [ ] 隔离环境手工验证

## T13 `utility workspace` CLI

**文件**：新建 `U/Sources/CLI/WorkspaceCommand.swift`；修改 `U/Sources/CLI/UtilityCLI.swift:13-21`、`U/Sources/Resources/*.json`、`scripts/gen-l10n.py` 生成物

**接口**
- `utility workspace enable --workspace <id> [--start-command <cmd>]` / `disable --workspace <id>`：写入/清除 `protocol` 字段，是本期唯一的协议配置入口
- `utility workspace status`：列出本机服务与状态
- `utility workspace send --to <id> --kind <notify|task|reply> --text <text>`
- `utility workspace inbox --service <id> [--limit N]`
- `utility workspace list`
- 输出文案走 L10n；`--json` 输出机器可读

**验收**
- [ ] `status` 在 gateway 未启用时返回明确提示并以非 0 退出
- [ ] `send` 成功打印 message id
- [ ] `--json` 输出可被 `jq` 解析

**验证**：`cd U && swift build && .build/debug/utility workspace status --json`

**步骤**
- [ ] 写失败测试：未启用退出码、JSON 结构
- [ ] 实现子命令与文案
- [ ] 跑 `gen-l10n.py --check` 与 `check-l10n-contract.py`

## 检查点 C（T9-T13）

- [ ] `swift build`、`run-tests.sh`、l10n 双检查通过
- [ ] 本机单 gateway：注册 → CLI 发送 → 工作区收到通知
- [ ] 关闭 `mcp.enabled` 后协议完全静默

## T14 文档与配置同步

**文件**：新建 `U/.claude/docs/architecture/agent-mesh.md`；修改 `U/CLAUDE.md`、`G/CLAUDE.md`、`U/default-config.yaml`、`U/.claude/docs/architecture/overview.md`

**内容**
- 分层、Card/Message 结构、目录布局、`/mesh/*` 接口、错误码
- 门控链：`mcp.enabled` → `isGatewayAvailable` → 工作区 `protocol.enabled`
- 不变量：不保投递、不重试、inbox 由消费方删除、跨机必须 Bearer
- 已知坑：bind 默认 127.0.0.1、tmux 恢复不执行启动命令、旧版本丢弃 protocol 字段

**验收**
- [ ] 文档中的命令可直接复制执行
- [ ] CLAUDE.md 索引含新文档
- [ ] `default-config.yaml` 注释与实际键一致

**验证**：`cd U && python3 scripts/gen-l10n.py --check && python3 scripts/check-l10n-contract.py`

**步骤**
- [ ] 起草文档
- [ ] 同步索引与配置注释
- [ ] 跑校验

## T15 端到端验证（lume + utility-env）

**文件**：证据写入 `U/.agent/plans/2026-11-25-agent-mesh/evidence/`

**验证矩阵**
- [ ] L2 本机双 gateway：数据目录 `/tmp/mesh-gw-a` / `/tmp/mesh-gw-b`，端口 9001 / 9311，`peers` 互指，A 注册服务 → B 通过 `/mesh/send` 投递 → A 的 inbox 出现文件
- [ ] L3 本机 utility：`.build/debug/utility` 隔离 HOME 启动，工作区注册成功，`utility workspace send` 产生通知
- [ ] L3 lume `utility-env`：冷启动 VM → 安装构建 → 首启 → 开启 gateway → 工作区协议注册与心跳 → 关闭 gateway 后协议不启用
- [ ] 失败输入：peers 不可达、无 token、65 KB 消息各返回规定错误码

**命令**
- `~/.local/bin/lume start utility-env`（SSH 需密码，手工步骤）
- `cd G && PYTHONPATH=src python -m agent_gateway.cli.minod --serve`
- `cd U && bash scripts/e2e-isolated.sh`

**验收**
- [ ] 证据目录含命令输出、`debug.log` 片段、关键截图
- [ ] 跨机（本机 ↔ VM）若网络不可达，记录为待验并写明缺什么

**步骤**
- [ ] 本机双 gateway 脚本化并保存输出
- [ ] utility 本机端到端
- [ ] VM 隔离验证
- [ ] 汇总证据与待验项

## 最终检查点 D（T14-T15）

- [ ] 两仓测试与格式检查全绿
- [ ] 四类失败输入均返回规定错误码
- [ ] 证据齐全，待验项明确
