# 知识面板（knowledge_*.py + Knowledge*.swift）

> 从 `.claude/CLAUDE.md` 分层迁出（2026-10-18），内容逐字保留。
> 修改对应模块前先读本文件；CLAUDE.md 只保留必须遵守的不变量。

### 知识面板（knowledge_*.py + Knowledge*.swift）
- 从互联网取用户没想到过的新内容：**主题卡片**沿主线逐个概念推进，使用 `knowledge_engine.advance()`。碎片标签页与生成链路已移除
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
- `cards` 无 `shown` 状态：只有 `shown_count`。默认只取 `shown_count = 0` 的未读卡；自动关闭（用户没操作）的卡计入已展示，不再回到默认轮转
- `showReviewedCards = false` 时旧卡完全不出现；置为 true 才回退到 `shown_count < maxShownPerCard` 的旧卡，且未读卡仍优先
- 点赞只标记 `liked` 并停留当前卡，不调用 `advance()`；`saveLikedMarkdown` 为真时同步写出 Markdown 到 `likedSaveDir`；该值为空时从 notes 根派生 `<notes>/知识卡片`，禁止硬编码个人路径
- `option+k` 是纯显隐切换：可见时发 `requestClose`，不可见时发 `requestShow`；`showPanel` 只在 `currentCard == nil` 时取卡，已有卡原样显示（不再有「已消费」标记），池中无卡才会显示空态并触发补池
- `concepts` 只增不减（「展开过就算推过」）：严格单调前进、不可能死循环、崩溃自愈；代价是卡片生成失败会吃掉一个概念
- `fail_streak` 计入**卡片失败与自检未过**（需求字面只要求「展开失败或依据不足」，此处刻意取超集）：只算两项时，一个「每次都能展开但每次都幻觉」的主题会永不 done，无限烧 LLM 调用
- 配置面 `knowledge.*`（`KnowledgeConfig`，YAML key 必须与属性名逐字相同）；env `KNOWLEDGE_TOPICS/TOPIC_TARGET/MAX_FAIL_STREAK` 经 `knowledgeEnvironment()` 注入，**两个注入点都要合并**（`baseEnvironment()` + `taskEnvironmentOverrides()`）
- ⚠️ **自检的证据必须给全文,不能截断**（2026-10-16 实测）：把 10469 字截到 6000 字后,模型把后半段的真实内容逐条判成「卡片自行添加」（violations 里列的正是被截掉的那些），同一张卡从 `ok` 翻成 `not ok`。缩短输入不是省钱,是批量制造假阳性
- **系统休眠不执行**：`willSleep` 置 `suspended` + 停两个 timer；已在跑的补货子进程由 `runCaptureOutput` 新增的 `shouldCancel` 闭包中止 —— 否则它被冻结后一直挂着（不耗 CPU 但占着端口与句柄），唤醒时又立刻撞上 wall-clock 超时被杀。`didWake` 清标志 + `rearm()` + 立刻补一轮
- 菜单栏「任务」子菜单里有一条知识补货（`知识补货 · 池 2/3 · 12:30 · made=2`，运行中打勾），但它**不注册进 TaskScheduler**：`mode: .manual` 虽不进调度,可点击会走 `TaskExecutor` 直接起进程,绕过 `KnowledgeService` 的防重闸门。现为手工追加一条 menu item,点击走 `KnowledgeService.launchRefill()`
