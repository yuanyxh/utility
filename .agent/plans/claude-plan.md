终端改造为工作区实施计划

把现有单会话终端窗口升级为 VS Code 形态的工作区：左侧常驻工作区列表，中部主终端，右侧文件/git 面板与内容区，底部多子终端。全部围绕当前工作区文件夹，目标是把开发注意力合并进 utility。

背景

当前终端是「220pt 会话侧栏 + 单个终端容器」的固定布局，没有工作区概念，文件与 git 需要切到其他应用。用户 2026-11-04 确认直接改造，不等尚未实施的 GUI 重构计划。

已定决策

┌──────────────┬───────────────────────────────────────────────────────────┐
│     决策     │                           结论                            │
├──────────────┼───────────────────────────────────────────────────────────┤
│ GUI 重构前置 │ 取消。直接基于现有 accessory 窗口实现，GUI 化另案         │
├──────────────┼───────────────────────────────────────────────────────────┤
│ 布局持久化   │ 全局一份 WindowLayout，切换工作区不改分割条位置           │
├──────────────┼───────────────────────────────────────────────────────────┤
│ 子终端形态   │ 底部终端内容 + 右侧竖向会话列表，可拖拽调高度             │
├──────────────┼───────────────────────────────────────────────────────────┤
│ 文件编辑     │ 纯文本编辑、行号、语法高亮、Markdown 预览、图片预览       │
├──────────────┼───────────────────────────────────────────────────────────┤
│ git 范围     │ 只读 status + diff，不做 add/commit/restore               │
├──────────────┼───────────────────────────────────────────────────────────┤
│ 会话挂载     │ 只挂载当前工作区；切走时结束客户端进程，tmux 会话继续存活 │
└──────────────┴───────────────────────────────────────────────────────────┘

架构

窗口布局

mermaid
flowchart TD
    W[工作区窗口 NSWindow] --> R[rootSplit 左右]
    R --> S[WorkspaceSidebarView 220pt]
    R --> M[主终端 mainTerminalHost]
    R --> RP[右侧 rightSplit 上下]
    RP --> F[文件区]
    RP --> T[子终端区 260pt]
    F --> A[ActivityBar 44pt: Files / Git]
    F --> FS[fileSplit: 文件列表 240pt | 编辑器]
    T --> TS[subSplit: 子终端内容 | 会话列表 180pt]

┌────────────┬──────┬──────────────────────────────────┬────────────────────────────────┐
│  分割视图  │ 方向 │             默认尺寸             │            最小尺寸            │
├────────────┼──────┼──────────────────────────────────┼────────────────────────────────┤
│ rootSplit  │ 左右 │ 侧栏 220、主终端自适应、右栏 560 │ 侧栏 180、主终端 360、右栏 480 │
├────────────┼──────┼──────────────────────────────────┼────────────────────────────────┤
│ rightSplit │ 上下 │ 文件区自适应、子终端 260         │ 文件区 260、子终端 120         │
├────────────┼──────┼──────────────────────────────────┼────────────────────────────────┤
│ fileSplit  │ 左右 │ 列表 240、编辑器自适应           │ 列表 160、编辑器 320           │
├────────────┼──────┼──────────────────────────────────┼────────────────────────────────┤
│ subSplit   │ 左右 │ 子终端自适应、列表 180           │ 子终端 320、列表 140           │
└────────────┴──────┴──────────────────────────────────┴────────────────────────────────┘

窗口默认 1440×900，最小 1120×680，保留 setFrameAutosaveName("utility.terminal-window")。分割条 1pt，颜色用 VSTheme.separator，通过 NSSplitView 子类覆写 dividerColor。

布局只在首次显示时应用一次；用 isApplyingLayout 防止 delegate 回写；拖动结束 300ms 后去抖写盘；读取时按最小尺寸与屏幕可见区域钳制，非法值回默认。

数据模型与存储

workspaces.json 是唯一真源，存 WorkspaceDocument：

