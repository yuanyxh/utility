# 终端改造为工作区任务清单

方案、非目标、存储与风险见同目录 `plan.md`。按依赖顺序执行，每个任务结束都跑验证命令。未获用户明确允许不提交。

- [x] T1 工作区模型、配置、存储与迁移（依赖：无，规模：M）
- [x] T2 `WorkspaceManager` 会话编排（依赖：T1，规模：M）
- [x] T3 工作区窗口骨架与入口切换（依赖：T2，规模：M）
- [x] T4 工作区侧栏 CRUD（依赖：T3，规模：S）
- [x] T5 主终端与子终端面板（依赖：T3，规模：M）
- [x] T6 文件树与路径规则（依赖：T3，规模：M）
- [x] T7 编辑器与行号（依赖：T6，规模：M）
- [x] T8 保存、冲突与未保存提示（依赖：T7，规模：M）
- [x] T9 语法高亮（依赖：T7，规模：M）
- [x] T10 git 状态与 diff（依赖：T6，规模：M）
- [x] T11 Markdown 与图片预览（依赖：T7，规模：M）
- [ ] T12 i18n、文档、打包与回归（依赖：T4/T5/T9/T10/T11，规模：S）

## 检查点 A（T1-T2）

- [x] `swift build` 通过。
- [x] fixture 迁移、往返、重新归属、恢复计划四条 CLI 断言全部通过。
- [x] `terminal-sessions.json` 仍可被旧结构解码。

## 检查点 B（T3-T5，MVP）

- [x] 新窗口承载工作区、主终端、子终端与右侧占位。
- [x] 热键、菜单、关闭隐藏、Dock 图标、失焦兜底行为与旧窗口一致。
- [x] 重启恢复工作区与分割条尺寸。
- [x] 旧 `TerminalManager` / `TerminalWindowController` 已移废纸篓且无编译引用。

## 检查点 C（T6-T8）

- [ ] 目录树、编辑器、行号可用。
- [ ] 保存、未保存提示、外部修改冲突三条路径可用。
- [ ] 编辑中 `kill -9` 后重启能恢复草稿，原文件未被改写。
- [ ] 外部改动：干净文件自动重载，脏文件弹横幅，删除后保存走另存为。

## 检查点 D（T9-T11）

- [ ] 高亮、git、预览全部可用，超限降级正确。

## 检查点 E（T12）

- [ ] 全量验证命令通过，打包产物可启动。

---

## T1 工作区模型、配置、存储与迁移

**文件**

- 新建：`Sources/Workspace/WorkspaceModel.swift`
- 新建：`Sources/Workspace/WorkspaceStore.swift`
- 新建：`Sources/Workspace/WorkspaceMigration.swift`
- 新建：`Sources/CLI/WorkspaceCheckCommand.swift`
- 修改：`Sources/Terminal/TerminalSessionStore.swift:3-27`
- 修改：`Sources/Core/ConfigTypes.swift:30-64`、`Sources/Core/ConfigTypes.swift:87-113` 后
- 修改：`Sources/Resources/default-config.yaml:346-355`
- 修改：`Sources/CLI/UtilityCLI.swift:11-17`
- 修改：`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`
- 生成：`Sources/Core/L10nKeys.swift`（运行 `scripts/gen-l10n.py`，不手改）

**接口**

