# 项目状态

## 当前目标

1.1.42 基线整理：RSS 解析与去重、配置键对齐、基座按 agent-vibe 1.4.0 对齐。

## 进行中

- 换机迁移与首启引导：计划 `.agent/plans/2026-11-06-env-migration/`，T1–T11 完成。归档核心与设置导出面板、`EnvironmentProbe`、`CommandRunner`、`SetupProbe/SetupInstaller`、首启四步向导（导入→检测→安装→完成）均已落地；`GatewayInstaller` 强制 Python ≥ 3.12，Homebrew 缺失时写 `.command` 并打开 Terminal。文档：`README.md`/`README.zh.md`、`.claude/docs/architecture/portability.md`、CLAUDE 索引。验证：`swift build`、`run-tests.sh`（6/6）、`archive-check --roundtrip`、`setup-check`、swift-format 全过；隔离 HOME 截图确认向导 1/4 页，已有配置不出现向导；`Utility-1.1.91.dmg` 内二进制完整导出（1627 文件 / 117 MB）通过。修复：WAL 数据库缺少 `-shm` 时只读连接报 SQLITE_CANTOPEN（错误 14），读取器改为只读失败后回退读写；roundtrip 增加强制 WAL 无 sidecar 场景。待用户 L3：设置导出、向导导入、外部路径选择、真实安装与 Homebrew 拉起。未提交，待用户授权
- GUI 化重构：T1-T6 代码完成，`swift build` 与 `run-tests.sh` 通过；待用户 L3 手测（Dock、主菜单、设置保存、面板键盘、OCR 退出）
- 工作区协议化：计划 `.agent/plans/2026-11-05-workspace-protocol/`，T1-T13 完成并过两轮审查修复。状态层 + 五个窗格协议化（终端/子终端/文件树/Git/编辑器）、手型光标、⌘Z 脏点、git 忽略灰化、`ui` 字段 v2 持久化与 `.bak` 迁移、`--ui` CLI、文档与打包（`Utility-1.1.75.dmg` 已过期，需重打包）。审查修复两轮：滚动恢复布局、横幅跨文件泄漏、子目录灰化、status 失败被吞、切工作区残留；invalidate 代际号、脏重算 0.1ms、首启空态、备份只查一次、落盘收敛与 flush、指针方法去重、文档「窗格 vs 浮动面板」澄清。验证：`swift build`、`run-tests.sh`、l10n 双检查全过；列表选择三项回归（空白点击丢选中、选中底色变灰、图标与 x 按钮不变白）已修并经用户确认正常，代码已提交；已删 `PointerCursorController`（实测 0 次触发）、`FileTreeUIState.truncated`、`snapshot.workspaceID`/`focused`、`canHighlight`、`syntaxProvider` 注入参数；审查建议全部落地，`swift build` 与 `run-tests.sh` 全过
- 终端工作区：T1-T12 代码、文档与打包完成；检查点 A、B 通过；打包产物 `Utility-1.1.64.dmg`（app 19M / DMG 7.4M，卷根含 `Utility.app` 与 `Applications` 软链）；L3 逐项手测待做（切换与退出三选、脏文档横幅、只读保存、删除后另存为、中英文切换）

## 最近完成（2026-11-06）

- 列表选择回归三项（用户报告并手测通过）：空白点击不再清选中（`PersistentSelectionTableView` / `FileOutlineView` 早退）；选中底色由 `PointerRowView.drawSelection` 自绘，焦点转到编辑器/终端后仍是强调蓝；选中行文字、图标与行内 `NSButton`（子终端 x）统一转白，取消时按基色还原。`swift build` 与 `run-tests.sh` 全过。

