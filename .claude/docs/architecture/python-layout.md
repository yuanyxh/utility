# Python 层目录约定

Python 代码全部位于 `Sources/MCPScripts/`，随 SwiftPM `.copy("MCPScripts")` 整体进 bundle。

## 结构

```
Sources/MCPScripts/
  server.py / token_proxy.py / summarize.py / rss_daily.py
  knowledge_refill.py / ast_extractor.py   # 6 个入口 shim
  prompts/                        # 内置提示词，Swift PromptManager 也直接读这里
  utility/                        # 唯一顶层包
    core/       config db log_utils l10n l10n_catalog prompt_loader prompt_template
                tool_text tool_defaults synonyms agent_call
    llm/        client.py
    scanner/    ast_extractor.py + ast-js/
    services/
      mcp/      server* web_search 之外的 MCP 工具实现
      search/   engines.py（引擎搜索层）+ web_search.py（兼容 facade）
      fetch/    http.py（抓取层：UA/代理/限流/重试）
      markdown/ html.py（转换层：纯 HTML→Markdown）
      read/     read_service.py（内置 read_url 编排）
      proxy/    token_proxy + proxy_*
      rss/      rss_daily rss_article rss_render clash_proxy
      knowledge/ knowledge_engine knowledge_pool knowledge_refill
      summarize/ summarize summary_llm summary_rules summary_stats
```

## 入口 shim

根目录 6 个 `.py` 只做一件事：从 `utility/` 导入并调用 `main()`。Swift 的
`PythonScripts` 常量与 `findScript(named:)` 依赖这些文件名，**改名或删除会导致任务静默不可用**。

新增入口时：根目录加 shim + 在 `Sources/Core/Constants.swift` 登记 + 契约脚本会校验两侧一致。

## import 规则

- 一律**绝对导入**：`from utility.core.config import ...`、`from utility.services.proxy.token_proxy import ...`。
- 禁止 `sys.path` 操作；脚本以文件路径执行时 `sys.path[0]` 已是 `MCPScripts/` 根。
- 禁止相对导入（`from ..core import x`）——入口 shim 与模块被不同方式加载时行为不一致。

## 硬约束

1. **不能有顶层 `mcp/` 目录**：`requirements.txt` 依赖 pip 的 `mcp>=1.6.0`，同名会遮蔽官方包。MCP 实现放在 `utility/services/mcp/`。
2. **资源路径只有两处**，搬迁模块时必须同步：`utility/scanner/ast_extractor.py` 的 `SCRIPT_DIR`（找 `ast-js/`）、`utility/core/prompt_loader.py` 的 `_builtin_root()`（`parents[2]/prompts`）。
3. `prompts/` 留在根目录：Swift `PromptManager` 与契约脚本都按 `MCPScripts/prompts/...` 定位。
4. 契约脚本（`scripts/check-*.py`）把 `Sources/MCPScripts` 当 `sys.path` 根并按递归 glob 扫描；移动文件后要检查其中的路径常量。

## 验证

```bash
swift build
python3 -m compileall -q Sources/MCPScripts
python3 -m unittest discover -s tests/python -t .
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
python3 scripts/check-router-config-contract.py
python3 scripts/check-web-search.py
python3 scripts/check-search-cache-invariants.py
```

运行期冒烟：分别 `import` 6 个入口 shim（`server` 需要 `QDRANT_PATH`），再重启 app 检查 MCP / token proxy / RSS。
