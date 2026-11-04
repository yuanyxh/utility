# Utility GUI 化重构任务清单

方案、非目标与风险见同目录 `plan.md`。每个任务独立可验证，按依赖顺序执行。

- [ ] T1 应用形态、配置段与主菜单（依赖：无，规模：M）
- [ ] T2 终端主窗口与常规应用行为（依赖：T1，规模：S）
- [ ] T3 设置窗口骨架与保存通道（依赖：T1，规模：M）
- [ ] T4 设置分组与校验（依赖：T3，规模：M）
- [ ] T5 设置入口与中英文案（依赖：T1、T3，规模：S）
- [ ] T6 文档同步与打包验证（依赖：T2、T4、T5，规模：S）

## T1 应用形态、配置段与主菜单

**文件**

- 新建：`Sources/Core/AppBehaviorConfig.swift`
- 修改：`Sources/Core/ConfigTypes.swift:27-63`
- 修改：`Sources/Resources/default-config.yaml:1-3`
- 修改：`scripts/package-utility.sh:128-129`
- 新建：`Sources/App/AppMainMenu.swift`
- 修改：`Sources/App/AppDelegate.swift:12-21`、`104-134`
- 修改：`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`
- 生成：`Sources/Core/L10nKeys.swift`（运行脚本，不手改）

**接口**

- 产出：`struct AppBehaviorConfig: Codable`，字段 `var hideDockIcon: Bool = false`、`var showTerminalOnLaunch: Bool = true`。
- 产出：`AppConfig.app: AppBehaviorConfig`。
- 产出：`AppMainMenu.install()`、`AppMainMenu.rebuild()`；`rebuild()` 同时设置 `NSApp.mainMenu`、`NSApp.windowsMenu`、`NSApp.servicesMenu`。
- 产出：`AppDelegate.applyActivationPolicy()`，按 `ConfigManager.shared.config.app.hideDockIcon` 调用 `NSApp.setActivationPolicy`。

**步骤**

- [ ] 新建 `AppBehaviorConfig.swift`：属性初值 `false` / `true`，`init(from:)` 用 `decodeIfPresent`，注释用英文。
- [ ] `ConfigTypes.swift:42` 后增加 `var app: AppBehaviorConfig = .init()`；`ConfigTypes.swift:62` 后增加 `app = (try? c.decodeIfPresent(AppBehaviorConfig.self, forKey: .app)) ?? .init()`。
- [ ] `default-config.yaml` 在文件头注释与 `# ---------- Notifications ----------` 之间插入 `app` 段，写入 `hideDockIcon: false` 与 `showTerminalOnLaunch: true`，注释说明 `true` 等于菜单栏模式。
- [ ] `package-utility.sh:128-129` 删除 `<key>LSUIElement</key>` 与紧随的 `<true/>`。
- [ ] 新建 `AppMainMenu.swift`，构建应用、编辑、窗口三组菜单；标准动作的 `target` 设为 `nil`，靠 responder chain 分发。
- [ ] 应用菜单项：关于（`orderFrontStandardAboutPanel:`）、服务（子菜单）、隐藏（`hide:`）、隐藏其他（`hideOtherApplications:`）、显示全部（`unhideAllApplications:`）、退出（`terminate:`，复用 `L10n.Menu.quit`）。
- [ ] 编辑菜单项：撤销、重做、剪切、拷贝、粘贴、删除、全选，分别用 `undo:`、`redo:`、`cut:`、`copy:`、`paste:`、`delete:`、`selectAll:`。
- [ ] 窗口菜单项：关闭窗口（`performClose:`，`keyEquivalent: "w"`）、最小化（`performMiniaturize:`，`keyEquivalent: "m"`）、缩放（`performZoom:`）、前置全部窗口（`arrangeInFront:`）。
- [ ] `AppDelegate.swift:15` 删除 `setActivationPolicy(.accessory)`；在配置加载 `do/catch`（第 17-21 行）之后插入 `applyActivationPolicy()` 与 `AppMainMenu.install()`。
- [ ] `applyActivationPolicy()` 记录日志 `[Utility] activation policy=regular|accessory`。
- [ ] `onConfigReloaded()`（`AppDelegate.swift:104-134`）末尾调用 `applyActivationPolicy()`，让 `hideDockIcon` 改配置后即时生效。
- [ ] 两个语言 JSON 增加下列键，运行 `python3 scripts/gen-l10n.py` 生成访问器。