- 工作区协议化收尾：`SubTerminalPane`/`FileExplorerPane`/`GitPane`/`FileEditorPane`/`TerminalHostView` 全部实现 `WorkspacePanel`，控制器统一 `render` 分发；分支、git 状态、忽略集合改由控制器写快照
- 编辑器：脏状态改用 `savedText` 基线 + 150ms 重算 + 撤销通知；越界回原内容脏点消失（隔离实例实测）；预览模式、光标与滚动位置写入快照（200ms 去抖）
- 持久化：`workspaces.json` 升 v2，工作区带 `ui` 字段（页签/展开/光标/滚动/预览），首次写 v2 前复制 `.bak`；重启恢复实测通过
- 光标：根因与修法沉淀在 `cursor-evidence.md` 与 `workspace.md`「光标（手型）」一节
- 验证：`swift build`、`run-tests.sh`、`gen-l10n --check`、`check-l10n-contract` 全过；打包 `Utility-1.1.75.dmg`（app 20M / DMG 7.5M，资源 bundle 存在）
- 独立审查（新上下文子 agent + 本人复验）：1 阻断 + 6 应修；已修 1 阻断 + 4 应修，见 `tasks.md`「审查修复（2026-11-06）」；滚动恢复用隔离实例验证 `scrollY=3000` 往返保持

## 最近完成（2026-11-05）

