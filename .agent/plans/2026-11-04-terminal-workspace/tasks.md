# 终端改造为工作区任务清单

方案、非目标、风险见同目录 `plan.md`。按依赖顺序执行，每个任务结束都运行验证命令。未获用户明确允许不提交。

- [ ] T1 工作区模型、配置、存储与迁移（依赖：无，规模：S）
- [ ] T2 `WorkspaceManager` 会话编排与恢复（依赖：T1，规模：M）
- [ ] T3 工作区窗口骨架与入口切换（依赖：T2，规模：M）
- [ ] T4 工作区侧栏交互（依赖：T3，规模：S）
- [ ] T5 主终端与子终端面板（依赖：T3，规模：M）
- [ ] T6 文件树、名称过滤与列表列（依赖：T3，规模：M）
- [ ] T7 文件编辑器渲染（依赖：T6，规模：M）
- [ ] T8 编辑保存、未保存提示与冲突（依赖：T7，规模：M）
- [ ] T9 git 状态列表（依赖：T6，规模：S）
- [ ] T10 git diff 查看（依赖：T9，规模：S）
- [ ] T11 工作区全文搜索（依赖：T7，规模：M）
- [ ] T12 实时监听与刷新（依赖：T6、T8、T9，规模：M）
- [ ] T13 Markdown 与图片预览（依赖：T7，规模：M）
- [ ] T14 i18n、文档、打包与回归（依赖：T4、T5、T10、T12、T13，规模：S）

## T1 工作区模型、配置、存储与迁移

**文件**

- 新建：`Sources/Workspace/Workspace.swift`、`Sources/Workspace/WorkspaceStore.swift`、`Sources/CLI/WorkspaceCheckCommand.swift`
- 修改：`Sources/Terminal/TerminalSessionStore.swift:3-27`、`Sources/Core/ConfigTypes.swift:85-111`、`Sources/Resources/default-config.yaml:338-348`、`Sources/CLI/UtilityCLI.swift:11-19`、`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`
- 生成：`Sources/Core/L10nKeys.swift`

**接口**

- 产出 `enum TerminalRole: String, Codable { case main, sub }`。
- 产出 `struct WorkspaceLayout: Codable, Equatable`，字段见 `plan.md` 数据模型，带属性初值。
- 产出 `struct Workspace: Codable, Equatable, Identifiable`，字段见 `plan.md`。
- 产出 `enum WorkspaceMigration { static func group(_ sessions: [StoredTerminalSession], now: Date) -> [Workspace] }`。
- 产出 `final class WorkspaceStore`：`init(fileURL: URL = AppPaths.configDir.appendingPathComponent("workspaces.json"))`、`func load() -> [Workspace]`、`func save(_ workspaces: [Workspace])`。
- 产出 `public struct WorkspaceConfig: Codable`：`ignoredDirectories: [String]` 默认 `[".git", "node_modules", ".build", "DerivedData", "Pods", "dist", ".next"]`、`showHiddenFiles: Bool` 默认 `false`、`maxFileSizeMB: Int` 默认 `5`；`AppConfig` 增加 `workspace: WorkspaceConfig`。
- 修改 `StoredTerminalSession`：增加 `var workspaceID: String?`、`var role: TerminalRole?`，`init(from:)` 用 `decodeIfPresent`。
- 产出 `WorkspaceCheckCommand: ParsableCommand`，参数 `--sessions <path>`、`--roundtrip <path>`、`--dry-run`；输出格式固定：`workspaces: <n>`，每个工作区一行 `- <name> <path> main=<id> subs=<n> exists=<yes|no>`；`--dry-run` 按迁移规则打印分组不写盘；`--roundtrip` 把给定 `workspaces.json` 读入、写到同目录临时文件、再读回并打印 `roundtrip: ok|mismatch`。

**验收**

- [ ] 给定 3 条旧会话、两个不同 `cwd`，`workspace-check --sessions <fixture> --dry-run` 输出 2 个工作区，主终端为组内最早 `createdAt`，其余为子终端（L2）。
- [ ] `WorkspaceStore` 保存后重新 `load()` 与原数组等值，`layout` 与 `selectedSubSessionID` 保留（L2，用 `workspace-check --roundtrip <file>` 断言输出 `roundtrip: ok`）。
- [ ] `default-config.yaml` 的 `workspace` 段与 `WorkspaceConfig` 属性初值、`decodeIfPresent` 兜底完全一致（L1，人工比对三处）。

