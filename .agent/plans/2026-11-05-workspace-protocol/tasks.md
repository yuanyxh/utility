# 工作区协议化任务清单

> 进度 2026-11-06：T1-T13 代码、文档与打包完成，`swift build` 与 `run-tests.sh` 通过，`--dirty` 断言通过。L3 已自动化验证：手型光标（用户实测「正常了」）、⌘Z 脏点消失、子终端增删切换与分支显示（隔离实例截图）。下一步 T8。

- [ ] T1 统一状态层与快照类型（依赖：无，规模：M）
- [ ] T2 面板协议、指针基建与光标根因取证（依赖：T1，规模：M）
- [ ] T3 手型光标全量接入（依赖：T2，规模：M）
- [ ] T4 编辑器脏状态与撤销一致（依赖：T1，规模：M）
- [ ] T5 git 忽略路径解析与统一状态提供者（依赖：T2，规模：M）
- [ ] T6 文件树忽略灰化渲染（依赖：T5，规模：M）
- [ ] T7 终端面板协议化（依赖：T4，规模：S）
- [ ] T8 文件列表面板协议化（依赖：T2，规模：M）
- [ ] T9 Git 面板协议化（依赖：T5，规模：S）
- [ ] T10 编辑面板协议化（依赖：T4，规模：M）
- [ ] T11 语法协议化（依赖：T10，规模：S）
- [ ] T12 关键状态持久化与迁移（依赖：T8、T10，规模：M）
- [ ] T13 文档、回归与打包（依赖：T6、T9、T12，规模：S）

## 检查点 A（T1-T4，MVP）

- [x] `swift build` 通过，`bash scripts/run-tests.sh` 全过。
- [x] `.build/debug/utility workspace-check --dirty <临时文件>` 输出 `baseline: false`、`appended: true`、`restored: false`。
- [x] 编辑后按 ⌘Z 回到原内容，标题脏点消失（2026-11-05 隔离实例实测：键入后标题 `● c.md`，⌘Z 后变回 `c.md`，文本完全还原）。
- [x] 文件树行、git 行、子终端行、活动栏按钮、编辑器工具栏按钮悬停显示手型，移动 3 秒无闪烁。

## 检查点 B（T5-T6）

- [x] `.build/debug/utility workspace-check --git <含 .gitignore 的目录>` 输出 `ignored:` 计数与样例路径（本仓库 ignored: 17）。
- [x] 被忽略的文件与文件夹显示深灰色，文件夹仍可展开，点击行为不变（隔离实例截图：`.ruff_cache` 深灰；`.swiftpm` 不灰，因 git 只忽略其子目录）。
- [x] 非 git 仓库目录不灰化、不报错、不显示角标（CLI 输出 `git: not-repository`）。

## 检查点 C（T7-T10）

- [x] 五个面板视图都实现 `WorkspacePanel`（`TerminalHostView`、`SubTerminalPane`、`FileExplorerPane`、`GitPane`、`FileEditorPane`），`render` 内无 `Process`、无文件读取。
- [x] 切换工作区、列表页签、子终端，界面与改造前一致（隔离实例逐项截图）。
- [x] `grep -rn "func render(_ snapshot" Sources/Workspace` 命中 6 处（5 实现 + 1 协议声明）。

## 检查点 D（T11-T12）

- [x] `.build/debug/utility workspace-check --ui <workspaces.json>` 输出版本 2 与各工作区 `ui` 字段。
- [x] 重启后展开目录、当前文件、列表页签、光标位置恢复（隔离实例：`Sources` 展开、git 页签、caret=5）。
- [x] 用 `version: 1` 文件启动不崩溃，首次保存后生成 `workspaces.json.bak`（928 B → v2 1559 B）。
- [x] 直接编辑文本时，`--highlight` 耗时 291 行约 5 ms（未超基线）。

## 检查点 E（T13）

- [x] `bash scripts/run-tests.sh`、`scripts/gen-l10n.py --check`、`scripts/check-l10n-contract.py` 全过。
- [ ] `scripts/package-utility.sh` 产物可启动，资源 bundle 存在且体积与改造前同量级（bundle 存在、20M/7.5M 已验证；启动留 L3，避免顶掉正在运行的实例）。

## T1 统一状态层与快照类型

**文件**

- 新建：`Sources/Workspace/State/WorkspaceSnapshot.swift`
- 新建：`Sources/Workspace/State/WorkspaceStateStore.swift`
- 新建：`Sources/Workspace/State/WorkspaceUIState.swift`
- 修改：`Sources/Workspace/FileEditorPane.swift:583-587`（私有 `PreviewMode` 提升为文件级 `EditorPreviewMode`）
- 修改：`Sources/Workspace/WorkspaceWindowController.swift:27-37`（持有 store）

**接口**

- 产出：

