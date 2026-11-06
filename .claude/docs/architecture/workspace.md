# 终端工作区（WorkspaceManager + 文件树 + 编辑器）

> 2026-11-05 从 terminal.md 拆出。修改工作区、文件树、编辑器、git 面板或预览前先读本文件。

## 组件与职责

| 组件 | 位置 | 职责 |
|---|---|---|
| `WorkspaceManager` | `Sources/Workspace/` | 工作区与会话编排、tmux 生命周期、双写持久化、恢复计划 |
| `WorkspaceModel` / `WorkspaceStore` | `Sources/Workspace/` | 工作区数据模型与 JSON 读写 |
| `WorkspaceMigration` | `Sources/Workspace/` | 旧 `terminal-sessions.json` 迁入工作区 |
| `WorkspaceWindowController` | `Sources/Workspace/` | 窗口、三栏布局、编辑器与文件区接线 |
| `FileExplorerPane` / `FileTreeModel` / `FileTreeWatcher` | `Sources/Workspace/` | 文件树、目录扫描、FSEvents 刷新 |
| `FileEditorPane` / `FileDocument` / `EditorDraftStore` | `Sources/Workspace/` | 编辑器、文件状态、崩溃草稿 |
| `GitPane` / `GitService` / `DiffView` / `ProcessRunner` | `Sources/Workspace/`、`Sources/Core/` | git 状态与 diff |
| `MarkdownPreviewView` / `ImagePreviewView` | `Sources/Components/`、`Sources/Workspace/` | Markdown 与图片预览 |

旧的 `TerminalManager`、`TerminalWindowController` 已删除，`WorkspaceManager` 是唯一会话入口。

## 状态层与工作区窗格

- `WorkspaceStateStore`（`Sources/Workspace/State/`）是唯一 UI 状态源：`update` 先比对再通知，`observe` 返回 UUID 令牌；控制器把快照分发给所有 `WorkspacePanel.render`。
- `WorkspaceSnapshot` 由 `ui`（页签、展开路径、光标、滚动、预览模式）、`fileTree`、`git`、`editor`、`terminals` 组成，全部 `Equatable`，未变化的更新不触发通知。
- 窗格（`TerminalHostView`、`SubTerminalPane`、`FileExplorerPane`、`GitPane`、`FileEditorPane`）实现 `WorkspacePanel`：`panelID`、`focusTarget`、`render(_:)`。控制器按固定数组统一分发，窗格不自行订阅 store。
- `render` 内禁止同步阻塞 IO、禁止 `store.update`。异步取数只有两条路：控制器取数后写快照（`refreshGitStatus`、`refreshBranch`），或窗格自身扫描后直接渲染（文件树 `applyRoot` → `FileTreeModel.loadRoot`）。
- 从属例外：`FileExplorerPane` 持有 `gitPane` 作为同列二选一视图（文件/Git），二者也只经快照与控制器回调通信；其余窗格之间禁止互相持有引用。
- 窗格内部只保留与视图绑定的临时缓冲（如 `FileNode` 树、`FileDocument` 内容），可跨会话的界面状态放在快照。
- 光标、滚动变化写快照前经 200ms 去抖；快照 `ui` 变化经 500ms 去抖写盘，窗口失焦立即 flush。
- 所有列表（工作区、文件树、Git、子终端）忽略空白区域点击：`allowsEmptySelection = true` 时点空白会清掉选中，但快照状态不变，行样式丢失且无法自愈。`PersistentSelectionTableView` 与 `FileOutlineView` 在 `clickedRow < 0` 时直接 return；`allowsEmptySelection` 保持 true 供程序化清空。
- 选中底色由行视图自己画（`PointerRowView.drawSelection`）：点文件/子终端后焦点交给编辑器或终端，列表失去 first responder，用 AppKit 默认绘制会立刻从强调蓝变灰。窗口不是 key 时才用 `selectionInactive`。选中行的文字、图标与行内 `NSButton`（子终端关闭 x）同时转 `selectionText`，取消时按记录的基色还原（含 gitignore 灰化色）。

### 与浮动面板的区别

- 「面板协议」指 `Sources/Core/PanelProtocol.swift` + `PanelManager` 管理的**浮动面板栈**：剪贴板、翻译、知识卡片等接入该接口，`PanelManager` 是唯一 show/close 入口，栈顶优先，Stage 不入栈；面板零引用 `PanelManager`，只经 `EventBus` 发 requestShow/requestClose。
- 工作区窗格是同一窗口内的常驻视图，走 `WorkspaceStateStore` + `WorkspacePanel`，**不接入** `PanelManager`、不参与栈管理；两套机制互不调用，改文档时不要混用「面板」二字。

