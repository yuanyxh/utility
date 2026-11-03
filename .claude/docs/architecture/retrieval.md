# 检索性能约定（2026-09-11）

> 从 `AGENTS.md` 分层迁出（2026-11-03），内容逐字保留。
> 检索实现主要在 agent-gateway 仓；本文件记录宿主侧与跨仓共同遵守的结论。

- **notes 关键词搜索禁止 subprocess**：`search_cold_layer` 曾对 notes 目录「每个文件 × 每个 token」各起一个 `grep` 子进程 —— notes 有 454 个 .md，实测 2.4s(N=1) / 4.5s(N=2) / 7.5s(N=4)，**随 token 数线性放大**，是 `recall` 的最大单项开销。改为 Python 原生 `str.lower()` + `in` 一次读文件匹配全部 token；snippet 由 `_notes_snippet` 复刻 `grep -inF -m 3` 的输出格式（`行号:行内容`）。等价性已对拍验证（文件集合 100% 一致，仅保留源行尾部空格的差异）
- **`_ensure_note_cache` 不做目录 mtime 快速跳过**：曾用「项目**根目录** mtime ≤ 缓存中 .md 的**最大** mtime」判断，两者语义不同（根目录 mtime 只在直接子项增删时变化）——改深层已有文件会被漏判为「未变」而**返回陈旧结果**（正确性缺陷），根目录有增删则触发全量重扫。现始终 walk + 逐文件 diff（实测 453 个 .md 仅 7ms），只对真正变更的文件做 embedding，且待嵌入文本合批推理（`_embed_in_batches`）；单文件的「删旧行 + 插新行」在同一事务内提交以保证原子性
- **查询嵌入走 `server_embed.embed_query` 共享 LRU**（容量 `EMBED_QUERY_CACHE_SIZE`，默认 64，`0` 关闭缓存）：同一轮 agent 常对同一 query 并行调用多个检索工具，此前各自独立嵌入（单条约 45ms）。返回的 ndarray **就是缓存对象本身，调用方只读**
- mem0 内部使用它自己的 embedder，不经过 `embed_query`，那一路无法共享
- `recall` / `_contradiction_check_hot` 不再传 `rerank=True`：`MEM0_CONFIG` 未配置 RerankerFactory 所需的 `reranker` 段，mem0 内部条件 `if rerank and self.reranker` 恒假，该参数是空操作，留着只会误导后来的读者