```swift
enum PanelID: String, CaseIterable, Sendable {
    case mainTerminal, subTerminals, fileTree, gitList, editor
}
enum ListMode: String, Codable, Sendable { case files, git }
enum EditorPreviewMode: String, Codable, Sendable { case source, markdown, image }

struct FileTreeUIState: Equatable {
    var root: URL?
    var ignoredPaths: Set<String>
    var selectedPath: String?
    var truncated: Bool
}
struct GitUIState: Equatable {
    var root: URL?
    var isRepository: Bool
    var files: [GitFileStatus]
    var collapsed: Set<GitSectionKind>
    var selectedPath: String?
}
struct EditorUIState: Equatable {
    var url: URL?
    var isDirty: Bool
    var externalChange: ExternalChange
    var previewMode: EditorPreviewMode
    var canHighlight: Bool
}
struct TerminalUIState: Equatable {
    var mainSessionID: String?
    var subSessionIDs: [String]
    var selectedSubSessionID: String?
    var branch: String?
}
struct WorkspaceSnapshot: Equatable {
    var workspaceID: String?
    var focused: PanelID?
    var ui: WorkspaceUIState
    var fileTree: FileTreeUIState
    var git: GitUIState
    var editor: EditorUIState
    var terminals: TerminalUIState
}

@MainActor
final class WorkspaceStateStore {
    private(set) var snapshot: WorkspaceSnapshot
    init(snapshot: WorkspaceSnapshot = WorkspaceSnapshot())
    func update(_ mutate: (inout WorkspaceSnapshot) -> Void)
    func observe(_ handler: @escaping (WorkspaceSnapshot) -> Void) -> UUID
    func cancel(_ token: UUID)
}
```

- 消费：`GitFileStatus`（`Sources/Workspace/GitStatusModel.swift`）、`GitSectionKind`（同文件）、`ExternalChange`（`FileDocument.swift:14-18`）。

**验收**

- [ ] `update` 在快照值未变化时不通知订阅者，`debugLog("[State] changed=\(changed) notified=\(count)")` 计数可查。
- [ ] 切换列表页签时 `[State] changed=true`，连续切回同一页签 `changed=false`。
- [ ] 现有界面行为不变，窗口可打开、可切换工作区。

**验证**

- 命令：`swift build`
- 期望：`Build complete!`，无警告新增。
- 命令：`.build/debug/utility --help`
- 期望：退出码 0，命令列表包含 `workspace-check`。

**依赖 / 规模**：无 / M

- [x] 写 `WorkspaceUIState`（含 `expandedPaths` 上限 2000、`caretLocation` 与 `scrollY` 钳制函数 `clamped(textLength:contentHeight:)`）。
- [x] 写 `WorkspaceSnapshot` 与四个面板子状态，全部 `Equatable`。
- [x] 写 `WorkspaceStateStore`，`update` 内先拷贝、比对、赋值、再通知，`observe` 返回 UUID 令牌。
- [x] 把 `FileEditorPane` 的私有 `PreviewMode` 改为文件级 `EditorPreviewMode`，原处改引用。
- [x] 在 `WorkspaceWindowController` 建 store，列表页签切换时 `update { $0.ui.activeList = mode }`。
- [x] 跑 `swift build` 与 `.build/debug/utility --help`。
- [x] 报告结果等用户测试，不提交。

## T2 面板协议、指针基建与光标根因取证

**文件**

- 新建：`Sources/Workspace/Protocol/WorkspacePanel.swift`
- 新建：`Sources/Components/PointerControls.swift`
- 新建：`Sources/Core/Debug/CursorTrace.swift`
- 修改：`Sources/Workspace/FileExplorerPane.swift:385-399,538-550`（行视图 + `rowViewForItem`）
- 修改：`Sources/Workspace/WorkspaceActivityBar.swift:16-29`
- 修改：`Sources/Workspace/SubTerminalPane.swift:250-301`

**接口**

- 产出：

```swift
@MainActor
protocol WorkspacePanel: AnyObject {
    var panelID: PanelID { get }
    var focusTarget: NSView? { get }
    func render(_ snapshot: WorkspaceSnapshot)
}

final class PointerButton: NSButton {}
final class PointerRowView: NSTableRowView {}

enum CursorTrace {
    static func installIfRequested()   // env UTILITY_CURSOR_TRACE=1 时生效，DEBUG 编译
}
```

- 消费：`PanelID`、`WorkspaceSnapshot`（T1）。

**验收**

- [ ] 文件树每一行、活动栏两个按钮悬停显示手型光标，移出恢复箭头。
- [ ] 移动 3 秒无手型/箭头闪烁。
- [ ] 点击行为、键盘焦点、展开收起与改造前一致。

**验证**

