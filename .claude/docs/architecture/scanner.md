# 符号提取（Scanner）

> 2026-11-02 移除：`.utility/deps.sqlite` 符号扫描链（ProjectScanner / ProjectDatabase /
> 各语言 extractor / import resolver / FTS5 符号索引）已整体删除；agent-gateway 侧对应读取模块
> （project_tools / search_symbols / search_vectors / server_search）同批移除。

现役项目索引只有 `.agent-gateway/graph.sqlite`，扫描与写入都在 agent-gateway
（`services/graph/project_scan.py` / `store.py`）；`GraphScanner` 只发 `sync` 与文件事件，
`FileWatcher` 只做事件过滤。设计、schema 与查询约定见
`.claude/docs/architecture/project-graph.md`。