- 产出 `WorkspaceDocument`：`version: Int = 1`、`selectedWorkspaceID: String?`、`layout: WindowLayout`、`workspaces: [Workspace]`。
- 产出 `Workspace`：`id: String`、`name: String`、`path: String`、`mainSessionID: String?`、`subSessionIDs: [String]`、`selectedSubSessionID: String?`、`lastOpenedRelativePath: String?`、`createdAt: Date`。
- 产出 `WindowLayout`：`sidebarWidth = 220`、`rightPaneWidth = 580`、`fileListWidth = 200`、`subTerminalHeight = 260`、`subListWidth = 180`，均为 `Double`。
- 产出 `TerminalRole: String, Codable`：`main` / `sub`。
- 产出 `WorkspaceStore.init(fileURL:)`、`load() throws -> WorkspaceDocument?`、`save(_:) throws`、`backupSessionsIfNeeded()`；解码失败时把原文件改名为 `.corrupt-<timestamp>` 后抛错。
- 产出 `WorkspaceMigration.plan(sessions: [StoredTerminalSession], now: Date) -> WorkspaceDocument`，纯函数。
- 产出 `StoredTerminalSession.workspaceID: String?`、`role: TerminalRole?`，`init` 默认 `nil`，解码用 `decodeIfPresent`。
- 产出 `WorkspaceConfig`：`showHiddenFiles = false`、`maxFileSizeMB = 5`、`imagePreviewMaxSizeMB = 20`、`ignoredDirectories: [String] = []`；`AppConfig.workspace` 同样三处默认一致。
- 产出 `WorkspaceCheckCommand`：`--sessions <path>`、`--dry-run`、`--roundtrip <path>`、`--state <path>`。

**验收**

- [x] 3 条旧会话、2 个 cwd 的 fixture 经 `--dry-run` 输出 2 个工作区，最早 `createdAt` 为主终端（L2）。
- [x] `--roundtrip` 输出 `roundtrip: ok`，`layout` 与选中项保留（L2）。
- [x] `default-config.yaml`、属性初值、`decodeIfPresent` 兜底三处一致（L1）。

**验证**

```bash
swift build
.build/debug/utility workspace-check --sessions /tmp/ws-fixture.json --dry-run
.build/debug/utility workspace-check --roundtrip /tmp/ws-roundtrip.json
python3 scripts/gen-l10n.py --check
```

**依赖 / 规模**：无 / M

- [x] 写 `WorkspaceModel.swift`：模型、角色、布局钳制函数、`WorkspaceDocument.normalized()`。
- [x] 写 `WorkspaceStore.swift`：原子写、ISO8601、`.sortedKeys`；损坏文件改名并抛错。
- [x] 写 `WorkspaceMigration.swift`：按标准化 `cwd` 分组，同组最早为主终端，其余按时间排子终端。
- [x] 扩展 `StoredTerminalSession` 可选字段，`backend` 继续必写 `"tmux"`。
- [x] 增加 `WorkspaceConfig` 与 `default-config.yaml` 的 `workspace` 段。
- [x] 写 `WorkspaceCheckCommand` 并注册到 `UtilityCLI`，补齐中英文案与生成器。
- [x] 构造 `/tmp/ws-fixture.json` 跑三条命令，贴输出。

## T2 `WorkspaceManager` 会话编排

**文件**

- 新建：`Sources/Workspace/WorkspaceManager.swift`
- 修改：`Sources/Workspace/WorkspaceMigration.swift`（新增重新归属与恢复计划纯函数）
- 修改：`Sources/CLI/WorkspaceCheckCommand.swift`（新增 `--reattach`、`--restore`）

**接口**

- 消费：T1 的 `WorkspaceDocument`、`WorkspaceStore`、`WorkspaceMigration.plan`、`TerminalSessionStore`。
- 产出 `WorkspaceReattribution.apply(document:sessions:) -> WorkspaceDocument`：按 id 归属，未命中的按 `cwd` 归入已有工作区或新建。
- 产出 `WorkspaceRestorePlan.make(document:liveIDs:) -> WorkspaceRestorePlan`：过滤不存活会话，主终端缺失时标记用工作区路径重建。
- 产出 `WorkspaceState`：`workspaces`、`selectedWorkspaceID`、`mainSession: TerminalSession?`、`subSessions: [TerminalSession]`、`selectedSubSessionID`、`layout`。
- 产出 `WorkspaceManager`（`@MainActor` 单例）：`state`、`observer: WorkspaceManagerObserving?`、`mainTerminalView()`、`subTerminalView(sessionID:)`、`createWorkspace(path:)`、`selectWorkspace(id:)`、`renameWorkspace(id:name:)`、`removeWorkspace(id:)`、`addSubSession()`、`selectSubSession(id:)`、`closeSubSession(id:)`、`updateLayout(_:)`、`persist()`、`restoreIfNeeded()`。
- 产出 `protocol WorkspaceManagerObserving: AnyObject { func workspaceStateDidChange() }`。
- 迁移 `TerminalManager.swift:86-157` 的创建/选择/关闭、`166-209` 的恢复、`222-268` 的通知与去重、`293-308` 的路径轮询、`326-342` 的持久化。