- 命令：`swift build`
- 期望：`Build complete!`。
- 命令：`UTILITY_CURSOR_TRACE=1 .build/debug/utility`
- 期望：鼠标经过工作区时 `debugLog` 输出 `[Cursor] set by <符号>`；文本记录到 `.agent/plans/2026-11-05-workspace-protocol/cursor-evidence.md`。
- 手测 L3：文件树与活动栏悬停。

**依赖 / 规模**：T1 / M

- [x] 写 `PointerButton`、`PointerRowView`，在 `resetCursorRects` 中 `addCursorRect(bounds, cursor: .pointingHand)`；控件隐藏或禁用时不注册。
- [x] 在 `FileExplorerPane` 实现 `outlineView(_:rowViewForItem:)` 返回 `PointerRowView`，替换默认行视图。
- [x] 活动栏两个按钮改用 `PointerButton`，跑一次 L3 悬停观察，记录结论。
- [x] 若手型未生效：写 `CursorTrace`，用 `method_exchangeImplementations` 交换 `NSCursor.set(_:)`，仅 `#if DEBUG`，仅在环境变量开启时输出调用栈前 6 帧。
- [x] 按取证结果修正：根因是 tracking area 的 owner 用了独立对象，AppKit 只向视图投递 cursorUpdate；改为视图自身作 owner。
- [x] 把取证结论与最终修法写入 `cursor-evidence.md`，供 T3 复用。
- [x] 跑 `swift build` 并用脚本移动光标 + 截图验证手型，见 `cursor-evidence.md`。

## T3 手型光标全量接入

**文件**

- 修改：`Sources/Workspace/FileEditorPane.swift:414-425,495-498`
- 修改：`Sources/Workspace/GitPane.swift:16,110-130`
- 修改：`Sources/Workspace/WorkspaceSidebarView.swift:11-20,70-80`
- 修改：`Sources/Workspace/SubTerminalPane.swift:108-116,272-281`
- 修改：`Sources/Workspace/FileExplorerPane.swift:344-363`

**接口**

- 消费：`PointerButton`、`PointerRowView`、`cursor-evidence.md` 的修法（T2）。
- 产出：无新类型，仅替换控件基类与行视图。

**验收**

- [ ] 侧栏新建按钮、git 刷新按钮、git 列表行、子终端列表行与关闭按钮、编辑器预览/源码按钮、冲突横幅按钮全部手型。
- [ ] 编辑器文本区仍是 I 型光标，选中文本行为不变。
- [ ] 鼠标在按钮与文本之间移动无闪烁。

**验证**

- 命令：`swift build`
- 期望：`Build complete!`。
- 手测 L3：逐个控件悬停，覆盖上述 8 处。

**依赖 / 规模**：T2 / M

- [x] 侧栏 `addButton`、git `refreshButton`、子终端 `addButton` 与 `closeButton` 改为 `PointerButton`。
- [x] 编辑器 `sourceButton`、`previewButton` 与横幅按钮改为 `PointerButton`，按 `cursor-evidence.md` 的结论应用修复。
- [x] `GitPane` 实现 `tableView(_:rowViewForRow:)`，`SubTerminalPane` 同样处理，返回 `PointerRowView`。
- [x] 文件树文件行的指针由 T2 的行视图提供，本任务只确认目录行与文件行都生效。
- [x] 跑 `swift build` 与 L3 悬停验证（文件树行截图确认手型；按钮与行共用同一套 tracking area 实现）。

## T4 编辑器脏状态与撤销一致

**文件**

- 修改：`Sources/Workspace/FileDocument.swift:35-56,123-125,142-150,170-194`
- 修改：`Sources/Workspace/FileEditorPane.swift:49,114,289-290,317-338,707-712,731-738`
- 修改：`Sources/CLI/WorkspaceCheckCommand.swift:5-46,47-96`
- 修改：`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`（新增 `cli.workspaceDirtyHelp`）

**接口**

- 产出：

```swift
// FileDocument
private(set) var savedText: String
func isDirty(currentText: String) -> Bool      // normalized(currentText) != savedText
func markSaved(_ text: String)                 // 保存或重载后调用

// FileEditorPane
func recomputeDirty()                          // 立即比较并同步 store、标题、草稿
private func scheduleDirtyRecompute()          // 150 ms 去抖
```

- 消费：`WorkspaceStateStore.update`（T1）。

**验收**

- [ ] `workspace-check --dirty <file>` 输出 `baseline: false`、`appended: true`、`restored: false`。
- [ ] 编辑后连续 ⌘Z 回到原内容，标题脏点消失，`~/.cache/utility/editor-drafts/` 下该文件快照被删除。
- [ ] 保存后再 ⌘Z 回到保存前内容，脏点立刻重新出现。

**验证**

- 命令：`swift build && .build/debug/utility workspace-check --dirty README.md`
- 期望：三行输出依次为 `baseline: false`、`appended: true`、`restored: false`。
- 命令：`bash scripts/run-tests.sh`
- 期望：四段全部通过。
- 手测 L3：编辑、⌘Z、保存、再 ⌘Z。