**验证**

```bash
swift build
.build/debug/utility workspace-check --sessions /tmp/ws-fixture.json --dry-run
.build/debug/utility workspace-check --roundtrip /tmp/ws-roundtrip.json
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
```

期望：构建成功；输出 `workspaces: 2` 且主/子分配符合 fixture；`roundtrip: ok`；两个 l10n 脚本退出码 0。

**依赖 / 规模**：无 / S

- [ ] 写 `Workspace.swift`：模型、角色枚举、迁移分组纯函数。
- [ ] 写 `WorkspaceStore.swift`：原子写、ISO8601、`sortedKeys`；首次保存前把已有 `terminal-sessions.json` 复制为 `.bak`。
- [ ] 扩展 `StoredTerminalSession` 可选字段，保持 `backend` 必写。
- [ ] 增加 `WorkspaceConfig` 与 `AppConfig.workspace` 解码。
- [ ] 在 `default-config.yaml` 的 `terminal` 段后插入 `workspace` 段与注释。
- [ ] 写 `WorkspaceCheckCommand` 并注册到 `UtilityCLI`；新增 4 个 l10n 键（中英各一）。
- [ ] 运行生成器与验证命令，构造 `/tmp/ws-fixture.json` 断言迁移分组，跑 `--roundtrip` 断言读写往返。

## T2 `WorkspaceManager` 会话编排与恢复

**文件**

- 新建：`Sources/Workspace/WorkspaceManager.swift`
- 修改：`Sources/Workspace/WorkspaceStore.swift`（本次只补迁移备份调用）

**接口**

- 产出 `@MainActor final class WorkspaceManager`，`static let shared`。
- 状态：`private(set) var workspaces: [Workspace]`、`private(set) var selectedWorkspaceID: String?`、`private(set) var sessions: [String: TerminalSession]`。
- 方法：`showWindow()`、`toggleWindow()`、`shutdown()`、`createWorkspace(path: String)`、`selectWorkspace(id: String)`、`renameWorkspace(id: String, name: String)`、`removeWorkspace(id: String)`、`addSubSession(workspaceID: String) -> String?`、`selectSubSession(workspaceID: String, sessionID: String)`、`closeSubSession(workspaceID: String, sessionID: String)`、`mainSession(of workspaceID: String) -> TerminalSession?`、`subSessions(of workspaceID: String) -> [TerminalSession]`、`session(id: String) -> TerminalSession?`、`persist()`。
- 消费 T1 的 `WorkspaceStore`、`WorkspaceStore.load`、`TerminalSessionStore`、`TmuxBackend`、`TerminalSession`。
- 复用 `TerminalManager` 的恢复、通知去重、`currentPaths()` 轮询逻辑，逻辑迁入后旧类保持原状直到 T3 删除。

**验收**