┌───────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│       类型        │                                                   字段                                                   │
├───────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ WorkspaceDocument │ version、selectedWorkspaceID、layout、workspaces                                                         │
├───────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Workspace         │ id、name、path、mainSessionID?、subSessionIDs、selectedSubSessionID?、lastOpenedRelativePath?、createdAt │
├───────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ WindowLayout      │ sidebarWidth、rightPaneWidth、fileListWidth、subTerminalHeight、subListWidth                             │
├───────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ TerminalRole      │ main / sub                                                                                               │
└───────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────┘

存储规则：

- 路径 AppPaths.configDir/workspaces.json，原子写、ISO8601、.sortedKeys。
- 路径用 standardizedFileURL.path 去重，不解析符号链接。
- 工作区名称默认 lastPathComponent，允许重命名；同名不同路径合法。
- 加载时校验目录存在，缺失只标记，不自动移除。

terminal-sessions.json 继续双写，StoredTerminalSession 增加可选 workspaceID 与 role，backend 必须继续写 "tmux"。

迁移

┌──────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────────┐
│             场景             │                                              行为                                               │
├──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 无 workspaces.json、有旧会话 │ 先复制 terminal-sessions.json 为 .bak，按标准化 cwd 分组，最早 createdAt 为主终端，其余为子终端 │
├──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 无任何旧会话                 │ 创建空文档，首次新建工作区时初始化                                                              │
├──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────┤
│ workspaces.json 解码失败     │ 原文件改名 .corrupt-<timestamp>，从旧会话重建并记录日志                                         │
├──────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 旧构建写回会话文件           │ 按 id 与 workspaceID 重新归属；未归属的按 cwd 归入已有工作区或新建                              │
└──────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────────┘

迁移只复制、不删除用户文件；旧会话文件保留。

会话编排

WorkspaceManager 取代 TerminalManager，仍是 @MainActor 单例。复用 TerminalSession、TerminalDropView、TmuxBackend、TerminalNotificationParser。

┌────────────┬────────────────────────────────────────────────────────────────────────────────────────────────┐
│    事件    │                                              行为                                              │
├────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 打开窗口   │ 应用布局后挂载当前工作区终端；restoreIfNeeded 只执行一次                                       │
├────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 恢复       │ liveIDs() 过滤；只恢复主/子会话 id，不立即全部 attach                                          │
├────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 选中工作区 │ 先 detach 旧工作区的客户端会话，再为当前工作区主终端与选中子终端创建 TerminalSession 并 attach │
├────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 新建工作区 │ NSOpenPanel 选目录，创建记录并立即创建主终端，cwd 为工作区路径                                 │
├────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 新建子终端 │ cwd 为工作区路径；受 terminal.maxSessions 全局上限约束；选中最新的子终端                       │
├────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 关闭子终端 │ kill tmux 会话、terminate 客户端、从工作区与镜像移除                                           │
├────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 主终端退出 │ 非退出场景 kill tmux，移除 id，当前工作区选中时重建                                            │
├────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 移除工作区 │ 确认后 kill 该工作区全部会话，删除配置条目，不删除磁盘文件                                     │
├────────────┼────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 退出应用   │ persist() 后只 terminate 客户端，tmux 会话保持存活                                             │
└────────────┴────────────────────────────────────────────────────────────────────────────────────────────────┘

性能取舍：只挂载当前工作区，避免多个 SwiftTerm 视图持续重绘拖高 WindowServer（2026-10-30 实测 3 个后台会话即可从 5.1% 抬到 23.7%）。代价是后台工作区不产生 OSC 通知，作为已知行为写入文档。        

主/子终端默认 cwd 规则：新建用工作区路径；恢复保留会话最后 cwd。

右侧文件区

- ActivityBar 切换 Files / Git，两个列表共用列表列。
- Files 用 NSOutlineView 懒加载；目录优先、localizedStandardCompare 排序；符号链接目录不递归；单目录最多 2000 条目。
- 忽略目录复用抽取后的 PathRules，来源为现有 ScannerConfig.skippedDirNames。
- 编辑器区顶部显示相对路径、dirty 标记、保存按钮、Markdown 的 Preview/Source 切换。
- 文件打开路由：UTF-8 文本进编辑器；Markdown 默认预览；位图进图片预览；含 NUL、超 maxFileSizeMB、非 UTF-8 只读提示。

