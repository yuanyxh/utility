# Review 修复轮验证（2026-11-25）

## 决策

- 启动语义：状态驱动——工作区按主 tmux 会话存活上报 `ready/offline`；`service_start` 以 `status` 判定，不看心跳新鲜度
- 修复范围：全部阻断 + 应修项
- 跨机暴露：`bind` 非回环时强制 token，REST/MCP/`/mesh/*` 统一 Bearer

## 已修（gateway）

| 问题 | 修复 |
|---|---|
| REST/MCP 无鉴权 | `remote_token_middleware` + 非回环无 token 拒绝启动 + MCP `transport_security` 放行 |
| endpoint 越界写 | 目录卡 endpoint 必须落在 inbox 根内，否则 `invalid_card` |
| 远端卡本地投递 | 仅 `owner_gateway == gateway_id` 走本地投递，反向注册卡改走 peers |
| 远端可改注册表 | `/mesh/register`、`/mesh/deregister` 仅本机来源 |
| 心跳状态破坏 | `touch` 校验六个合法状态；过期卡不再把 `offline` 写盘 |
| 409 折叠 | `HTTPTransport.deliver` 解析远端 `error_code` 与 `startable` |
| control 绕过 startable | 未 startable 的 control start 返回 `target_offline` |
| 远端 probe 误报 | 远端分支检查 `is_alive` |
| 事件循环阻塞 | 8 个工具与 API 的注册/心跳/列表/启动全部走线程池 |
| 参数校验异常 | 工具统一返回 `{"ok":false,"error_code":...}` |
| 注册表满 | 满额时先把过期/损坏卡移入 `.trash` 再注册 |

## 已修（utility）

| 问题 | 修复 |
|---|---|
| 卡恒 ready | 按主会话存活派生状态，30s 刷新；control start 后回写 ready/offline |
| CLI 无法发现自动端口 | `PortProbe.recordedPort`；应用 `.running` 时写 `runtime/mcp.json` |
| CLI 写文件被覆盖 | App 每 2s 合并磁盘 protocol 字段 |
| disable 不生效 | `WorkspaceProtocolConfig.enabled`；false 时不注册、不监听 |
| inbox 目录表只增 | 目录表以 coordinator endpoints 为准，端点变化重建快照 |
| 网关停止未清理 | 非 running 分支停止 mesh/watcher/重试 |
| 无超时 | MeshClient 3s 请求 / 5s 资源超时 |
| 负 limit 崩溃 | `max(0, limit)` |
| 元数据不刷新 | 指纹变化重新注册；重命名触发刷新 |

## 验证（L2）

- gateway：`1016 tests OK`；`ruff check`/`format --check` 全绿
- utility：`run-tests.sh 49 tests OK`；`gen-l10n --check` 与契约检查通过
- 隔离 HOME 实测：
  - 应用启动写 `runtime/mcp.json`；`utility workspace status` 无显式端口可列出卡
  - 主会话不存在时卡状态 `offline`；control start 后状态随会话存活变化
  - CLI `disable` 后 2s 内日志 `[Mesh] protocols reloaded from disk`，卡被注销；`enable` 后重新注册
- 静态确认：非回环无 token 时 `serve()` 直接抛 `RuntimeError`（未起进程实测）

## 仍未覆盖

- VM GUI 工作区（VM 无 tmux）；VM→宿主反向消息（工作区网关 token 为空）
- 跨机非回环 `bind` + token 的真实启动（沙箱内未起非回环监听）
