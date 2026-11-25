# lume 真实 agent 复验（review 修复后，2026-11-25）

## 拓扑

```text
真实 agent (claude -p, 宿主)
  └─ MCP http://127.0.0.1:9101/mcp → gw-host (9101, 修复版)
       ├─ peer gw-vm  http://192.168.64.14:19001 (Bearer e2e-token, 修复版)
       └─ peer gw-yuanyxhdeMacBook-Pro http://127.0.0.1:9002 (隔离 HOME 的修复版 utility)
```

## 修复项实测（VM 网关）

| 用例 | 结果 |
|---|---|
| 远端 `POST /mesh/register`（带正确 token） | `401 unauthorized` |
| 远端 `GET /mesh/health` 无 token | `401 unauthorized` |
| `heartbeat` 传 `status="bogus"` | `400 invalid_message` |
| 本机注册 `endpoint="../../escape"` | `invalid_card: endpoint outside mesh inbox` |

## 真实 agent 调用

| 动作 | 工具返回 | 落点 |
|---|---|---|
| `service_send` → ws-l3 notify | `{"ok":true,...,"forwarded":true}` | 宿主 utility `[Mesh] message from real-agent` |
| `service_send` → vm-agent task | `{"ok":true,...,"forwarded":true}` | VM `inbox/vm-agent/1795619029389-20ff....json`，消费者记 `SEEN` |
| `service_start` → vm-start（离线可启动） | `{"ok":true,"status":"starting"}` | VM `inbox/vm-start/1795619030278-....json`（control） |
| `service_start` → ws-l3（当时 ready） | `{"ok":true,"status":"already_running"}` | 状态驱动判定生效 |
| `service_start` → ws-l3（随后 offline） | `{"ok":true,"status":"starting"}` | utility `[Mesh] start request for ws-l3`，卡状态转 `ready` |

## 验证命令

```bash
cd agent-gateway && PYTHONPATH=src .venv/bin/python -m unittest discover -s tests -t .
cd utility && bash scripts/run-tests.sh
```

结果：gateway `1016 tests OK`；utility `49 tests OK`；ruff 与 l10n 双检查通过。

## 结论与残留

- 修复后的跨机鉴权、注册表边界、状态驱动启动均通过真实 agent + lume 环境验证（L3 交互，日志与 inbox 文件为证）
- VM 无 tmux：`utility-env` 内 GUI 工作区仍未验证，工作区侧改在宿主隔离实例验证
- VM→宿主反向消息未测（工作区网关 token 为空，非本机来源按设计拒绝）
