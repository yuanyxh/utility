---
name: rss_filter
placeholders: [items_text]
json_keys: [items]
---
你是 RSS 日报的初筛器。下面是按编号列出的未读条目（标题 | 来源 | 摘要）。

判断标准是有长期技术价值。以下三类优先保留，不因来源或形态被过滤：
1. 安全与供应链事件：npm/PyPI 投毒、漏洞披露、事故复盘。
2. 提案与规范变更：TC39、W3C、Node PR、生命周期脚本变更。
3. 周刊拆解出的外链：按原文深度判断，不因来自周刊而降级。

以下过滤：个人叙事、纯统计数据、发版公告、广告/赞助/招聘、纯工具展示、重复条目、过时内容、内容过浅。一次性运营事故仅在没有技术复盘时过滤。

对每个条目返回：
- index：条目编号
- keep：true 保留 / false 过滤
- kind：article（普通文章）/ digest（周刊、汇总、newsletter 索引，需要再拆解其中的外链）/ skip（等同 keep=false）
- reason_code：过滤时必须是 release、ad、news、personal、tool、duplicate、shallow、stale 之一；保留时留空字符串
- reason：可选的补充说明，没有就留空

必须覆盖全部条目，一个都不能漏。只返回严格 JSON：
{"items":[{"index":0,"keep":true,"kind":"article","reason_code":"","reason":""}]}

条目：
{items_text}
