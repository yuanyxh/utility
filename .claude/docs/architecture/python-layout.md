# Python 层位置与调用约定

Python 能力层在**独立仓** `agent-gateway`（import 名 `agent_gateway`），本仓不再有 Python 源码。
目录结构、import 规则、入口 shim 全部归 gateway 仓的文档管理；这里只记宿主必须遵守的约定。

## 宿主如何拿到 Python

| 场景 | 来源 | 定位入口 |
|---|---|---|
| 打包运行 | app 内 `Gateway/` 下的 wheel，首启装进 `~/.config/utility/mcp-venv` | `Sources/Core/GatewayResources.swift`、`Sources/MCP/GatewayInstaller.swift` |
| 源码运行（有同级 gateway 仓） | `../agent-gateway/src/agent_gateway`，注入 `PYTHONPATH` | `GatewayResources.developmentSourceRoot()` |
| prompts（Swift 侧渲染） | `Gateway/prompts/<lang>/<feature>.md` → 回退同级仓 | `GatewayResources.path(relative:)` |

候选顺序硬编码在 `GatewayResources`，**其他文件不得自行拼路径**：重复一份推导，改布局时必有一处
静默找不到文件（表现为功能静默不可用或提示词悄悄回退到 L10n）。

## 进程启动

- 一律按**模块名**启动：`python -c "from <module> import main; main()"`，参数由
  `PythonScriptRunner.bootstrapArguments(for:)` 生成
- 模块名常量集中在 `Sources/Core/Constants.swift` 的 `GatewayEntry`；新增入口在 gateway 仓加模块 +
  在这里登记，宿主侧不出现 `.py` 路径
- 常驻服务走 `PythonDaemon`（`arguments` 是闭包，配置重载后端口变化无需重建 daemon）；一次性任务走
  `runCaptureOutput(module:)`；`.sh` 定时任务走 `shellCommand(entry:)`

## venv 与依赖

- venv 固定 `~/.config/utility/mcp-venv`（`PythonScriptRunner.venvDir`）
- 依赖来自 wheel 的 extras（`proxy,memory,server`），不再有 `requirements.txt` 副本；同步升级时改
  gateway 仓的 `pyproject.toml`
- 首启安装用戳文件 `~/.config/utility/mcp-venv/.agent-gateway-wheel`（wheel 名 + size + mtime）判断，
  同一版本重启不重复跑 pip
- 离线首启：wheel 装得上，extras 装不上 → 日志明确写「依赖未装」，不静默吞掉

## 跨语言契约

env 键、工具 schema、配置 schema 由 gateway 仓导出到 `contracts/*.json`。本仓不再有
`check-config-parity.py` / `check-router-config-contract.py` 这类扫 Python 源码的脚本：源码不在本仓，
扫出来的只能是「文件不存在」。