- [ ] 首次启动（无 `workspaces.json`、有 `terminal-sessions.json`）日志出现 `[Workspace] migrated sessions=<n> workspaces=<m>`，生成 `workspaces.json` 且 `terminal-sessions.json.bak` 存在（L2）。
- [ ] tmux 存活会话恢复后，主终端与子终端 id 与 `workspaces.json` 一致；不存活的 id 从工作区移除（L2，查 `workspace-check` 输出）。
- [ ] 单工作区终端数量达到 `terminal.maxSessions` 时，`addSubSession` 返回 nil 并发送一次上限通知（L2 日志）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "\[Workspace\] migrated"
.build/debug/utility workspace-check
```

期望：构建成功；`strings` 计数 ≥ 1；`workspace-check` 输出与 `workspaces.json` 一致。

**依赖 / 规模**：T1 / M

- [ ] 新建 `WorkspaceManager.swift`，迁移 `TerminalManager` 的会话创建、`wire`、通知、轮询、恢复代码。
- [ ] 实现迁移：无 `workspaces.json` 且旧会话非空时调用 `WorkspaceMigration.group`，落盘并打印迁移日志。
- [ ] 实现恢复：按工作区顺序恢复主终端与子终端；主终端缺失时用工作区路径重建。
- [ ] 实现工作区 CRUD 与子终端增删；移除工作区时 kill 其全部 tmux 会话并清理 `sessions`。
- [ ] 实现 `persist()`：写 `workspaces.json` 与 `terminal-sessions.json`（含 `workspaceID`、`role`）。
- [ ] 运行构建与 `workspace-check`，用 fixture 验证迁移结果。

## T3 工作区窗口骨架与入口切换

**文件**

- 新建：`Sources/Workspace/WorkspaceWindowController.swift`、`Sources/Workspace/WorkspaceSidebarView.swift`
- 修改：`Sources/App/AppDelegate.swift:77`、`AppDelegate.swift:229`、`Sources/Core/MenuBarManager.swift:154`
- 移废纸篓：`Sources/Terminal/TerminalManager.swift`、`Sources/Terminal/TerminalWindowController.swift`

**接口**

- 产出 `@MainActor final class WorkspaceWindowController: NSWindowController, NSWindowDelegate`。
- 回调：`onSelectWorkspace: ((String) -> Void)?`、`onCreateWorkspace: (() -> Void)?`、`var wantsVisible: Bool`。
- 方法：`func reloadWorkspaces(_ workspaces: [Workspace], selectedID: String?)`、`func showMainTerminal(_ view: NSView)`、`func apply(layout: WorkspaceLayout)`、`var currentLayout: WorkspaceLayout { get }`。
- 消费 `WorkspaceManager.shared` 的工作区与主终端视图。
- `WorkspaceManager` 接管 `AppEvent.terminalOpenSession` 订阅与 `showWindow` / `toggleWindow` / `shutdown` 三个入口。

**验收**

- [ ] 默认启动显示工作区窗口：左侧工作区列表、中部主终端、右侧文件区与底部子终端区为空占位（L3）。
- [ ] 选中不同工作区时，主终端切换到该工作区的会话，cwd 为工作区路径（L3）。
- [ ] 关闭窗口后菜单栏入口、热键、Dock 唤起仍能重新打开窗口（L3，沿用 GUI 计划行为）。
- [ ] 重启应用后工作区列表与主终端恢复（L3）。

**验证**

```bash
swift build
bash scripts/run-tests.sh
strings .build/debug/utility | grep -c "WorkspaceWindowController"
```

期望：构建成功；脚本全过；符号计数 ≥ 1。窗口行为按 L3 手工验证，记录截图与日志。

**依赖 / 规模**：T2 / M

- [ ] 新建 `WorkspaceSidebarView`：只读列表（名称 + 路径），选中高亮；顶部 + 按钮先留空回调。
- [ ] 新建 `WorkspaceWindowController`：顶层 `NSSplitView(vertical)`，侧栏 / 主终端 / 右侧占位；右侧占位再建垂直 `NSSplitView` 与底部空面板。
- [ ] 实现 `apply(layout:)` 与 `currentLayout`：设置/读取各分隔条位置；窗口 minSize 改为 1100×640。
- [ ] 迁移窗口失活兜底、`wantsVisible`、`AppWindowRegistry.register`、语言切换通知。
- [ ] 修改 `AppDelegate`、`MenuBarManager` 入口为 `WorkspaceManager.shared`；旧两个文件移到废纸篓。
- [ ] 运行构建与手工验证，记录窗口截图与 `[Workspace]` 日志。

## T4 工作区侧栏交互

**文件**

- 修改：`Sources/Workspace/WorkspaceSidebarView.swift`、`Sources/Workspace/WorkspaceManager.swift`

**接口**

- 产出回调：`onCreateWorkspace: (() -> Void)?`、`onRenameWorkspace: ((String, String) -> Void)?`、`onRemoveWorkspace: ((String) -> Void)?`、`onSelectWorkspace: ((String) -> Void)?`。
- 消费 `WorkspaceManager.createWorkspace(path:)`、`renameWorkspace(id:name:)`、`removeWorkspace(id:)`。

**验收**

- [ ] 点 + 弹出 `NSOpenPanel` 仅允许目录；选择后新工作区出现在列表并自动选中，主终端 cwd 为该目录（L3）。
- [ ] 双击名称可重命名，空名称被拒绝；重启后名称保留（L3）。
- [ ] 移除工作区弹确认框，文案含会话数量与「不删除磁盘文件」；确认后列表项消失、tmux 会话结束、相邻工作区被选中（L3 + L2 日志）。
- [ ] 路径不存在的工作区在列表中标红，点击不崩溃（L3）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "removeWorkspace"
```