**依赖 / 规模**：T1 / M

- [x] 给 `FileDocument` 加 `savedText`，在 `load`、`savedCopy`、`applyReload`、`save` 四处同步维护。
- [x] 实现 `isDirty(currentText:)`，先 `normalizedText` 再与 `savedText` 比较。
- [x] 删掉 `FileDocument.isDirty` 布尔字段与所有直接赋值，改为 `FileEditorPane` 计算。
- [x] `textDidChange` 改为：先按需置脏用于即时反馈，再 `scheduleDirtyRecompute()`。
- [x] 注册 `NSUndoManagerDidUndoChange`、`NSUndoManagerDidRedoChange`，回调里立即 `recomputeDirty()`。
- [ ] `recomputeDirty` 变为干净时删除草稿、隐藏标题脏点、更新 store；变为脏时启动 2 秒草稿快照（store 同步随 T10 接线）。
- [x] 新增 CLI `--dirty <file>`：加载文件、比较空改动、追加一个字符、还原，三行输出。
- [x] 加 i18n 键 `cli.workspaceDirtyHelp`，跑 `python3 scripts/gen-l10n.py` 重新生成访问器。
- [x] 跑 `swift build`、`run-tests.sh`、`--dirty` 断言与 L3 实测（隔离实例 + 合成输入 + 截图，见检查点 A）。

## T5 git 忽略路径解析与统一状态提供者

**文件**

- 修改：`Sources/Workspace/GitStatusModel.swift:1-84`
- 修改：`Sources/Workspace/GitService.swift:51-65`
- 新建：`Sources/Workspace/GitStatusProvider.swift`
- 修改：`Sources/Workspace/GitPane.swift:60-100`
- 修改：`Sources/CLI/WorkspaceCheckCommand.swift`（扩展 `--git` 输出）

**接口**

- 产出：

```swift
struct GitStatusResult: Equatable {
    var files: [GitFileStatus]
    var ignoredPaths: Set<String>       // 相对路径，目录不带尾斜杠
}
// GitStatusModel
static func parse(_ output: String) -> GitStatusResult

// GitService
func status() async throws -> GitStatusResult   // 参数追加 --ignored=traditional

@MainActor
final class GitStatusProvider {
    struct Result: Equatable {
        var isRepository: Bool
        var files: [GitFileStatus]
        var ignoredPaths: Set<String>
    }
    var onUpdate: ((URL, Result) -> Void)?
    func result(for root: URL) async -> Result   // 缓存 + 单飞
    func invalidate(root: URL)
}
```

- 消费：`ProcessRunner.run`、`GitService.status`。

**验收**

- [ ] `workspace-check --git` 在含 `.gitignore` 的目录输出 `ignored: <n>` 与最多 3 个样例路径。
- [ ] 非仓库目录仍输出 `git: not-repository`。
- [ ] 一次刷新只产生一个 `git status` 进程，日志 `[Git] status root=…` 单条。

**验证**

- 命令：`.build/debug/utility workspace-check --git /Users/yuanyxh/Documents/selfdata/projects/utility`
- 期望：包含 `git: repository`、`branch:`、`ignored:` 行。
- 命令：`.build/debug/utility workspace-check --git /tmp`
- 期望：`git: not-repository`，退出码 0。

**依赖 / 规模**：T2 / M

- [x] `GitStatusModel.parse` 识别 `!!` 记录，目录尾斜杠去掉，返回 `GitStatusResult`。
- [x] `GitService.status` 拆成两次查询：`--untracked-files=all` 取改动文件，`--ignored=traditional` 取折叠后的忽略目录（`-uall` 会把 `.build/` 展开成 9000 多个文件）。
- [x] 写 `GitStatusProvider`：按 root 缓存结果；同一 root 同时只允许一个在途任务；`invalidate` 后下一次调用重新查询。
- [x] `GitPane.refresh` 改为调用 provider，仍保留 400 ms 去抖与代次校验。
- [x] CLI `--git` 增加 `ignored:` 与 `ignored-sample:` 输出。
- [x] 跑 `--git` 于本仓库（ignored: 17）与非仓库目录（not-repository）。
- [ ] 跑 `swift build`，报告结果等用户测试。

## T6 文件树忽略灰化渲染

**文件**

- 新建：`Sources/Workspace/State/IgnoreRules.swift`
- 修改：`Sources/Workspace/FileTreeModel.swift:3-16`
- 修改：`Sources/Workspace/FileExplorerPane.swift:385-399,420-462`
- 修改：`Sources/Core/Styles/VSTheme.swift:8-16`

**接口**

- 产出：

```swift
struct IgnoreRules: Equatable {
    var paths: Set<String>              // 相对路径
    func isIgnored(relativePath: String) -> Bool   // 自身或任一祖先命中
}
// FileNode
var isIgnored = false
```

