# Utility GUI 化重构任务清单

方案、非目标与风险见同目录 `plan.md`。每个任务独立可验证，按依赖顺序执行。

- [ ] T1 应用形态、配置段与主菜单（依赖：无，规模：M）
- [ ] T2 启动主窗口与 Dock 唤起（依赖：T1，规模：S）
- [ ] T3 设置窗口骨架与保存通道（依赖：T1，规模：M）
- [ ] T4 设置项分组与校验（依赖：T3，规模：M）
- [ ] T5 设置入口与中英文案（依赖：T1、T3，规模：S）
- [ ] T6 文档同步与打包验证（依赖：T2、T4、T5，规模：S）

## T1 应用形态、配置段与主菜单

**文件**

- 新建：`Sources/Core/AppBehaviorConfig.swift`
- 修改：`Sources/Core/ConfigTypes.swift:27-64`
- 修改：`Sources/Resources/default-config.yaml:1-3`
- 新建：`Sources/App/AppMainMenu.swift`
- 修改：`Sources/App/AppDelegate.swift:15-21`、`104-134`
- 修改：`scripts/package-utility.sh:122-129`
- 修改：`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`
- 生成：`Sources/Core/L10nKeys.swift`

**接口**

- 产出：`public struct AppBehaviorConfig: Codable`，字段 `var hideDockIcon: Bool`、`var showTerminalOnLaunch: Bool`，解码兜底 `false` / `true`。
- 产出：`AppConfig.app: AppBehaviorConfig`。
- 产出：`AppMainMenu.install()` 与 `AppMainMenu.rebuild()`，监听 `L10n.languageDidChange`。
- 产出：`AppDelegate.applyActivationPolicy()`，读取 `ConfigManager.shared.config.app.hideDockIcon`。

**步骤**

- [ ] 新建 `AppBehaviorConfig.swift`，属性初值 `false` / `true`，`init(from:)` 用 `decodeIfPresent`。
- [ ] `ConfigTypes.swift` 的 `AppConfig` 增加 `var app: AppBehaviorConfig = .init()`，并在 `init(from:)` 增加 `app = (try? c.decodeIfPresent(AppBehaviorConfig.self, forKey: .app)) ?? .init()`。
- [ ] `default-config.yaml` 在 `# ---------- Notifications ----------` 前插入 `app` 段，注释写明 `.accessory` 同时移除应用菜单栏与 Cmd+Tab。
- [ ] `package-utility.sh` 删除 `<key>LSUIElement</key>` 与紧随的 `<true/>`。
- [ ] 新建 `AppMainMenu.swift`，构建应用、编辑、窗口三组菜单，`windowsMenu` 赋值，`install()` 中重建。
- [ ] `AppDelegate.swift` 删除第 15 行 `setActivationPolicy(.accessory)`；新增 `applyActivationPolicy()`，在配置加载的 `do/catch` 之后调用，并在 `onConfigReloaded()` 末尾调用。
- [ ] 两个语言 JSON 增加 `menu.*` 键，运行 `python3 scripts/gen-l10n.py`。

**验收**

- [ ] 打包后 `Info.plist` 不含 `LSUIElement`。
- [ ] 默认启动有 Dock 图标、Cmd+Tab 入口与三组主菜单。
- [ ] `hideDockIcon` 改为 `true` 并重载配置后，Dock 图标与菜单栏消失，菜单栏图标与热键仍可用。

**验证**

```bash
swift build
grep -c "LSUIElement" scripts/package-utility.sh
strings .build/debug/utility | grep -c "hideDockIcon"
python3 scripts/gen-l10n.py --check
```

期望：构建成功；`grep` 输出 `0`；`strings` 输出至少 `1`；l10n 检查通过。

## T2 启动主窗口与 Dock 唤起

**文件**

- 修改：`Sources/App/AppDelegate.swift:12-62`、`268` 前新增方法

**接口**

- 消费：`ConfigManager.shared.config.app.showTerminalOnLaunch`、`ConfigManager.shared.config.terminal.enabled`、`TerminalManager.shared.showWindow()`、`AppWindowRegistry.frontmostWindow`。
- 产出：`applicationShouldHandleReopen(_:hasVisibleWindows:) -> Bool`。