期望：构建成功；符号计数 ≥ 1；手工用例逐条通过。

**依赖 / 规模**：T3 / S

- [ ] 侧栏 + 按钮接 `NSOpenPanel`，`canChooseDirectories = true`、`canChooseFiles = false`。
- [ ] 行内重命名：双击进入编辑态，回车提交，Esc 取消，空值恢复原名。
- [ ] 右键菜单或行尾按钮提供移除；`NSAlert` 确认文案走 l10n。
- [ ] 路径存在性用 `FileManager.fileExists` 判断，缺失行文字使用 `VSTheme.error`。
- [ ] 运行构建与手工验证。

## T5 主终端与子终端面板

**文件**

- 新建：`Sources/Workspace/SubTerminalPane.swift`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift`、`Sources/Workspace/WorkspaceManager.swift`

**接口**

- 产出 `struct SubSessionRow { let id: String; let title: String; let cwd: String }`。
- 产出窗口方法：`func reloadSubSessions(_ rows: [SubSessionRow], selectedID: String?)`、`func showSubTerminal(_ view: NSView)`。
- 产出回调：`onAddSubSession: ((String) -> Void)?`、`onSelectSubSession: ((String, String) -> Void)?`、`onCloseSubSession: ((String, String) -> Void)?`、`onLayoutChange: ((WorkspaceLayout) -> Void)?`。
- 消费 `WorkspaceManager.addSubSession`、`selectSubSession`、`closeSubSession`、`subSessions`。

**验收**

- [ ] 子终端面板顶部 + 新建子终端，默认 cwd 为工作区路径，列表新增一行并选中（L3）。
- [ ] 点击列表行切换终端视图；关闭按钮结束会话并从列表移除（L3）。
- [ ] 底部面板分隔条可拖拽，高度写入当前工作区 `layout.subTerminalHeight`，重启恢复（L3）。
- [ ] 终端标题变化时只刷新对应行，不重建列表（L3 + L2 日志）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "SubTerminalPane"
```

期望：构建成功；符号计数 ≥ 1；手工用例逐条通过。

**依赖 / 规模**：T3 / M

- [ ] 新建 `SubTerminalPane`：左侧终端容器 + 右侧 `NSTableView`（标题、cwd、关闭按钮）+ 顶部加号。
- [ ] 注册 `TerminalSession.onTitleChange` 刷新子终端行。
- [ ] 窗口层：底部区域替换占位，接入 `reloadSubSessions` 与 `showSubTerminal`。
- [ ] 分隔条拖动结束写回 `WorkspaceManager` 并去抖 `persist()`。
- [ ] 工作区切换时保存旧工作区布局、应用新工作区布局。
- [ ] 运行构建与手工验证。

## T6 文件树、名称过滤与列表列

**文件**

- 新建：`Sources/Workspace/FileTreeModel.swift`、`Sources/Workspace/FileExplorerPane.swift`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift`

**接口**

- 产出 `final class FileNode { let url: URL; let isDirectory: Bool; var children: [FileNode]? }`，`FileTreeModel(root: URL, config: WorkspaceConfig)`。
- 方法：`func loadChildren(of node: FileNode) -> [FileNode]`、`func reload()`、`func filter(_ text: String) -> Bool`。
- 产出 `FileExplorerPane`：`var onOpenFile: ((URL) -> Void)?`；`func showTree(root: URL, config: WorkspaceConfig)`、`func refresh()`、`func setActivity(.files | .git)`。
- 消费 `WorkspaceConfig.ignoredDirectories`、`showHiddenFiles`、`WorkspaceManager.selectedWorkspace`。

**验收**

- [ ] 展开目录按需读取，忽略目录与隐藏文件不出现在树中（L3）。
- [ ] 名称过滤框输入后仅保留匹配节点，清空恢复完整树（L3）。
- [ ] 双击文件触发 `onOpenFile`，目录双击展开/收起（L3）。
- [ ] 空目录显示空状态，不崩溃（L3）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "FileTreeModel"
```