## 光标（手型）

- `NSTrackingArea` 的 `owner` **必须是视图自身**；用独立对象作 owner 时区域装上但 `cursorUpdate` 回调为 0（实测 0 次 vs 行视图自身 759 次），AppKit 随后在 `routeEnterExitEvent` 里把光标清回箭头。
- 只处理 `cursorUpdate` 会在鼠标继续移动时被重置（漂移测试看不出，真实滑动必现）；必须同时处理 `.mouseMoved` + `mouseMoved(with:)`。
- `PointerButton` / `PointerRowView` 统一实现三处：`updateTrackingAreas` 装区域、`cursorUpdate`、`mouseMoved`；`resetCursorRects` 仅作兜底。
- 按钮不能叠在 `NSTextView` 上，否则 I-beam 抢走命中；编辑器工具栏因此放在标题行。
- 验证必须模拟滑动路径（多次 `mouseMoved` + 截图连光标），直接 `CGWarpMouseCursorPosition` 会掩盖问题；取证见 `.agent/plans/2026-11-05-workspace-protocol/cursor-evidence.md`。

## 存储

- 工作区状态：`~/.config/utility/workspaces.json`，`version: 2`，含 `workspaces`、`selectedWorkspaceID`、`layout`，每个工作区带 `ui`（`activeList`、`expandedPaths`、`caretLocation`、`scrollY`、`previewMode`）。布局字段（`sidebarWidth`、`rightPaneWidth`、`subTerminalHeight`、`fileListWidth`）随窗口拖动落盘。
- 首次把 v1 文档写成 v2 前复制 `workspaces.json.bak`；`ui` 字段类型错误时按默认空状态解析，不整份隔离。
- 会话元数据：`~/.config/utility/terminal-sessions.json` 继续写，`StoredTerminalSession` 增加可选 `workspaceID` / `role`，`backend` 必须继续写（见 `terminal.md`）。
- 草稿：`~/.cache/utility/editor-drafts`，文件名取标准化路径 SHA256 前 8 字节；脏缓冲 2 秒去抖写入，保存/丢弃/关闭时删除；上限 20 份 / 50 MB，按最后修改时间淘汰；损坏草稿改名 `.corrupt-<timestamp>`。
- 恢复草稿只进编辑器、不写回原文件，启动时弹「恢复 / 丢弃 / 对比」。

## 会话与恢复

- 每个工作区一个主 tmux 会话加若干子会话；后端只有 tmux，见 `terminal.md`。
- 恢复时用 `WorkspaceRestorePlan`：按 `liveIDs` 判断会话是否存活，主终端缺失才重建，子会话按持久化顺序重新附着。
- 旧会话通过 `WorkspaceReattribution` 按 id 或 cwd 归入工作区。

## 窗口布局

- 左栏 44pt 活动栏加文件/ Git 列表，主终端吸收窗口缩放，右列文件区在上、子终端在下。
- 默认 `rightPaneWidth` 480、`fileListWidth` 200、子终端 260；右列最小 525。
- 非 vertical 的 `NSSplitView` 按插入顺序自顶向下：先加文件区再加子终端，`setPosition(height - subHeight - divider)`。

## 文件树

- `FileTreeScanner` 不跟随符号链接，目录名走 `PathRules.shouldSkip`，单目录上限 2000 条并提示截断；`workspace.showHiddenFiles` 默认 `true`，关闭时按点号前缀过滤；`.DS_Store` / `.localized` 无论开关都隐藏（`PathRules.isAlwaysHiddenFile`）。
- `FileTreeWatcher` 监听当前工作区根（FSEvents，400ms 去抖），按同一 `showHiddenFiles` 开关过滤隐藏路径与 `PathRules` 忽略目录，只重扫事件涉及的父目录。
- 重扫用 `merge(existing:scanned:)` 复用路径未变的节点对象，已展开目录不会折叠；根路径统一 `resolvingSymlinksInPath`（`/tmp` 与 `/private/tmp` 前缀不一致会导致事件全部丢失）。
- 单击文件夹行任意位置切换展开/收起，第二次点击（`clickCount == 2`）同样切换；单击文件直接打开编辑器，双击是重复调用（`open` 内部按同 URL 去重）；点在展开三角上时交给系统；列表上下留白 6 / 16。
- 展开状态按工作区根路径记在 `expansionByRoot`，切换工作区后按层级异步恢复，每条路径只消费一次（空目录反复 `expandItem` 会让递归不退出）。
- 列表（文件树、Git、子终端）作为 `NSScrollView` 的 documentView 必须用 autoresizing（`autoresizingMask = [.width]`，不关闭 `translatesAutoresizingMaskIntoConstraints`）。关掉后位于 Auto Layout 下又无高度约束，滚动视图每次布局都会把内容压回可视高度，表现为「能展开但滚不动」。

