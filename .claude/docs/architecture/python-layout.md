# Python 层目录约定

Python 代码全部位于 `Sources/MCPScripts/`，随 SwiftPM `.copy("MCPScripts")` 整体进 bundle。

## 结构

```
Sources/MCPScripts/
  server.py / token_proxy.py / summarize.py / rss_daily.py
  knowledge_refill.py / ast_extractor.py / minod.py   # 7 个入口 shim
  prompts/                        # 内置提示词，Swift PromptManager 也直接读这里
  utility/                        # 唯一顶层包
    core/       config config_loader ports daemon db log_utils l10n l10n_catalog
                prompt_loader prompt_template tool_text tool_defaults synonyms agent_call
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

根目录 7 个 `.py` 只做一件事：从 `utility/` 导入并调用 `main()`。Swift 的
`PythonScripts` 常量与 `findScript(named:)` 依赖这些文件名，**改名或删除会导致任务静默不可用**。

新增入口时：根目录加 shim + 在 `Sources/Core/Constants.swift` 登记 + 契约脚本会校验两侧一致。

## import 规则

- 一律**绝对导入**：`from utility.core.config import ...`、`from utility.services.proxy.token_proxy import ...`。
- 禁止 `sys.path` 操作；脚本以文件路径执行时 `sys.path[0]` 已是 `MCPScripts/` 根。
- 禁止相对导入（`from ..core import x`）——入口 shim 与模块被不同方式加载时行为不一致。

## 硬约束

1. **不能有顶层 `mcp/` 目录**：`requirements.txt` 依赖 pip 的 `mcp>=1.6.0`，同名会遮蔽官方包。MCP 实现放在 `utility/services/mcp/`。
2. **资源路径只有两处**，搬迁模块时必须同步：`utility/scanner/ast_extractor.py` 的 `AST_JS_DIR`
   （`files("utility.scanner")/"ast-js"`）、`utility/core/prompt_loader.py` 的 `_builtin_root()`
   （包内 `prompts` 优先，源码树回落 `parents[2]/prompts`）。
3. `prompts/` 留在根目录：Swift `PromptManager` 与契约脚本都按 `MCPScripts/prompts/...` 定位。
4. 契约脚本（`scripts/check-*.py`）把 `Sources/MCPScripts` 当 `sys.path` 根并按递归 glob 扫描；移动文件后要检查其中的路径常量。

## 配置读取

`config.yaml` 是唯一用户配置面，`utility/core/config.py` 仍是唯一消费入口。取值顺序：

1. 显式 env（Swift `PythonScriptRunner` 注入）
2. `utility/core/config_loader.py` 读 `<UTILITY_DATA_DIR>/config.yaml`（按 path/mtime/size 缓存，
   重载后下一次读取即生效）
3. 访问器传入的 `default`

`_YAML_FALLBACKS` 把 env 名映射到点分键，并声明序列化形态（`text` / `json` / `csv`），
下游 `json.loads`、逗号切分等解析逻辑不必为 YAML 单独分支。新增配置面 env 必须同时登记映射，
否则 `scripts/check-config-parity.py` 报红。`UTILITY_DATA_DIR`、`UTILITY_BIN`、`UTILITY_USER_ID`
属于运行时事实，在脚本的豁免表里；`NOTES_DIR` 映射到 `mcp.knowledgeBasePath`，为空时由
`config.notes_dir()` 派生 `<config root>/notes`。

### runtime.selfManaged

`selfManaged: true` 时 Swift 停止注入配置面 env（ai / knowledge / note / log / rss / NOTES_DIR），
由 Python 读 `config.yaml`；运行时值（`UTILITY_DATA_DIR`、`UTILITY_BIN`、端口、代理、超时）照旧注入。
例外是 `UTILITY_LANG`：语言由配置与系统偏好合成，Python 无法从 `general.language` 单独解析
「跟随系统」，因此始终注入。默认 `false`，回滚只需改配置。

`minod` 目前只提供 `--check`（配置根、config.yaml 可解析、Python ≥ 3.12、状态目录、端口可用或健康）；
服务启动需要把 Swift 侧的 env 派生迁到 Python，属 P3。

## 端口与运行时状态

`utility/core/ports.py` 与 `utility/core/daemon.py` 供无 Swift 父进程的常驻形态使用。

- 端口判据是 bind 测试（不开 listen），与 Swift `PortProbe` 一致；**调用方负责缓存**，
  服务起来后探测自己的端口会得到下一个空闲端口
- 清理只杀监听者：macOS `lsof -ti:<port> -sTCP:LISTEN`，Linux 先 `ss -lptnH` 再回落 lsof；
  **`-sTCP:LISTEN` 不能省**，否则会把连到该端口的客户端一起杀掉
- 服务启动后写 `<UTILITY_DATA_DIR>/runtime/<service>.json`（`service`/`port`/`pid`/`startedAt`，
  临时文件 + `os.replace` 原子落盘）；服务名常量 `daemon.SERVICE_MCP` / `SERVICE_PROXY`
- Swift 侧 `PortProbe.recordedPort(service:)` 读同一文件，**PID 不存活即视为过期**；
  解析优先级：显式配置 → 已缓存 → 状态文件 → bind 探测

## 打包（pyproject.toml）

仓库根新增 `pyproject.toml`（hatchling），源码布局不变，wheel 只装 `utility` 包。

- 版本唯一来源是根目录 `VERSION`；`[tool.hatch.version]` 的 regex 必须捕获整行，否则读出的是空值
- `packages = ["Sources/MCPScripts/utility"]` 安装后为顶层 `utility`
- `prompts/` 源码仍在 `MCPScripts/prompts`（Swift 与契约脚本依赖该位置），wheel 经
  `force-include` 复制到 `utility/prompts`
- `ast-js/node_modules` 显式排除；wheel 只带宽 `parse.mjs` 与 `package.json`
- 依赖分组：base（httpx / pathspec / PyYAML）、`proxy`（aiohttp + br/zstd）、
  `memory`（mem0ai / fastembed / numpy / qdrant-client）、`server`（mcp / uvicorn / starlette / anyio）
- `requirements.txt` 仍是 mcp-venv 的安装清单，新增依赖必须两边同步

资源解析统一走 `importlib.resources`：`files("utility.scanner") / "ast-js"`、
`files("utility") / "prompts"`；源码树里 `utility/prompts` 不存在，`_builtin_root()` 回落到
`parents[2]/prompts`，该回退分支只服务未安装场景。

## 验证

```bash
swift build
python3 -m compileall -q Sources/MCPScripts
python3 -m unittest discover -s tests/python -t .
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
python3 scripts/check-router-config-contract.py
python3 scripts/check-config-parity.py
python3 scripts/check-web-search.py
python3 scripts/check-search-cache-invariants.py
python3 -m build --wheel
```

wheel 验证必须在独立 venv 里做：`pip install dist/*.whl` 后执行
`from utility.core.prompt_loader import _builtin_root` 与 `from utility.scanner.ast_extractor import AST_JS_DIR`，
两者都应指向 site-packages 内。系统自带的 python3（3.9）跑不了 `build`，用 3.12 的 venv。

运行期冒烟：分别 `import` 6 个入口 shim（`server` 需要 `QDRANT_PATH`），再重启 app 检查 MCP / token proxy / RSS。