| 键 | zh-Hans | en |
|---|---|---|
| `menu.app_about` | 关于 Utility | About Utility |
| `menu.services` | 服务 | Services |
| `menu.app_hide` | 隐藏 Utility | Hide Utility |
| `menu.app_hide_others` | 隐藏其他 | Hide Others |
| `menu.app_show_all` | 显示全部 | Show All |
| `menu.edit` | 编辑 | Edit |
| `menu.edit_undo` | 撤销 | Undo |
| `menu.edit_redo` | 重做 | Redo |
| `menu.edit_cut` | 剪切 | Cut |
| `menu.edit_copy` | 拷贝 | Copy |
| `menu.edit_paste` | 粘贴 | Paste |
| `menu.edit_delete` | 删除 | Delete |
| `menu.edit_select_all` | 全选 | Select All |
| `menu.window` | 窗口 | Window |
| `menu.window_close` | 关闭窗口 | Close Window |
| `menu.window_minimize` | 最小化 | Minimize |
| `menu.window_zoom` | 缩放 | Zoom |
| `menu.window_front` | 前置全部窗口 | Bring All to Front |

**验收**

- [ ] `swift build` 通过，`grep -c LSUIElement scripts/package-utility.sh` 输出 `0`。
- [ ] 默认启动有 Dock 图标、Cmd+Tab 入口与三组主菜单。
- [ ] `hideDockIcon` 改为 `true` 并重载配置后，Dock 图标与应用菜单栏消失，菜单栏状态项与热键仍可用。

**验证**

```bash
swift build
grep -c "LSUIElement" scripts/package-utility.sh
strings .build/debug/utility | grep -c "hideDockIcon"
python3 scripts/gen-l10n.py --check
```

期望：构建成功；`grep` 输出 `0`；`strings` 输出至少 `1`；l10n 检查通过。

## T2 终端主窗口与常规应用行为

**文件**

- 修改：`Sources/App/AppDelegate.swift:58-62`、文件末尾新增方法
- 修改：`Sources/Terminal/TerminalWindowController.swift:26`、`278-303`

**接口**

- 消费：`ConfigManager.shared.config.app.showTerminalOnLaunch`、`ConfigManager.shared.config.terminal.enabled`、`TerminalManager.shared.showWindow()`、`AppWindowRegistry.frontmostWindow`。
- 产出：`applicationShouldHandleReopen(_:hasVisibleWindows:) -> Bool`。

**步骤**

- [ ] `AppDelegate.swift:61` 的 `debugLog("[Utility] Ready")` 之前，按 `showTerminalOnLaunch && terminal.enabled` 调用 `MainActor.assumeIsolated { TerminalManager.shared.showWindow() }`。
- [ ] 新增 `applicationShouldHandleReopen`：有可见窗口返回 `true`；否则终端可用时展示终端窗口，不可用时在 `MainActor.assumeIsolated` 中取 `AppWindowRegistry.frontmostWindow` 前置，两者都不满足返回 `true`。
- [ ] `TerminalWindowController.swift:26` 的 `styleMask` 增加 `.miniaturizable`。
- [ ] `didResignActive()`（`278-288`）首行增加 `guard NSApp.activationPolicy() == .accessory else { return }`。
- [ ] `scheduleRestoreCheck(after:)`（`293-303`）闭包首行增加同样的 guard，防止 regular 应用被 `Cmd+H` 隐藏后自动弹出。

**验收**

- [ ] 默认配置启动即展示终端主窗口；`showTerminalOnLaunch=false` 时启动不弹窗。
- [ ] `Cmd+W` 关闭窗口后应用不退出；点 Dock 图标重新展示终端窗口；`Cmd+M` 可最小化。
- [ ] `Cmd+H` 后 1.5 s 内窗口不自动出现，日志中无 `[Terminal] restoring after focus loss`。

**验证**

```bash
swift build
tail -n 80 ~/.cache/utility/debug.log | grep -E "activation policy|\[Utility\] Ready|\[Terminal\] restoring"
```

期望：构建成功；日志出现 `activation policy=regular` 与 `[Utility] Ready`；`Cmd+H` 后无 `restoring` 记录；手工路径全部通过。

## T3 设置窗口骨架与保存通道

**文件**