编辑器与语法高亮

- NSTextView 非富文本、等宽字体、usesFindBar，参考 ConfigEditorWindowController.swift:124-150。
- 行号用 NSRulerView，只枚举可见 glyph range；维护行首索引，编辑后局部更新。
- 语法高亮：SyntaxHighlighter + SyntaxDefinitions，正则 + 关键字表；支持 Swift、JS/TS/JSX/TSX、JSON、YAML、Markdown、Shell、Python、HTML/CSS，其余纯文本。
- 范围：可见行上下各 200 行；编辑后 100ms、滚动后 50ms 去抖；输入法 hasMarkedText 时跳过。
- 上限：文件 >1MB 或 >2 万行关闭高亮；单行 >2000 字符跳过；加载上限 5MB。
- 着色期间挂起 undo 注册，结束后恢复；只 invalidate 可见范围布局。

git 只读服务

新增 ProcessRunner（超时、输出上限、不经过 shell），GitService 后台执行：

┌──────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│   操作   │                                                    命令                                                    │
├──────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 判定仓库 │ git -C <ws> rev-parse --is-inside-work-tree                                                                │
├──────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 状态     │ git -c core.quotepath=false -C <ws> status --porcelain=v1 -z --untracked-files=all --relative              │
├──────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ diff     │ git -c core.quotepath=false -C <ws> diff --no-color --no-ext-diff --no-textconv --unified=3 HEAD -- <path> │
└──────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

无 HEAD 时退回 --cached + 普通 diff；未跟踪文件直接读内容并标注；二进制用 --numstat 判定；status 超时 5 秒、diff 超时 10 秒、输出上限 2MB / 5000 行。保存后与手动刷新触发，400ms
去抖，结果哈希不变不重绘。

Markdown 与图片预览

- 从 KnowledgeMarkdownView 抽取共享 MarkdownPreviewView，继续用 Bundle.module 的 marked.umd.js，baseURL 为文件所在目录。
- 加 CSP：只允许 file: / data: 图片与内联样式脚本；http/https 链接交 NSWorkspace 打开。
- 图片用 ImageIO 缩略到最长边 4096px；上限 20MB，超过只提示不加载。

任务

依赖顺序：

mermaid
flowchart TD
    T1[T1 模型存储迁移] --> T2[T2 WorkspaceManager]
    T2 --> T3[T3 窗口骨架]
    T3 --> T4[T4 侧栏]
    T3 --> T5[T5 主/子终端]
    T3 --> T6[T6 文件树]
    T6 --> T7[T7 编辑器行号]
    T7 --> T8[T8 保存冲突]
    T7 --> T9[T9 语法高亮]
    T6 --> T10[T10 git]
    T7 --> T11[T11 预览]
    T4 --> T12[T12 收尾]
    T5 --> T12
    T9 --> T12
    T10 --> T12
    T11 --> T12

T1 工作区模型、配置、存储与迁移

新建 Sources/Workspace/WorkspaceModel.swift、WorkspaceStore.swift、Sources/CLI/WorkspaceCheckCommand.swift；修改
TerminalSessionStore.swift、ConfigTypes.swift、default-config.yaml、UtilityCLI.swift、zh-Hans.json、en.json。

接口：WorkspaceDocument、Workspace、WindowLayout、TerminalRole；WorkspaceStore.load/save/backup；WorkspaceMigration.plan(sessions:now:) 纯函数；WorkspaceConfig(ignoredDirectories,
showHiddenFiles, maxFileSizeMB, imagePreviewMaxSizeMB)；workspace-check --sessions/--roundtrip/--dry-run。

验收：

