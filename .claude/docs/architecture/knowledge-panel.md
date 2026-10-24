# 知识面板（knowledge_*.py + Knowledge*.swift）

> 从 `.claude/CLAUDE.md` 分层迁出（2026-10-18），内容逐字保留。
> 修改对应模块前先读本文件；CLAUDE.md 只保留必须遵守的不变量。

### 知识面板（knowledge_*.py + Knowledge*.swift）
- 从互联网取用户没想到过的新内容：**主题卡片**沿主线逐个概念推进，使用 `knowledge_engine.advance()`。碎片标签页与生成链路已移除
- **补货与显示分离**：`knowledge_refill.py` 后台按间隔补货入池，面板弹出直接从池读（秒开）。生成一张卡要 1~2 分钟（3 次 LLM 调用 + 检索），不能放在弹窗路径上
- ⚠️ **补货不能走 TaskScheduler**：`handleMissed()` 以「今天 00:00 后第一个 cron 点」为基准，`lastFire >= todayPoint` 即跳过 → 任何 sub-daily 的 cron 都静默退化成每天一次（`*/30 * * * *` 实测一天只跑一次，无任何报错）。改用 `KnowledgeService` 自建 Timer：「间隔」只是唤醒节拍，真正的开关是池容量
- ⚠️ **`runCaptureOutput` 默认不传 environment**：子进程继承 Utility.app（launchd 启动的 GUI 进程）环境，没有 `AI_API_KEY` / `UTILITY_DATA_DIR` → Python 侧 `default_target().ready == false`，静默返回 None、一张卡都出不来。已加可选参数 `environment:`，`KnowledgeService` 显式传 `PythonScriptRunner.environment(overrides: [:])`
- **Markdown 渲染 = WKWebView + 内嵌 marked.js**（`Sources/Resources/markdown/marked.umd.js`，v18.1.1，MIT）：GFM 表格/删除线/自动链接开箱可用，选中/复制/右键菜单由 WebKit 提供，链接点击经 `WKNavigationDelegate` 交给系统浏览器。资源被 `.process` 扁平化到 bundle 根，加载时同时尝试 `markdown/` 子目录与根目录；缺失则页面用 `textContent` 降级纯文本。**旧的 `AttributedString` 逐 run 字体映射已移除**——它不解析 GFM 表格，且 260 行映射表是纯手工维护成本
- ⚠️ **CJK 强调需扩展**（2026-10-24 实测）：CommonMark 的强调定界符是标点敏感的，`**邻居发现协议（NDP）**对自身` 这类「闭合 `**` 紧跟全角括号」默认不解析、原样输出星号。页面加载时注册 marked inline 扩展 `cjkStrong` / `cjkDel` 放宽闭合条件；围栏代码与行内代码不受影响（code token 先于 inline tokenizer）
- **样式覆盖全部节点**：`::selection` 自定义高亮（亮/暗两套）、`body/a/li/td` 统一 `overflow-wrap: anywhere` 防长 URL 裁切、`pre` 用 `pre-wrap` 换行、滚动条隐藏但可滚
- ⚠️ **WKWebView 必须关掉底色**：默认会画一张不透明白卡，和毛玻璃面板强烈割裂。`underPageBackgroundColor = .clear` 不够，必须 `setValue(false, forKey: "drawsBackground")`；注意 `responds(to: "setDrawsBackground:")` 返回 false 但 KVC 实际可用，不能用它做保护（2026-10-24 实测：窗口角落 alpha 从 1 变 0）
- **来源显示标题**：`evidence_urls` 存 `[{"url","title"}]`，标题取自维基/搜索结果；Swift 解码兼容旧的纯字符串数组，缺标题时回退域名。历史卡已于 2026-10-24 回填（206/344 成功，其余 403/超时保留空标题）
- **代码块与表格边界**：透明背景上纯灰 `rgba(127,127,127,…)` 看不出边界，必须用 `rgba(60,60,67,…)`（浅色）/ `rgba(235,235,245,…)`（深色）并带 1px 边框
  - 新 SDK 的 `intent.components` 元素是 `IntentType` 包装，真正的枚举在 `.kind` 上（当成 `Kind` 直接用会编译失败）