- 修改：`Sources/Core/ConfigManager.swift:38-59`
- 新建：`Sources/App/SettingsModel.swift`
- 新建：`Sources/App/SettingsWindowController.swift`
- 新建：`Sources/App/SettingsView.swift`
- 修改：`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`
- 生成：`Sources/Core/L10nKeys.swift`

**接口**

- 产出：`public func apply(_ newConfig: AppConfig) throws`：重编码为 YAML，合并原文件未知顶层键，校验可解码与大小上限，备份原文件后原子写入，再 `load()` 发布 `configDidLoad`。
- 产出：`public func readConfigFromDisk() throws -> AppConfig`：只解码文件，不发布事件，供设置窗口重新加载。
- 产出：`enum ConfigApplyError: Error`，只含 `fileTooLarge(Int)`；`errorDescription` 用英文仅供日志，设置窗口映射到 `L10n.Settings.errorFileTooLarge`。
- 产出：`final class SettingsModel: ObservableObject`，`@Published var config: AppConfig`、`func save()`、`func reload()`、`enum Status { case idle, saved, failed(String) }`。
- 产出：`SettingsWindowController.shared.show()`，单例 `NSWindowController`，窗口 760×560，`isReleasedWhenClosed = false`，可最小化与缩放。

**步骤**

- [ ] `ConfigManager.apply(_:)`：`YAMLEncoder().encode(newConfig)` 后拼上 `L10n.Config.headerComment`，再用 `YAMLDecoder` 解码校验。
- [ ] 大小检查：`content.utf8.count > 1_048_576` 时抛 `ConfigApplyError.fileTooLarge`，不写盘。
- [ ] 未知键合并：读原文件顶层键，把新编码里没有的键原样补回；用 `Yams.dump(object:allowUnicode:sortKeys:)` 输出。只处理顶层键，原文件解析失败时直接使用新编码，在注释里写明限制。
- [ ] 备份：把原文件内容写到 `AppPaths.configDir/config.yaml.bak`（原子写），不删除旧备份以外的任何文件。
- [ ] 写入 `configFile` 后调用 `load()`；失败时原文件已被新内容替换前已完成校验，不会出现半截文件。
- [ ] `SettingsModel` 初始值取 `ConfigManager.shared.config`；`reload()` 用 `readConfigFromDisk()` 读磁盘，失败回退内存；`save()` 捕获错误写入 `status`。
- [ ] `SettingsWindowController` 用 `NSWindow` + `NSHostingController(rootView: SettingsView(model: model))`，`setFrameAutosaveName("utility.settings-window")`，标题 `L10n.Settings.title`，并调用 `AppWindowRegistry.register(window)`。
- [ ] `show()` 只在窗口不可见时 `model.reload()`，再 `makeKeyAndOrderFront(nil)` 与 `NSApplication.shared.activate(ignoringOtherApps: true)`，避免丢掉未保存编辑。
- [ ] `SettingsView` 先放一个「应用」占位分组、保存与重新加载按钮、状态文本。
- [ ] 两个语言 JSON 增加 T3 所需键，运行 `python3 scripts/gen-l10n.py`。

| 键 | zh-Hans | en |
|---|---|---|
| `settings.title` | 设置 | Settings |
| `settings.save` | 保存 | Save |
| `settings.reload` | 重新加载 | Reload |
| `settings.saved` | 已保存 | Saved |
| `settings.save_failed` | 保存失败：{message} | Save failed: {message} |
| `settings.backup_hint` | 保存前会备份为 config.yaml.bak | A backup is written to config.yaml.bak |
| `settings.error_file_too_large` | 配置文件超过 1 MB，拒绝保存 | Config file exceeds 1 MB; not saved |

**验收**

- [ ] 连续调用 `SettingsWindowController.shared.show()` 复用同一实例，关闭后仍可再次打开。
- [ ] 保存后 `config.yaml` 更新、`.bak` 存在、日志出现 `configDidLoad` 触发的重载记录。
- [ ] 原文件含 `search` 等未知顶层键时保存成功且该键保留；编码后超过 1 MB 时保存被拒，`config.yaml` 的 mtime 不变。

**验证**

```bash
swift build
ls -l ~/.config/utility/config.yaml ~/.config/utility/config.yaml.bak
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
```

期望：构建成功；保存一次后两个文件都存在；两项 l10n 检查通过。

## T4 设置分组与校验

**文件**

- 修改：`Sources/App/SettingsView.swift`
- 修改：`Sources/App/SettingsModel.swift`
- 修改：`Sources/Core/HotkeyManager.swift:14`、`71`
- 修改：`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`
- 生成：`Sources/Core/L10nKeys.swift`