**验收**

- [x] `--reattach` 把只带 `cwd` 的旧会话重新归入已有工作区（L2）。
- [x] `--restore` 只保留 `liveIDs` 内会话，不存活的主终端被标记重建（L2）。
- [x] `WorkspaceManager` 构建通过，会话创建、恢复、持久化与通知判据复用现有 `TerminalManager`（L1）。

**验证**

```bash
swift build
.build/debug/utility workspace-check --reattach /tmp/ws-old-sessions.json
.build/debug/utility workspace-check --restore /tmp/ws.json --live a1b2c3d4
grep "\\[Workspace\\]" ~/.cache/utility/debug.log | tail -5
```

**依赖 / 规模**：T1 / M

- [x] 写重新归属与恢复计划纯函数，先让 `--reattach` / `--restore` 断言通过。
- [x] 写 `WorkspaceManager` 的会话创建、选择、关闭与视图持有。
- [x] 迁移通知抑制与 3 秒去重逻辑，保持 `TerminalManager.swift:241-268` 的判据。
- [x] 迁移 `persist()`：同时写 `workspaces.json` 与 `terminal-sessions.json`，保留未恢复条目。
- [x] 写 `restoreIfNeeded()`：`liveIDs` 过滤、按工作区恢复主/子会话、预置视图尺寸。
- [x] 跑构建与两条 CLI 断言。

## T3 工作区窗口骨架与入口切换

**文件**

- 新建：`Sources/Workspace/WorkspaceWindowController.swift`
- 新建：`Sources/Workspace/WorkspaceSplitView.swift`
- 修改：`Sources/Workspace/WorkspaceManager.swift`（新增 `showWindow`、`toggleWindow`、`attach(window:)`、`shutdown()`）
- 修改：`Sources/App/AppDelegate.swift:73-77`、`127-132`、`303-309`
- 修改：`Sources/Core/MenuBarManager.swift:152-154`
- 移废纸篓：`Sources/Terminal/TerminalManager.swift`、`Sources/Terminal/TerminalWindowController.swift`（本任务验收通过后）

**接口**

- 消费：T2 的 `WorkspaceManager.state`、`mainTerminalView()`、`subTerminalView(sessionID:)`。
- 产出 `WorkspaceWindowController`：`reload(state:)`、`attachMain(view:)`、`attachSub(view:sessionID:)`、`detachTerminal(id:)`、`apply(layout:)`、`currentLayout`、`terminalContentSize`、`wantsVisible`、`showEmptyState(message:)`。
- 产回调：`onSelectWorkspace`、`onCreateWorkspace`、`onRenameWorkspace`、`onRemoveWorkspace`、`onAddSubSession`、`onSelectSubSession`、`onCloseSubSession`、`onLayoutChanged`。
- 产出 `WorkspaceSplitView: NSSplitView`：覆写 `dividerColor` 为 `VSTheme.separator`，`dividerThickness = 1`，持有各栏最小尺寸。

**验收**

