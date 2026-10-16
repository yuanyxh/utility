# Utility 项目

**必须基于事实而不是猜测**

## 项目概述
macOS 菜单栏工具，Swift + AppKit + SPM。
- LSUIElement（无 Dock 图标）
- NSStatusItem 菜单栏入口
- NSPanel floating 面板：剪贴板管理、翻译、Stage 暂存
- Carbon EventHotKey 全局快捷键
- GRDB 本地 SQLite 存储
- Vision OCR 屏幕区域识别

## Git 流程
- 用户测试通过后才 commit
- 只提交暂存区（`git commit` 不加 `-a`）
- 提交前检查 `default-config.yaml`、`README.md`、`AGENTS.md` 是否需要同步更新
- 如需更新，改后等用户确认，不继续提交动作

## Build
- Clean build: `rm -rf .build && swift build`
- 二进制路径：`.build/debug/utility`、release 为 `.build/release/utility`（SwiftPM 维护的符号链接）
- 实际产物目录随 SwiftPM 版本变化（旧 `.build/arm64-apple-macosx/{debug,release}`，新 `.build/out/Products/{Debug,Release}`）——**脚本中禁止硬编码，用 `swift build -c <config> --show-bin-path` 查询**
- 验证改动进二进制：`strings .build/debug/utility | grep keyword`
- ⚠️ `package-utility.sh` 曾硬编码 `.build/arm64-apple-macosx/release/utility_utility.bundle` 且包在 `if [ -d ]` 里，新版布局下该目录不存在 → 资源 bundle 被**静默漏拷**（app 18M→9.8M），启动即 `Fatal error: unable to find bundle named utility_utility`（`resource_bundle_accessor.swift`）。资源缺失一律硬失败，不做条件跳过

## 核心架构

### PanelManager
- 面板零引用 PanelManager，仅通过 EventBus 发 requestShow/Close 事件
- PanelManager 唯一订阅 + 唯一调 showPanel/closePanel
- 栈结构 = 激活面板，后入栈顶
- dispatchKey：栈顶→底遍历，handleKeyEvent 对自己关心的键全 return true 阻断下层
- didResignKey：用 DispatchQueue.main.async 等通知链完再读 NSApp.keyWindow（不用 didResignActive）
- Stage 独立不入栈

### EventBus
- 线程安全 pub/sub，枚举 key 对应多 handler
- 跨模块通信走 EventBus，禁止直接持有对方引用

### Request 封装
- 请求封装类必须用 `RequestConfig` struct 收束所有控制参数（timeout/retryCount/headers/body/method/url）
- 不要拆成单独函数参数
- OpenAIClient/CustomClient 保持不动——新工具不为兼容已有代码而扭曲设计

### i18n
- JSON-dict 模式，`L10n + Bundle.module`
- `%@`（String）、`%ld`（Int）
- `refreshAllTitles()` 模式刷新运行时语言

### Stage 拖放
- `NSPasteboard(name: .drag)` 拖放结束后不清空，changeCount 不变
- 检测新拖拽：mouseDown 快照 changeCount → mouseUp 对比
- 仅检查 pasteboard 内容（hasContent）会因残留数据误判
- 图片类型统一定义在 `PasteboardImageTypes.all`

### 全局热键（HotkeyManager）
- `keyCodeMap` 必须**完整覆盖 26 个字母 + 常用符号**：表里缺哪个键，配了它的热键就 `parse` 失败，弹「热键解析失败」通知 —— 且**只影响用户自己配的那个键**，看起来像配置写错了
  - 实测踩坑（2026-10-16）：知识面板默认热键 `option+k` 部署后立刻报解析失败，根因是表里只列了 c/d/f/v/s/a/x/z/w/q/e/r/y/t **14 个字母**，没有 `k`。现补齐 60 条并与 `kVK_ANSI_*` 逐项核对
- `parse` 的 keyCode 用 `Optional`，**不能用 0 表示「未匹配」**：`a` 的 ANSI 键码就是 0，旧的 `guard keyCode != 0` 让 `cmd+a`/`option+a` 一律解析失败
- 热键只在 `AppDelegate.registerAllHotkeys()`（启动时调一次）注册，**配置重载不重注册** —— 改热键要重启 app

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
- AST 脚本目录：`Sources/MCPScripts/ast_extractor.py`（Python 分发） + `ast-js/parse.mjs`（@babel/parser）
- `.js` 文件始终启用 `jsx` plugin 以支持 React Native/Expo
- Java/Kotlin 用 regex 提取（无 AST 脚本），共享 `RegexMatch` 辅助结构（`ExtractorProtocol.swift`）
- RegexMatch 原为 SwiftExtractor fileprivate，后提升至 ExtractorProtocol.swift internal 供所有提取器复用
- 注意：macOS NSRegularExpression 使用 ICU 语法，不支持嵌套字符类（如 `[\], ]` 非法）
- **符号含 start_line/end_line 行号**（1-based，v3 schema，ProjectDatabase alter symbols 加列；FTS external content 表不重建）——支持定位代码范围/跳转/框出。`SymbolRecord` 带默认值 nil 的自定义 init，不破坏既有调用
- 正则提取器行号靠 **bodyStack 状态机**（带体 kind 栈，bodyDepth=nil 等待体后续行打开，brace-depth 回落定 end）；PythonExtractor 用缩进栈 `openDefs` + `lastContentLine`；EOF 收尾 end=lines.count
- 三个 `stripCommentsAndStrings`（Swift/Java/Kotlin）在块注释/字符串分支**保留 \n\r**，修复跨行注释塌缩导致的行号错位（正则提取器行号准确的地基）
- AST 脚本节点加 start_line/end_line：`ast_extractor.py` 全部节点；`parse.mjs` symbol() 用 loc 展开（VariableDeclaration 用 decl.loc）；Vue 行号偏移补偿 `offset=content[:m.start(2)].count("\n")+lead_newlines`
- 坑：Swift 编译器对 `if top.bodyDepth == nil { break }` 后直接 `if newDepth < top.bodyDepth` 的流分析在部分文件失效，统一改 `if let bodyDepth = top.bodyDepth, newDepth < bodyDepth`（四提取器对齐）
- **全量扫描的写入是单事务原子替换**（`ProjectDatabase.replaceScanResults()`，2026-09-21）：清空全部表 + 写目录/文件/符号/包 + `symbols_fts` rebuild 全在同一个 `dbQueue.write` 内。旧流程是 `clearAll()` 先独立提交、等遍历与提取（大项目数十秒）跑完才由 `batchWriteFiles()` 写回——该窗口内 MCP 读者看到的是**空库**，检索工具一律返回「什么都没有」，模型据此判定代码不存在并重复实现已有功能；扫描中途被打断（Ctrl-C / OOM / 抛错）则空库一直留到下次扫描才恢复。**`clearAll()` 已整体删除，不要重新引入**：单独暴露一个可从外部调用的清库方法，会诱导后来者在扫描开头清库、把这个空窗放回来。`failed_files` **有意不清空**（AST 3-strike 记忆必须跨扫描保留），已消失文件的条目交给 `pruneFailedFiles`
- **模块根标记（`has_package_manifest`）的判定必须在 includes 过滤之前**：`package.json`/`pyproject.toml`/`Podfile`/`build.gradle`/`Package.swift` 都不匹配任何 include 模式（includes 只列源码扩展名），放到过滤后面就永远标不上模块根。标记**统一在遍历结束后回填**（`manifestDirs` 集合 → `dirMap`），不依赖枚举顺序——清单可能先于或后于其目录被枚举，父目录也可能由惰性创建补出。**不要拿目录名去比对清单文件名**（`isManifestFile(_:)` 那组是文件名常量，用目录名比对恒为 false，曾让该字段长期恒为 0）
- **向量检索的符号缓存键必须用业务字段，不能用 `symbols.id`**：全量扫描 `replaceScanResults()` 先整体 `DELETE FROM symbols` 再重插、`FileWatcher` 增量路径（`Sources/CLI/FileWatcher.swift`）先 `DELETE FROM symbols WHERE file_path = ?` 再 `insertSymbols` —— **两条写入路径都「先删后插」**，同一符号每次重扫都拿到新自增 id；以 id 为键的 `symbol_embeddings` 会全部失效（曾 67438 行 0 行有效、占 132MB），下次向量检索重算全部符号（实测 349s）。现键 = `sha1(file_path|name|kind|signature|doc_comment)` = embedding 输入字段本身，**改这条必须保证键覆盖全部输入字段**