**接口**

- 消费：`AppConfig` 的 `app`、`general`、`clipboard`、`translation`、`knowledge`、`terminal`、`rss.daily`。
- 产出：`SettingsModel.validate() -> [String]`，返回本地化错误文案；非空时不写盘。
- 产出：`HotkeyManager.isValid(_ hotkey: String) -> Bool`，复用现有 `parse` 判定。

**步骤**

- [ ] `HotkeyManager.parse` 从 `private func` 改为 `static func`，`register` 调用改为 `Self.parse(hotkey:)`，新增 `static func isValid(_ hotkey: String) -> Bool { parse(hotkey: hotkey) != nil }`。
- [ ] 分组「应用」：`hideDockIcon`、`showTerminalOnLaunch`。
- [ ] 分组「通用」：`language`（跟随系统 / 中文 / English，写回 `""` / `zh` / `en`）、`httpTimeout`、`aiTimeout`。
- [ ] 分组「剪贴板」：`maxDays`、`pollInterval`、`hotkey`。
- [ ] 分组「翻译」：`hotkey`、`hotkeyOCR`、`sourceLang`、`targetLang`。
- [ ] 分组「知识」：`enabled`、`autoShowEnabled`、`refillIntervalMinutes`、`hotkey`。
- [ ] 分组「终端」：`enabled`、`fontSize`、`alwaysOnTop`、`shell`、`workingDirectory`。
- [ ] 分组「RSS」：`daily.enabled`、`daily.cron`、`daily.maxAgeDays`。
- [ ] 校验规则：`pollInterval` 0.05-5、`fontSize` 8-32、`refillIntervalMinutes` 1-1440、`httpTimeout` 与 `aiTimeout` ≥ 0、`maxDays` 与 `maxAgeDays` ≥ 0；热键用 `HotkeyManager.isValid` 检查四个热键字段。
- [ ] 每个热键字段下方显示 `L10n.Settings.fieldRestartHint`。
- [ ] 两个语言 JSON 增加下列键并重新生成。

| 键 | zh-Hans | en |
|---|---|---|
| `settings.group_app` | 应用 | Application |
| `settings.group_general` | 通用 | General |
| `settings.group_clipboard` | 剪贴板 | Clipboard |
| `settings.group_translation` | 翻译 | Translation |
| `settings.group_knowledge` | 知识 | Knowledge |
| `settings.group_terminal` | 终端 | Terminal |
| `settings.group_rss` | RSS | RSS |
| `settings.field_hide_dock_icon` | 隐藏 Dock 图标 | Hide Dock icon |
| `settings.field_show_terminal_on_launch` | 启动时打开终端 | Open terminal on launch |
| `settings.field_language` | 界面语言 | UI language |
| `settings.field_http_timeout` | HTTP 超时（秒） | HTTP timeout (s) |
| `settings.field_ai_timeout` | AI 超时（秒） | AI timeout (s) |
| `settings.field_clipboard_max_days` | 保留天数 | Retention days |
| `settings.field_clipboard_poll_interval` | 轮询间隔（秒） | Poll interval (s) |
| `settings.field_clipboard_hotkey` | 剪贴板热键 | Clipboard hotkey |
| `settings.field_translation_hotkey` | 翻译热键 | Translation hotkey |
| `settings.field_translation_hotkey_ocr` | OCR 翻译热键 | OCR translation hotkey |
| `settings.field_source_lang` | 源语言 | Source language |
| `settings.field_target_lang` | 目标语言 | Target language |
| `settings.field_knowledge_enabled` | 启用知识面板 | Enable knowledge panel |
| `settings.field_knowledge_auto_show` | 自动弹出 | Auto show |
| `settings.field_refill_interval` | 补货间隔（分钟） | Refill interval (min) |
| `settings.field_knowledge_hotkey` | 知识面板热键 | Knowledge hotkey |
| `settings.field_terminal_enabled` | 启用终端 | Enable terminal |
| `settings.field_font_size` | 字号 | Font size |
| `settings.field_always_on_top` | 置顶 | Always on top |
| `settings.field_shell` | Shell | Shell |
| `settings.field_working_directory` | 工作目录 | Working directory |
| `settings.field_rss_daily_enabled` | 启用日报 | Enable daily digest |
| `settings.field_rss_daily_cron` | Cron 表达式 | Cron expression |
| `settings.field_max_age_days` | 最大文章天数 | Max article age (days) |
| `settings.field_restart_hint` | 修改热键后需重启应用 | Hotkey changes apply after restart |
| `settings.language_system` | 跟随系统 | System |
| `settings.language_zh` | 中文 | Chinese |
| `settings.language_en` | English | English |
| `settings.error_out_of_range` | {field} 必须在 {min} 与 {max} 之间 | {field} must be between {min} and {max} |
| `settings.error_hotkey_invalid` | {field} 格式不合法 | {field} is not a valid hotkey |

