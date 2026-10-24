# 符号提取（Scanner）

> 从 `.claude/CLAUDE.md` 分层迁出（2026-10-18），内容逐字保留。
> 修改对应模块前先读本文件；CLAUDE.md 只保留必须遵守的不变量。

### 符号提取（Scanner）
- `ProjectScanner` 全量扫描 + `FileWatcher` 增量扫描，结果写入 `.utility/deps.sqlite`
- 多语言提取器通过 `SymbolExtractor` 协议注册，以扩展名为 key
- **提取优先级**：AST 脚本优先 → regex 提取器兜底 → 都失败则计数
- AST 连续 3 次失败后跳过（`failed_files` 表计数），文件修改后自动重置
- 支持的提取器：
  - `SwiftExtractor` — 正则 + brace-depth，class/struct/enum/protocol/extension/func/var/let/actor/macro/precedencegroup/operator。修饰符组贪心通用匹配（final/@objc/lazy 等任意修饰符）
  - `JSTSExtractor` — 正则，JS/TS/JSX/TSX 的 export function/class/const/interface/type
  - `PythonExtractor` — 正则，def/class/async def/UPPER_CASE 常量/装饰器。matchTripleQuote 行内任意位置检测，stripInlineComment 感知三引号
  - `VueExtractor` — 正则提取 `<script>` 块后委托 JSTSExtractor
  - `JavaExtractor` — 正则 + brace-depth，class/interface/enum/@interface/record + method + field + 注解追踪。方法名 `[a-z]` → `[a-zA-Z_]`（构造器/测试方法），所有正则前缀消耗 @Override 等行内注解
  - `KotlinExtractor` — 正则 + brace-depth，fun/suspend fun/class/object/companion/val/var/typealias + value/inline/annotation class + fun interface/data object。修饰符组贪心通用匹配（override suspend operator 等多修饰符），companionRegex 支持命名 companion