- [ ] 3 条旧会话、2 个 cwd 的 fixture 经 --dry-run 输出 2 个工作区，最早者为主终端（L2）。
- [ ] --roundtrip 输出 roundtrip: ok，layout 与选中项保留（L2）。
- [ ] default-config.yaml、属性初值、decodeIfPresent 三处默认值一致（L1）。

验证：

swift build
.build/debug/utility workspace-check --sessions /tmp/ws-fixture.json --dry-run
.build/debug/utility workspace-check --roundtrip /tmp/ws-roundtrip.json
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py

T2 WorkspaceManager 会话编排

新建 Sources/Workspace/WorkspaceManager.swift。

接口：shared；workspaces、selectedWorkspaceID、sessions；showWindow/toggleWindow/shutdown；createWorkspace/selectWorkspace/renameWorkspace/removeWorkspace；ensureMainSession/addSubSession/sele   
ctSubSession/closeSubSession；persist/restoreIfNeeded；订阅 AppEvent.terminalOpenSession。

验收：

- [ ] 首次启动日志出现 [Workspace] migrated sessions=<n> workspaces=<m>，生成 workspaces.json 与 .bak（L2）。
- [ ] 切换工作区时旧会话 detach、新会话 attach，tmux list-sessions 数量不变（L2）。
- [ ] 达到 terminal.maxSessions 时新增返回失败并只通知一次（L2）。
- [ ] 退出只 detach，不 kill tmux（L2）。

验证：

swift build
.build/debug/utility workspace-check
tmux -L utility list-sessions

T3 工作区窗口骨架与入口切换

新建 Sources/Workspace/WorkspaceWindowController.swift、WorkspaceSplitView.swift；修改 AppDelegate.swift、MenuBarManager.swift；验收后把 TerminalManager.swift、TerminalWindowController.swift     
移入废纸篓。

接口：reloadWorkspaces、attachMainTerminal、attachSubTerminal、reloadSubSessions、apply(layout:)、currentLayout、wantsVisible；回调 onSelectWorkspace/onCreate/onRename/onRemove。

验收：

- [ ] 三栏窗口、四条分割线可拖，重启后尺寸恢复（L3）。
- [ ] 热键显隐、菜单入口、失焦后窗口恢复、关闭只隐藏（L3）。
- [ ] 布局损坏值回退默认且不崩溃（L2）。

验证：

swift build
strings .build/debug/utility | grep -c "WorkspaceWindowController"

T4 工作区侧栏 CRUD

新建 Sources/Workspace/WorkspaceSidebarView.swift；修改窗口与 manager。

验收：

- [ ] 点 + 用 NSOpenPanel 只选目录，新建后自动选中，主终端 cwd 正确（L3）。
- [ ] 双击重命名，空名称拒绝，重启保留（L3）。
- [ ] 移除确认文案含会话数量与「不删除磁盘文件」，确认后结束会话并选中相邻工作区（L3）。
- [ ] 路径缺失标红，重复路径拒绝（L3）。

验证：

swift build
.build/debug/utility workspace-check

T5 主终端与子终端面板

新建 Sources/Workspace/TerminalHostView.swift、SubTerminalPane.swift；修改窗口与 manager。

接口：attach(view:)、detach()、showSubSession(id:)、reloadSubSessions、terminalContentSize。

验收：

- [ ] 主终端 cwd 为工作区路径；新建多个子终端 cwd 相同，可切换、关闭（L3）。
- [ ] 底部高度可拖并持久化（L3）。
- [ ] 标题变化只刷新对应行（L3）。
- [ ] 3 个工作区后台驻留时 CPU 与 WindowServer 无明显抬升（L3，对照 2026-10-30 数据）。

验证：

swift build
tmux -L utility list-panes -a -F "#{session_name} #{pane_current_path}"

T6 文件树与路径规则

新建 Sources/Core/PathRules.swift、Sources/Workspace/FileTreeModel.swift、FileExplorerPane.swift、WorkspaceActivityBar.swift；修改 ScannerConfig.swift 复用共享规则。

验收：