- 工作区 T1：新增 `Sources/Workspace/{WorkspaceModel,WorkspaceStore,WorkspaceMigration}.swift` 与 `workspace-check` CLI；`StoredTerminalSession` 增加可选 `workspaceID`/`role`，`backend` 继续必写
- 配置：新增 `workspace` 段（`showHiddenFiles`/`maxFileSizeMB`/`imagePreviewMaxSizeMB`/`ignoredDirectories`），属性初值、解码兜底、`default-config.yaml` 三处一致
- 工作区 T2：新增 `WorkspaceManager`（会话编排、tmux 生命周期、双写持久化、恢复计划）与 `WorkspaceReattribution` / `WorkspaceRestorePlan`
- 工作区 T3：新增 `WorkspaceWindowController`、`WorkspaceSplitView`；`AppDelegate` 启动/热键/退出与 `MenuBarManager` 入口改接 `WorkspaceManager`；旧 `TerminalManager`/`TerminalWindowController` 保留待 L3 验收后移除
- 工作区 T4：新增 `WorkspaceSidebarView`（列表、新建、双击重命名、右键移除确认、路径缺失标红）
- 工作区 T5：新增 `TerminalHostView`、`SubTerminalPane`（主终端 + 底部子终端内容与竖向列表）
- 工作区 T6：新增 `Sources/Core/PathRules.swift`（`ScannerConfig` 改为复用）、`FileTreeModel`、`FileExplorerPane`、`WorkspaceActivityBar`；`workspace-check --tree` 统计忽略后的文件数
- 工作区 T7：新增 `FileDocument`、`FileEditorPane`、`LineNumberRulerView`；文件树双击打开、`lastOpenedRelativePath` 恢复；编辑器改为横向滚动并按需定位行号
- 布局再次校正：`rightPaneWidth` 580、`fileListWidth` 200、右栏最小 525，保证编辑器可用宽度；窗口截图确认行号与代码对齐
- 工作区 T8：新增 `EditorDraftStore`、`EditorDraftDiffWindow`；`FileDocument` 加保存/外部变更/内容哈希；编辑器加 ⌘S/另存为、未保存三选、冲突横幅、2 秒草稿快照；文件菜单与退出拦截接线
- 工作区 T8 验证：`workspace-check --save/--draft` 断言 BOM/CRLF、同 size+mtime 内容变化判冲突、删除判据、草稿隔离与淘汰；隔离实例截图确认恢复弹窗、⌘S 落盘清草稿、外部修改自动重载
- 布局调整（2026-11-05 用户反馈）：主终端区加宽，`rightPaneWidth` 默认 560→480 并由主区吸收窗口缩放；右侧改为文件区在上、子终端在下；子终端面板标题由「工作区」改为「终端」
- 文件树交互：单击文件夹行任意位置切换展开/收起（三角除外），列表滚动区上下留白 6/16
- 工作区 T9：新增 `SyntaxDefinitions`（12 种扩展名）与 `SyntaxHighlighter`（关键字/字符串/注释/数字）；编辑器取可见范围上下各 200 行，编辑 100ms、滚动 50ms 去抖，着色时挂起 undo，输入法预编辑跳过，超 1MB 或 2 万行降级纯文本；`workspace-check --highlight` 输出 token 统计与耗时
- 文件列表自动刷新：新增 `FileTreeWatcher`（FSEvents，400ms 去抖，过滤隐藏目录与忽略目录），只重扫受影响目录并复用节点对象保留展开状态
- 工作区 T10：新增 `ProcessRunner`（不经 shell、超时、2MB 输出上限）、`GitService`（isRepository/status/diff）、`GitStatusModel`（porcelain `-z` 解析与分组）、`GitPane`、`DiffView`；ActivityBar 切换到 Git 列表，保存后与手动刷新 400ms 去抖；`workspace-check --git` 输出分组统计
- 工作区 T11：抽出 `Components/MarkdownPreviewView`（知识面板改为复用，接口不变；CSP 只放行 `file:`/`data:` 图片与内联脚本）；新增 `ImagePreviewView`（ImageIO 最长边 4096、20MB 上限、后台解码）；编辑器 `.md` 默认源码，右上角浮动「预览/源码」切换，图片扩展名直接预览。修复 `ImagePreviewView` 未关闭 autoresizing 导致所有文件无法显示的布局冲突
- 工作区 T12：新增 `.claude/docs/architecture/workspace.md`（存储、迁移、会话、布局、文件树、编辑器、高亮、git、预览与已知限制）；`terminal.md` 指向该文档，`CLAUDE.md` 与 `AGENTS.md` 索引同步；README 中英文「终端工作区」段重写；`swift build`、`run-tests.sh`、l10n 双检查、`package-utility.sh` 全过，产物 `Utility-1.1.64.dmg`
- 打包产物启动验证：只读挂载 DMG，卷根为 `Utility.app` + `Applications` 软链，Info.plist 1.1.64，二进制 arm64 17.3MB；DMG 内二进制跑 `workspace-check --help` 输出含 `--highlight`/`--git`；隔离 HOME 启动 61 秒稳定（RSS 129MB，tmux 子进程已建，SIGTERM 正常退出无残留）。挂载点会有一条 `sandbox_extension_issue_file_to_process` 警告，不影响启动。窗口可见性未验证（`osascript` 无辅助功能权限），归入 L3 手测
- 文件树滚动最终修复（1.1.72/1.1.73，用户实测通过）：根因是 `outline`/`table`/`tableView` 作为 NSScrollView 的 documentView 时关闭了 `translatesAutoresizingMaskIntoConstraints`，Auto Layout 下没有高度约束，滚动视图每次布局都按可视区把内容压回（日志实测 832→694）。改回默认 autoresizing + `autoresizingMask = [.width]`；`refreshTreeScroll` 只做 `reflectScrolledClipView`；诊断日志已移除。坑写入 `workspace.md`
- 文件树滚动（1.1.70）：`refreshTreeScroll()` 立即刷新一次并在下一轮 runloop 再刷新一次，异步那次额外调用 `scrollView.tile()`；根因是 `reloadItem` 后 outline 自身布局未结束，同步刷新被随后布局覆盖，所以首次展开滚不动、折叠再展开才生效。`restoreExpansion` 改为每条路径只消费一次，避免空目录导致无限递归。`[Tree]` 诊断日志暂留
- 审查修复（1.1.68）：工作区恢复打开文件时不再抢终端焦点（`open(focus:)`）；`workspace-check --git` 遇 git 失败输出 `git: error` 并退出 1，`--tree` 对非目录同样报错；`reload(nil)` 清空 Git 面板与 model；重新加载与草稿恢复清空撤销栈；另存为删除旧路径草稿；Git 面板语言切换重建分组；`imagePreviewMaxSizeMB` 真正生效；git status 截断抛错、`capture` 区分 no-index 的退出码 1；`containsSkippedDir` 不再把文件名当目录名。新增：文件树展开状态按工作区保存并异步恢复；子项加载后 `noteNumberOfRowsChanged()` 刷新内容高度。活动栏图标间距 6→14
- 工作区 UI 返修（14 项）：`.DS_Store`/`.localized` 无论开关都隐藏；`OverlayScrollView` 子类在 `tile` 与加入窗口时强制 overlay + autohide；活动栏 Git 图标加红底数字角标（`GitPane.onCountChange`，超 99 为 `99+`）；编辑器改用独立 `NSUndoManager`（`EditorTextView` 覆写），打开文件清空撤销记录，`EditingShortcutRouter` 在 `canUndo` 为假时放行事件并加日志；Edit 菜单补 `Cmd+F` 查找
- 工作区 UI 返修（10 项）：单击文件直接打开编辑器（双击按同 URL 去重）；子终端区底部新增 22pt 状态栏 `WorkspaceStatusBar`，左侧显示 `git branch --show-current`（detached HEAD 回退短 hash），工作区切换与窗口重新成为 key 时刷新；`workspace-check --git` 增加 `branch:` 输出
- 工作区 UI 返修（8 项）：`workspace.showHiddenFiles` 默认改 `true` 并让 `FileTreeWatcher` 跟随同一开关过滤隐藏路径；编辑器标题与 Git diff 标题改只显示文件名（完整路径进 toolTip）；Git 列表行只显示文件名；文件树图标 14→16、行高 26、活动栏图标 18pt；Git 面板标题显示总数（>99 为 `99+`），三个分组可折叠且右侧显示本组数量；编辑器与 DiffView 补 `scrollerStyle = .overlay`；文件树点击不再限制 `clickCount == 1`，连点第二次可折叠；工作区与子会话切换后在下一轮 runloop 把焦点交给对应终端视图
- 验证：`swift build` 与 `run-tests.sh` 通过；隔离 HOME + 隔离 tmux 启动真实二进制，日志 `[Workspace] migrated sessions=...`、窗口 `became key responder=TerminalDropView`、两个 tmux 会话同时 attached；窗口级截图确认新布局；落盘 sidebar 220 / right 480 / sub 260；证据级别 L3（窗口截图 + 用户实测热键/关闭）