- AST 脚本 — `--batch` 模式：单次 subprocess 调用批量处理所有 AST 文件（`ast_extractor.py --batch`），通过 stdin 传入 JSON 数组，缩短总耗时
- AST 脚本目录：`Sources/MCPScripts/utility/scanner/ast_extractor.py`（Python 分发） + 同目录 `ast-js/parse.mjs`（@babel/parser）
- `.js` 文件始终启用 `jsx` plugin 以支持 React Native/Expo
- Java/Kotlin 用 regex 提取（无 AST 脚本），共享 `RegexMatch` 辅助结构（`ExtractorProtocol.swift`）
- RegexMatch 原为 SwiftExtractor fileprivate，后提升至 ExtractorProtocol.swift internal 供所有提取器复用
- 注意：macOS NSRegularExpression 使用 ICU 语法，不支持嵌套字符类（如 `[\], ]` 非法）
- **符号含 start_line/end_line 行号**（1-based，v3 schema，ProjectDatabase alter symbols 加列；FTS external content 表不重建）——支持定位代码范围/跳转/框出。`SymbolRecord` 带默认值 nil 的自定义 init，不破坏既有调用
- 正则提取器行号靠 **bodyStack 状态机**（带体 kind 栈，bodyDepth=nil 等待体后续行打开，brace-depth 回落定 end）；PythonExtractor 用缩进栈 `openDefs` + `lastContentLine`；EOF 收尾 end=lines.count。Swift/Java/Kotlin/JSTS 四提取器共享 `ExtractorProtocol.swift` 的 `SymbolBodyTracker`：`advance` 统一深度更新与 body 收尾，`attachSymbol` 统一单行体 / 后续行开体 / 无体判定
- 注释与字符串剥离合并为 `CommentStringStripper.strip`（ExtractorProtocol.swift），块注释/字符串分支**保留 \n\r**，修复跨行注释塌缩导致的行号错位（正则提取器行号准确的地基）
- AST 脚本节点加 start_line/end_line：`ast_extractor.py` 全部节点；`parse.mjs` symbol() 用 loc 展开（VariableDeclaration 用 decl.loc）；Vue 行号偏移补偿 `offset=content[:m.start(2)].count("\n")+lead_newlines`
- 坑：Swift 编译器对 `if top.bodyDepth == nil { break }` 后直接 `if newDepth < top.bodyDepth` 的流分析在部分文件失效，统一改 `if let bodyDepth = top.bodyDepth, newDepth < bodyDepth`（逻辑已收进 `SymbolBodyTracker.advance`）
- **全量扫描的写入是单事务原子替换**（`ProjectDatabase.replaceScanResults()`，2026-09-21）：清空全部表 + 写目录/文件/符号/包 + `symbols_fts` rebuild 全在同一个 `dbQueue.write` 内。旧流程是 `clearAll()` 先独立提交、等遍历与提取（大项目数十秒）跑完才由 `batchWriteFiles()` 写回——该窗口内 MCP 读者看到的是**空库**，检索工具一律返回「什么都没有」，模型据此判定代码不存在并重复实现已有功能；扫描中途被打断（Ctrl-C / OOM / 抛错）则空库一直留到下次扫描才恢复。**`clearAll()` 已整体删除，不要重新引入**：单独暴露一个可从外部调用的清库方法，会诱导后来者在扫描开头清库、把这个空窗放回来。`failed_files` **有意不清空**（AST 3-strike 记忆必须跨扫描保留），已消失文件的条目交给 `pruneFailedFiles`
- **模块根标记（`has_package_manifest`）的判定必须在 includes 过滤之前**：`package.json`/`pyproject.toml`/`Podfile`/`build.gradle`/`Package.swift` 都不匹配任何 include 模式（includes 只列源码扩展名），放到过滤后面就永远标不上模块根。标记**统一在遍历结束后回填**（`manifestDirs` 集合 → `dirMap`），不依赖枚举顺序——清单可能先于或后于其目录被枚举，父目录也可能由惰性创建补出。**不要拿目录名去比对清单文件名**（`isManifestFile(_:)` 那组是文件名常量，用目录名比对恒为 false，曾让该字段长期恒为 0）
- **增量删除必须按子树级联**（2026-10-23）：`FileWatcher` 发现路径已不存在时，除精确匹配外还要用 `instr(path, '<relPath>/') = 1` 删除 `files` / `symbols` / `failed_files` / `directories`。FSEvents 可能把整目录删除合并成一个目录事件，只按精确路径删会留下全部子文件（实测残留 66/242 文件、640 符号）。单文件删除不受影响，前缀条件对文件路径不会误伤
- **`imports` 表（v4）是文件级依赖边**：`from_path` / `raw_target` / `to_path` / `is_external` / `kind` / `line` / `confidence` / `resolver`。提取器只产出 raw（AST 1.0、正则 0.9、AST 失败兜底 0.6），`ResolutionContextBuilder` + `ImportResolverRegistry` 在写入前统一解析；目标文件不存在时 `to_path=NULL`，不猜路径
- **AST 成功按结果 key 是否存在判断**，不能用 `symbols.isEmpty`：只有 import、没有符号的文件不能被误判为 AST 失败；imports 的 AST 输出与 symbols 同批返回
- **新增语种只加两样**：`SymbolExtractor.imports(...)` + `LanguageImportResolver`，在 `ProjectScanner.init()` 与 `ImportResolverRegistry` 注册；需要 AST 时再加 parser 分支。DB / FileWatcher / MCP 查询不改
- 全量 `replaceScanResults(..., imports:)` 与增量 `replaceFileExtraction` 都把 symbols/files/imports/failed_files 放在同一事务；`deletePathSubtree` 删出边、入边保留 raw 并置 `resolver='stale'`
- MCP `project_dependencies` 只做 1 跳（outgoing/incoming/both）；旧库缺 `imports` 表时返回 `degraded`，不抛错
- **向量检索的符号缓存键必须用业务字段，不能用 `symbols.id`**：全量扫描 `replaceScanResults()` 先整体 `DELETE FROM symbols` 再重插、`FileWatcher` 增量路径（`Sources/CLI/FileWatcher.swift`）先 `DELETE FROM symbols WHERE file_path = ?` 再 `insertSymbols` —— **两条写入路径都「先删后插」**，同一符号每次重扫都拿到新自增 id；以 id 为键的 `symbol_embeddings` 会全部失效（曾 67438 行 0 行有效、占 132MB），下次向量检索重算全部符号（实测 349s）。现键 = `sha1(file_path|name|kind|signature|doc_comment)` = embedding 输入字段本身，**改这条必须保证键覆盖全部输入字段**