**步骤**

- [ ] `applicationDidFinishLaunching` 末尾、`debugLog("[Utility] Ready")` 之前，按 `showTerminalOnLaunch && terminal.enabled` 调用 `TerminalManager.shared.showWindow()`。
- [ ] 新增 `applicationShouldHandleReopen`：有可见窗口返回 `true`；否则终端可用时展示终端窗口，不可用时前置 `AppWindowRegistry.frontmostWindow`，返回 `false`。
- [ ] 手工验证关闭终端窗口后进程仍驻留。

**验收**

- [ ] 默认配置启动即展示终端主窗口。
- [ ] `Cmd+W` 关闭终端窗口后应用不退出，Dock 图标仍在。
- [ ] 点 Dock 图标重新展示终端窗口。
- [ ] `showTerminalOnLaunch=false` 时启动不弹窗。

**验证**

```bash
swift build
tail -n 60 ~/.cache/utility/debug.log | grep -E "activation policy|\[Utility\] Ready"
```

期望：构建成功；日志出现 `activation policy=regular` 与 `[Utility] Ready`；手工路径全部通过。

## T3 设置窗口骨架与保存通道

**文件**

- 新建：`Sources/App/SettingsWindowController.swift`
- 新建：`Sources/App/SettingsView.swift`
- 新建：`Sources/App/SettingsModel.swift`
- 修改：`Sources/Core/ConfigManager.swift:34-59`

**接口**

- 产出：`public func apply(_ newConfig: AppConfig) throws`，编码为 YAML、写入前备份 `config.yaml.bak`、调用 `load()` 发布 `configDidLoad`。
- 产出：`SettingsWindowController.shared.show()`，单例 `NSWindowController`，`isReleasedWhenClosed = false`。
- 产出：`SettingsModel: ObservableObject`，`@Published var config: AppConfig`、`save() throws`、`reload()`。

**步骤**

- [ ] `ConfigManager` 新增 `apply(_:)`：`try?` 复制原文件到 `AppPaths.configDir/config.yaml.bak`，再编码 `newConfig` 并调用现有 `apply(rawText:)`。
- [ ] `SettingsModel` 持有 `ConfigManager.shared.config` 副本，`save()` 调用 `ConfigManager.shared.apply(config)` 并把错误写入 `status`。
- [ ] `SettingsWindowController` 用 `NSWindow` + `NSHostingController(rootView: SettingsView(model:))`，尺寸 720×520，标题走 `L10n`。
- [ ] `SettingsView` 先用 `Form` 放一个占位分组，确认窗口可打开与关闭。

**验收**

- [ ] 调用 `SettingsWindowController.shared.show()` 能打开窗口，重复调用不新建。
- [ ] 关闭窗口后 `shared` 仍持有实例，可再次打开。
- [ ] 保存后 `config.yaml` 更新，`configDidLoad` 被触发，`.bak` 文件存在。

**验证**

```bash
swift build
ls -l ~/.config/utility/config.yaml ~/.config/utility/config.yaml.bak
```

期望：构建成功；保存一次后两个文件都存在，`config.yaml` 值已变化。

## T4 设置项分组与校验

**文件**

- 修改：`Sources/App/SettingsView.swift`
- 修改：`Sources/App/SettingsModel.swift`

**接口**

- 消费：`AppConfig` 的 `app`、`general`、`clipboard`、`translation`、`knowledge`、`terminal`、`rss`。
- 产出：`SettingsModel.validate() -> [String]`，返回人类可读错误列表。

**步骤**

- [ ] 分组「应用」：`hideDockIcon`、`showTerminalOnLaunch`。
- [ ] 分组「通用」：`language`（zh-Hans / en / 跟随系统）、`httpTimeout`、`aiTimeout`。
- [ ] 分组「剪贴板」：`maxDays`、`pollInterval`、`hotkey`。
- [ ] 分组「翻译」：`hotkey`、`hotkeyOCR`、`sourceLang`、`targetLang`。
- [ ] 分组「知识」：`enabled`、`autoShowEnabled`、`refillIntervalMinutes`、`hotkey`。
- [ ] 分组「终端」：`enabled`、`fontSize`、`alwaysOnTop`、`shell`、`workingDirectory`。
- [ ] 分组「RSS」：`daily.enabled`、`daily.cron`、`daily.maxAgeDays`。
- [ ] 校验：`pollInterval > 0`、`fontSize` 8-32、`refillIntervalMinutes > 0`、`maxAgeDays >= 0`；失败时不写文件。
- [ ] 热键字段下方显示「修改后需重启应用生效」。