期望：构建成功；符号计数 ≥ 1；手工用例逐条通过。

**依赖 / 规模**：T3 / M

- [ ] 写 `FileTreeModel`：`FileManager.contentsOfDirectory` 懒加载、排序（目录优先、`localizedStandardCompare`）、忽略规则。
- [ ] 写 `FileExplorerPane`：图标栏两个按钮（files / git）、`NSOutlineView` 容器、名称过滤框。
- [ ] 窗口接入：文件区替换占位，选中工作区时重载根节点。
- [ ] 名称过滤只过滤已加载节点；未加载目录保持占位，展开后按过滤条件裁剪。
- [ ] 运行构建与手工验证。

## T7 文件编辑器渲染

**文件**

- 新建：`Sources/Workspace/FileDocument.swift`、`Sources/Workspace/FileEditorPane.swift`、`Sources/Workspace/LineNumberRulerView.swift`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift`、`Sources/Workspace/FileExplorerPane.swift`

**接口**

- 产出 `@MainActor final class FileDocument`：`let url: URL`、`private(set) var text: String`、`private(set) var isDirty: Bool`、`private(set) var readOnlyReason: String?`、`init(url: URL) throws`、`func updateText(_ text: String)`。
- 产出 `final class FileEditorPane`：`func show(document: FileDocument)`、`func clear()`、`var onTextChange: ((String) -> Void)?`。
- 产出窗口方法：`func showFile(_ document: FileDocument)`、`func clearEditor()`。
- 消费 `WorkspaceConfig.maxFileSizeMB`、`VSTheme`。
- 二进制判定：读取前 8192 字节含 `0x00` 即视为二进制。
- 编码：只接受 UTF-8 / UTF-8 BOM；`String(contentsOf:encoding:.utf8)` 失败时只读并提示。

**验收**

- [ ] 点击文件在编辑器区显示内容，等宽字体、行号与内容对齐、滚动时行号同步（L3）。
- [ ] 文本文件可直接编辑；`FileDocument.isDirty` 随输入变化（L3）。
- [ ] 二进制、非 UTF-8、超过 `maxFileSizeMB` 的文件显示只读提示，不渲染乱码（L3）。
- [ ] 切换文件后旧文档内容不残留（L3）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "LineNumberRulerView"
```

期望：构建成功；符号计数 ≥ 1；手工用例逐条通过。

**依赖 / 规模**：T6 / M

- [ ] 写 `LineNumberRulerView`：`NSRulerView` 子类，绘制可见行行号，监听滚动与文本变化。
- [ ] 写 `FileDocument`：后台读取、大小/二进制/编码检查、换行风格记录。
- [ ] 写 `FileEditorPane`：`NSScrollView` + `NSTextView` + 行号 ruler；编辑器区与 diff 区占位切换。
- [ ] 文件树双击接入 `onOpenFile`，窗口持有当前 `FileDocument`。
- [ ] 运行构建与手工验证。

## T8 编辑保存、未保存提示与冲突

**文件**

- 修改：`Sources/Workspace/FileDocument.swift`、`Sources/Workspace/FileEditorPane.swift`、`Sources/Workspace/WorkspaceWindowController.swift`、`Sources/Workspace/WorkspaceManager.swift`

**接口**

- 产出 `enum FileSaveError: LocalizedError { case conflict, notWritable(String) }`。
- 产出 `FileDocument.save() throws`、`reload() throws`；保存前比较 `mtime`、文件大小与打开时快照。
- 产出窗口方法：`func presentUnsavedChanges(name: String, onSave: @escaping () -> Void, onDiscard: @escaping () -> Void)`。
- 消费 l10n 键：未保存标题/正文、冲突标题/正文、保存失败。

**验收**

