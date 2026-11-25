# Agent Mesh 本机验证证据（2026-11-25）

## 1. 双网关跨机转发（L2，harness + 真实 HTTP）

- 网关 A：`/tmp/mesh-gw-a`，端口 9101，`gw-a`，peers=[gw-b]
- 网关 B：`/tmp/mesh-gw-b`，端口 9311，`gw-b`，peers=[gw-a]
- A 注册 `svc-a`（directory，endpoint `/tmp/mesh-gw-a/inbox/svc-a`）
- B 发送：

```
POST /mesh/send {"message":{"sender":"agent-b","recipient":"svc-a","kind":"task","payload":{"text":"cross-gateway ping"}}}
→ {"ok":true,"message_id":"ce4d0d6a...","forwarded":true}
```

- A inbox 出现 `1795614593040-ce4d0d6a3d4546ef88f4b548821e7f03.json`
- B `GET /mesh/services` 合并返回 `[('svc-a','gw-a')]`

## 2. 失败输入

| 输入 | 结果 |
|---|---|
| 70 KB payload | `413 {"ok":false,"error_code":"payload_too_large",...}` |
| 停掉 A 后 B 发送到 svc-a | `{"ok":false,"error_code":"target_unknown"}`（find 尽力而为，不区分 peer 宕机） |
| 非本机来源无 token | 单测 `test_requires_token` 覆盖（401），本机回环按设计免鉴权 |
| 旧版网关（9001）无 `/mesh/*` | CLI 映射为「工作区协议未启用」，退出码 64 |

## 3. 本机 utility L3（隔离 HOME）

环境：`CFFIXED_USER_HOME=/tmp/utility-mesh-e2e/l3/home`、`TMUX_TMPDIR=/tmp/utility-mesh-e2e/l3/tmux`、dev 构建 `.build/debug/utility`，预置工作区 `ws-l3`（`protocol.startCommand=echo L3_START_OK`）。

| 观测点 | 证据 |
|---|---|
| 注册 | `GET /mesh/services` → `ws-l3 / workspace / ready / startable=true / endpoint=.../mesh/inbox/ws-l3` |
| 心跳 | `heartbeat_at 13:58:06` → 35s 后 `13:58:33`（30s 周期） |
| 通知消费 | 发送 notify 后 `debug.log: [Mesh] message from cli-l3`，状态回写 `ready` |
| control 拉起 | `debug.log: [Mesh] start request for ws-l3`，状态 `starting` |
| 重启不重放 | 重启后旧 inbox 文件未产生新 `[Mesh] message from` |
| 门控 | `mcp.enabled=false` 重启后 `debug.log: [Mesh] refresh enabled=false port=9004 count=1`，无注册请求 |

## 4. 本轮修复（验证中发现）

1. `HTTPTransport.find` 未解 `{"ok":true,"card":...}` 信封 → 跨机转发恒 `target_unknown`
2. `/mesh/services` 在 peers 间互相递归 + 同步 httpx 调用阻塞事件循环 → 列表挂起；改为 `?remote=0` + 线程池
3. utility 启动时网关尚未监听 → 首次注册失败后再无重试；新增 `mcp_state_changed` 订阅 + 2s 重试（上限 30 次）
4. 消费消息后服务卡停留 `pending`；新增消费后状态回写（notify→ready，control→starting）

## 5. 待验

- lume `utility-env` 全链路（SSH 需密码，未执行）
- 真实 agent 在工作区内调用 `service_*` 工具的端到端行为