**验收**

- [ ] 七个分组可编辑并保存，保存后 `config.yaml` 对应键变化。
- [ ] 非法数值或非法热键被拒绝，窗口显示本地化错误，`config.yaml` mtime 不变。
- [ ] 修改 `fontSize` 并保存后，新建终端会话使用新字号。

**验证**

```bash
swift build
python3 scripts/check-examples-parity.py
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
grep -n "fontSize" ~/.config/utility/config.yaml
```

期望：构建成功；三项检查通过；配置文件中出现新字号；非法输入时文件 mtime 不变化。

## T5 设置入口与中英文案

**文件**

- 修改：`Sources/App/AppMainMenu.swift`
- 修改：`Sources/Core/MenuBarManager.swift:54-68`、`587-598`、`612-618`
- 修改：`Sources/Resources/zh-Hans.json`、`Sources/Resources/en.json`
- 生成：`Sources/Core/L10nKeys.swift`

**接口**

- 消费：`SettingsWindowController.shared.show()`。
- 产出：主菜单 `Cmd+,` 菜单项与菜单栏「设置…」菜单项。

**步骤**

- [ ] `AppMainMenu` 在应用菜单「关于」之后加入「设置…」，`keyEquivalent: ","`，`target` 指向 `SettingsWindowController.shared`，`action` 指向 `@objc func showFromMenu()`。
- [ ] `MenuBarManager` 新增 `settingsItem` 属性，`buildMenu()` 在 `openConfigItem` 之前插入该菜单项，`target = self`，`@objc` 方法调用 `SettingsWindowController.shared.show()`。
- [ ] `refreshAllTitles()`（`587-598`）增加 `settingsItem.title = L10n.Menu.settings`。
- [ ] 两个语言 JSON 增加 `menu.settings`（设置… / Settings…），运行 `python3 scripts/gen-l10n.py`。
- [ ] 切换语言后验证主菜单、设置窗口标题、菜单栏入口同时刷新。

**验收**

- [ ] 主菜单 `Cmd+,` 与菜单栏「设置…」打开同一个窗口实例。
- [ ] 中文与英文界面文案正确，源码中无硬编码用户可见字符串。

**验证**

```bash
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
swift build
```

期望：两项 l10n 检查通过；构建成功；手工路径通过。

## T6 文档同步与打包验证

**文件**

- 修改：`README.md:5`
- 修改：`AGENTS.md:8-12`
- 修改：`.claude/CLAUDE.md:6-8`
- 修改：`.claude/docs/architecture/panel-ui.md`

**接口**

- 无新增代码接口。

**步骤**

- [ ] `README.md` 把「No Dock icon, no main window」改为默认 Dock 应用、启动展示终端主窗口、`app.hideDockIcon` 可回菜单栏模式。
- [ ] `AGENTS.md` 与 `.claude/CLAUDE.md` 去掉「LSUIElement（无 Dock 图标）」的绝对表述，改为由 `app.hideDockIcon` 决定。
- [ ] `panel-ui.md` 记录激活策略切换、主窗口启动与 Dock 唤起、终端窗口在 regular 下不自动恢复、设置窗口入口与保存通道。
- [ ] 运行全量验证并记录 L1 / L2 / L3 证据，未完成项单列。

**验收**

- [ ] 文档描述与运行时行为一致。
- [ ] `run-tests.sh` 与打包脚本通过，产物 `Info.plist` 无 `LSUIElement`。
- [ ] L3 未完成项在交付说明中单列。

**验证**

```bash
swift build
bash scripts/run-tests.sh
python3 scripts/gen-l10n.py --check
python3 scripts/check-l10n-contract.py
SIGNING_IDENTITY=<sha1> bash scripts/package-utility.sh
plutil -p Utility.app/Contents/Info.plist | grep -c LSUIElement
```