### Python 脚本统一入口（PythonScriptRunner + PythonDaemon）
- **`PythonScriptRunner`**（Sources/MCP/PythonScriptRunner.swift）：所有 py 脚本的 venv 路径（`pythonVenvPath`）、脚本路径解析（`findScript`，bundle→dev fallback）、环境变量（`baseEnvironment` 公共 AI/路径 + `environment(overrides:)` 脚本专属）、shell 命令构造（`shellCommand`，TaskScheduler .sh 用）、一次性执行（`runCaptureOutput`，边读边存防 pipe 阻塞 + 超时 kill）统一收束于此
- **`PythonDaemon`**（Sources/MCP/PythonDaemon.swift）：参数化常驻 Python 进程守护（启动/崩溃重启/健康检查/停止），`MCPProcessManager` 与 `TokenProxyManager` 共用。Config 通过闭包注入 `scriptPath`/`port`/`environment`——配置重载后 `forceRestart` 无需重建 daemon 即可应用新值；状态经 `onStateChange`/`onMaxRestarts` 回调上报，组合方自行映射自身 State enum 并广播
- ⚠️ **复用进程不留句柄 = 停不掉**（2026-09-21 修复）：冷启动复用健康进程（孤儿）时 `start()` **不设置 `process`**，`stopSync()` 的 `guard let proc = process` 直接 return，`forceRestart()` 因此关不掉孤儿、新 spawn 撞端口（uvicorn 报 `Errno 48` → exit 3），服务静默挂掉且不自愈。现 `forceRestart()` 在 `process == nil`（即复用场景）时调 `terminatePortOccupant()` 按端口清理监听者。清理用 `/usr/sbin/lsof -ti:<port> -sTCP:LISTEN` —— **`-sTCP:LISTEN` 绝不能省**，不带时会把「连接该端口的客户端」一并返回（实测 8613 返回正在走代理的 Clash Verge），照杀即误杀。清理**只放 `forceRestart()`，不进 `stopSync()`**（后者被 `stop()` 共用，波及 app 退出与配置 disabled 两条路径，有跨实例误杀风险）
- ⚠️ **崩溃判据漏掉非零退出码**（2026-09-21 修复）：原先只看 `reason == .uncaughtSignal`，而 Python 未捕获异常 / 端口绑定失败 / 外部 kill 都退化为 `.exit`（非零退出码被忽略）→ 静默置 `.stopped` 且永不重试、不通知；所谓「崩溃自动重启」实际只对 SIGKILL/SIGSEGV 生效。现为 `reason == .uncaughtSignal || terminationStatus != 0`（主动停止由 `isStopping` 提前 return，不误触发）
- ⚠️ **`terminationHandler` 的身份判断必须凌驾于 `isStopping` 之上**（2026-09-21 修复）：`forceRestart()` 的 `stopSync()` 置 `isStopping = true` 后**立刻**调 `launchProcess()`，而后者第一步就把该标志重置回 `false`；等这个由系统在自己队列回调、再被派发回 `lifecycleQueue` 的闭包真正跑起来时，标志早已失效 —— **旧进程的正常关闭被误判成崩溃**，于是每次重载配置凭空多 spawn 一个进程，它撞上仍被占用的端口后进入无限重启循环（实测 784 次、持续 49 分钟）。现为 `if process !== p { return }`，且**必须放在 `if isStopping` 之前**：`process` 已被替换成新进程即说明这次退出属于旧进程；真崩溃时 `process` 仍等于 `p`，判定不受影响
- **崩溃重启前先探测端口，健康则「认领」而非再 spawn**：崩溃分支在延迟重启的闭包里先调 `probeExistingServer()`，命中则 `crashCount = 0` + `state = .running`（日志 `Adopted healthy process after crash`），否则才 `launchProcess()`。理由是新进程撞上被占用端口是「崩溃」最常见的成因，再 spawn 只会重复撞，把一次端口冲突放大成重启风暴
- **端口解析必须缓存，禁止每次访问重新探测**（`PortProbe.swift` + 各 Manager 的 `currentPort`）：探测手段是对 127.0.0.1 做 bind 测试，而服务起来后**自己就占着那个端口**，再探测会跳过它返回下一个（9001→9002 / 8613→8614）。曾把 `port` 写成每次重算的 computed property，后果是运行期任何一次读取都拿到漂移值——`fetchTodaySummary()` 因代理自己占着 8613 而恒打 8614，菜单栏今日用量永远为空；`MCPClient` 则硬编码 9001 兜底，与 `MCPProcessManager` 的自动探测构成两处推导，9001 被占用时所有项目检索请求失败。现修法：公共逻辑收进 `PortProbe`（原先两个 Manager 逐字重复 37 行），`currentPort` 惰性解析一次并缓存，且**显式配置（`port > 0`）始终优先、不走缓存**（用户改配置要能立即生效）
- **PythonDaemon 的并发不变量**：`state`/`crashCount`/`isStopping`/`process` 由 `lifecycleQueue` 独占（`terminationHandler` 由系统在自己队列回调，必须收敛回该队列再读写）；`state` 的 `onStateChange` 回调统一 `DispatchQueue.main.async` 投递（消费方要更新菜单栏 UI）；`healthCheckTimer` 在主线程 runloop 上创建与失效
- **健康判据是纯函数 `isHealthyBody(_:service:)`**：复用探测（`probeExistingServer`，在 lifecycleQueue 上用信号量同步等待，不碰主线程故无死锁）与轮询检查（`checkHealth`，`@MainActor` + async/await）共用同一判据——两处各写一份会漂移，表现为「复用了进程却一直判定未就绪」
- **MCPProcessManager**：server.py 业务编排——State 5 态/EventBus 广播/端口复用探测（service=="mino-brain" 校验）/pythonCheck 预检/崩溃通知；进程生命周期委托 PythonDaemon
- 就绪检测：stderr 输出 "Application startup complete" / "Uvicorn running on"（readySignals）；token_proxy 静默启动直接健康检查
- 无启动超时杀进程——`terminationHandler` 处理真实崩溃，`isStopping` 标志防止 stop() 误触重启
- Python venv 路径 `~/.config/utility/mcp-venv/bin/python3`
- **健康检查必须 `async/await` + `@MainActor`**，不能用 `DispatchSemaphore`（阻塞主线程导致 URLSession 回调死锁）
- ⚠️ **env 有两个注入点，新增跨语言 env 必须两处都加**：一是 `baseEnvironment()`（MCP 服务与 token 代理进程消费），二是 `AppDelegate.updateMCPSummaryTask()` 里 `.sh` 任务的白名单（经 `shellCommand(environmentOverrides:)`）——后者**刻意不消费 `baseEnvironment()`**（`.sh` 走 `/bin/bash -c`，把继承环境与代理设置内联进命令串既污染又可能因值含空格而截断）。取值逻辑因此抽到 `aiEnvironment()` / `resolvedNotesDir()`，`.sh` 侧由 `taskEnvironmentOverrides()` 组装。漏掉第二处的症状是「服务进程里配置生效、定时任务里静默回退默认」：`AI_LLM_TIMEOUT` 与 `UTILITY_LANG` 就这样漏过一次（定时总结恒用 120s 超时——而 `ai.llmTimeout` 的消费方恰好全在 summarize；英文界面下仍走中文提示词，且因 `current_lang()` 已等于基线**连 warning 都不记**）
- **契约脚本第 3 组断言的是「实际注入点」而非「源码里出现过这个名字」**（`env["NAME"] = …` / `env[EnvKeys.xxx] = …`）：后者会被 `EnvKeys` 的声明本身满足，判据恒真——它看不见「漏了一个注入点」这类集合覆盖问题，而上面那次事故正是这样溜过去的。同组还有：脚本专属 env 的直读断言（覆盖 `MODEL_PROXY_*` 等不经 `config.py` 的名字，不再只兜 `MCP_SYNONYMS`）与一份**每条都必须写明理由**的豁免表 `_SCRIPT_ENV_EXEMPT`（`PATH` 系统提供；`EMBED_QUERY_CACHE_SIZE` 是有内置默认的内部调优值，非用户配置面）