- [ ] ⌘S 保存写盘，成功后 `isDirty == false`，磁盘内容与编辑器一致（L3）。
- [ ] 有未保存改动时切换文件、切换工作区、关闭窗口均弹「保存 / 丢弃 / 取消」，取消中止切换（L3）。
- [ ] 打开后外部修改同一文件，再保存时弹冲突提示，选择覆盖后磁盘为编辑器内容，选择重新加载后编辑器为磁盘内容（L3）。
- [ ] 只读文件按 ⌘S 不写盘并提示（L3）。

**验证**

```bash
swift build
bash scripts/run-tests.sh
```

期望：构建成功；脚本全过；手工用例逐条通过并记录日志。

**依赖 / 规模**：T7 / M

- [ ] 实现 `FileDocument` 磁盘快照与 `save()`：临时文件 + 原子替换，保留原换行风格。
- [ ] 实现冲突检测与 `FileSaveError.conflict`。
- [ ] 编辑器绑定 `textDidChange`，更新 dirty 并刷新标题圆点。
- [ ] 窗口实现未保存三选提示，所有切换入口先查询当前文档。
- [ ] 保存成功后触发 git/文件树刷新回调（T12 接入前可为空实现）。
- [ ] 运行构建与手工验证。

## T9 git 状态列表

**文件**

- 新建：`Sources/Workspace/GitService.swift`
- 修改：`Sources/Workspace/FileExplorerPane.swift`、`Sources/Workspace/WorkspaceWindowController.swift`

**接口**

- 产出 `struct GitChange: Equatable { enum Area: String { case staged, unstaged, untracked }; let path: String; let area: Area; let status: String }`。
- 产出 `enum GitService`：`static func repositoryRoot(at path: String) -> String?`、`static func changes(in root: String) -> [GitChange]`。
- 产出 `FileExplorerPane` 方法：`func showGit(root: String?)`、`func reloadGit()`。
- 消费 `TerminalShell.run`；所有命令在后台队列执行，主线程回填。

**验收**

- [ ] git 仓库改动文件按「已暂存 / 未暂存 / 未跟踪」分组显示，状态字母与 `git status` 一致（L3）。
- [ ] 非 git 目录显示「不是 git 仓库」空状态，文件树仍可用（L3）。
- [ ] 保存文件或点刷新后列表更新（L3）。
- [ ] 大型仓库刷新不阻塞窗口拖动与输入（L3，观察无卡顿）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "GitService"
```

期望：构建成功；符号计数 ≥ 1；手工用例逐条通过。

**依赖 / 规模**：T6 / S

- [ ] 写 `GitService`：`rev-parse --show-toplevel`、`status --porcelain=v1 -z` 解析，处理重命名双路径。
- [ ] 后台队列执行，结果带回主线程；失败返回空数组并 `debugLog`。
- [ ] `FileExplorerPane` 增加 git 列表（分组标题 + 行），图标栏切换文件/git。
- [ ] 工作区切换时刷新 git 根与列表。
- [ ] 运行构建与手工验证。

## T10 git diff 查看

**文件**

- 修改：`Sources/Workspace/GitService.swift`、`Sources/Workspace/FileEditorPane.swift`、`Sources/Workspace/FileExplorerPane.swift`

**接口**

- 产出 `GitService.diff(in root: String, change: GitChange) -> String`。
- 产出 `FileEditorPane.showDiff(_ text: String)`：只读 `NSTextView`，`+` 行 `VSTheme.success`、`-` 行 `VSTheme.error`、`@@` 行 `VSTheme.syntaxKey`。
- 消费 `GitChange.area`：staged 用 `git diff --cached`，unstaged 用 `git diff`，untracked 用 `git diff --no-index /dev/null <path>`。

**验收**

- [ ] 点击 git 列表文件在编辑器区显示 diff，增删行着色正确（L3）。
- [ ] 暂存与未暂存改动分别显示对应 diff；未跟踪文件显示全新增 diff（L3）。
- [ ] 二进制文件显示「二进制文件」提示；超过 5000 行截断并提示（L3）。
- [ ] diff 视图只读，⌘S 不触发保存（L3）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "showDiff"
```

期望：构建成功；符号计数 ≥ 1；手工用例逐条通过。

**依赖 / 规模**：T9 / S