期望：构建与测试通过；打包成功；`plutil` 的 `grep` 输出 `0`。

## 检查点 A（T1-T2 后）

- [ ] `swift build` 通过。
- [ ] Dock 图标、Cmd+Tab、三组主菜单、终端主窗口手工验证通过。
- [ ] `Cmd+H` 不触发终端窗口自动恢复；最小化与 Dock 唤起可用。
- [ ] 菜单栏图标、热键、四个功能面板行为不变。

## 检查点 B（T3-T5 后）

- [ ] 设置窗口两处入口一致，重复打开复用实例。
- [ ] 保存、校验、备份、未知键保留、热重载全部通过；最后一个面板关闭时设置窗口不被连带隐藏。
- [ ] 语言切换后主菜单与设置窗口文案即时刷新。
- [ ] l10n 两项检查通过。

## 检查点 C（T6 后）

- [ ] `run-tests.sh` 全过。
- [ ] 打包产物的 `Info.plist` 无 `LSUIElement`。
- [ ] 文档同步完成，三档证据齐备。

## 执行记录（2026-11-04）

| 任务 | 状态 | 证据 |
|---|---|---|
| T1 | 代码完成 | `swift build`；`grep -c LSUIElement scripts/package-utility.sh`=0；`strings` 命中 `hideDockIcon` |
| T2 | 代码完成 | `swift build`；`styleMask` 含 `.miniaturizable`；regular 下失焦不自动恢复 |
| T3 | 代码完成 | `ConfigManager.apply(_:)`、`.bak`、1 MB 与未知键合并；设置窗口单例 |
| T4 | 代码完成 | 七个分组与校验；`HotkeyManager.isValid`；`gen-l10n --check` 通过 |
| T5 | 代码完成 | 主菜单 `Cmd+,` 与菜单栏「设置…」共用 `SettingsWindowController.shared` |
| T6 | 文档完成 | README / README.zh / AGENTS / CLAUDE.md / panel-ui.md 已同步；`run-tests.sh` 全过 |

### 待用户 L3 手测

- [x] 默认启动为 Dock 应用，出现三组主菜单；终端主窗口展示。
- [x] `Cmd+W` 后应用驻留；点 Dock 图标恢复窗口；`Cmd+M` 可最小化。
- [x] `Cmd+H` 后 1.5 s 内终端窗口不自动弹回。
- [x] 主菜单 `Cmd+,` 与菜单栏「设置…」打开同一设置窗口。
- [x] 修改字号保存后 `config.yaml` 与 `.bak` 更新，新会话使用新字号。
- [x] `hideDockIcon` 保存后即时切换；`true` 时菜单栏项与热键仍可用。
- [x] 剪贴板、翻译、知识、Stage 面板键盘输入正常；OCR 选区 ESC 可退出。

L3 结果（1.1.59）：`Cmd+W` 后立即 `activation policy=accessory mainWindowActive=false`，热键重开为 `regular mainWindowActive=true`；启动后无 `restoring after focus loss`。

打包未执行：`scripts/package-utility.sh` 会自增 VERSION 并需要 `SIGNING_IDENTITY`，留待用户授权后运行。

### 审查修复（2026-11-04）

- 阻断：`apply(_:)` 改为合并保留未知顶层键（`search` 等）后写入，不再抛 `wouldDropKeys`；对应错误类型与文案已删。
- 应修：窗口菜单补「关闭窗口」`Cmd+W`；保存前 `makeFirstResponder(nil)` 结束编辑；设置窗口仅在不可见时从磁盘重载。
- 建议：设置菜单改用轻量 target，启动不再构建设置窗口；`terminal.md` 同步主菜单与失焦兜底描述。
- 追加修复：`Cmd+M` 最小化后被失焦兜底 0.4s 拉回，`scheduleRestoreCheck` 与 `windowDidResignKey` 跳过 `isMiniaturized` 窗口；待重新打包后 L3 复验。
- 打包修复：DMG 改用含 `Utility.app` 的暂存目录生成，打包后挂载断言卷根存在 `Utility.app`，并加 `/Applications` 软链；旧命令会把 `Contents/` 铺到卷根。
- 行为调整（用户选定）：`hideDockIcon: true` 只在终端窗口关闭时隐藏 Dock 图标；窗口打开或最小化时保持 regular，菜单栏与 Cmd+Tab 可用。策略入口收敛到 `AppActivation`。