## 最近完成（2026-11-03）

- RSS：解析失败返回 nil 并记录 feed/原始串；落库统一 `RSSItem.unknownDate`；迁移 v3 清理 17 组重复链接
- 配置：用户 `config.yaml` 与 `default-config.yaml` 键集合对齐（121/121），删除 `project_search.limit`、`terminal.backend`
- 基座：`seed_version: 1.4.0`、`.githooks/{pre-commit,commit-msg}`、backlog/upgrades/plans 模板、`memory/INDEX.md`、4 条 `.claude/rules` 补 `paths:`、`AGENTS.md` 收缩到 116 行
- 清理：7 个 `.DS_Store` 与 0 B `deps.sqlite` 已移废纸篓

## 最近完成（2026-11-04）

- 解耦：项目图库改由 gateway 写入 `.agent-gateway/graph.sqlite`，Swift 删除 `GraphDatabase`，`GraphScanner` 只发 `sync` 与文件事件
- 配置：`GatewayConfigWriter` 生成 `agent-gateway.yaml`；env 改为 `GATEWAY_*`，旧 `UTILITY_*` 保留一个发布周期；`skillDedupEnabled` → `toolOutputDedup`
- 新增 `scripts/e2e-isolated.sh`：临时 HOME 跑真实 `utility -a`，断言首建 4 符号 / 2 边、watcher 增量到 6 符号、lookup / impact 命中
- 图库刷新：`GraphIndexerClient.launch()` 把项目根传给索引器；索引器启动后在 `.agent-gateway/indexer.json` 登记，退出时注销；e2e 增加 live/stopped 断言
- 1.1.48 部署：MCP `project_lookup` 缺失图库与旧图库都在 30 秒后重建，第二次查询命中；部署版索引器被连续 SIGTERM 时注销会被中断，下一次查询会清理
- 1.1.49 部署：安装包与随包 wheel 均含 `SIG_IGN` 修复；真实 `utility -a` 索引器登记 live，退出后直接为空；MCP 缺失图库 35 秒后重建并命中；旧 agent 会话 30624/30631 仍运行 1.1.48 索引器，重启会话后才会登记
- 1.1.50 部署：安装包与随包 wheel 含 TZ / Overflow / 延迟导入修复；索引器登记 UTC 时间、退出后为空；MCP 缺失图库 35 秒后重建并命中；旧 agent 会话 41753/41760 仍是 1.1.49 索引器，需重启