### Token Proxy（token_proxy.py）
- aiohttp 反向代理，拦截 Claude Code API 请求记录 token 用量
- **模型路由（providers）**：config.yaml `modelProxy.providers` 定义路由表（`ProviderConfig`：name/url/apiFormat/anthropic|openai/apiKey/models）。`body.model` 精确匹配某 provider.models → 该 provider（上游 model 用原值）；未匹配 → `providers[0]` 兜底（上游 model 用其 models[0]）。`MODEL_PROXY_PROVIDERS` env 由 Swift `TokenProxyManager.providersJSON()` 从 config 序列化（**JSON 侧字段统一 snake_case**：`api_format`/`api_key`，由 Payload 的 `CodingKeys` 映射；YAML 用户配置面仍是 camelCase 的 `apiFormat`/`apiKey`，两者不是一回事）；providers 为空回退旧单上游 `MODEL_PROXY_URL`（兼容）。Python 侧字段解析的**唯一入口**是 `proxy_provider.py`（`api_format_of`/`api_key_of`/`missing_keys`），`token_proxy.py` 从这里读——两处各写一遍字段名时，Swift 一改名就双双静默退回默认值。`scripts/check-router-config-contract.py` 的契约校验覆盖 providers / client / env / 提示词 / 参数描述等全部跨语言契约面（`--selftest` 反向验证检查器本身）
- **协议转换**：客户端 anthropic ↔ provider openai 时 `ProtocolConverter` 双向转换（request_anthropic_to_openai / request_openai_to_anthropic / response_openai_to_anthropic）
- **鉴权 key 替换**：转发按 provider 替换 apiKey（openai 用 `Authorization: Bearer`，anthropic 用 `x-api-key`），为空则透传客户端 key
- **网关模型发现**：`GET /v1/models`（或兼容别名 `/open/v1/models`）返回 providers 全部模型，**响应 schema 按协议选择**（`_models_schema_for`：带 `anthropic-version` 头 → Anthropic 格式 `{data:[{type,id,display_name,created_at}],has_more,first_id,last_id}`；带 `Authorization: Bearer` → OpenAI 格式 `{object:"list",data:[{id,object:"model",created,owned_by}]}`；两者都无则按兼容入口兜底为 Anthropic 并记 `models_schema_fallback`）。只提供一种格式会让另一种协议的 SDK 解析失败。判据只用协议级请求头，不用 UA（UA 是客户端产品指纹、与协议无关）。**限制（v2.1.193 实测）**：Claude Code 对发现结果做客户端硬过滤（`/^(claude|anthropic)/i`），第三方模型（deepseek/mimo 等）全被滤掉、`/model` 选择器列不出——`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` 仅对 claude/anthropic 前缀模型生效；且 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`（值 `"1"`/`"0"` 均 truthy）会在 bootstrap 拦截模型发现。**切换第三方模型的正确姿势：`/model <名字>` 直接输入**（如 `/model mimo-v2.5-pro`），走 i5t 服务器探测（max_tokens:1 验证请求到代理）→ 代理按 body.model 路由
- **默认 provider 切换**：MenuBar「Proxy」菜单点击 provider 项 → `ConfigManager.setDefaultProvider`（移到 providers[0]）+ 持久化 + `TokenProxyManager.forceRestart()` 重启代理
- **转发入口两形态并存**：`/v1/*`（协议原生入口）与 `/open/*`（历史兼容别名，已配 `ANTHROPIC_BASE_URL=.../open/v1` 的用户不受影响）共用同一 handler，路径在 `_upstream_path` 归一为 provider 相对路径（`/v1/messages` 与 `/open/v1/messages` 都 → `v1/messages`）后原样转发到 `provider.url/{path}`。**协议判据优先取入口路径**（`_api_format_from_path`：Anthropic `v1/messages*`（含 `count_tokens`）/ OpenAI `v1/chat/completions`｜`v1/completions`），仅当路径不表明协议时才回退请求体启发式 `_detect_api_format`；两者不一致记 `format_mismatch` 告警而**不静默采信**——旧实现只靠启发式，无 system、无 tools 的单轮请求会落到 anthropic 兜底、被错误转换
- ⚠️ **转发上游时不得透传客户端的 `Accept-Encoding`**（2026-10-12 修复）：上游按这个头挑响应压缩方式——deepseek 实测声明 zstd 就回 zstd、声明 br 就回 br，**200 的 SSE 流也一样压**（不是只压错误响应）；而代理必须读并改写响应体（usage 提取、模型名注入、skill 去重、输出过滤）。客户端（Claude Code 二进制里的默认头表 `gzip, deflate, br, zstd`）的值被原样透传后，aiohttp 撞上解不开的编码即抛 `ContentEncodingError`（本 venv 既无 `Brotli` 也无 `backports.zstd`——zstd 是 aiohttp 3.14 新增能力、只随 `speedups` extra 安装），它继承 `PayloadEncodingError(BadHttpMessage)`、**code 恒为 400**，在 `ClientResponse.start()` 被包成 `ClientResponseError(status=400, message='Can not decode content-encoding: …')`，由 token_proxy 的 except 转成 502。**这个 400 不是上游状态码**：解码失败发生在解析响应头阶段，上游的**真实状态码与错误体一起被吞掉**（本来 200 的正常流也在被吞之列），客户端只看到来路不明的 502、反复重试（用户报障形态：日志里同一请求形态连发 3~4 次 `proxy_error`）。现由模块常量 `UPSTREAM_ACCEPT_ENCODING`（`gzip, deflate, br, zstd`）**自己声明**：`skip_headers` 加上 `accept-encoding` + `headers["Accept-Encoding"] = UPSTREAM_ACCEPT_ENCODING` **两处都要**（只赋值不跳过时 dict 里会留下客户端原值与你新加的两个键，两条头都发出去）。同时把解码库装进 venv（`Brotli` + `backports.zstd`，已写进 `requirements.txt`；**旧 venv 要补装**，且 aiohttp 的能力探测在 import 时做，装完必须重启进程）。**两层都要**：只装库也能治好当下这 502（HEAD 版本在装库后同样不再报错），但那样等于把「能声明什么」交给「这台机器碰巧装了哪些库」——客户端下次声明新编码就复发，且每次失败都连真实状态码一起吞；只收敛声明不装库则是白白放弃 br/zstd 的传输收益。契约脚本第 7 组把两者绑在一起断言：声明里每个编码本进程都解得开（判据取自 aiohttp 的 `HAS_BROTLI`/`HAS_ZSTD`，未装库就写进常量即红）、透传守卫必须排除 `accept-encoding`、必须有显式声明
  - 修复后实测（单进程内驱动真实 handler、上游真 deepseek，脚手架在 /tmp 未入库）：客户端声明 zstd / br / 不带 AE 全部 200（装库前的前两者是 502）；**42KB 多 chunk 长流完整收到 `message_stop`**（证明 zstd 逐块解压无损），usage 照常记录（output_tokens 346）；上游 4xx 的真实错误体也能透出来（`messages: at least one message is required`，HTTP 400），此前被伪装成 502
  - 同类风险不在 httpx 侧：`llm_client` 用的 httpx 只声明自己装了库的解码器（本 venv 实测默认头 `gzip, deflate`），不声明解不开的编码
- SSE 流式解析：`model` 在早期 chunk，`usage` 在最后 chunk，`stop_reason` 在 `delta.stop_reason`
- LLM usage field resolver：自动发现不同 provider 的 usage 字段路径，缓存到 SQLite `usage_field_cache` 表
- `cache_write_tokens` 恒为 0——deepseek/mimo 等 provider 的 usage 响应不含非零 `cache_creation_input_tokens`，resolver 路径已正确配置，属上游不返回（非解析缺陷）
- TokenProxyManager.swift：业务编排——State 语义/EventBus 广播/providers 路由（providersJSON→MODEL_PROXY_PROVIDERS）；进程生命周期（lifecycleQueue + terminationHandler + health check）委托 `PythonDaemon`
- `response_valid`：只有 `error` stop_reason 是无效，`max_tokens`/`end_turn`/`stop_sequence` 正常
- 费用估算已移除（不准确），`estimated_cost_usd` 字段已从写入侧、API 与表结构整体移除
- `session_id`/`project_path` 采集已废弃（Claude Code 请求 metadata 无此字段，全为空），`/usage/by_project` 端点与 Swift `ProjectCost` 已删除
- 用户设置 `ANTHROPIC_BASE_URL=http://localhost:8613/open/v1` 使请求经代理转发
- **分层记录模式**：`request_level` 字段区分 `core`（end_turn，最终回复）和 `process`（tool_use，工具调用）
- **输入过滤**：`actual_user_input` 跳过续接提示词与**已登记的**客户端注入标签（`proxy_client.ClientText`：`CONTINUATION_PREFIXES` / `SUMMARY_PREFIXES` / `CLIENT_INJECTED_TAGS`），并**剥离注入的规则块**。这两类文案取自**可配置表**（config.yaml `modelProxy.clientText` → `MODEL_PROXY_CLIENT_TEXT`，**增量补充**：内置默认在前、配置追加）——各客户端取值不同且随版本变化，写死单一客户端的文案会让其他客户端的续接/摘要文本混进 `actual_user_input`、并锚歪会话标识（`session_key` 以首条用户输入为锚）；未登记的长消息（≥ `UNREGISTERED_BLOB_MIN_CHARS`）记 `client_text_miss`（debug，含样本）便于补登记。标签清理**只按名剔除**，不能把任意 `<...>` 当标签——用户输入里的比较运算符（`if x < y and y > z`）或 HTML 片段会被整段吃掉（实测 `'if x < y and y > z: pass'` 被清成 `'if x z: pass'`）（`proxy_protocol.strip_injected_rules`，标记常量 `RULE_START_MARK`/`RULE_END_MARK` 由注入方唯一定义）。剥离必须**早于**标签清理——规则正文里的尖括号若先把 `---rule_end` 吃掉，剥离函数找不到结束标记会把块后面的真实用户输入一并丢弃。注入块可达数千字符而摘取上限只有 100~500，不剥离则三个字段看到的全是守则开头
- **错误记录**：`error_message` 字段存储 API 错误；SSE 流中断（ConnectionReset/BrokenPipe/RuntimeError/Cancelled）时记录异常类型与信息
- **超时配置**：`total=300s`（5 分钟），`sock_connect=10s`，`sock_read=30s`，捕获 `ConnectionResetError`/`BrokenPipeError`/`asyncio.CancelledError`
- **503 瞬时重试**：上游（deepseek 等 provider）偶发返回 503（"temporarily unavailable"）时等待 0.5s 重试，最多 3 次（`proxy_retry` 日志；策略值现由 `llm_client.DEFAULT_RETRY_503_MAX/DELAY` 提供，与 LLM 调用侧共用同一对常量）。根因：Claude Code 的 safety classifier 调用撞上上游 503 会导致 Bash 被拦截（2026-08-04 诊断：1090 请求中 25 个 503≈2.3%，latency 300-1300ms 快速拒绝，非超时）
- **classifier 请求加速**：auto mode 的 safety classifier 请求（deepseek 默认 thinking 时响应 28-32s，撞约 30s 内部超时 → Bash/Agent 被拦截）注入 `thinking: disabled` 后降至 1-3s。识别分两步——**结构判据** `_is_classifier_candidate`（纯结构启发式：stream != true + tools 空 + messages ≤ 2；v2.1.160+ 带 assistant pre-fill 为 2 条，真实对话几十到上百条；不匹配任何硬编码签名防版本静默失效，与客户端无关）+ **可配置客户端白名单** `proxy_client.matches_accel_client`（config.yaml `modelProxy.clientAccel` → `MODEL_PROXY_CLIENT_ACCEL`；**增量补充**语义：内置默认两条 = Claude Code 的 `x-anthropic-billing-header` 信号与 UA 信号、彼此 **OR**；同名覆盖，`enabled=false` 是唯一关闭开关）。客户端身份**不是协议事实**，故不写死指纹——写死会让其他客户端在同一结构的请求下拿不到加速、撞上游超时而拦掉其关键操作。注入用 `_inject_classifier_disabled`（anthropic 设 `thinking: disabled` + 移除 `reasoning_effort`/`output_config`；openai 仅移除 `reasoning_effort`）。**关键路径日志**：命中记 `classifier_thinking_disabled`（info，含 client/model/messages/api_format），命中白名单但非候选记 `classifier_check_skip`（debug，含 stream/tools/messages 供观测形态变化），未命中白名单记 `classifier_client_not_allowed`（debug，含 UA 摘要）——三类返回点可区分，修复失效可观测
- **输出提取**：`_extract_output_from_sse()` 从 SSE 流提取 LLM 输出文本，写入 `output_preview`（上限 2000 字符）
- **工具名提取**：`tool_name` 字段记录工具调用名称（Bash/Read/Edit 等），SSE 流提取优先，请求体 assistant 消息兜底不要求请求含 `tools` 定义（仅需 `stop_reason == "tool_use"`）
- **OpenAI 格式适配**：`_detect_api_format()` 三步检测（顶层 system 数组→messages[0].role=="system"→tools 定义格式）
- **OpenAI SSE 解析**：`_extract_usage_from_sse()` 归一化 `prompt_tokens→input_tokens`，`finish_reason→stop_reason`；`_extract_output_from_sse()` 读 `choices[0].delta.content`；`_extract_tool_name_from_sse()` 读 `choices[0].delta.tool_calls[0].function.name`
- **`finish_reason → stop_reason` 映射是单一常量 `FINISH_REASON_MAP`**（`proxy_protocol.py`），流式转换 / 非流式转换 / SSE usage 提取三处共用。曾三处各写一份且其中一份多一个 `content_filter`，于是「内容被过滤」在两个转换层被 fallback 成 `end_turn`——客户端与路由层都当成正常结束，异常信号整个丢失，而数据库里却如实写着 `content_filter`。未知值在**转换层**兜底为合法枚举（`FALLBACK_STOP_REASON`），在**记录层**保留原样（入库要如实）
- **协议参数双向转换的字段名陷阱**：Anthropic `stop_sequences` ↔ OpenAI `stop`（曾读 `stop` 导致该参数恒不转换、静默失效）；`tool_choice` 两种格式映射（auto/any/tool ↔ auto/required/function）；`_detect_api_format` 判 Anthropic tools 的字段是 `input_schema`（曾误写 MCP 的 `inputSchema`，分支永不命中）
- **规则注入（用户消息）**：`_inject_system_prompt` 从 `System_Prompts.md` 读取规则，注入到**每一条**真实用户输入（role==user 且 content 为字符串 / 数组含 text 块；纯 tool_result 消息不含 text 故被跳过），在该消息内插入 `---rule_start/---rule_end` 块。**必须全量注入，不能只注入最后一条**：注入点一旦跟随「最近一次真实发言」移动，用户每次发言时规则块就从旧消息消失，上游 prompt cache 自该处起整段失效——实测真实会话（逐条模拟 247 个请求）：移动注入点断 2 次、首次断掉整个前缀（公共前缀仅 43/102,603 字节），全量注入断 0 次、平均命中率 1.000。且**注入到 system 或 messages[0] 均不可取**：部分模型对 system 遵守率不稳定，messages[0] 会随上下文变大被污染，故只能靠「所有用户消息都注入」兼顾遵守度与前缀稳定——每条消息的注入是确定性的，前缀跨 turn 字节一致，最新一轮仍被覆盖。注入发生在代理转发时，Claude Code 上下文不含注入后 body（实测该会话 7 条真实用户发言的 content 全不含规则块，jsonl 里 `rule_start` 只出现在 assistant 消息与 attachment 中），故不累积。返回 `(body_bytes, 注入条数)`，文件缺失 / 读取失败 / 未命中为 0，未命中时记 `rule_inject_no_target` warning 防静默失效。**旧注已证伪**：曾称「注入位置在末位真实用户输入前，天然在缓存前缀外，无需 `cache_control`」——该缓存假设与实测不符，它恰恰每次跨 turn 改写前缀
- **skill 全文去重（`proxy_skill_dedup.py`，2026-10-10）**：本项目的 `think`/`hunt`/`health`/`ui` 等是 **mino-brain 的 MCP 工具**，不是 Claude Code 原生 skill，吃不到官方那套「渲染后内容相同则只加短提示」——同一会话反复调用同一 skill 时，每次都把整份 SKILL.md 再插一遍（实测 6 份逐字节相同 15184 B）。代理转发前扫入站 `messages`，**逐字节相同**的 tool_result / tool 文本第二份起换成 i18n 短提示，**保留第一次**（模型仍能在上文读到全文）。判据是内容而非工具名——代理拿不到 skill 名单（那份名单在 MCP server 内），且内容相同即语义相同；副作用是重复的非 skill 输出（两次相同 `ls`）也被折叠，无害且同样省 token。开关 `modelProxy.skillDedupEnabled` → `MODEL_PROXY_SKILL_DEDUP`（默认开，总是注入 `"1"`/`"0"`）
  - **必须在代理层而非 MCP server 层**：server 无会话历史视野，只能靠进程内状态记「已返回过」，多客户端/多会话共用一个 server 时会把 A 会话的加载状态泄漏给 B——B 收到「已加载」而上文没有 → 静默失效，最难排查的一类
  - **插入点在 `record_request_body` 之后、`ProtocolConverter` 之前**：记录层必须留原样，否则 `tool_output_log` 记的是替换后内容、度量标尺被自己毁掉；转换前只需处理一种格式
  - **只换文本不动外壳**：`tool_use_id`/`tool_call_id` 与消息结构保持，否则上游以「tool_use 缺少配对 tool_result」直接 400
  - **短提示 i18n**：`SKILL_DEDUP_NOTES` 按 `config.ui_language()`（← `UTILITY_LANG` ← `general.language`）选文案，缺该语言回退 `zh-Hans`，与 `tool_text`/`prompt_loader` 同源
  - **已知风险**：客户端 `/compact` 压掉上文后，模型读到「已加载」却找不到内容（官方同风险）
- **shell 工具输出瘦身（`proxy_output_filter.py`，2026-10-10）**：超长砍头尾（保留前 70% + 后 30%，插自证标记 `[... 已截断 N 字节 ...]`，文案按 `general.language` 选）+ JSON 无损 minify。开关 `modelProxy.outputFilter` → `MODEL_PROXY_OUTPUT_FILTER`（JSON 串，**总是注入**）。收益来自「事后过滤」——本代理是反向代理，看不到执行前的命令，**snip/rtk/context-compress 收益主体的 `inject`（执行前改命令，如 `go test` 注入 `-json` 275→8 token）整条路不可用**
  - **只对 shell 类工具生效**：Read/Edit 等是模型点名要的文件内容，截断等于损坏；shell 输出才是「命令五花八门、结果不可预期」的来源
  - **识别必须靠结构判据而非工具名**：`input` 含字符串 `command` 即 shell 类（协议级事实）。工具名**不是协议事实**——跨客户端各不相同（Claude Code=`Bash`、Anthropic 原生=`bash`、Gemini=`run_shell_command`、Cursor=`run_terminal_cmd`、Codex=`local_shell`/`shell`），硬编码 `"Bash"` 会让其他客户端接进来后过滤永不触发且**不报错**。`shellTools` 为可配置增量名单（内置默认 `("Bash",)` 作兜底）；名字不在名单但靠结构命中时记 `shell_tool_unlisted`（含名字），使新客户端可被**发现**（同 `client_text_miss` 模式）
  - **两种 API 格式各一份**：Anthropic 从 `tool_result` 块配 `tool_use_id` 取 assistant 的 `tool_use.input.command`；OpenAI 从 `role=="tool"` 消息配 `tool_call_id` 取 `tool_calls[].function`——**`arguments` 是 JSON 字符串，必须先 `json.loads` 才拿得到 `command`，解析失败则跳过命令级过滤（L1/L2 不受影响）**。与 skill 去重同样跑在**协议转换之前**（那时 `api_format` 是客户端格式）
  - **插入点在 `record_request_body` 之后、ProtocolConverter 之前**（与 skill 去重同处、**排其后**）：记录层必须留原文，否则 `tool_output_log` 的度量标尺被自己毁掉
  - **`foldRepeatedLines` 默认关**：连续重复行折叠为 `行 (xN)` 会**改变行数**，不是无损，与「L2 只做无损」的口径冲突；JSON minify 才是真无损（仅去空白，`ensure_ascii=False`）
  - **规则表默认空**：`rules`（`command`/`subcommand`/`dropLines`/`keepLines`/`maxBytes`，语义对齐 snip 的 filter）机制完整可用，但实测本项目**没有可规则化的模板噪音**——Bash 797 次/1.24MB 中 ≤4KB 占多数（是模型要的内容），>8KB 全是内容型（vue grep 结果、文章正文、TS 报错）。硬写规则只会凭空制造**误删风险**（误删静默且不可逆），等真出现靶子再补
- **响应注记（`proxy_response_note.py`，2026-10-10）**：代理在**响应末尾**追加一行 `{model} | 已执行: Bash 过滤/Skill 短提示`，让用户看得见代理改了什么。开关 `modelProxy.responseAnnotationEnabled` → `MODEL_PROXY_RESPONSE_NOTE`（默认开，总是注入）
  - **只追加在最终回复**：判据取**最后一个 content block 的类型**（`text` 才加，`tool_use` 不加），**不取 stop_reason**——后者要到 `message_delta` 才出现，那时 content block 已经 stop，来不及再补 delta。工具调用轮不加：那行的读者是用户，插在工具调用里既没意义、又可能干扰客户端对工具块的解析
  - **SSE 注入点是「延迟 `content_block_stop`」**：收到 stop 先缓存，等下一个事件才知道它是不是最后一个——是则在它前面补一个 `content_block_delta`（**复用该 block 的 index**，不新建 block、不管 index 递增），不是则原样放行；`finish()` 里残留的 stop 必是最后一个。这是全项目**唯一一处响应侧改写**
  - **无改写时也加**（显示 `{model} | 无改写`，`NOTE_EMPTY`）：模型名才是这行的主信息——新会话头几轮还没有 tool_result，skill_dedup / output_filter 都不触发，若此时整行消失就完全看不到当前模型（用户实测反馈）。代价是每条最终回复都要解析 SSE，「零开销纯透传」只剩开关关闭时那条路。400 错误响应与 `status >= 400` 一律不加
  - **feed/finish 收发 bytes 并使用增量 UTF-8 解码**（`codecs.getincrementaldecoder`）：SSE 分片会把多字节字符切成两半，逐片 `decode()` 会解出替换字符、污染 JSON。转换分支现有的 `chunk.decode(errors="replace")` 属同类隐患但不在本次范围
  - **注入的 delta 不进 `collected_body`**（先 extend 原始 chunk 再 feed）：usage 提取只看上游原始流，度量标尺不被自己改的内容污染
  - **未覆盖**：客户端 openai 格式的响应不加；openai→anthropic 的 SSE 转换分支暂未接入（当前配置两端都是 anthropic，走直通）
- ⚠️ **含 tool_result 的消息必须插到最后一个 tool_result 之后，禁止 `insert(0)`**：响应 tool_use 的消息里 tool_result 必须是 content 首个块，插到首位会把工具结果挤后，上游直接 400「`tool_use` ids were found without `tool_result` blocks immediately after」（Anthropic 官方 Troubleshooting 明列此错因）。触发形态是 Claude Code 在工具执行中用户插话产生的 `['tool_result', …, 'text']` 混合消息；**危害被回退机制放大**——混合消息一旦产生即成为「最近的真实用户输入」，此后每个末尾为纯 tool_result 的请求（即所有工具轮次）都反复命中它，持续 400 直到用户发出新的纯文本输入（线上表现为连续 2~3 次**完全相同**的 `messages.N` 错误后自愈）。判定侧 `is_real_user_input` 无需改动，只改插入点；无 tool_result 时 `last_tool_result = -1` 自然退化为 `insert(0)`，行为不变

### Python LLM 调用统一入口（llm_client.py）
- Python 侧**唯一 LLM 出口**。此前三处各自实现「读配置 → 拼 body/头 → POST → 取 content → 异常吞掉」：`summary_llm._llm_chat`（同步 httpx）、`server._check_contradiction`（异步 httpx）、`proxy_usage.UsageFieldResolver._ask_model`（异步 aiohttp）
- **不统一调用风格**：`chat`（同步 httpx）/ `achat`（异步，每次新建 `AsyncClient`——连接池绑定 event loop，本模块被两个进程导入，共享实例是偶发故障源）。强行同步化会卡死事件循环，强行异步化要改 summarize 全部调用链
- **配置唯一来源 `config.py`**，本模块不读 env、不持默认值。`proxy_usage` 的 `LLM_API_URL/LLM_API_KEY/LLM_MODEL` 三个别名已删除（同一份配置读第二遍 + 守卫条件散落）
- **`LLMTarget` 两个判据别混**：`ready`（endpoint+model 齐备＝可发请求）+ `configured`（再要求 api_key）。**api_key 为空是合法的**——provider 的 `apiKey` 留空表示透传客户端 key，把它并进「可发请求」会让所有这些 provider 的分类直接失效
- **协议差异按 `api_format` 分派**：鉴权头（`Bearer` ↔ `x-api-key` + `anthropic-version`）、响应取文本（`choices[0].message.content` ↔ `content[0].text`）。取文本的失败语义**有意不一致**：openai 缺 `choices` → `None`（失败），anthropic 缺 `content` → `""`（分类器既有语义：空答案）
- **关思考分两层**：`disable_thinking` 管协议层（anthropic 注入 `thinking:disabled` + 删 `reasoning_effort/output_config`；openai 无标准字段故只删推理参数）；provider **私有**扩展走 `extra_body`（如 deepseek 的 OpenAI 兼容端点接受 `thinking`）——写进公共层会让其他 openai provider 收到未知字段而 400
- **503 重试策略是单一权威**：`DEFAULT_RETRY_503_MAX/DELAY` 定义在此，`token_proxy` 主转发路径 import 同一对常量（同类故障两处都要处理）。缺省 `retry_503=0` 即不重试——**自带重试环的调用方必须保持 0**（分类器按 `maxRetries` + 总预算重试，两层叠加会把打转型上游放大成 N×M 次调用）
- 失败日志统一到 `~/.cache/utility/llm_client.log`（`msg=llm_call_failed` + `label` 保留各调用点原判定名，按旧名 grep 仍可命中）
- **超时单一来源**：`config.yaml ai.llmTimeout` → Swift `EnvKeys.aiLLMTimeout` 注入 `AI_LLM_TIMEOUT` → `config.llm_timeout()` → `llm_client.DEFAULT_SYNC_TIMEOUT` → 三处 summarize 侧常量（`summary_llm.SUMMARY_LLM_TIMEOUT` / `summary_rules.RULES_LLM_TIMEOUT` / `summarize.AGGREGATE_LLM_TIMEOUT`）全部引用它。原先三处各写死 90/120/120——换个慢模型要改三处、漏一处就在长上下文上超时失败，且没人知道哪个值在生效。**缺省/非数字/非正值一律回退默认 120**（与 Swift `OpenAIClient.init` 的 `timeout > 0` 约定一致；**不要**套用 `general.httpTimeout` 那套「0 = 不限制」，同一个 0 在两处含义相反）。分类器/resolver 仍传自己的超时（分类器按总预算、resolver 用更短的探测值）——调用方显式传 `timeout=` 时以调用方为准
- **⚠️ 两个 `aiTimeout` 别混**：`general.aiTimeout`（`ConfigDefaults.defaultAITimeout`）= agent/HTTP 调用超时，注入 `AGENT_TIMEOUT`；`ai.llmTimeout`（`ConfigDefaults.llmTimeout`）= Python 侧 LLM 单次推理超时，注入 `AI_LLM_TIMEOUT`。两者默认值恰好都是 120，合并会让「调大 agent 超时」意外改动 LLM 调用行为
- ⚠️ **坑：类内同名方法会静默覆盖**——新写的 `_classify` 覆盖了已有的 `_classify(turns)`，调用方拿到的是 `TypeError: missing 3 required positional arguments`，且只在运行到该路径时才暴露。新方法命名要避开既有名（现为 `_classify_with_provider`）
- ⚠️ `scripts/check-router-config-contract.py` 现在 import 链会拉到 `httpx`，用系统 `python3` 跑会在 import 阶段失败（报错与契约无关、易误导）——脚本已加 **venv 自举**（`os.execv` 到 `~/.config/utility/mcp-venv/bin/python3`），用法不变

### 提示词外置（prompt_loader.py + PromptManager.swift + prompts/）
- 提示词**不再写死在代码里**：Python 侧 11 个模板（`quality_judge` 判定 system、`quality_judge_user` 判定 user 前缀、`aggregate`/`merge_cross_batch`/`extract_keywords`/`decide_merge`/`gen_new`/`gen_merge`/`extract_rules`/`contradiction`/`classify_tier`）与 Swift 侧 2 个（`translate`/`translate_auto`）都在 `Sources/MCPScripts/prompts/<lang>/<feature>.md`，随 `.copy("MCPScripts")` 分发（bundle 内 `MCPScripts/prompts/...`）。**system 与 user 各占一份文件**——`quality_judge` 的 user 前缀原先硬编码为 `f"记忆内容：\n{text}"`，英文环境下会变成「中文前缀 + 英文 system」
- **两侧共用同一目录、同一契约**：改一句提示词、加一个语言，在 Swift 与 Python 是同一件事。Swift `PromptManager.parseTemplate` 与 `prompt_loader.parse_template` 逐条对齐（front-matter 键、name 校验、placeholders 双向自校验、渲染规则）
- **目录优先级**：`<配置域>/prompts/<feature>.md`（用户覆盖，**与语言无关**）→ 内置 `MCPScripts/prompts/<lang>/<feature>.md`（按当前语言 → `zh-Hans` 基线）。两处的语言维度**有意不同**：内置面向「使用者可能是不同母语的人」，用户覆盖是**用户自己控制**的一份文件——写 prompt 的人只有一种母语，让它「放哪个目录」取决于界面语言既无意义、又会因切换语言而失效。配置域复用**既有** env 契约：Swift 注入的 `UTILITY_DATA_DIR` 就是 `~/.config/utility`，故不新增 env 项。Swift 侧同序（`PromptManager.candidatePaths`，候选元组第二项 `nil` = 语言无关、不报语言回退），两侧顺序必须一致——否则会出现「Python 用了用户覆盖、Swift 用了内置」这种没法解释的组合
- **资源定位唯一来源**：`MCPScriptsResources.path(relative:)`（bundle → dev 目录）。`PythonScriptRunner.findScript` 与 `PromptManager` 都走它——两处各写一份 bundle 路径推导时，改了布局只改一处、另一处**静默读不到文件**（脚本表现为功能不可用，提示词表现为悄悄回退成兜底文案）
- **契约**（front-matter，扁平键、无 YAML 依赖）：`name`（必须与 feature 同名，防文件放错位置静默生效）、`placeholders`（与正文实际占位符**双向**自校验；Python 缺实参 → 抛 `PromptLoadError`，Swift → error 日志 + `{占位符}` 原样保留，多传只 warning）、`json_keys`（期望模型输出的键，空=未声明；Swift 侧无消费方，仅登记）
- **渲染禁用 `str.format` / 逐 key 替换**：提示词里大量出现 JSON 花括号（`{"action": "merge"}`），format 会当成占位符。两侧统一为「按名字**一次性**替换」——未登记的 `{...}` 原样保留，且替换进来的值不会被后续轮次误伤（逐 key `replacingOccurrences` 会让值里的 `{target}` 被二次替换）
- **加载失败链**：用户覆盖文件不合法（name 不符 / placeholders 声明与实际不符）→ error 日志 + **继续找下一个候选**（用户改坏了不该让功能停摆）；Python 侧内置也读不到 → 抛 `PromptLoadError`（安装损坏属开发期错误，静默给空提示词更糟）；Swift 侧最后回退 `L10n`（见下条）
- **Swift 的 L10n 兜底不是第二份文案**：`Resources/<lang>.json` 的 `prompt.translate` / `prompt.translate_auto` 只在 `MCPScripts/prompts/` 缺失（安装不完整）时启用——那时发一段空 system prompt 比直接失败更难排查（表现为「模型答非所问」而非「翻译报错」）。两层内容由契约脚本**逐字断言**（strip 后相等），不会漂移
- **语言**：`general.language` → `L10n.resolvedLanguage()`（**唯一判据**，Swift `L10n.setup()` 与注入 Python 的 `UTILITY_LANG` 同源）→ 选目录；该语言缺该文件 → 回退 `zh-Hans` 基线 + warning（未翻译不该让功能停摆，但不能静默）。基线常量两侧同值（`PromptManager.fallbackLanguage` / `prompt_loader.FALLBACK_LANG`）由契约脚本断言。**现状**：12 个 feature 均有 `zh-Hans` + `en`（未翻译的语言如 `ja` 回退中文基线并记 warning）
- **迁移方式是 AST 逐字提取**（脚手架在 /tmp，未入库）：提示词差一个标点不会报错、只会静默改变模型行为，故用 `ast.Constant.value`（**已解码**，f-string 里的 `{{` 在 AST 里就是 `{`）展平出「渲染后文本 + {占位符}」，并留快照做逐字比对。复杂插值（`group.get('topic','')` 等）登记进映射表转为语义占位符，未登记则脚手架直接失败。Swift 2 个由 `Resources/<lang>.json` 直接迁移（既有文本，非重写），生成脚本回读断言正文逐字一致
- **解析失败可观测**：`_llm_json(..., feature=...)` 在两次都解析不出 JSON 时记 `PROMPT_JSON_PARSE`；解析成功但缺模板声明的 `json_keys` 时记 `PROMPT_JSON_MISS`（**不改返回值**——缺键是「模型没按契约输出」，是否当失败由调用方定）
- **契约校验脚本第 5 组**：断言 24 份模板（12 feature × 2 语言）都被**生产解析器**（`prompt_loader.parse_template`）接受、占位符与基线登记一致、翻译版的 `json_keys` 与基线一致；Swift 侧有 L10n 兜底的两个 feature 还要求正文与 `Resources/<lang>.json` 逐字一致；基线语言两侧同值。基线语言**强制齐全**（它是其它语言的回退目标），`en` 按存在性校验——渐进补译是正常节奏。两个设计要点：解析取自**入参文本**而非重读磁盘（否则自检喂不进「假设的坏文件」，变异会静默无效）；遍历**期望集合**（语言 × feature）而非入参字典的键（否则「模板漏发」会因 key 消失而被静静漏掉）
- **翻译不能改结构**：占位符名、JSON 契约键（`"judge":`、`"relation":` 这些会被代码解析的键）在译文里必须原样保留——译文改名不会报错，只会在运行期表现为「渲染缺参」或「模型没按契约输出却检测不出来」。故 `json_keys` 有跨语言一致性断言，占位符有「与基线登记一致」断言

### 工具参数描述国际化（tool_text.py）
- **只做参数描述**（`inputSchema` 里的 `description`）。工具**描述**不在此列：`TOOL_DEFAULTS` 与用户自定义的 `DESCRIPTIONS.md` 本来就有覆盖渠道，且更长、改动更频繁，内置一份译文本只会多出一份没人维护的副本
- **键是语义名而非「工具.参数」路径**：18 条唯一文案在 schema 里出现 **23 处**（`param.db_path` 被 4 个 `project_*` 工具引用、`param.max_results` ×2、`param.memory_content` ×2）。按路径命名会让同一句文案在翻译时分叉成几份，「改一处忘三处」会随翻译一起放大
- `param_text(key)` 的语言判据与提示词**同源**（`config.ui_language()` ← `UTILITY_LANG` ← `general.language`），缺该语言回退 `zh-Hans`；`tool_text.FALLBACK_LANG` / `prompt_loader.FALLBACK_LANG` / `PromptManager.fallbackLanguage` **三处同值**由契约脚本断言（漂移会让同一份缺失在两条路径上得到不同结果，且都不报错）
- **未登记的键抛 `MissingParamText`，不回退成键名**：静默回退会把 `param.xxx` 这样的内部标识当文案发给模型；这类错误在静态层就被契约脚本拦下，运行期再兜底只会掩盖它
- **契约第 6 组**（静态 AST，不 import server.py——它导入即拉起 mem0/qdrant）：`handle_list_tools()` 内所有 `"description"` 必须经 `param_text(...)` 取，裸字面量与「无法判定的形式」都算违反；引用的键必须存在、表中不得有孤儿键、各键语言集合**一致且含基线**。看的是 dict 的 `"description"` 键，工具级 `Tool(description=...)` 是关键字参数、天然在范围外
- **混语言比统一未翻译更糟**：schema 是一次性整体呈现的，故断言「各键语言集合一致」而非「每键有基线即可」——后者允许一部分参数中文、一部分英文
- **`param.memory_content` 与 `TOOL_DEFAULTS["remember"]` 必须同为三要素口径**（场景/决策/演进）：两处描述的是同一段模型行为，分叉时模型收到两套要求（曾一处三要素、一处五要素，2026-09-18 用户裁定「三要素为主」后改齐）。用户自定义的 `DESCRIPTIONS.md` 是另一份自有文案（notes 目录、不随包分发），不受此约束
- 迁移**逐字一致**的判据取自 `git show HEAD:Sources/MCPScripts/server.py`（迁移前那一版）而非手抄：手抄的比对只能证明「我抄对了自己」（脚本在 /tmp，未入库）

### 知识面板（knowledge_*.py + Knowledge*.swift）
- 从互联网取用户没想到过的新内容：两个标签页（**主题卡片** = 沿主线逐个概念推进 / **碎片** = 领域池轮转），共用一套引擎 `knowledge_engine.advance()`
- **补货与显示分离**：`knowledge_refill.py` 后台按间隔补货入池，面板弹出直接从池读（秒开）。生成一张卡要 1~2 分钟（3 次 LLM 调用 + 检索），不能放在弹窗路径上
- ⚠️ **补货不能走 TaskScheduler**：`handleMissed()` 以「今天 00:00 后第一个 cron 点」为基准，`lastFire >= todayPoint` 即跳过 → 任何 sub-daily 的 cron 都静默退化成每天一次（`*/30 * * * *` 实测一天只跑一次，无任何报错）。改用 `KnowledgeService` 自建 Timer：「间隔」只是唤醒节拍，真正的开关是池容量
- ⚠️ **`runCaptureOutput` 默认不传 environment**：子进程继承 Utility.app（launchd 启动的 GUI 进程）环境，没有 `AI_API_KEY` / `UTILITY_DATA_DIR` → Python 侧 `default_target().ready == false`，静默返回 None、一张卡都出不来。已加可选参数 `environment:`，`KnowledgeService` 显式传 `PythonScriptRunner.environment(overrides: [:])`
- ⚠️ **Markdown 渲染**：`AttributedString(markdown:)` 只给语义属性（`presentationIntent` / `inlinePresentationIntent`），**不带任何字体** —— 直接塞进 NSTextView 是「标题与正文一样大、加粗不变粗、列表没有项目符号」，静默且只在弹面板时看得见。`KnowledgeMarkdownView` 逐 run 把 intent 翻成字体/段落样式；命中表格（GFM 表格它不解析）或解析失败则整体降级纯文本
  - 新 SDK 的 `intent.components` 元素是 `IntentType` 包装，真正的枚举在 `.kind` 上（当成 `Kind` 直接用会编译失败）
- **数据层**：`knowledge_pool.py` 是 schema 唯一所有者（`init_db()` 幂等迁移 + WAL）；Swift `KnowledgeStore` 只做裸 SQL、绝不建表、每个方法容忍缺表。跨进程同时打开同一文件 → **两侧都要 WAL + busy timeout**（只设一侧会回落 delete 模式互相阻塞），`nextCard` 的「读 + UPDATE shown_count」放同一写事务
- **卡片失败源几乎全是上游 LLM 超时/断连**，不是内容判据：`knowledge_card` 原带 thinking 生成 8k（单次 60~180s，`ReadTimeout` / `RemoteProtocolError: incomplete chunked read`）→ 现三处全部 `disable_thinking=True`，card 收窄到 4096
- `_llm_json` **区分「调用未返回内容」与「返回了但解析不出」**并分别记日志：混成一条会让上游超时看起来像提示词问题，真实成因只留在 `llm_client.log` 里
- `concept` 必须是**领域公认的标准名称**（提示词硬约束）：生造措辞一条资料都搜不到，卡片只能靠编（实测「分层协议栈模型」1 条无效 vs「TCP/IP 四层模型」10 条）；`gather_evidence` 在 concept 检索不足 `MIN_SEARCH_HITS` 时**退化为主题级检索**
- `gather_evidence` 的检索**只查 concept、不拼 theme**：`web_search._matches` 的多词判据是 AND 语义，拼上主题会让「分阶段架构 编译原理」直接返回 0 条
- `cards` 无 `shown` 状态：只有 `shown_count`。自动关闭（用户没操作）的卡回到轮转尾部而非被静默烧掉 —— autoClose 会频繁发生
- `concepts` 只增不减（「展开过就算推过」）：严格单调前进、不可能死循环、崩溃自愈；代价是卡片生成失败会吃掉一个概念
- `fail_streak` 计入**卡片失败与自检未过**（需求字面只要求「展开失败或依据不足」，此处刻意取超集）：只算两项时，一个「每次都能展开但每次都幻觉」的主题会永不 done，无限烧 LLM 调用
- 配置面 `knowledge.*`（`KnowledgeConfig`，YAML key 必须与属性名逐字相同）；env `KNOWLEDGE_DOMAINS/TOPICS/TOPIC_TARGET/FRAGMENT_TARGET/MAX_FAIL_STREAK` 经 `knowledgeEnvironment()` 注入，**两个注入点都要合并**（`baseEnvironment()` + `taskEnvironmentOverrides()`）
- ⚠️ **自检的证据必须给全文,不能截断**（2026-10-16 实测）：把 10469 字截到 6000 字后,模型把后半段的真实内容逐条判成「卡片自行添加」（violations 里列的正是被截掉的那些），同一张卡从 `ok` 翻成 `not ok`。缩短输入不是省钱,是批量制造假阳性
- **系统休眠不执行**：`willSleep` 置 `suspended` + 停两个 timer；已在跑的补货子进程由 `runCaptureOutput` 新增的 `shouldCancel` 闭包中止 —— 否则它被冻结后一直挂着（不耗 CPU 但占着端口与句柄），唤醒时又立刻撞上 wall-clock 超时被杀。`didWake` 清标志 + `rearm()` + 立刻补一轮
- 菜单栏「任务」子菜单里有一条知识补货（`知识补货 · 池 2/3 · 12:30 · made=2`，运行中打勾），但它**不注册进 TaskScheduler**：`mode: .manual` 虽不进调度,可点击会走 `TaskExecutor` 直接起进程,绕过 `KnowledgeService` 的防重闸门。现为手工追加一条 menu item,点击走 `KnowledgeService.launchRefill()`

### 共享 Python 日志模块（log_utils.py）
- `setup_logging(name)` 输出到 `~/.cache/utility/[name].log`
- 禁止 StreamHandler（pipe buffer 死锁），TimedRotatingFileHandler midnight 轮转 30 天
- server.py 和 summarize.py 已替换为使用此模块

### server.py（MCP Python 服务）
- mem0 热层（`Memory.from_config`）使用 Qdrant 本地存储 + fastembed 嵌入
- Qdrant 冷层独立集合 `knowledge_base`
- **embedder 维度由 fastembed 元数据解析**（`server_embed.resolve_embedder_dims()` 读 `TextEmbedding.list_supported_models()` 条目的 `dim` 字段；实测 `all-MiniLM-L6-v2` → 384、`BAAI/bge-base-en` → 768），查不到/字段不可用才回退 `384` + warning。**Swift 不参与注入维度**：维度是模型固有属性，另建一份「模型名 → 维度」映射必然与真实值漂移。元数据字段名（`model`/`dim`）提为常量——那是**外部库的字段名**，库改名时要一处红，而不是各处静默取不到、全体回退兜底
- **启动时校验冷层集合维度**：集合维度**首次创建即固定**，换模型后旧向量与新查询向量不可比，Qdrant 报 dimension 错误，而 `search_cold_layer` 把异常吞成一条 warning → 表现为「冷层检索静默失效、用户只觉得结果变少」。现在不一致即 `logger.error` + 处置建议（改回原模型 / 删集合按新维度重建并全量重扫）并**禁用冷层**（`qdrant = None`；其余 qdrant 用法均有 `if qdrant` 守卫，热层与项目检索照常）。降级而非拒绝启动：MCP 服务还承载热层记忆与项目检索，为一个冷层维度不符让整体不可用，损失大于收益
- 热层初始化含 PostHog 遥测 SSL 握手，双重禁用：模块级 `posthog.disabled = True` + 环境变量 `MEM0_TELEMETRY=False`（后者更关键——mem0 的 `AnonymousTelemetry` 创建独立 PostHog 实例，不受 `posthog.disabled` 影响）
- 热层惰性初始化：不在模块加载阶段执行，由 `_ensure_hot_memory()` 在首次工具调用时触发
- `FASTEMBED_CACHE_PATH`（注意不是 `FASTEMBED_CACHE_DIR`）是 fastembed 读取的环境变量名，两处设置此变量：server.py 模块级 + Swift `MCPProcessManager.serverEnvironment`（经 `PythonScriptRunner.environment(overrides:)` 注入）
- `MEM0_CONFIG["embedder"]["config"]` 不支持 `cache_dir` 参数（`BaseEmbedderConfig` 不接受），依靠 `FASTEMBED_CACHE_PATH` 环境变量让 mem0 内部 fastembed 找到已有缓存
- `tool_resource` 工具返回已注册 skill 的附属资源：path 必须位于 `references`/`agents`/`scripts` 之下，双重校验——normpath 语法层挡 `../` 穿越 + realpath 语义层解析 symlink 后仍须位于 skill 目录真实路径内（防附属目录内 symlink 指向外部文件泄露），读取用 realpath 结果避免 TOCTOU
- `_scan_skills` 递归 os.walk：目录含 SKILL.md（Waza 式目录 skill）→ 跳过 `_SKILL_SKIP_DIRS` 子目录且只注册 SKILL.md 本身；无 SKILL.md 的普通目录 → 其内所有 .md（含附属子目录）照常注册
- `_find_skill_dir` 按 normalize 后注册名定位 skill 目录；扁平 .md skill 不在目录注册表，定位失败返回 None → `"skill not found"`（设计使然非 bug）
- **检索同义词表 = 内置默认 + 用户增量**：`synonyms.py` 的 `SYNONYM_MAP` 是内置，`config.yaml` 的 `mcp.synonyms` 是用户增量（**同名覆盖、异名追加**，只写要加的、不必抄回整张表）。Swift `MCPProcessManager.synonymsJSON()` 把用户表序列化后按 `synonymsEnvKey`（`MCP_SYNONYMS`）注入，Python 侧 `load_synonyms()` 合并并缓存（env 在进程启动时固定，改配置要重启服务）。**该 env 不进 `config.py`**（脚本专属 env 的既有约定），故契约第 3 组的「Python 读了 Swift 必须注入」覆盖不到它——脚本单独交叉断言两侧常量同值（`find_synonym_env_violations`），否则改名后内置表照常工作、**用户配的同义词静默失效**（无任何报错）。**不迁入 notes**：检索质量不该成为可被静默改坏的变量，改坏了的表现是「搜不到」，与「这条记录本来就不存在」无法区分
- **工具参数默认值 = 内置默认 + 用户增量**（2026-10-10）：`tool_defaults.py` 的 `TOOL_ARG_DEFAULTS` 是内置，`config.yaml` 的 `mcp.toolDefaults` 是用户增量（**同名覆盖**，键结构 **tool name → args name → 值**）。Swift `MCPProcessManager.toolDefaultsJSON()` 序列化后按 `toolDefaultsEnvKey`（`MCP_TOOL_DEFAULTS`）注入，Python `load_defaults()` 合并缓存。**该 env 不进 `config.py`**，契约第 3 组同样覆盖不到——单独交叉断言（`find_tool_defaults_env_violations`）。默认值直接决定每次调用的**返回量即 token 消耗**，故做成配置面：`recall.limit=6`、`project_search.limit=15`、`project_structure.limit=15`
  - **schema 的 `default` 与 handler 兜底必须同源**：`DEFAULT_RECALL_LIMIT` / `DEFAULT_PROJECT_SEARCH_LIMIT` / `DEFAULT_PROJECT_STRUCTURE_LIMIT` 全部取自 `arg_default()`，两处各写一份字面量会漂移成「schema 声明 6、实际取 8」（recall 上次 10→8 踩过这个坑）
  - **`project_search` / `project_structure` 原先没有 limit 参数**：内部分别硬编码 `[:15]`/`[:10]`/全量 与 `MAX_ITEMS=200`，本次新增 `limit` 形参接入配置面。**`project_search` 的 exact 分支此前返回全量 `all_found`**（可达数百条），是输出膨胀的主因
  - **整数参数一律经 `_int_arg`**：客户端显式传 `null` 时 `arguments.get` 返回 None，直接切片 `all_found[:None]` 是**不截断**——静默把 token 治理关掉
- **MCP 层文案统一英文，重复的收敛为常量**：这一层（工具返回、HTTP 端点、`logger.*`）面向**模型与开发者**，不与 `UTILITY_LANG` 联动——面向终端用户的文案在 Swift 侧由 `L10n` 覆盖。盘点时发现 `'Hot layer not initialized'` 硬编码了 **6 处**，`set_memory_processed` 的 3 条参数校验在 MCP handler 与 HTTP 端点**各写一份**且是中文（与其余英文错误混着）——现收敛为 `ERR_*` 常量与 `err_bit_out_of_range()` 共用。判定口径：**重复出现的文案必须走常量**（单处出现的抽常量没有收益，重复的才有漂移风险；同一状态在两条入口提示不同，调用方无从归纳怎么改参数）
- `pyproject.toml` 未知，依赖见 `requirements.txt`

### OCR overlay
- 无文案提示
- 暗灰 0.5pt 边框
- 选区内半透明高亮 + 尺寸标注
- LSUIElement 下用 CGEventTap 拦截 ESC（passRetained + perform:afterDelay:）
- CGDisplayCreateImage 放后台线程
- 遮罩用 .nonactivatingPanel 不抢前台焦点

### 内存诊断
- `ps -p PID -o rss` → `leaks PID` → `vmmap --summary PID | grep "Physical footprint"`
- 多快照对比找增长趋势，heap 定位具体类
- utility 进程空闲时 physical footprint ~17MB baseline（AGENTS.md 有最新数据）

## 设计原则

### 最小暴露
- 类的内部实现用 private/fileprivate，仅对外暴露必要的 public/internal API
- 不在 AppDelegate 暴露内部属性供外部调用——自管生命周期

### 解耦
- 视图与逻辑分离：Service/Manager 不依赖 NSView/NSWindow/NSViewController
- PasteHelper、SelectedTextService、Translator、OCRService 全部无视图依赖

### 单⼀调用
- 核心逻辑不依赖 UI 上下文，可直接从 CLI 或无头模式调用

### Orchestrate 多 Agent 编排（设计沉淀，代码已移除）
> ⚠️ 现状（2026-08-03 确认）：`PlanManager.swift` + `OrchestrateCommand.swift` 从未被 git 跟踪，工作区开发验证后删除；`utility orchestrate` 子命令已不存在。以下为设计思路沉淀，核心已被 devflow 研发编排沿袭。
- 设计理念：loop 循环编排器——输入计划，启动多个子 Agent 进程（Coding Agent 持久化上下文 + Reviewer 干净上下文），循环直至计划完成
- 状态机：pending→oa_task→review→oa_response→done/blocked；OA（Orchestrator Agent）是最终决策者
- OA 通过 `--session-id <uuid>` 创建 + `--resume <uuid>` 恢复，跨 task 保持上下文
- Reviewer 用 `-p --no-session-persistence` 做干净一次性审查
- **Prompt 必须行动导向**（"直接修改源代码"），不是报告导向（"写入分析到文件"）——第二次测试 4 task 全部实际落码验证（2 新建 + 10 修改文件）
- 数据路径（设计）：`<项目>/.utility/plans/<name>.md`（plan）+ `<项目>/.utility/artifacts/<plan>/`（运行时产物）

### Claude Code CLI 关键标志（v2.1.193）
- `-p` 从 stdin 读 prompt（非位置参数），输出到 stdout
- `--session-id <uuid>` 创建命名会话；`--resume <uuid>` 恢复
- `--add-dir <dir>` 授予工具访问权限（无 `--dir`）
- `--no-session-persistence` 一次性用完不保存 session
- 原设计中 `--non-interactive` 不存在

### 拒绝猜测
- 看不懂某段代码为什么那样写时，先查 git log 看提交记录和 commit message
- git 记录看不出来时问用户，不要自己假设
- Bug 修复依赖现实调试信息，禁止靠猜测修改

## 未来规划
- Orchestrate 已实现 + 真实测试验证通过（2026-07-15），但代码已移除（2026-08-03 确认），设计沉淀见「Orchestrate 多 Agent 编排」小节与 `.claude/plans/agent-orchestrate.md`
- devflow 研发编排（云效需求拉取 → 子会话 → 状态流转 → 汇报）为当前落地方向
- MCP 移植、Agent 寄生模式已完成；项目依赖图持续维护
