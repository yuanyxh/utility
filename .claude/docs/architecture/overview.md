# 组件总览（宿主侧）

> 从 `AGENTS.md` 分层迁出（2026-11-03），内容逐字保留。
> 修改对应模块前先读本文件；`AGENTS.md` 只保留常驻不变量。

## 核心组件

| 组件 | 职责 |
|------|------|
| `AppDelegate` | 入口：注册 hotkey、初始化管理器 |
| `EventBus` | 线程安全 pub/sub（枚举 key 对应多 handler） |
| `ConfigManager` | YAML 配置加载/热重载 |
| `MenuBarManager` | NSStatusItem + NSMenu |
| `HotkeyManager` | Carbon RegisterEventHotKey |
| `PanelManager` | 栈结构面板生命周期：注册/弹出/关闭/焦点追踪 |
| `KeyDispatcher` | 责任链键盘事件派发：栈顶→栈底→系统 |
| `PanelProtocol` | 面板统一协议：panelID / showPanel / closePanel / handleKeyEvent |
| `SSEParser` | SSE 帧解析器：`data:` 行 → content delta 回调 |
| `ClipboardPanelController` | 剪贴板面板 + clipboardStorage + clipboardWatcher（自管生命周期） |
| `TranslationPanelController` | 翻译面板 + 选中文本获取 |
| `StageWindowController` | Stage 暂存窗口 + StageDropMonitor（自管注册） |
| `TaskScheduler` | Timer + cron + 系统唤醒检测（含内部任务注册） |
| `TaskExecutor` | 外部脚本执行（sh/js/py） |
| `TaskStateDB` | GRDB 任务状态持久化 |
| `MCPProcessManager` | Python server.py 服务编排：State 语义/EventBus 广播/端口复用探测/python 预检；进程生命周期委托 `PythonDaemon` |
| `PythonScriptRunner` | py 脚本统一入口：venv 路径 / 脚本定位（bundle→dev fallback）/ env 构造（baseEnvironment+overrides）/ shell 命令 / 一次性执行（runCaptureOutput） |
| `PythonDaemon` | 参数化常驻 Python 进程守护：启动/崩溃重启/健康检查/停止（`MCPProcessManager` 与 `TokenProxyManager` 共用） |
| `TokenProxyManager` | token_proxy.py 服务编排：State 语义/EventBus 广播/providers 路由；进程生命周期委托 `PythonDaemon` |
| `MCPMenuManager` | MCP 服务状态独立菜单栏管理（app 内部分离） |
| `GraphScanner` / `GraphDatabase` | 项目调用图全量/增量扫描与 `.utility/graph.sqlite` 写入 |
| `FileWatcher` | FSEvents 文件监控 + 3s 防抖，把变更镜像到图库 |
| `NotificationManager` | 本地通知 |
| `Translator` | OpenAI 兼容 API 翻译 |
| `OCRService` | Vision 帧捕获 + 文本识别 |
| `Database` | GRDB DatabaseQueue 单例 |
| `PasteHelper` | 粘贴到目标 app（osascript 子进程 + CGEventPost fallback） |
| `SelectedTextService` | AX Accessibility + 剪贴板兜底选中文本获取 |

## 并发约定

- `Task?.cancel()` + `guard isCancelled` 模式
- 翻译用序列计数器（`translationSeq`）拒绝 stale 回调

## 内存基线

| 指标 | 值 |
|------|-----|
| RSS（空闲） | ~76 MB |
| Physical footprint（空闲） | ~22.5 MB |
| Physical footprint（回收后） | ~18.9 MB |
| Heap nodes | ~44,770 / ~6.8 MB |
| 粘贴后稳定 | ~30.4 MB（不再增长） |
| 粘贴方案 | NSTask + osascript，零 NSAppleScript 内存分配 |
