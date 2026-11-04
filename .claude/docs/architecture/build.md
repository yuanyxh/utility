# 构建、验证与脚本目录

> 从 `AGENTS.md` 分层迁出（2026-11-03），内容逐字保留。
> 交付前必须按本文件实跑对应命令。

## Build

- Clean build: `rm -rf .build && swift build`
- 二进制：`.build/debug/utility`、release 为 `.build/release/utility`（SwiftPM 维护的符号链接）
- 实际产物目录随 SwiftPM 版本变化（旧 `.build/arm64-apple-macosx/{debug,release}`，新 `.build/out/Products/{Debug,Release}`）——**脚本中禁止硬编码，用 `swift build -c <config> --show-bin-path` 查询**
- 验证改动进二进制：`strings .build/debug/utility | grep keyword`
- ⚠️ `package-utility.sh` 曾硬编码 `.build/arm64-apple-macosx/release/utility_utility.bundle` 且包在 `if [ -d ]` 里，新版布局下该目录不存在 → 资源 bundle 被**静默漏拷**（app 18M→9.8M），启动即 `Fatal error: unable to find bundle named utility_utility`（`resource_bundle_accessor.swift`）。资源缺失一律硬失败，不做条件跳过
- 版本唯一来源是仓库根 `VERSION`：`package-utility.sh` 每次打包自增 patch 并写回，无文件时以 `INITIAL_VERSION=1.0.93` 起步
- macOS 26 起 `hdiutil create` 弃用，打包改用 `diskutil image create from --format UDZO --volumeName "$APP_NAME" "$APP" "$DMG"`（目标已存在时自动覆盖）
- ⚠️ **bash 3.2 会把紧跟 `$VAR` 的全角字符并入变量名**（`$VERSION（` → `VERSION<乱码>: unbound variable`，`set -u` 下直接退出）：变量后接中文/全角标点必须写 `${VAR}`

## Verification

交付前必须实跑（行为约束见 `.claude/rules/verification-before-completion.md`）：

```bash
swift build
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py          # 加 --python-root ../agent-gateway/src/agent_gateway 连 Python 侧一起查
python3 scripts/check-examples-parity.py
python3 scripts/check-gateway-entries.py --entries ../agent-gateway/contracts/entries.json
bash scripts/run-tests.sh
bash scripts/e2e-isolated.sh                    # 临时 HOME 跑真实 agent 模式 + 图库增量
```

打包产物验证（本地不打包也能跑 wheel 路径）：`UTILITY_GATEWAY_USE_WHEEL=1 .build/debug/utility`。
干净 clone 直接 `swift build` 不含 wheel、也没有同级仓时 AI 功能不可用——发包必须走 `package-utility.sh`。
**Python 侧验证在 `agent-gateway` 仓内做**（unittest、向量缓存不变式、web-search）：`PYTHONPATH=src ~/.config/utility/mcp-venv/bin/python3 -m unittest discover -s tests -t .`。
本仓已无 Python 源码，`Sources/MCPScripts` 于 2026-10-26 删除。

## scripts 目录

- `scripts/` 根只放可执行入口（`check-*.py`、`gen-l10n.py`、`package-utility.sh`、`run-tests.sh`、`e2e-isolated.sh`），这些路径被文档与 `run-tests.sh` 引用，**不得移动**
- `e2e-isolated.sh`：`HOME`/`CFFIXED_USER_HOME` 指向临时目录，软链 gateway `.venv`，真实跑 `utility -a`；断言首建、watcher 增量、`project_lookup`/`project_impact`。`KEEP_TEMP=1` 保留现场，`GATEWAY_REPO`/`PYTHON` 可覆盖路径，失败自动保留并打印日志尾部
- 校验器实现放子包；新增校验脚本同样建包，根部入口只做 import + `main()`
- 子包内路径常量：`SCRIPTS_DIR = dirname(dirname(__file__))`、`ROOT = dirname(SCRIPTS_DIR)`
- 引用 Python 源码的校验（`router_contract`、`config_parity`、web-search、向量缓存不变式）已随源码迁往 `agent-gateway` 仓的 `scripts/`
- `gen-l10n.py` 只写 `L10nKeys.swift`；Python 侧语言包由 agent-gateway 自持（`locales/*.json`），本仓不再生成