- [x] 启动显示三栏窗口与底部占位，四条分割线可拖，重启后尺寸恢复（L3）。
- [x] 热键显隐、菜单入口、关闭只隐藏、`AppActivation` 切换 Dock 图标、accessory 失焦兜底与旧行为一致（L3）。
- [x] 首次启动日志出现 `[Workspace] migrated sessions=<n> workspaces=<m>`，生成 `workspaces.json` 与 `terminal-sessions.json.bak`（L2，`~/.cache/utility/debug.log`）。
- [ ] 布局非法值回退默认且不崩溃（L2，手改 `workspaces.json` 的 `layout`）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "WorkspaceWindowController"
grep -E "\\[Workspace\\]|activation policy" ~/.cache/utility/debug.log | tail -10
```

**依赖 / 规模**：T2 / M

- [ ] 写 `WorkspaceSplitView`，先接入三栏与底部占位。
- [ ] 写窗口控制器：布局应用一次、`isApplyingLayout` 防回写、拖动结束 300ms 去抖写盘。
- [ ] 迁移 `TerminalWindowController.swift:19-55` 的窗口配置与 `248-311` 的关闭/失焦逻辑。
- [ ] `AppDelegate` 启动、热键、退出改接 `WorkspaceManager`；`MenuBarManager` 入口同步。
- [ ] 手测 L3 清单后，把旧两个文件移到废纸篓并重跑构建。

## T4 工作区侧栏 CRUD

**文件**

- 新建：`Sources/Workspace/WorkspaceSidebarView.swift`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift`
- 修改：`Sources/Workspace/WorkspaceManager.swift`

**接口**

- 消费：T2 的 `createWorkspace(path:)`、`renameWorkspace(id:name:)`、`removeWorkspace(id:)`、`state.workspaces`。
- 产出 `WorkspaceSidebarView.reload(workspaces:selectedID:)`；回调 `onCreate`、`onSelect(id:)`、`onRename(id:name:)`、`onRemove(id:)`。
- 行内容复用 `TerminalWindowController.swift:364-433` 的标题/副标题/关闭按钮布局思路。

**验收**

- [x] 点 + 用 `NSOpenPanel` 只选目录，新建后自动选中，主终端 cwd 正确（L3）。
- [x] 双击重命名，空名称拒绝，重启保留（L3）。
- [x] 移除确认文案含会话数量与「不删除磁盘文件」，确认后结束会话并选中相邻工作区（L3）。
- [x] 路径缺失标红，重复路径拒绝（L3）。

**验证**

```bash
swift build
.build/debug/utility workspace-check --state ~/.config/utility/workspaces.json
```

**依赖 / 规模**：T3 / S

- [ ] 写侧栏列表与 + 按钮，先接只读展示。
- [ ] 接 `NSOpenPanel` 新建与自动选中。
- [ ] 双击重命名与空名称校验。
- [ ] 移除确认、会话清理、相邻选中。
- [ ] 路径存在性检查与重复拒绝。

## T5 主终端与子终端面板

**文件**