**验收**

- [ ] 每个分组可编辑并保存，保存后 `config.yaml` 对应键变化。
- [ ] 非法数值被拒绝，窗口显示错误，`config.yaml` 保持原值。
- [ ] 修改 `fontSize` 并保存后，新建终端会话使用新字号。

**验证**

```bash
swift build
python3 scripts/check-examples-parity.py
grep -n "fontSize" ~/.config/utility/config.yaml
```

期望：构建成功；配置文件中出现新字号；非法输入时文件 mtime 不变化。

## T5 设置入口与中英文案

**文件**

- 修改：`Sources/App/AppMainMenu.swift`
- 修改：`Sources/Core/MenuBarManager.swift:54-139`
- 修改：`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`
- 生成：`Sources/Core/L10nKeys.swift`

**接口**

- 消费：`SettingsWindowController.shared.show()`。
- 产出：主菜单 `Cmd+,` 项与菜单栏「设置…」项。

**步骤**

- [ ] `AppMainMenu` 在应用菜单加入「设置…」，`keyEquivalent: ","`。
- [ ] `MenuBarManager.buildMenu()` 在「打开配置文件」前加入「设置…」项，`target` 指向自身，`@objc` 调 `SettingsWindowController.shared.show()`。
- [ ] 两个 JSON 增加 `menu.settings`、`menu.preferences` 文案，运行 `python3 scripts/gen-l10n.py`。
- [ ] 切换语言后验证菜单与窗口标题刷新。

**验收**

- [ ] 主菜单 `Cmd+,` 与菜单栏「设置…」打开同一个窗口实例。
- [ ] 中文与英文界面文案正确，无硬编码字符串。

**验证**

```bash
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
swift build
```

期望：两项 l10n 检查通过；构建成功。

## T6 文档同步与打包验证

**文件**

- 修改：`README.md:3-5`、`README.zh.md:3-5`
- 修改：`AGENTS.md:11-12`、`.claude/CLAUDE.md:6-7`
- 修改：`.claude/docs/architecture/panel-ui.md`

**接口**

- 无新增代码接口。

**步骤**

- [ ] README 两份把「No Dock icon, no main window」改为默认 Dock 应用、启动展示终端主窗口、`app.hideDockIcon` 可回菜单栏模式。
- [ ] `AGENTS.md` 与 `.claude/CLAUDE.md` 去掉「LSUIElement（无 Dock 图标）」，改为可配置。
- [ ] `panel-ui.md` 记录激活策略、主窗口与设置窗口行为。
- [ ] 运行全量验证并记录 L1 / L2 / L3 证据。

**验收**

- [ ] 文档描述与运行时行为一致。
- [ ] `run-tests.sh` 与打包脚本通过。
- [ ] L3 未完成项在交付说明中单列。

**验证**

```bash
swift build
bash scripts/run-tests.sh
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
SIGNING_IDENTITY=<sha1> bash scripts/package-utility.sh
plutil -p Utility.app/Contents/Info.plist
```

期望：构建与测试通过；打包成功；`Info.plist` 无 `LSUIElement`。

## 检查点

### 检查点 A（T1-T2 后）

- [ ] `swift build` 通过。
- [ ] Dock 图标、Cmd+Tab、主菜单、终端主窗口手工验证通过。
- [ ] 菜单栏图标、热键、四个功能面板行为不变。

### 检查点 B（T3-T5 后）

- [ ] 设置窗口两处入口一致。
- [ ] 保存、校验、备份、热重载全部通过。
- [ ] l10n 两项检查通过。

### 检查点 C（T6 后）

- [ ] `run-tests.sh` 全过。
- [ ] 打包产物的 `Info.plist` 正确。
- [ ] 文档同步完成。
