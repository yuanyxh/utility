# RSS（采集 / 解析 / 日报）

> 从 `AGENTS.md` 分层迁出（2026-11-03），内容逐字保留，并补充 2026-11-03 的解析与去重约定。

## 内置日报

- 采集与编排同在宿主：`RSSManager.fetchAll()` 抓取，`RSSDigestService`（CLI `utility rss --digest`）跑完整日报，Python 侧不再有 `rss_daily`
- 日报由内部任务 `rss-daily` 驱动（`AppDelegate.updateRSSDailyTask()`），cmd 直接执行宿主二进制 `rss --digest --fetch`；`cron` 为空时注册 `manual` 模式；启用时直接 register，禁止先 unregister
- 抓正文与摘要走 gateway `/api/read`、`/api/summarize`；筛选、周刊拆解走 `/api/llm/chat`，提示词在 `Sources/Resources/prompts/<feature>.<lang>.md`（业务层持有，SwiftPM 会扁平化资源目录，语言写在文件名里）
- 三次 LLM 调用必须 `disableThinking` + `extra_body={"thinking":{"type":"disabled"}}`：不关闭思考会耗尽 `max_tokens`
- LLM 只返回 JSON；标题格式、来源方括号、归档路径由 `RSSDigestRender` 确定性拼装
- 同一天重跑按去重键**追加**到当天归档（`mergeWithExisting`）：文章用 URL 归一化，过滤项用 URL（无 URL 时用标题）；空结果不会清空已有日报与过滤记录
- 单篇抓取/总结失败降级为「已过滤条目」，不中断整次日报

## 解析与去重（2026-11-07）

- 日期解析失败时 `parseDate` 返回 `nil`，记录 `feed` 与原始串，落库使用 `RSSItem.unknownDate` 哨兵并记 `dateKnown = false`
- 解析成功但早于或等于 1970 的占位日期（如 `0001-01-01`）同样按未知处理，避免新旧数据判定不一致
- `unread(maxAgeDays:)` 的发布时间窗把未知日期放行：`pub_date >= cutoff OR date_known = 0`
- 入库去重按 `id` 或非空 `link`：同一条目经不同 feed（如 HN 与原文源）以不同 guid 出现时只保留首次入库行
- 迁移 v3 一次性清理历史重复链接：同一 link 保留未读行，全部已读时保留最早行
- 迁移 v4 新增 `date_known` 列，并一次性把既有 `pub_date <= 1970-01-01` 的行标记为 0
- 历史未知日期条目无法回溯真实日期，仅以哨兵存储；判定统一看 `date_known = 0`