- 新建：`Sources/Workspace/TerminalHostView.swift`
- 新建：`Sources/Workspace/SubTerminalPane.swift`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift`

**接口**

- 消费：T2 的 `mainTerminalView()`、`subTerminalView(sessionID:)`、`addSubSession()`、`selectSubSession(id:)`、`closeSubSession(id:)`。
- 产出 `TerminalHostView.attach(view:)`、`detach()`、`showEmptyState(message:)`、`terminalContentSize`。
- 产出 `SubTerminalPane.reload(sessions:selectedID:)`、`attach(view:)`、`detach()`、`terminalContentSize`。
- attach 前按容器尺寸预置 frame，顺序固定为：移除旧父视图 → 加约束 → `layoutIfNeeded` → `makeFirstResponder`（`terminal.md:10`）。

**验收**

- [x] 主终端 cwd 为工作区路径；新建多个子终端 cwd 相同，可切换、关闭（L3）。
- [ ] 达到 `terminal.maxSessions` 时新增返回失败并只通知一次（L2 日志）。
- [x] 底部高度可拖并持久化（L3）。
- [x] 标题变化只刷新对应行（L3）。
- [ ] 3 个工作区交替切换后只保留当前工作区视图；静止 10 分钟 CPU 与 WindowServer 不高于切换前基线（L3，对照 2026-10-30 的 5.1% → 23.7% 数据）。

**验证**

```bash
swift build
tmux -L utility list-panes -a -F "#{session_name} #{pane_current_path}"
```

**依赖 / 规模**：T3 / M

- [ ] 写 `TerminalHostView`，复用 `showTerminal` 的约束方式。
- [ ] 写 `SubTerminalPane`：上部内容、下部竖向列表 180pt、可拖高度。
- [ ] 接新建、切换、关闭子终端；标题变化只 reload 单行。
- [ ] 切换工作区时先 detach 旧会话，再 attach 新会话。
- [ ] 跑 3 工作区 CPU 对照并记录数字。

## T6 文件树与路径规则

**文件**

- 新建：`Sources/Core/PathRules.swift`
- 新建：`Sources/Workspace/FileTreeModel.swift`
- 新建：`Sources/Workspace/FileExplorerPane.swift`
- 新建：`Sources/Workspace/WorkspaceActivityBar.swift`
- 修改：`Sources/Scanner/ScannerConfig.swift:52-55`（改为引用 `PathRules`）
- 修改：`Sources/Workspace/WorkspaceWindowController.swift`
- 修改：`Sources/CLI/WorkspaceCheckCommand.swift`（新增 `--tree`）

**接口**

- 产出 `PathRules.skippedDirNames: Set<String>`（迁移 `ScannerConfig.swift:53-56` 的 15 项）与 `PathRules.shouldSkip(name:)`、`PathRules.shouldInclude(path:)`。
- 产出 `FileTreeModel.init(root: URL, showHiddenFiles: Bool)`、`func loadChildren(of:) async -> [FileNode]`、`func invalidate()`。
- 产出 `FileExplorerPane.reload(root:)`；回调 `onOpenFile(URL)`；`WorkspaceActivityBar.onSelectMode(.files/.git)`。
- 产出 CLI `--tree <dir>` 输出 `tree: <count>`。

**验收**

- [x] 忽略 `.git`、`node_modules`、`.build`、`DerivedData`、`Pods`、`dist`、`next`（L2，`--tree` 断言）。
- [x] 懒加载展开、空目录与无权限提示、双击打开文件（L3）。
- [ ] 隐藏文件受 `workspace.showHiddenFiles` 控制（L3）。
- [ ] 单目录超过 2000 条只显示前 2000 条并提示（L3）。

**验证**

```bash
swift build
.build/debug/utility workspace-check --tree /tmp/ws-tree-fixture
```

**依赖 / 规模**：T3 / M

- [ ] 抽 `PathRules`，让 `ScannerConfig` 委托，跑构建确认索引行为不变。
- [ ] 写 `FileTreeModel` 的后台枚举、目录优先、`localizedStandardCompare` 排序。
- [ ] 写 `NSOutlineView` 懒加载与展开占位行。
- [ ] 写 ActivityBar 与 Files/Git 切换骨架。
- [ ] 接双击打开文件回调，先只打印路径。

## T7 编辑器与行号

**文件**

- 新建：`Sources/Workspace/FileDocument.swift`
- 新建：`Sources/Workspace/FileEditorPane.swift`
- 新建：`Sources/Workspace/LineNumberRulerView.swift`
- 修改：`Sources/Core/Styles/VSTheme.swift`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift`

**接口**

- 产出 `FileDocument.load(url:maxBytes:) -> FileLoadResult`，结果含 `.text(FileDocument)`、`.tooLarge`、`.binary`、`.unsupportedEncoding`、`.unreadable`。
- 产出 `FileDocument.text`、`isDirty`、`encoding`、`lineEnding`、`save() throws`、`reload() throws`。
- 产出 `FileEditorPane.open(url:)`、`close()`、`markDirty`、`onDirtyChanged`。
- 产出 `LineNumberRulerView.init(textView:)`，只枚举可见 glyph range。
- `VSTheme` 增加 `editorBackground`、`gutterBackground`、`gutterText`、`editorFont(size:)`。

**验收**

