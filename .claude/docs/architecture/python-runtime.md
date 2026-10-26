# Python 运行时（PythonScriptRunner / PythonDaemon / 日志）

> Python 源码在独立仓 `agent-gateway`（`src/agent_gateway/`）；本仓只有 Swift 宿主与打包时的 wheel。 进程一律按模块名启动（`GatewayEntry`），不再有脚本路径。

> 从 `.claude/CLAUDE.md` 分层迁出（2026-10-18），内容逐字保留。
> 修改对应模块前先读本文件；CLAUDE.md 只保留必须遵守的不变量。

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
- **MCPProcessManager**：MCP 服务业务编排——State 5 态/EventBus 广播/端口复用探测（service=="mino-brain" 校验）/pythonCheck 预检/崩溃通知；进程生命周期委托 PythonDaemon
- 就绪检测：stderr 输出 "Application startup complete" / "Uvicorn running on"（readySignals）；token_proxy 静默启动直接健康检查
- 无启动超时杀进程——`terminationHandler` 处理真实崩溃，`isStopping` 标志防止 stop() 误触重启
- Python venv 路径 `~/.config/utility/mcp-venv/bin/python3`
- **健康检查必须 `async/await` + `@MainActor`**，不能用 `DispatchSemaphore`（阻塞主线程导致 URLSession 回调死锁）
- ⚠️ **env 有两个注入点，新增跨语言 env 必须两处都加**：一是 `baseEnvironment()`（MCP 服务与 token 代理进程消费），二是 `AppDelegate.updateMCPSummaryTask()` 里 `.sh` 任务的白名单（经 `shellCommand(environmentOverrides:)`）——后者**刻意不消费 `baseEnvironment()`**（`.sh` 走 `/bin/bash -c`，把继承环境与代理设置内联进命令串既污染又可能因值含空格而截断）。取值逻辑因此抽到 `aiEnvironment()` / `resolvedNotesDir()`，`.sh` 侧由 `taskEnvironmentOverrides()` 组装。漏掉第二处的症状是「服务进程里配置生效、定时任务里静默回退默认」：`AI_LLM_TIMEOUT` 与 `UTILITY_LANG` 就这样漏过一次（定时总结恒用 120s 超时——而 `ai.llmTimeout` 的消费方恰好全在 summarize；英文界面下仍走中文提示词，且因 `current_lang()` 已等于基线**连 warning 都不记**）
- **契约脚本第 3 组断言的是「实际注入点」而非「源码里出现过这个名字」**（`env["NAME"] = …` / `env[EnvKeys.xxx] = …`）：后者会被 `EnvKeys` 的声明本身满足，判据恒真——它看不见「漏了一个注入点」这类集合覆盖问题，而上面那次事故正是这样溜过去的。同组还有：脚本专属 env 的直读断言（覆盖 `MODEL_PROXY_*` 等不经 `config.py` 的名字，不再只兜 `MCP_SYNONYMS`）与一份**每条都必须写明理由**的豁免表 `_SCRIPT_ENV_EXEMPT`（`PATH` 系统提供；`EMBED_QUERY_CACHE_SIZE` 是有内置默认的内部调优值，非用户配置面）
### 共享 Python 日志模块（log_utils.py）
- `setup_logging(name)` 输出到 `~/.cache/utility/[name].log`
- 禁止 StreamHandler（pipe buffer 死锁），TimedRotatingFileHandler midnight 轮转 30 天
- `services/mcp/server.py` 和 `services/summarize/summarize.py` 已替换为使用此模块
