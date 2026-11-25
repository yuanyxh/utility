# lume 跨机 + 真实 agent 验证（2026-11-25）

## 拓扑

```
真实 agent (claude -p, 宿主)
   └─ MCP http://127.0.0.1:9101/mcp → 宿主全量网关 gw-host (9101)
        ├─ peer gw-vm  http://192.168.64.14:19001  (Bearer e2e-token)
        └─ peer gw-yuanyxhdeMacBook-Pro http://127.0.0.1:9004 (工作区网关)
```

- VM `utility-env`（macOS 26.4，IP 192.168.64.14）内运行新版 `services/mesh` 源码，venv 3.12.16
- 宿主工作区网关由隔离 HOME 的 dev 构建提供，注册 `ws-l3`（startable）

## 跨机鉴权

| 请求 | 结果 |
|---|---|
| `GET http://192.168.64.14:19001/mesh/health` 无 token | `{"ok":false,"error_code":"unauthorized"}` |
| 带 `Authorization: Bearer e2e-token` | `{"ok":true,"gateway":"gw-vm"}` |

## 真实 agent 调用（claude -p + `--mcp-config`）

服务列表（9101 聚合本机 + 两个 peer）：

```json
[('vm-agent','gw-vm'), ('ws-l3','gw-yuanyxhdeMacBook-Pro')]
```

| 动作 | 工具返回 | 落点证据 |
|---|---|---|
| 发送 notify → ws-l3 | `{"ok":true,"message_id":"61775e...","forwarded":true}` | 宿主 utility `debug.log: [Mesh] message from real-agent` |
| 发送 task → vm-agent | `{"ok":true,"message_id":"9b53c7...","forwarded":true}` | VM `gw-home/inbox/vm-agent/1795615717375-9b53c7....json` |
| service_start → vm-start（离线可启动） | `{"ok":true,"status":"starting"}` | VM `gw-home/inbox/vm-start/1795615916362-....json`，`kind=control payload={"action":"start"}` |

VM 侧消息消费日志：`~/mesh-e2e/vm-inbox.log`（1s 轮询打印新文件）。

## 本轮修复（跨机验证中发现）

1. `service_start` 只查本地注册表 → 远程卡恒 `target_unknown`；改为本机未命中时 `remote.find`，并转发 control 消息
2. `/mesh/services/{id}` 默认隐藏过期卡 → peers 无法发现离线可启动服务；单卡接口改为 `include_expired=True`（状态字段标 `offline`）
3. 路由层对过期卡一律拒绝投递 → control start 无法唤醒；`kind=control + action=start` 绕过存活门槛
4. `lume cp` 的目标路径会被加上字面单引号（落在 `'file'`），需复制后 `mv` 修正

## 未覆盖

- VM 内 GUI：虚拟机无 tmux（无 Homebrew），工作区终端后端不可用，`utility-env` 内未启动 GUI 工作区；工作区侧改在宿主隔离实例验证。补齐需在 VM 安装 tmux（需用户同意）
- VM → 宿主反向消息：本轮仅验证宿主→VM 与宿主→工作区两个方向；反向需给工作区网关配置 mesh token（当前 token 为空，非本机来源一律拒绝）