- **数据层**：`knowledge_pool.py` 是 schema 唯一所有者（`init_db()` 幂等迁移 + WAL）；Swift `KnowledgeStore` 只做裸 SQL、绝不建表、每个方法容忍缺表。跨进程同时打开同一文件 → **两侧都要 WAL + busy timeout**（只设一侧会回落 delete 模式互相阻塞），`nextCard` 的「读 + UPDATE shown_count」放同一写事务
- **卡片失败源几乎全是上游 LLM 超时/断连**，不是内容判据：`knowledge_card` 原带 thinking 生成 8k（单次 60~180s，`ReadTimeout` / `RemoteProtocolError: incomplete chunked read`）→ 现三处全部 `disable_thinking=True`，card 收窄到 4096
- `_llm_json` **区分「调用未返回内容」与「返回了但解析不出」**并分别记日志：混成一条会让上游超时看起来像提示词问题，真实成因只留在 `llm_client.log` 里
- `concept` 必须是**领域公认的标准名称**（提示词硬约束）：生造措辞一条资料都搜不到，卡片只能靠编（实测「分层协议栈模型」1 条无效 vs「TCP/IP 四层模型」10 条）；`gather_evidence` 在 concept 检索不足 `MIN_SEARCH_HITS` 时**退化为主题级检索**
- `gather_evidence` 的检索**只查 concept、不拼 theme**：`web_search._matches` 的多词判据是 AND 语义，拼上主题会让「分阶段架构 编译原理」直接返回 0 条
- `cards` 无 `shown` 状态：只有 `shown_count`。默认只取 `shown_count = 0` 的未读卡；自动关闭（用户没操作）的卡计入已展示，不再回到默认轮转
- `showReviewedCards = false` 时旧卡完全不出现；置为 true 才回退到 `shown_count < maxShownPerCard` 的旧卡，且未读卡仍优先
- **赞与踩都只标记并停留当前卡，不调用 `advance()`**；换卡只由定时自动弹出（`showAuto` → `advance`）与补货后的 `reloadCurrent()` 触发。面板不提供「已知」按钮。`saveLikedMarkdown` 为真时同步写出 Markdown 到 `likedSaveDir`；该值为空时从 notes 根派生 `<notes>/知识卡片`，禁止硬编码个人路径
- **落盘按主题分目录**：`<likedSaveDir>/<主题>/<补零 id>-<标题>.md`（如 `TCP-IP 协议栈/0054-网络策略.md`）。文件名用卡片 id，不用时间戳——同一张卡重复点赞保持同一路径；主题为空时直接落在根目录
- **两个 tab：卡片 / 列表**。列表只查轻量列（`id/title/theme/status/created_at`，`LIMIT 1000`）并按 `id DESC` 展示 `pool + liked`，双击行用 `card(id:)` 只读预览（**不更新 `shown_count`**），切回卡片 tab 显示；关闭面板丢弃预览，轮转位置不受影响
- **重启不换卡**：当前卡 id 持久化在 `UDKey.knowledgeCurrentCard`；`showPanel` 在 `currentCard == nil` 时先只读恢复，恢复不到才 `advance()`。只有自动弹出到点才推进——旧实现每次重启首次打开都会白吃一张
- 列表与正文都用 `hasVerticalScroller = false`：隐藏滚动条但滚轮/触控板照常可滚；列表 cell 走 `makeView(withIdentifier:)` 复用，不加载 `body/evidence`
- 被踩卡片是**生成侧负反馈**：`knowledge_pool.disliked_titles()` 取该主题 `status='disliked'` 的标题，作为 `{disliked}` 喂给 `knowledge_expand`（不要选它们及其相邻话题）与 `knowledge_gate`（第 5 条判据）。只标记不反馈等于白踩
- 来源 URL 不得是搜索引擎结果页：`gather_evidence._usable_source()` 过滤非 http(s) 与 `is_engine_page()`；Swift `KnowledgeStore` 解码时再过滤一次（旧卡兜底），展示用 `- <url>` autolink，避免 `[url](url)` 在 URL 含空格时退化成字面括号
- `option+k` 是纯显隐切换：可见时发 `requestClose`，不可见时发 `requestShow`；`showPanel` 只在 `currentCard == nil` 时取卡，已有卡原样显示（不再有「已消费」标记），池中无卡才会显示空态并触发补池
- `concepts` 只增不减（「展开过就算推过」）：严格单调前进、不可能死循环、崩溃自愈；代价是卡片生成失败会吃掉一个概念
- ⚠️ **主题必须带 `scope` / `exclude`**：只给主题名时，「下一个自然概念」会无限外溢（实测 TCP/IP 协议栈从 SDN 一路滑到意图驱动、AI 驱动、服务网格、eBPF、容器网络）。`scope` 写覆盖范围，`exclude` 写产品/厂商方案/行业趋势/新词；两者同时喂给 `knowledge_expand`、`knowledge_gate`、`knowledge_card`。`seed_from_config()` 对已存在主题也同步 scope（配置是种子主题边界的唯一来源）
- **选题闸门是独立的一次 LLM 判断**（`knowledge_gate`，零温度、512 token），不让 expand 自评：生成与审核分开，才不会被「自然引出」的叙事自我说服。四条硬判据：在 scope 内、稳定（非产品/厂商/近五年新词）、单卡能讲到机制层、是主题核心概念。拒绝的概念落 `rejected` 且**不烧 fail_streak**（闸门正常工作不是管线失败），下一轮不再重问
- `fail_streak` 只计**内容失败**（依据不足 / 卡片失败）；上游不可用（`expand_fail` / `card_unavailable` / `gate_unavailable`）与闸门拒绝都不计 —— 否则一次网络抖动或一次正常越界就能把主题永久标成 done
- ⚠️ **截断必须按截断处理**（2026-10-24 实测）：reason/why_now 在字符串中间被切断时，旧日志只报「解析不出 JSON」，掩盖了 `max_tokens` 预算不足。`parse_json_partial()` 返回 `(dict, repaired)`；expand/gate 允许按字段恢复，card 必须 `allow_partial=False`（半张卡不入池）。`chat(raise_on_error=True)` 的 `LLMClientError.content` 携带被截断的前半段
- 配置面 `knowledge.*`（`KnowledgeConfig`，YAML key 必须与属性名逐字相同）；env `KNOWLEDGE_TOPICS/TOPIC_TARGET/MAX_FAIL_STREAK/RETENTION_DAYS` 经 `knowledgeEnvironment()` 注入，**两个注入点都要合并**（`baseEnvironment()` + `taskEnvironmentOverrides()`）
- **保留期**：`retentionDays`（默认 365，0 = 永久）在每轮补货开始时删 `created_at` 超期的卡片；**liked 永久保留**（用户收藏），removed/disliked 过期即清
- ⚠️ **自检的证据必须给全文,不能截断**（2026-10-16 实测；自检步骤后因长输入必断连已移除，重建时必须遵守）：把 10469 字截到 6000 字后,模型把后半段的真实内容逐条判成「卡片自行添加」（violations 里列的正是被截掉的那些），同一张卡从 `ok` 翻成 `not ok`。缩短输入不是省钱,是批量制造假阳性
- **系统休眠不执行**：`willSleep` 置 `suspended` + 停两个 timer；已在跑的补货子进程由 `runCaptureOutput` 新增的 `shouldCancel` 闭包中止 —— 否则它被冻结后一直挂着（不耗 CPU 但占着端口与句柄），唤醒时又立刻撞上 wall-clock 超时被杀。`didWake` 清标志 + `rearm()` + 立刻补一轮
- 菜单栏「任务」子菜单里有一条知识补货（`知识补货 · 池 2/3 · 12:30 · made=2`，运行中打勾），但它**不注册进 TaskScheduler**：`mode: .manual` 虽不进调度,可点击会走 `TaskExecutor` 直接起进程,绕过 `KnowledgeService` 的防重闸门。现为手工追加一条 menu item,点击走 `KnowledgeService.launchRefill()`