- 消费：`GitStatusProvider.onUpdate`（T5）。

**验收**

- [ ] 被 `.gitignore` 忽略的文件显示深灰色，图标同步变灰。
- [ ] 被忽略的目录整行深灰，展开后的子项同样深灰。
- [ ] 修改 `.gitignore` 后在 1 秒内重新着色，展开状态不丢失。

**验证**

- 命令：`swift build`
- 期望：`Build complete!`。
- 手测 L3：在临时仓库放 `build/` 与 `.gitignore`，展开观察颜色；删除 `.gitignore` 后 1 秒恢复常规色。

**依赖 / 规模**：T5 / M

- [x] `VSTheme` 增加 `dimmedText`（`0x6E6E6E`），与 `secondaryText` 区分。
- [x] 写 `IgnoreRules`：把 `ignoredPaths` 拆成路径集合，`isIgnored` 逐级向上匹配父目录。
- [x] 不做节点字段，`FileExplorerPane` 在 `viewFor` 时按相对路径实时判定，避免重扫后标记失效。
- [x] `FileExplorerPane` 订阅 `GitStatusProvider.onUpdate`，规则变化后 `outline.reloadData()` 并保留展开状态。
- [x] 文件树根目录加载、FSEvents 回扫、编辑器保存三个时机触发刷新；`.gitignore` 变化时先 invalidate。
- [x] `viewFor` 中设置文字色与图标色，`toolTip` 追加 `(gitignored)`。
- [ ] 跑构建与 L3 手测，报告结果等用户测试。

## T7 终端面板协议化

**文件**

- 修改：`Sources/Workspace/SubTerminalPane.swift:3-57,80-99`
- 修改：`Sources/Workspace/TerminalHostView.swift`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift:126-141`
- 修改：`Sources/Workspace/WorkspaceStateStore.swift`（若需新增派生方法）

**接口**

- 产出：`SubTerminalPane: WorkspacePanel`，`panelID = .subTerminals`，`focusTarget = currentView`。
- 消费：`snapshot.terminals`（T1）。

**验收**

- [ ] `SubTerminalPane.render` 只使用 `snapshot.terminals`，不调用 `GitService` 取分支。
- [ ] 切换子终端、新建、关闭、分支显示与改造前一致。
- [ ] `grep -n "GitService" Sources/Workspace/SubTerminalPane.swift` 无命中。

**验证**

- 命令：`swift build && grep -c "func render(_ snapshot" Sources/Workspace/SubTerminalPane.swift`
- 期望：构建通过，计数为 1。
- 手测 L3：子终端增删切换、分支刷新。

**依赖 / 规模**：T4 / S

- [x] `SubTerminalPane` 实现 `WorkspacePanel`，`render` 比对 `lastRendered` 后刷新列表、选中项与状态栏分支。
- [x] 删除 `reloadBranch(root:)` 与内部 `GitService` 调用，分支值改由快照下发（控制器 `refreshBranch()` 取数写 `terminals.branch`）。
- [x] `WorkspaceWindowController` 统一在 `focus(_ panel:)` 里设第一响应者，面板观察者集中 `render`。
- [x] 跑构建与 L3 验证：隔离实例新建、关闭、切换两个子终端，列表与空态随快照刷新，状态栏分支显示 `master`（截图）。

## T8 文件列表面板协议化

**文件**

- 修改：`Sources/Workspace/FileExplorerPane.swift:25-34,71-116,276-292`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift:99-115,159-161`
- 修改：`Sources/Workspace/WorkspaceActivityBar.swift:11-14`

**接口**

- 产出：`FileExplorerPane: WorkspacePanel`，`panelID = .fileTree`，`focusTarget = outline`。
- 消费：`snapshot.fileTree`、`snapshot.ui.activeList`、`snapshot.ui.expandedPaths`。

**验收**

- [ ] 列表页签、根目录、忽略集合、选中项全部来自快照；面板内部不再有 `mode` 独立状态。
- [ ] 切换工作区、切换页签、展开目录与改造前一致。
- [ ] `WorkspaceWindowController` 通过 `store.update` 驱动，不再直接调用 `filePane.apply(mode:)`。

**验证**

- 命令：`swift build && grep -n "var mode" Sources/Workspace/FileExplorerPane.swift`
- 期望：构建通过，无输出。
- 手测 L3：页签切换、目录展开、文件打开。

**依赖 / 规模**：T2 / M