- [ ] 实现 `GitService.diff`，处理退出码 1 与二进制 `--numstat` 判定。
- [ ] `FileEditorPane` 增加 diff 模式，切换时清空编辑状态。
- [ ] git 列表点击接入 `onOpenGitDiff` 回调与 diff 渲染。
- [ ] 运行构建与手工验证。

## T11 工作区全文搜索

**文件**

- 新建：`Sources/Workspace/WorkspaceSearchService.swift`
- 修改：`Sources/Workspace/FileExplorerPane.swift`、`Sources/Workspace/FileEditorPane.swift`

**接口**

- 产出 `struct SearchHit: Equatable { let file: String; let line: Int; let text: String }`。
- 产出 `enum WorkspaceSearchService { static func search(root: String, query: String, config: WorkspaceConfig, limit: Int = 500) -> [SearchHit] }`。
- 产出 `FileExplorerPane.showSearch()`，搜索模式下输入框去抖 300ms 执行。
- 产出 `FileEditorPane.reveal(file: URL, line: Int)`：打开文件并滚动到目标行。

**验收**

- [ ] 搜索模式输入关键词返回按文件分组的结果，点击结果打开文件并定位到对应行（L3）。
- [ ] 忽略目录、二进制文件、超过 `maxFileSizeMB` 的文件不参与搜索（L3）。
- [ ] 结果超过 500 行显示截断提示；空关键词不执行（L3）。
- [ ] 搜索执行期间窗口保持可交互（L3）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "WorkspaceSearchService"
```

期望：构建成功；符号计数 ≥ 1；手工用例逐条通过。

**依赖 / 规模**：T7 / M

- [ ] 写 `WorkspaceSearchService`：递归遍历、忽略规则、逐行匹配、上限截断、取消标志。
- [ ] `FileExplorerPane` 增加搜索模式与结果 `NSOutlineView`（文件分组 + 行结果）。
- [ ] 搜索结果点击回调接入窗口，调用 `reveal(file:line:)`。
- [ ] 运行构建与手工验证。

## T12 实时监听与刷新

**文件**

- 新建：`Sources/Workspace/WorkspaceFileWatcher.swift`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift`、`Sources/Workspace/FileExplorerPane.swift`、`Sources/Workspace/WorkspaceManager.swift`

**接口**

- 产出 `@MainActor final class WorkspaceFileWatcher`：`init(root: URL, ignoredDirectories: [String])`、`func start()`、`func stop()`、`var onChange: (() -> Void)?`。
- 使用 FSEvents C API，递归监听；回调在后台线程去抖 0.5s 后切主线程；忽略路径前缀命中的事件。
- 消费 `FileExplorerPane.refresh()`、`reloadGit()`；`FileDocument.reload()`。
- 编辑器自身保存时向 watcher 设置 `suppressUntil` 时间戳，避免自写触发重载。

**验收**