- [x] 文本文件可编辑，行号与内容对齐，滚动同步（L3）。
- [ ] 二进制、非 UTF-8、超 5MB 文件只读提示（L3）。
- [ ] 切换文件不残留旧内容（L3）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "LineNumberRulerView"
```

**依赖 / 规模**：T6 / M

- [ ] 写 `FileDocument` 读取、编码识别、CRLF/BOM 记录。
- [ ] 写编辑器视图并复用 `ConfigEditorWindowController.swift:124-150` 的 `NSTextView` 配置。
- [ ] 写行号标尺，滚动与编辑后局部失效。
- [ ] 接文件树双击到编辑器，处理四类降级提示。

## T8 保存、冲突与未保存提示

**文件**

- 新建：`Sources/Workspace/EditorDraftStore.swift`
- 修改：`Sources/Workspace/FileDocument.swift`
- 修改：`Sources/Workspace/FileEditorPane.swift`
- 修改：`Sources/Workspace/WorkspaceManager.swift`、`WorkspaceWindowController.swift`
- 修改：`Sources/App/AppDelegate.swift:84-114`

**接口**

- 产出 `FileDocument.diskFingerprint: (size: Int64, mtime: Date)`、`save(overwriteExternal:) throws`。
- 产出 `FileEditorPane.confirmClose() -> Bool`：保存 / 丢弃 / 取消三选。
- 产出 `WorkspaceManager.confirmTermination() -> Bool`；`AppDelegate.applicationShouldTerminate` 在修改 `terminateRequested` 之前调用，取消时返回 `.terminateCancel`。
- 产出 `EditorDraft: Codable`：`url`、`text`、`encoding`、`lineEnding`、`fingerprint`、`savedAt`。
- 产出 `EditorDraftStore.init(directory: URL = AppPaths.cacheDir.appendingPathComponent("editor-drafts"))`、`save(_:) throws`、`loadAll() -> [EditorDraft]`、`delete(for url: URL)`、`evict(maxCount: Int = 20, maxBytes: Int = 50 * 1024 * 1024)`。
- 产出 `WorkspaceManager.pendingDrafts() -> [EditorDraft]` 与恢复三选：恢复 / 丢弃 / 对比。
- 落盘规则：临时文件 + `rename` 原子替换；单文件 JSON 以原路径哈希命名；解码失败改名 `.corrupt-<timestamp>`。
- 产出 `ExternalChange`：`.unchanged` / `.modified` / `.deleted`；`FileDocument.checkExternalChange() -> ExternalChange`、`reloadFromDisk()`、`loadedContentHash: String`。
- 触发点固定为：`NSApplication.didBecomeActiveNotification`、切换文件或工作区前、保存前；不挂 FSEvents。
- 行为：无本地改动且 `.modified` 自动重载并保留滚动位置；有本地改动弹顶部横幅「重新加载 / 保留我的 / 对比」；`.deleted` 保留缓冲，保存改走 `NSSavePanel`。
- 保存前比对 `loadedContentHash` 与磁盘内容哈希，指纹相同但内容变化同样判冲突。

**验收**

- [x] ⌘S 原子写盘，保留 BOM 与 CRLF，`isDirty` 复位（L2 + L3）。
- [ ] 有改动时切换文件/工作区/退出弹三选，取消中止操作（L3）。
- [ ] 外部修改后保存弹冲突三选；覆盖或重新加载后内容正确（L3）。
- [ ] 只读文件保存失败并保持 dirty（L3）。
- [ ] 编辑中 `kill -9` 后重启弹恢复，内容与最后一次快照一致，原文件未被改写（L3）。
- [x] 正常保存或选择丢弃后 `editor-drafts` 无残留（L2）。
- [x] 草稿损坏只影响自身，其他草稿可恢复（L2）。
- [x] 打开的文件被外部修改且本地无改动，切回窗口自动重载，滚动位置保留（L3）。
- [ ] 本地有改动时外部修改只弹横幅，不打断输入；三个动作结果正确（L3）。
- [ ] 文件被外部删除或改名后缓冲保留，⌘S 打开另存为面板（L3）。
- [x] size/mtime 相同但内容变化，保存前仍判冲突（L2）。

**验证**

```bash
swift build
bash scripts/run-tests.sh
ls ~/.cache/utility/editor-drafts/ | wc -l
```

**依赖 / 规模**：T7 / M

- [x] 加 `fingerprint` 与外部修改检测。
- [x] 加 `ExternalChange` 与 `checkExternalChange`，接 `didBecomeActive`、切换前、保存前三个触发点。
- [x] 干净文档自动重载并保留滚动；脏文档顶部横幅三选。
- [x] 删除或改名分支：保留缓冲，保存走 `NSSavePanel`。
- [x] 保存前比对内容哈希，覆盖 mtime 被还原的场景。
- [x] 保存保留 BOM/CRLF，失败保持 dirty。
- [x] 实现文件/工作区切换三选。
- [x] 写 `EditorDraftStore`：临时文件 + `rename` 原子替换，损坏改名，20 份 / 50 MB 淘汰。
- [x] 脏缓冲 2 秒去抖快照；保存、丢弃、关闭文档时删除对应草稿。
- [x] 启动扫描草稿并弹「恢复 / 丢弃 / 对比」，恢复只进编辑器，不写回原文件。
- [x] 在 `applicationShouldTerminate` 最前面接 `confirmTermination`，确认取消路径返回 `.terminateCancel`。

## T9 语法高亮

**文件**

- 新建：`Sources/Workspace/SyntaxDefinitions.swift`
- 新建：`Sources/Workspace/SyntaxHighlighter.swift`
- 修改：`Sources/Workspace/FileEditorPane.swift`
- 修改：`Sources/CLI/WorkspaceCheckCommand.swift`（新增 `--highlight`）

**接口**

- 产出 `SyntaxDefinition`：`keywords`、`lineComment`、`blockComment`、`stringDelimiters`、`numberPattern`、`caseInsensitive`。
- 产出 `SyntaxDefinitions.definition(forExtension:) -> SyntaxDefinition?`，覆盖 Swift、JS、TS、JSX、TSX、JSON、YAML、Markdown、Shell、Python、HTML、CSS。
- 产出 `SyntaxHighlighter.apply(text:visibleRange:definition:) -> [(NSRange, NSColor)]`，纯函数便于 CLI 断言。
- 产出 CLI `--highlight <file>` 输出 `highlight: <lines>`。

**验收**

- [x] 10 类语言的关键字、字符串、注释、数字着色正确（L2，`--highlight`）。
- [x] 可见 300 行着色 ≤8ms，输入可感知延迟 <50ms（L2 日志）。
- [ ] 大文件、超长行自动降级纯文本（L3）。

**验证**

```bash
swift build
.build/debug/utility workspace-check --highlight /tmp/ws-highlight-fixture.swift
```

**依赖 / 规模**：T7 / M

- [x] 写 `SyntaxDefinitions` 与 12 种扩展名映射。
- [x] 写纯函数高亮，先用 `--highlight` 断言四类 token。
- [x] 接编辑器：只取可见范围上下各 200 行，编辑 100ms / 滚动 50ms 去抖。
- [x] 着色时挂起 undo 注册，结束后恢复；`hasMarkedText` 跳过。
- [x] 超 1MB 或 2 万行关闭高亮。

## T10 git 状态与 diff

**文件**

- 新建：`Sources/Core/ProcessRunner.swift`
- 新建：`Sources/Workspace/GitService.swift`
- 新建：`Sources/Workspace/GitStatusModel.swift`
- 新建：`Sources/Workspace/GitPane.swift`
- 新建：`Sources/Workspace/DiffView.swift`
- 修改：`Sources/Workspace/FileExplorerPane.swift`、`FileEditorPane.swift`
- 修改：`Sources/CLI/WorkspaceCheckCommand.swift`（新增 `--git`）

**接口**

- 产出 `ProcessRunner.run(executable:arguments:workingDirectory:timeout:maxBytes:) async throws -> ProcessResult`，不经 shell。
- 产出 `GitService.isRepository(at:) async -> Bool`、`status(at:) async throws -> [GitFileStatus]`、`diff(at:path:) async throws -> String`。
- 产出 `GitFileStatus`：`path`、`staged`、`unstaged`、`untracked`、`binary`。
- 产出 CLI `--git <dir>` 输出 `git: <n> files`。

**验收**

- [x] staged / unstaged / untracked 分组与 `git status --porcelain=v1 -z` 一致（L2）。
- [ ] 点击文件显示着色 diff，增删行颜色正确（L3）。
- [ ] 非仓库空状态、删除/重命名/二进制/无 HEAD 场景正确（L3）。
- [ ] 大型仓库刷新不阻塞窗口（L3）。

**验证**

```bash
swift build
.build/debug/utility workspace-check --git /tmp/ws-git-fixture
```

**依赖 / 规模**：T6 / M

- [x] 写 `ProcessRunner`：超时、输出上限、退出码与 stderr 捕获。
- [x] 写 `GitService` 三条命令，status 超时 5 秒、diff 超时 10 秒、输出上限 2MB/5000 行。
- [x] 写 `GitStatusModel` 解析 `-z` 输出与重命名条目。
- [x] 写 `GitPane` 与 `DiffView`，保存后与手动刷新触发，400ms 去抖。
- [x] 接 ActivityBar 切换与文件点击。

## T11 Markdown 与图片预览

**文件**

- 新建：`Sources/Components/MarkdownPreviewView.swift`
- 新建：`Sources/Workspace/ImagePreviewView.swift`
- 修改：`Sources/Knowledge/KnowledgeMarkdownView.swift:17-21`、`130-160`
- 修改：`Sources/Workspace/FileEditorPane.swift`

**接口**

- 产出 `MarkdownPreviewView.render(markdown:baseURL:)`，内部继续用 `Bundle.module` 的 `marked.umd.js`。
- 产出 `ImagePreviewView.load(url:) async -> Result<NSImage, ImagePreviewError>`。
- `KnowledgeMarkdownView` 改为持有 `MarkdownPreviewView`，对外接口 `render(_:)` 不变。

**验收**

- [ ] `.md` 默认源码，可切预览，预览与源码同步（L3）。
- [ ] png/jpg/jpeg/gif/tiff/heic/webp 显示；超 20MB 与损坏图片提示（L3）。
- [ ] 远程资源被 CSP 阻止，链接交系统浏览器（L3）。

**验证**

```bash
swift build
strings .build/debug/utility | grep -c "ImagePreviewView"
```

**依赖 / 规模**：T7 / M

- [x] 抽 `MarkdownPreviewView`，让知识面板先复用并通过构建。
- [x] 加 `baseURL` 与 CSP：只允许 `file:` / `data:` 图片与内联样式脚本。
- [x] 写图片预览：ImageIO 缩略到最长边 4096px，20MB 上限。
- [x] 在编辑器顶部加 Preview/Source 切换。

## T12 i18n、文档、打包与回归

**文件**

- 修改：`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`
- 生成：`Sources/Core/L10nKeys.swift`
- 修改：`.claude/docs/architecture/terminal.md`
- 新建：`.claude/docs/architecture/workspace.md`
- 修改：`CLAUDE.md`（架构文档表新增 workspace.md）
- 修改：`AGENTS.md`、`README.md`、`README.zh.md`

**接口**

- 消费：T1-T11 全部用户可见文案键。
- 产出：`gen-l10n.py --check` 与 `check-l10n-contract.py` 通过；文档写清工作区存储、迁移、只挂载当前工作区与 CSI 限制。

**验收**

- [x] `gen-l10n.py --check`、`check-l10n-contract.py` 通过（L1）。
- [x] `swift build`、`run-tests.sh`、`package-utility.sh` 通过，打包产物可启动（L1/L2）。
- [ ] 中英文切换文案完整；工作区、终端、文件、git、预览逐项回归（L3）。

**验证**

```bash
swift build
bash scripts/run-tests.sh
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
bash scripts/package-utility.sh
```

**依赖 / 规模**：T4、T5、T9、T10、T11 / S

- [x] 补齐两个语言 JSON 与生成器。
- [x] 更新 `terminal.md`，新建 `workspace.md`（含 `editor-drafts` 路径、2 秒去抖、20 份 / 50 MB 淘汰与恢复语义），同步 `CLAUDE.md` 文档表。
- [x] 更新 README 与 AGENTS 的相关说明。
- [ ] 按 plan.md 的 L3 清单逐项手测并记录证据级别。
- [x] 跑全量验证与打包，贴退出码与输出尾部。