## 验证（2026-11-04）

- `swift build` 通过；`bash scripts/run-tests.sh` 全过；`bash scripts/e2e-isolated.sh` 连续两次通过
- 1.1.45 部署验证：wheel 安装、MCP/代理健康、`agent-gateway.yaml` 生成、查询链路均正常；全量 `sync` 因压缩 JS 重复 `sym_key` 失败
- 1.1.46 部署复验：wheel 含去重修复，含 `marked.umd.js` 的项目全量 sync 成功（248 符号/47 边）；MCP 查询正常；旧 `utility -a claude` 会话（4760/4766）仍待退出
- 重启新会话后：旧 4760/4766 已退出，新 `utility -a claude --resume`（18693）拉起索引器 18700，环境无 `PYTHONPATH`（wheel 模式）；图库 4546 符号，watcher 已产生 `index_file`，服务健康
- 本机遗留迁移：`config.yaml` 的 `skillDedupEnabled` 改为 `toolOutputDedup`；`deps.sqlite` 移入废纸篓；agent-gateway（210 文件/2970 符号）与 agent-vibe（空图）完成图库迁移；agent-gateway / yuanyxh.github.io / generate-app 的 note 缓存已复制，旧 `.utility` 全部保留
- 审查修复：`GatewayConfigWriter` 保留 `search` 段（隔离 HOME 验证 `parallel=true` 不丢）；gateway 侧修 WAL 迁移、扫描链合并、idle env、契约；两仓 526 例 + run-tests + e2e 全过
- 1.1.47 部署复验：生成配置含 `search.parallel=true` 与 idle=600；含 `build/` 的临时项目全量 sync 只收 2 文件；旧会话 18693/18700 仍在跑旧索引器（日志可见扫描 `Utility.app/`），重启会话后由新 SKIP_DIRS 排除
- 13:53 重启复验：新会话 30624 + 索引器 30631（wheel 模式），旧进程已退出；图库 118 文件/4547 符号；新 `ping` 之后无 `Utility.app/` 或 `build/` 索引记录
- 15:40 重启复验：旧 30624/30631 已退出；新会话 41753 + 索引器 41760，索引器命令带项目根；`indexer.json` 登记 live；`project_lookup` 后未生成 `refresh.lock`，说明活索引器跳过刷新
- 图库刷新：`swift build` 通过；`e2e-isolated.sh` 登记 live → stopped；`run-tests.sh` 全过；后台重建定时器由 gateway 集成测试覆盖（L2）
- 1.1.48 部署复验：安装 wheel 含 `indexer_marker.py` / `refresh.py`；MCP `project_lookup` 缺失图库第一次 error、35 秒后 ok；旧图库第一次 no_match、35 秒后命中 `added`；部署版索引器退出条目残留，下一次查询清理
- 1.1.49 部署复验：安装包与随包 wheel 含 `SIG_IGN`；真实 `utility -a` 登记 live、退出后为空；MCP 缺失图库 35 秒后重建并命中
- 1.1.50 部署复验：安装包与随包 wheel 含 TZ / Overflow / 延迟导入修复；索引器登记 UTC 时间、退出后为空；MCP 缺失图库 35 秒后重建并命中
- 证据级别：L3（真实部署 MCP + 30 秒刷新；真实二进制 + 隔离 HOME 登记 live/stopped）；GUI 面板未验证；旧 agent 会话 41753/41760 需重启才用 1.1.50 索引器
- 1.1.56 打包验证：`Info.plist` 无 `LSUIElement`、签名有效、资源 bundle 完整（18M）、二进制含新功能标记；DMG 根目录是 `Contents` 而非 `Utility.app`，拖拽安装不可用
- 打包脚本已修并验证：1.1.58 DMG 卷根为 `Utility.app` + `Applications` 软链，含 `Cmd+M` 修复；该包不含动态激活策略
- 动态激活策略 L3 通过（1.1.59）：`Cmd+W` 关窗 → `accessory mainWindowActive=false`，热键重开 → `regular mainWindowActive=true`；最小化无 `restoring after focus loss`；GUI 手测项全部完成，待提交

