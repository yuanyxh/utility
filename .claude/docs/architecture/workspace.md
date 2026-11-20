# 终端工作区（WorkspaceManager）

> 2026-11-20 收敛为纯终端布局：删除文件树、Git 面板、编辑器、语法高亮与预览。改布局、窗格或持久化前先读本文件。

## 组件与职责

| 组件 | 位置 | 职责 |
|---|---|---|
| `WorkspaceManager` | `Sources/Workspace/` | 工作区与会话编排、tmux 生命周期、双写持久化、恢复计划 |
| `WorkspaceModel` / `WorkspaceStore` | `Sources/Workspace/` | 工作区数据模型与 JSON 读写 |
| `WorkspaceMigration` | `Sources/Workspace/` | 旧 `terminal-sessions.json` 迁入工作区 |
| `WorkspaceWindowController` | `Sources/Workspace/` | 窗口与三栏布局接线 |
| `WorkspaceSidebarView` | `Sources/Workspace/` | 工作区列表：切换 / 新建 / 重命名 / 移除 |
| `TerminalHostView` / `SubTerminalPane` | `Sources/Workspace/` | 主终端；子终端内容 + 竖向列表 + 分支状态栏 |
| `GitService` | `Sources/Workspace/` | 只读 `branch()`，供状态栏使用 |

旧的 `TerminalManager`、`TerminalWindowController` 已删除，`WorkspaceManager` 是唯一会话入口。

## 状态层与窗格

- `WorkspaceStateStore`（`Sources/Workspace/State/`）是唯一 UI 状态源：`update` 先比对再通知，`observe` 返回 UUID 令牌；控制器把快照分发给所有 `WorkspacePanel.render`。
- `WorkspaceSnapshot` 只含 `terminals`（主会话 id、子会话摘要、选中子会话、分支），全部 `Equatable`，未变化的更新不触发通知。
- 窗格（`TerminalHostView`、`SubTerminalPane`）实现 `WorkspacePanel`：`panelID`、`focusTarget`、`render(_:)`。控制器按固定数组统一分发，窗格不自行订阅 store。
- `render` 内禁止同步阻塞 IO、禁止 `store.update`。分支由控制器 `refreshBranch()` 异步取数后写快照。
- 窗格内部只保留与视图绑定的临时缓冲。

## 与浮动面板的区别

- 「面板协议」指 `Sources/Core/PanelProtocol.swift` + `PanelManager` 管理的**浮动面板栈**：剪贴板、翻译、知识卡片等接入该接口，`PanelManager` 是唯一 show/close 入口，栈顶优先，Stage 不入栈；面板零引用 `PanelManager`，只经 `EventBus` 发 requestShow/requestClose。
- 工作区窗格是同一窗口内的常驻视图，走 `WorkspaceStateStore` + `WorkspacePanel`，**不接入** `PanelManager`、不参与栈管理。

## 列表交互（工作区列表 / 子终端列表）

- 列表空白点击忽略：`allowsEmptySelection = true` 时点空白会清掉选中，但快照状态不变；`PersistentSelectionTableView` 在 `clickedRow < 0` 时直接 return。
- 选中底色由行视图自己画（`PointerRowView.drawSelection`）：点列表后焦点交给终端，列表失去 first responder，用 AppKit 默认绘制会立刻从强调蓝变灰。窗口不是 key 时才用 `selectionInactive`。选中行的文字、图标与行内 `NSButton`（子终端关闭 x）同时转 `selectionText`，取消时按记录的基色还原。
- 所有 `NSScrollView` 使用 `OverlayScrollView`，避免列表常驻滚动轨道。
- 列表作为 `NSScrollView` 的 documentView 必须用 autoresizing（`autoresizingMask = [.width]`，不关闭 `translatesAutoresizingMaskIntoConstraints`），否则「能显示但滚不动」。

## 光标（手型）

- `NSTrackingArea` 的 `owner` **必须是视图自身**；用独立对象作 owner 时区域装上但 `cursorUpdate` 回调为 0（实测 0 次 vs 行视图自身 759 次）。
- 只处理 `cursorUpdate` 会在鼠标继续移动时被重置；必须同时处理 `.mouseMoved` + `mouseMoved(with:)`。
- 验证必须模拟滑动路径（多次 `mouseMoved` + 截图连光标），直接 `CGWarpCursorPosition` 会掩盖问题。

## 存储

- 工作区状态：`~/.config/utility/workspaces.json`，`version: 2`，含 `workspaces`、`selectedWorkspaceID`、`layout`（`sidebarWidth`、`rightPaneWidth`）。
- 旧文档中的 `ui`、`lastOpenedRelativePath`、`fileListWidth`、`subTerminalHeight`、`subListWidth` 已无对应字段，解码时作为未知键忽略，下次写盘自然消失。
- 首次把 v1 文档写成 v2 前复制 `workspaces.json.bak`。
- 会话元数据：`~/.config/utility/terminal-sessions.json` 继续写，`StoredTerminalSession` 带可选 `workspaceID` / `role`，`backend` 必须继续写（见 `terminal.md`）。

## 会话与恢复

- 每个工作区一个主 tmux 会话加若干子会话；后端只有 tmux，见 `terminal.md`。
- 恢复时用 `WorkspaceRestorePlan`：按 `liveIDs` 判断会话是否存活，主终端缺失才重建，子会话按持久化顺序重新附着。
- 旧会话通过 `WorkspaceReattribution` 按 id 或 cwd 归入工作区。
- 子终端底部 22pt 状态栏显示 `git branch --show-current`，detached HEAD 回退短 hash；刷新时机为工作区切换与窗口重新成为 key。

## 窗口布局

- 三栏 `NSSplitView`：工作区列表（默认 220，最小 180）、主终端（吸收窗口缩放）、子终端区域（默认 580，最小 320），子终端内部为「内容 + 180pt 竖向列表」。
- `WorkspaceSplitView` 的 minimums 顺序与插入顺序一致；窗口最小尺寸 1120×680。
- 拖动分隔条 300ms 去抖后写入 `layout`，重启按 `applyLayoutIfNeeded` 恢复。

## 已知限制

- 工作区只挂载当前选中的工作区，其余工作区的 tmux 会话保持运行但不渲染。