- [ ] 忽略 .git、node_modules、.build、DerivedData、Pods、dist、.next（L2，workspace-check --tree）。
- [ ] 懒加载展开、空目录与无权限提示、双击打开文件（L3）。
- [ ] 隐藏文件受 workspace.showHiddenFiles 控制（L3）。

验证：

swift build
.build/debug/utility workspace-check --tree <fixture>

T7 编辑器与行号

新建 Sources/Workspace/FileDocument.swift、FileEditorPane.swift、LineNumberRulerView.swift；修改 VSTheme.swift 增加字体常量。

验收：

- [ ] 文本文件可编辑，行号与内容对齐，滚动同步（L3）。
- [ ] 二进制、非 UTF-8、超限文件只读提示（L3）。
- [ ] 切换文件不残留旧内容（L3）。

验证：

swift build
strings .build/debug/utility | grep -c "LineNumberRulerView"

T8 保存、冲突与未保存提示

修改 FileDocument.swift、FileEditorPane.swift、AppDelegate.swift（applicationShouldTerminate）。

验收：

- [ ] ⌘S 原子写盘，保留 BOM 与 CRLF，isDirty 复位（L2 + L3）。
- [ ] 有改动时切换文件/工作区/退出弹「保存 / 丢弃 / 取消」，取消中止操作（L3）。
- [ ] 外部修改后保存弹冲突三选；选择覆盖或重新加载后内容正确（L3）。
- [ ] 只读文件保存失败并保持 dirty（L3）。

验证：

swift build
bash scripts/run-tests.sh

T9 语法高亮

新建 Sources/Workspace/SyntaxHighlighter.swift、SyntaxDefinitions.swift；修改 FileEditorPane.swift。

验收：

- [ ] 10 类语言的关键字、字符串、注释、数字着色正确（L2，workspace-check --highlight <fixture>）。
- [ ] 可见 300 行着色耗时 <8ms，输入可感知延迟 <50ms（L2 日志）。
- [ ] 大文件、超长行自动降级纯文本（L3）。

验证：

swift build
.build/debug/utility workspace-check --highlight <fixture>

T10 git 状态与 diff

新建 Sources/Core/ProcessRunner.swift、Sources/Workspace/GitService.swift、GitStatusModel.swift、GitPane.swift、DiffView.swift；修改 FileExplorerPane.swift、FileEditorPane.swift。

验收：

- [ ] staged / unstaged / untracked 分组与 git status --porcelain 一致（L2）。
- [ ] 点击文件显示着色 diff，增删行颜色正确（L3）。
- [ ] 非仓库空状态、删除/重命名/二进制/无 HEAD 场景正确（L3）。
- [ ] 大型仓库刷新不阻塞窗口（L3，观察无卡顿）。

验证：

swift build
.build/debug/utility workspace-check --git <fixture>

T11 Markdown 与图片预览

新建 Sources/Components/MarkdownPreviewView.swift、Sources/Workspace/ImagePreviewView.swift；修改 KnowledgeMarkdownView.swift 复用共享视图、FileEditorPane.swift。

验收：

- [ ] .md 默认预览，可切源码，预览与源码同步（L3）。
- [ ] png/jpg/jpeg/gif/tiff/heic/webp 显示；超 20MB 与损坏图片提示（L3）。
- [ ] 远程资源被 CSP 阻止，链接交系统浏览器（L3）。

验证：

swift build
strings .build/debug/utility | grep -c "ImagePreviewView"

T12 i18n、文档、打包与回归

修改 zh-Hans.json、en.json、生成 L10nKeys.swift；更新 terminal.md、新建 workspace.md、AGENTS.md、README.md、README.zh.md。

验收：

- [ ] gen-l10n.py --check 与 check-l10n-contract.py 通过（L1）。
- [ ] swift build、run-tests.sh、package-utility.sh 通过，打包产物可启动（L1/L2）。
- [ ] 中英文切换文案完整；工作区、终端、文件、git、预览逐项回归（L3）。

验证：

swift build
bash scripts/run-tests.sh
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
bash scripts/package-utility.sh

MVP 与增强