## 阻塞

- 无

## 验证（2026-11-03）

- `swift build` 通过；`bash scripts/run-tests.sh` 全过；`verify-instantiation.sh` 0 errors / 0 warnings
- 已部署 `/Applications/Utility.app` 1.1.42，二进制含新日志串
- 迁移 v3 已执行：`rss_item` 4795→4778，重复链接组 0
- `rss --fetch` 实测：新增 32 条；31 条 `GitHub Trending Weekly` 无日期条目按预期记日志并使用哨兵；重复组仍为 0
- 证据级别：L2（真实库迁移 + 抓取日志断言）；配置热重载与日报渲染待下次定时任务验证（L3 待验）

## 最近完成（2026-11-07）

- 审查修复 10 项：notes 内嵌 liked/RSS 路径随父目录平移；`external[].archivePath` 严格校验；Xcode CLT 降为可选；安装失败信息不再被清空；安装页展示 Homebrew 官方脚本；manifest 记录 gateway wheel 并在不一致时作废安装戳；staging 在重选/校验失败/关闭时清理；外部目标预检可写；venv 缺解释器先移废纸篓；导出中禁用取消。
- 验证：`swift build` 通过；`run-tests.sh` 6/6；`archive-check --roundtrip` 覆盖嵌套路径平移与伪造 manifest 拒绝；`setup-check` 六项通过；改动文件 `swift-format lint --strict` 0 告警。
- 待验：设置导出、向导导入、真实依赖安装与 L3 手测。
- 编译告警清零：`AppConfig` 标为 `@unchecked Sendable`（纯值类型快照），`SetupModel.loadConfig` / `ExportModel.estimate`、`size` 标 `nonisolated`，导出闭包统一 `[weak self]` 所有权；并发类告警 0。

## 基座升级（2026-11-08）

- seed_version 1.4.0 → 1.5.0：新增 `steward`/`sandbox` 技能、`.agent/agent-health.md` 基线、`.agent/sandbox.md`、`.agent/.maintenance-state`、维护钩子与 SessionStart 注册；profile 补 `maintenance_*` 与 `isolation_*`。
- `verify-instantiation.sh`：0 warnings；2 errors 为既有校验器限制（`.githooks/pre-commit` 通过 `scripts/lint-staged-swift.py` 执行格式检查，校验器只匹配字面命令），未改钩子。
- 未执行：首次 `steward` 体检；`sandbox` 尚未实际创建环境。
- `CommandRunner` 已删除并统一到 `ProcessRunner`；上文迁移记录中的同类描述仅作历史，以本条为准。