- [x] 实现 `WorkspacePanel`，`render` 处理根目录变化、页签切换、忽略集合、选中项与截断提示。
- [x] `apply(mode:)` 改为 `applyListMode(_:)` 从快照读取，活动栏由 `setMode(_:)` 驱动视觉选中态。
- [x] 展开/收起写入 `snapshot.ui.expandedPaths`（`onExpandedPathsChange`），`expansionByRoot` 只保留当前会话缓存。
- [x] 点击文件的回调写 `fileTree.selectedPath`，控制器保留唯一打开入口。
- [x] 跑构建、grep 断言与 L3 实测：页签切换、目录展开、打开文件、忽略项灰化（隔离实例截图）。

## T9 Git 面板协议化

**文件**

- 修改：`Sources/Workspace/GitPane.swift:3-20,60-130,190-260`
- 修改：`Sources/Workspace/FileExplorerPane.swift:211-217,294-311`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift`

**接口**

- 产出：`GitPane: WorkspacePanel`，`panelID = .gitList`，`focusTarget = table`。
- 消费：`snapshot.git`、`GitStatusProvider.onUpdate`。

**验收**

- [ ] 分组折叠、计数角标、diff 打开全部由快照与 provider 驱动。
- [ ] 一次进入 git 页只触发一次状态查询。
- [ ] `grep -n "GitService" Sources/Workspace/GitPane.swift` 只在 diff 调用处命中。

**验证**

- 命令：`swift build && grep -n "func render(_ snapshot" Sources/Workspace/GitPane.swift`
- 期望：构建通过，命中 1 处。
- 手测 L3：折叠分组、打开 diff、保存后自动刷新。

**依赖 / 规模**：T5 / S

- [x] `GitPane` 实现 `WorkspacePanel`，`render` 比对 `lastRendered` 后重建行数组。
- [x] 删除面板内部 `refresh()` / `scheduleRefresh()` / `reload(root:)` 的取数逻辑，数据由控制器 `refreshGitStatus()` 写快照。
- [x] 折叠集合与选中路径搬入快照（`git.collapsed` / `git.selectedPath`），页签切换后保留。
- [x] 跑构建与 L3 实测：切页渲染 31 条、折叠分组、打开 diff（隔离实例截图）。

## T10 编辑面板协议化

**文件**

- 修改：`Sources/Workspace/FileEditorPane.swift:14-49,583-712,731-738`
- 修改：`Sources/Workspace/FileExplorerPane.swift:55-69`（内容区挂载）
- 修改：`Sources/Workspace/WorkspaceWindowController.swift:106-114,187-200`

**接口**

- 产出：`FileEditorPane: WorkspacePanel`，`panelID = .editor`，`focusTarget = textView`。
- 消费：`snapshot.editor`、`snapshot.ui`（光标、滚动）。

**验收**

- [ ] 标题脏点、外部改动横幅、预览模式、高亮开关全部由快照驱动。
- [ ] 保存、另存为、冲突三选、外部重载路径与改造前一致。
- [ ] `grep -n "document.isDirty" Sources/Workspace/FileEditorPane.swift` 无命中。

**验证**

- 命令：`swift build && grep -c "func render(_ snapshot" Sources/Workspace/FileEditorPane.swift`
- 期望：构建通过，计数为 1。
- 手测 L3：编辑、保存、外部改文件、切预览。

**依赖 / 规模**：T4 / M

- [x] 实现 `WorkspacePanel`，`render` 负责标题、脏点、横幅、预览可见性、只读切换。
- [x] `previewMode` 改由快照持有（`ui.previewMode`），按钮点击写快照，`render` 里更新界面。
- [x] 光标位置与滚动位置变化时写快照（`onPositionChange`，去抖 200 ms）。
- [x] 打开/关闭文件写 `editor.url`/`fileTree.selectedPath`，`confirmClose` 等交互保留为命令方法。
- [x] 跑构建与 L3 实测：预览/源码切换、外部修改自动重载（隔离实例截图）。

## T11 语法协议化

**文件**

- 新建：`Sources/Workspace/SyntaxProvider.swift`
- 修改：`Sources/Workspace/SyntaxHighlighter.swift:1-40`
- 修改：`Sources/Workspace/FileEditorPane.swift:742-821`
- 修改：`Sources/CLI/WorkspaceCheckCommand.swift`（`--highlight` 输出格式不变）

**接口**

- 产出：

```swift
protocol SyntaxProvider {
    func definition(for url: URL) -> SyntaxDefinition?
    func tokens(in text: NSString, range: NSRange) -> [SyntaxToken]
}
struct DefaultSyntaxProvider: SyntaxProvider {}
```

- 消费：`SyntaxDefinitions.definition(forExtension:)`、`SyntaxHighlighter.tokens`。

**验收**

- [ ] `FileEditorPane` 只依赖 `any SyntaxProvider`，不再直接引用 `SyntaxHighlighter`。
- [ ] `--highlight` 输出与改造前一致，300 行 Swift 耗时不高于 8 ms。
- [ ] 12 种扩展名仍能着色，超 1 MB 或 2 万行仍降级。

**验证**

- 命令：`swift build && .build/debug/utility workspace-check --highlight Sources/Workspace/FileEditorPane.swift`
- 期望：输出行数、耗时、四类 token 计数；耗时不超过 8 ms。

**依赖 / 规模**：T10 / S

- [x] 写 `SyntaxProvider` 与默认实现，把词汇表与着色策略收敛到实现内。
- [x] `FileEditorPane` 改为注入 `any SyntaxProvider`（`init(frame:syntaxProvider:)`，默认 `DefaultSyntaxProvider()`）。
- [x] 跑 `--highlight` 与构建：291 行 Swift 约 5 ms（阈值 8 ms），token 统计与改造前一致。

## T12 关键状态持久化与迁移

**文件**

- 修改：`Sources/Workspace/WorkspaceModel.swift:34-92,94-120`
- 修改：`Sources/Workspace/WorkspaceStore.swift`
- 修改：`Sources/Workspace/WorkspaceWindowController.swift:305-328`
- 修改：`Sources/CLI/WorkspaceCheckCommand.swift`
- 修改：`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`（`cli.workspaceUIHelp`）

**接口**

- 产出：

```swift
// Workspace
var ui: WorkspaceUIState
// WorkspaceDocument
static let currentVersion = 2
// WorkspaceStore
func save(_ document: WorkspaceDocument) throws   // 首次写 v2 前复制 .bak
```

- 消费：`WorkspaceUIState`（T1）。

**验收**

- [ ] 重启后展开目录、当前文件、列表页签、光标位置、滚动位置恢复。
- [ ] `version: 1` 文件加载后首次保存生成 `workspaces.json.bak`，原文件被替换为 v2。
- [ ] `ui` 字段类型错误时整份文档改名 `.corrupt-*`，程序按空文档启动。

**验证**

- 命令：`.build/debug/utility workspace-check --ui ~/.config/utility/workspaces.json`
- 期望：输出 `version: 2`，每个工作区一行 `ui: list=<files|git> expanded=<n> caret=<n> scroll=<n>`。
- 手测 L3：打开两三个目录与文件后退出重启。

**依赖 / 规模**：T8、T10 / M

- [x] `Workspace` 增加 `ui` 字段，`init(from:)` 用 `decodeIfPresent`，默认空状态。
- [x] `WorkspaceDocument.currentVersion` 改为 2；`normalized()` 经 `clamped(textLength:contentHeight:)` 截断 `expandedPaths`。
- [x] `WorkspaceStore.save` 在首次写 v2 且原文件为 v1 时复制 `.bak`（实测 928 B → 1559 B，`.bak` 保留原 v1）。
- [x] 控制器在窗口失焦、切换工作区、面板切换后 500 ms 去抖写盘，只写 `ui` 与布局（`onUIStateChanged` → `WorkspaceManager.updateUIState`）。
- [x] CLI 增加 `--ui <path>` 输出，含版本与各工作区 ui 摘要（`list= expanded= caret= scroll= preview=`）。
- [x] 用 `version: 1` 文件启动完成升级；L3 实测重启后 `expandedPaths`（Sources 展开）、`activeList`（git 页签）、`caretLocation` 恢复。
- [x] 跑构建、`--ui` 断言与 L3 重启验证。偏差：`ui` 字段类型错误时按默认空状态解析，不整份改名 `.corrupt-*`（避免单字段损坏丢全部工作区）。

## T13 文档、回归与打包

**文件**

- 修改：`.claude/docs/architecture/workspace.md`
- 修改：`.agent/status.md`
- 修改：`README.md`、`README.zh.md`（工作区段落补灰化与状态恢复）
- 修改：`AGENTS.md`（如验证命令新增）

**接口**

- 消费：全部前序任务。
- 产出：无代码接口。

**验收**

- [x] 架构文档新增「状态层与面板协议」「光标（手型）」两节并更新存储/编辑器/Git 段落，写明不变量与踩坑。
- [x] `bash scripts/run-tests.sh` 全过。
- [x] 打包产物生成，工作区可打开（隔离实例），资源 bundle 存在。

**验证**

- 命令：`bash scripts/run-tests.sh && python3 scripts/gen-l10n.py --check && python3 scripts/check-l10n-contract.py`
- 期望：全部通过。
- 命令：`bash scripts/package-utility.sh`
- 期望：生成 dmg，app 内含 `utility_utility.bundle`。

**依赖 / 规模**：T6、T9、T12 / S

- [x] 更新架构文档，补状态层入口、渲染约束、光标修法结论。
- [x] 更新 `status.md` 的进行中与最近完成。
- [x] 跑全量验证命令与打包：`run-tests.sh`、l10n 双检查全过；`Utility.app` 20M / `Utility-1.1.75.dmg` 7.5M，资源 bundle 存在。
- [ ] 汇报结果，等用户 L3 验收后再讨论提交。

## 审查修复（2026-11-06）

独立子 agent 审查 + 本人复验，结论「需修改」。本轮修复：

- [x] 阻断：滚动恢复时文本未布局，`maxY` 算成 0 → 存档 `scrollY` 恢复成 0 并回写。改为 `ensureLayout` 后读高度；隔离实例 `scrollY=3000` 恢复且落盘保持 3000（L3）。
- [x] 应修：外部修改横幅跨文件泄漏。`open` / `restore` / `close` 复位 `editor.externalChange`（L1）。
- [x] 应修：工作区为仓库子目录时忽略灰化失效。`rev-parse --show-toplevel` 算前缀，`GitStatusModel.scoped` 转换并过滤 porcelain 路径；`--git Sources` 输出 `App/AppDelegate.swift`（L2）。
- [x] 应修：`status` 失败被 `try?` 当干净结果。改为记录日志、沿用上次缓存且失败不写缓存（L1）。
- [x] 应修：切工作区与无 root 时残留旧 git 文件与分支。切换时清空 `git` / `ignoredPaths` / `branch`（L1）。

未修（审查其余建议，待排期）：`invalidate` 不清在途任务、5MB 文件脏重算约 43ms、快照死字段与未用 API、`SyntaxProvider` 注入参数、指针方法重复、文档与实现矛盾、首次启动空态提示、`PointerCursorController` 冗余。

## 审查修复第二轮（2026-11-06，功能与性能）

- [x] `GitStatusProvider.invalidate` 加代际号，在途任务回写前比对，切目录后旧结果不落缓存（L1）。
- [x] 脏状态重算改字节级 `memchr`：5MB 文本 42.3ms → 0.1ms；`workspace-check --dirty` 增 `crlf-equal` 断言，`run-tests.sh` 5/5 全过（L2）。
- [x] 首次启动文件树空态：`lastRenderedTree == nil` 视为 rootChanged，空目录也显示占位（L1）。
- [x] `WorkspaceStore` 启动时只检查一次旧档备份，复制失败写日志，不再每次落盘重试（L1）。
- [x] UI 状态落盘收敛：`updateUIState` 只写 `workspaces.json`；`persistUIStateNow()` 在切工作区、移除、退窗、退出前 flush（L1）。
- [x] 指针光标方法重复：`PointerRowView` 去 `final`，侧边栏行视图改继承，只保留 `drawSelection`（L1）。
- [x] 文档：`workspace.md` 改「状态层与工作区窗格」，新增「与浮动面板的区别」；从属例外（`FileExplorerPane` 持 `gitPane`）与异步取数两条路写清（L1）。
- [x] `PointerCursorController` 验证结论：真实滑动 + `UTILITY_CURSOR_TRACE=1`，`mouseMoved` 触发 0 次，行/按钮自身 tracking area 759 次 → 控制器从未生效。`PointerCursor.swift` 移入废纸篓，`PointerClickable` 并入 `PointerControls.swift`，移除 `attach(to:)` 调用；复测行视图 `mouseMoved` 仍触发 8 次、控制器 0 次（L2/L3）。
- [x] `FileTreeUIState.truncated` 永远是 false，却被 `render` 拿来和本地 `treeTruncated` 比较，文件树截断后任意快照更新都会把页脚冲掉。删字段与比较，本地状态唯一（L1）。
- [x] 回归：点列表空白丢选中样式。工作区/文件树/Git/子终端四处列表在空白区域点击时不再下发事件（`PersistentSelectionTableView` 与 `FileOutlineView` 的 `clickedRow < 0` 早退），`allowsEmptySelection` 保持 true 供程序化清空。
- [x] 回归：选中行文字/图标仍是基色（图标为 `secondaryText` 灰）。`PointerRowView` 在选中时把子孙 `NSTextField` / `NSImageView` 统一转 `VSTheme.selectionText`，取消时按记录的基色还原；配置阶段重设的基色会在下一次布局自动记录（L1，L3 待手测）。
- [x] 回归：选中态蓝一下变灰。点文件/子终端后焦点交给编辑器或终端，列表失去 first responder，AppKit 默认按非强调色绘制。`PointerRowView.drawSelection` 自己画 `selectionActive`，仅窗口非 key 时用 `selectionInactive`（L1，L3 待手测）。旧侧栏曾用 `allowsEmptySelection = false` 修过同一问题（`terminal.md`），重写列表时回退（L1/L2，L3 待用户手测）。
- [x] 死字段与假接缝按建议删除：`WorkspaceSnapshot.workspaceID` / `focused`（只写不读，连带删两处 `store.update`）、`EditorUIState.canHighlight`（零引用）、`FileEditorPane` 的 `syntaxProvider` 注入参数（唯一构造点不传参，无 Swift 单测）；`SyntaxProvider` 协议保留（L1）。