## 编辑器

- `FileDocument` 负责编码探测、BOM/CRLF 记录、指纹（size + mtime + 内容哈希）、原子替换保存（同目录临时文件 + `replaceItemAt`）。
- 脏状态由 `FileDocument.savedText` 基线与当前文本比较（`isDirty(currentText:)`），不再是布尔字段；`textDidChange` 先即时置脏，150ms 后重算，撤销/重做通知立即重算，回到基线时删除草稿并隐藏标题脏点。
- 外部修改检测只在三个触发点执行：应用激活、切换文件或工作区前、保存前；同 size + mtime 时再比内容哈希。
- 干净文档自动重载并恢复滚动位置；脏文档显示横幅（重新加载 / 保留我的 / 对比）；文件被删除时保留缓冲，保存走另存为。
- 编辑器使用独立的 `NSUndoManager`（`EditorTextView` 覆写 `undoManager`），高亮改属性不会污染窗口级撤销栈；打开文件后清空撤销记录。
- 着色时挂起 undo 注册，结束后恢复；`hasMarkedText()` 为真时跳过。
- 工作区所有 `NSScrollView` 用 `OverlayScrollView` 子类，在 `tile` 与加入窗口时强制 overlay + 自动隐藏，避免列表常驻滚动轨道。
- 活动栏 Git 图标右上角显示改动文件数（红底白字，超 99 为 `99+`），数据来自 `GitPane.onCountChange`。

## 语法高亮

- `SyntaxDefinitions` 覆盖 Swift、JS、TS、JSX/TSX、JSON、YAML、Markdown、Shell、Python、HTML、CSS 共 12 种扩展名。
- `SyntaxHighlighter` 只扫描可见范围上下各 200 行；编辑 100ms、滚动 50ms 去抖；超过 1 MB 或 2 万行关闭高亮。
- CLI 断言：`workspace-check --highlight <file>` 输出行数、耗时、四类 token 计数与样本。

## Git

- `ProcessRunner` 不经 shell，status 超时 5 秒、diff 超时 10 秒，输出上限 2 MB；`status` 遇到输出被截断或退出码非 0 时抛错，不当作空结果。
- `git diff --no-index` 有差异时退出码为 1，`GitService.capture` 用允许集合区分「有差异」与「失败」。
- `GitStatusModel` 解析 `git status --porcelain=v1 -z`，重命名记录跳过旧路径字段；未跟踪文件用 `git diff --no-index /dev/null <path>` 生成新增 diff。
- `GitStatusProvider` 单飞 + 按 root 缓存；文件树灰化与 Git 窗格共用同一份结果，控制器写入快照。
- 刷新时机：切到 Git 页、点刷新按钮、编辑器保存、文件系统变更集中后；二进制文件显示提示。
- 三个分组可折叠，标题右侧显示本组文件数，窗格标题右侧显示总数（超 99 显示 `99+`）；列表行只显示文件名，完整相对路径放 toolTip。
- CLI 断言：`workspace-check --git <dir>` 输出分组统计与当前分支；非仓库输出 `git: not-repository`。
- 子终端区域底部有 22pt 状态栏（`WorkspaceStatusBar`），左侧显示 `git branch --show-current`，detached HEAD 回退短 hash；刷新时机为工作区切换与窗口重新成为 key。

## 预览

- `MarkdownPreviewView` 用 WKWebView + 打包的 `marked.umd.js`；CSP 只放行 `file:` / `data:` 图片与内联脚本，外部链接交给系统浏览器。知识面板复用同一视图。
- 编辑器打开 `.md` 默认源码，右上角两个图标切换预览/源码；预览用不透明层覆盖编辑器，避免隐藏编辑器导致焦点转移。
- `ImagePreviewView` 支持 png/jpg/jpeg/gif/tiff/heic/webp；ImageIO 缩略到最长边 4096，超过 20 MB 或解码失败显示提示，解码在后台线程。
- GIF 只显示首帧。

## 已知限制

- 工作区只挂载当前选中的工作区，其余工作区的 tmux 会话保持运行但不渲染。
- 撤销/重做后脏点重算依赖 `textDidChange` 与 `NSUndoManagerDidUndoChange` 双通道；输入法预编辑（marked text）期间不置脏，提交后才计算。
- 恢复光标位置时 `setSelectedRange` 会顺带横向滚动到光标处，属 AppKit 行为。