┌────────┬────────┬────────────────────────────────────────────────────────────────────┐
│  阶段  │  范围  │                              交付标准                              │
├────────┼────────┼────────────────────────────────────────────────────────────────────┤
│ MVP    │ T1-T5  │ 选文件夹建工作区；主/子终端 cwd 正确；多子终端；底部可拖；重启恢复 │
├────────┼────────┼────────────────────────────────────────────────────────────────────┤
│ 完整版 │ T1-T12 │ 文件树、编辑、行号、高亮、保存冲突、git、Markdown/图片预览全部可用 │
├────────┼────────┼────────────────────────────────────────────────────────────────────┤
│ 增强   │ 后续   │ FSEvents 自动刷新、全文搜索、diff 行号、更多语言、工作区排序       │
└────────┴────────┴────────────────────────────────────────────────────────────────────┘

风险与规避

┌──────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────┬───────────────────────────────────────────────────┐      
│           风险           │                                                    规避                                                    │                     验证/回滚                     │      
├──────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤      
│ 多层 NSSplitView         │ 全局布局、视图常驻、拖动束后去抖、isApplyingLayout 防回写                                                  │ 记录切换前后 divider 位置；异常清空布局回默认     │      
│ 尺寸抖动                 │                                                                                                            │                                                   │      
├──────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤      
│ SwiftTerm 视图重挂载空白 │ 统一 attach(view:)：先移除旧父视图，再加约束、layoutIfNeeded、makeFirstResponder；启动前按容器尺寸预置     │ 用 stty size 核对行列；出现双父视图先查 attach    │      
│                          │ frame                                                                                                      │ 调用点                                            │      
├──────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤      
│ 迁移导致会话丢失         │ .bak、dry-run、旧文件不删、双写、backend 必写                                                              │ 删除 workspaces.json 后从 .bak 重建               │      
├──────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤      
│ 后台会话拖高             │ 只挂载当前工作区，切走即 detach                                                                            │ 3 工作区 CPU 对照；异常改为更激进的懒加载         │      
│ WindowServer             │                                                                                                            │                                                   │      
├──────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤      
│ 主线程阻塞               │ 文件枚举、git、图片解码、cwd 轮询全部后台；结果带 generation token 丢弃过期回调；ProcessRunner 超时        │ 日志记录 >100ms 操作                              │      
├──────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤      
│ 大文件/大图/高亮内存     │ 文本 5MB、高亮 1MB、图片 20MB、diff 2MB；只保留一个编辑器文档                                              │ 超限提示；降低配置阈值回退                        │      
├──────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤      
│ 编辑冲突丢失数据         │ 原子写、保存前 stat、未保存三选、退出拦截、保留 BOM/CRLF                                                   │ fixture 往返哈希；冲突保留缓冲区                  │      
├──────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤      
│ Markdown 外部资源        │ CSP 只允许 file:/data:，链接外跳                                                                           │ 远程图片被阻止的验收用例                          │      
└──────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────┴───────────────────────────────────────────────────┘      

验证

每个任务完成后运行对应命令，最终按以下顺序做完整验证：

swift build
bash scripts/run-tests.sh
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
bash scripts/package-utility.sh

L3 手工清单：

- 新建 2 个工作区，分别新建主终端与 2 个子终端，验证 cwd 与切换。
- 重启应用，验证工作区、分割条尺寸、会话恢复。
- 编辑文件触发未保存提示、外部修改冲突、CRLF 往返。
- 在 git 仓库查看 staged / unstaged / untracked 与 diff 着色。
- 打开 Markdown 预览、图片预览与大图/损坏图提示。
- 3 个工作区后台驻留 10 分钟，记录 CPU 与 WindowServer。

证据按 L1/L2/L3 标注；未达 L3 的项目在汇报中列出待验项。

批准后动作

- 把本计划同步到 .agent/plans/2026-11-04-terminal-workspace/plan.md 与 tasks.md，替换旧的 GUI 前置版本。
- 按 T1-T5 先交付 MVP，再继续 T6-T12。
- 未经用户明确允许不提交、不推送。