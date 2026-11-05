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

## 存储

- 工作区状态：`~/.config/utility/workspaces.json`，含 `workspaces`、`selectedWorkspaceID`、`layout`。布局字段（`sidebarWidth`、`rightPaneWidth`、`subTerminalHeight`、`fileListWidth`）随窗口拖动落盘。
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
- 刷新时机：切到 Git 页、点刷新按钮、编辑器保存后 400ms 去抖；二进制文件显示提示。
- 三个分组可折叠，标题右侧显示本组文件数，面板标题右侧显示总数（超 99 显示 `99+`）；列表行只显示文件名，完整相对路径放 toolTip。
- CLI 断言：`workspace-check --git <dir>` 输出分组统计与当前分支；非仓库输出 `git: not-repository`。
- 子终端区域底部有 22pt 状态栏（`WorkspaceStatusBar`），左侧显示 `git branch --show-current`，detached HEAD 回退短 hash；刷新时机为工作区切换与窗口重新成为 key。

## 预览

- `MarkdownPreviewView` 用 WKWebView + 打包的 `marked.umd.js`；CSP 只放行 `file:` / `data:` 图片与内联脚本，外部链接交给系统浏览器。知识面板复用同一视图。
- 编辑器打开 `.md` 默认源码，右上角两个图标切换预览/源码；预览用不透明层覆盖编辑器，避免隐藏编辑器导致焦点转移。
- `ImagePreviewView` 支持 png/jpg/jpeg/gif/tiff/heic/webp；ImageIO 缩略到最长边 4096，超过 20 MB 或解码失败显示提示，解码在后台线程。
- GIF 只显示首帧。

## 已知限制

- 预览切换图标的 hover 手型光标未实现：跟踪区域与 `cursorUpdate` 均正常触发，但会被窗口的光标更新覆盖，叠加覆盖层后出现手型/箭头闪烁，已回滚。
- 工作区只挂载当前选中的工作区，其余工作区的 tmux 会话保持运行但不渲染。