- [ ] 在 Finder 或终端新建/删除文件，文件树在 1s 内自动更新，展开状态保留（L3）。
- [ ] 修改已跟踪文件后 git 列表自动更新（L3）。
- [ ] 编辑器无改动时外部修改文件，内容自动重载；有改动时不覆盖，并在保存时提示冲突（L3）。
- [ ] 在工作区执行构建产生大量文件时，窗口不出现持续卡顿（L3）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "WorkspaceFileWatcher"
```

期望：构建成功；符号计数 ≥ 1；手工用例逐条通过。

**依赖 / 规模**：T6、T8、T9 / M

- [ ] 写 `WorkspaceFileWatcher`：`FSEventStreamCreate`、`SetDispatchQueue`、`Start`/`Stop` 成对调用。
- [ ] 事件去抖、忽略前缀过滤、工作区切换时重建 stream。
- [ ] 接入文件树与 git 刷新；编辑器按 dirty 状态决定重载或标记。
- [ ] 自身保存前设置抑制窗口。
- [ ] 运行构建与手工验证。

## T13 Markdown 与图片预览

**文件**

- 新建：`Sources/Workspace/FilePreviewView.swift`
- 修改：`Sources/Workspace/FileEditorPane.swift`、`Sources/Workspace/FileExplorerPane.swift`、`Sources/Workspace/WorkspaceWindowController.swift`

**接口**

- 产出 `enum FilePreviewKind { case text, markdown, image }` 与 `static func kind(for url: URL) -> FilePreviewKind`。
- 扩展名判定：`md` / `markdown` → `.markdown`；`png` / `jpg` / `jpeg` / `gif` / `tiff` / `heic` / `webp` → `.image`；其余 → `.text`。
- 产出 `final class FilePreviewView: NSView`：`func showMarkdown(text: String, baseURL: URL?)`、`func showImage(url: URL) -> Bool`、`func clear()`。
- 产出 `FileEditorPane.showPreview(_ kind: FilePreviewKind, document: FileDocument)`；Markdown 顶部显示「预览 / 源码」切换按钮。
- 复用 `KnowledgeMarkdownView` 的 marked.js 资源定位方式（`Bundle.module.url(forResource: "marked.umd", withExtension: "js", subdirectory: "markdown")`），不直接复用其面板样式类。
- Markdown 用 `WKWebView.loadHTMLString`，`baseURL` 为文件所在目录以支持相对图片；禁止外部导航，`http/https` 链接交 `NSWorkspace.shared.open`。

**验收**

- [ ] 打开 `.md` 默认显示渲染预览；切到源码可编辑，再切回预览显示最新内容（L3）。
- [ ] `png/jpg/jpeg/gif/tiff/heic/webp` 显示图片；损坏图片显示加载失败提示（L3）。
- [ ] 超过 20MB 的图片显示大小提示，不加载（L3）。
- [ ] 预览内点击 http/https 链接用系统浏览器打开，WebView 本身不跳转（L3）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "FilePreviewView"
```

期望：构建成功；符号计数 ≥ 1；手工用例逐条通过。

**依赖 / 规模**：T7 / M

- [ ] 实现 `FilePreviewKind` 判定与扩展名集合。
- [ ] 新建 `FilePreviewView`：`WKWebView` Markdown 渲染与 `NSImageView` 图片显示，两套视图按需创建。
- [ ] `FileEditorPane` 增加预览模式与「预览 / 源码」切换，Markdown 源码编辑与预览内容同步。
- [ ] 文件树打开文件时按类型路由，图片不进入文本编辑器。
- [ ] 图片大小与加载失败提示接入 l10n。
- [ ] 运行构建与手工验证。

## T14 i18n、文档、打包与回归

**文件**

- 修改：`Sources/Resources/zh-Hans.json`、`en.json`、`Sources/Core/L10nKeys.swift`（生成）、`.claude/docs/architecture/terminal.md`、`AGENTS.md`、`.claude/CLAUDE.md`、`README.md`、`README.zh.md`、`.agent/status.md`

**接口**

- 无新增接口；清理未使用的临时 l10n 键与调试日志。

**验收**

- [ ] 所有新增用户可见文本只存在于两个语言 JSON，`gen-l10n.py --check` 与 `check-l10n-contract.py` 通过（L1）。
- [ ] `swift build` 与 `bash scripts/run-tests.sh` 通过（L1/L2）。
- [ ] `bash scripts/package-utility.sh` 产物可启动，工作区窗口、终端、文件编辑、git 面板、Markdown/图片预览逐项手工回归（L3）。
- [ ] 文档记录工作区存储、迁移、监听与编辑器约束；`.agent/status.md` 更新完成项与证据级别（L1）。

**验证**

```bash
swift build
bash scripts/run-tests.sh
bash scripts/package-utility.sh
```

期望：构建成功；脚本全过；打包产物启动无 `unable to find bundle` 错误。

**依赖 / 规模**：T4、T5、T10、T12、T13 / S

- [ ] 汇总全部新键，补齐中英文，运行生成器。
- [ ] 删除临时 debugLog 与未使用键。
- [ ] 更新 `terminal.md` 与 `CLAUDE.md` 不变量（工作区模型、监听、编辑器限制）。
- [ ] 更新 README 功能段落与快捷键说明。
- [ ] 跑完整验证与打包，记录 L3 证据（截图、日志、待验项）。
- [ ] 等用户确认后再提交，不自动 commit。
