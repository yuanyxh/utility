# 环境探测

探测时间：2026-11-20（本机只读命令）

## 平台

| 项 | 值 | 状态 |
| --- | --- | --- |
| macOS | 27.2.1 (26B131) | 可用 |
| 架构 | arm64 | 可用 |
| Xcode | 27.2 (27B52) | 可用 |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9) | 可用 |
| git | 2.56.1 | 可用 |
| tmux | 3.8（/opt/homebrew/bin） | 可用，终端功能必需 |
| swift-format | 6.4.4（`xcrun swift-format`，Xcode 内置） | 格式门；项目内 `.swift-format` 定义 120 列、4 空格 |
| swiftlint | 缺失 | 静态检查门暂缺 |
| lume | 0.7.0（`~/.local/bin/lume`，不在 PATH） | 可用；VM `utility-env` / `macos-base-clean` 均 stopped |

## 可脚本化驱动方式

| 用途 | 方式 | 状态 |
| --- | --- | --- |
| 构建 | `swift build` | 可用 |
| 本地验证 | `bash scripts/run-tests.sh` | 可用 |
| 打包 | `SIGNING_IDENTITY=<sha1> bash scripts/package-utility.sh` | 可用（需签名身份） |
| 启动 app | `open -a /Applications/Utility.app` | 可用 |
| 启动开发版 | `./.build/debug/utility`（可与安装版并存，MCP 复用 9001） | 可用 |
| 进程级隔离 | 临时 `HOME` + `CFFIXED_USER_HOME` + 临时项目 + 克隆 venv | 可用；见 `.agent/sandbox.md` |
| VM 级隔离 | `~/.local/bin/lume start utility-env` | 可用；SSH 需密码 |
| 打开终端面板 | **无 CLI / URL scheme 入口** | **缺口**，只能靠 `option+space` 热键或菜单栏 |
| 截图 | `screencapture -x <path>` | 可用（整屏）；按窗口截图需先取 window id，未封装 |
| 运行日志 | `~/.cache/utility/debug.log` | 可用 |
| 用户配置 | `~/.config/utility/config.yaml` | 可用 |
| 终端会话元数据 | `~/.config/utility/terminal-sessions.json` | 可用 |

## 已知限制

- Claude Code 的 auto mode 会拦截 `osascript` System Events 按键模拟，无法用脚本触发全局热键。
- 需要辅助功能 / 屏幕录制权限的验证只能由人执行，按 TST-09 输出移交清单。
- 交互层 shell 继承 `MCP_PORT=9001`；隔离实跑必须显式覆盖，否则可能连到生产 MCP。
- `swift build` 是编译门，`swift-format lint` 是格式门；无独立静态检查。

## 替代与影响

| 缺失项 | 替代 | 影响 |
| --- | --- | --- |
| swiftlint | `swift build` + `swift-format lint` | 无独立静态检查，规则覆盖弱于 swiftlint |
| UI 自动化入口 | 热键 + 截图 + 日志断言 | 端到端验证需要人参与；详见 TST-09 |
| CI | 本地 `run-tests.sh` | 无远程回归记录 |

## 反馈回路

按交互面记录可重复回路（TST-10），命令取自上方「可脚本化驱动方式」。

| 交互面 | 启动 | 驱动 | 观测 | 证据脚本 |
| --- | --- | --- | --- | --- |
| 视觉 | `./.build/debug/utility` | 热键或菜单（无 CLI 入口） | `screencapture -x` | 待补 |
| 终端 | `./.build/debug/utility` | `option+space` 开面板 | `~/.cache/utility/debug.log` | 待补 |
| 协议 | `./.build/debug/utility` | `curl 127.0.0.1:9001/health` | 响应与端口状态 | 待补 |

首次回路运行：升级到 1.6.0 时无交互改动，按 TST-09 人工移交。
