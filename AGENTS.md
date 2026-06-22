# AGENTS.md — Utility Project

> 为 Hermes Agent 提供项目上下文、开发约定、内存数据参考。每次会话自动注入。

---

## 项目概述

**utility** — macOS 菜单栏工具，Swift + AppKit + SPM。
- LSUIElement（无 Dock 图标）
- NSStatusItem 菜单栏入口
- NSPanel floating 面板：剪贴板管理、翻译、Stage 暂存
- Carbon EventHotKey 全局快捷键
- GRDB 本地 SQLite 存储
- Vision OCR 屏幕区域识别

---

## 参考方针

> 以下约定覆盖所有开发活动。

1. **提交时机**：用户明确功能正常后，再提交代码。不要自己 commit。
   - 只提交暂存区代码（`git commit` 不加 `-a`）
   - 提交前检查 `default-config.yaml`、`README.md`、`AGENTS.md` 是否需要同步更新
   - 如需更新，更新后等用户确认，不继续提交动作
2. **排查策略**：2-3 轮对话后仍无法解决问题，搜索网络相关资料。
3. **Bug 修复**：依赖现实调试信息，禁止靠猜测修改。先给出明确的调试方案——如何获取必要信息。
   - **禁止猜测代码用途**：看不懂某段代码为什么那样写时，先查 git log 看提交记录和 commit message
   - git 记录看不出来时，问用户，不要自己假设
4. **大改动审批**：代码改动过大时，先询问，确认后再修改。

---

## 设计原则

> 所有代码必须遵循。

### 最小暴露
- 类的内部实现用 `private` / `fileprivate`，仅对外暴露必要的 `public` / `internal` API
- 不在 `AppDelegate` 暴露内部属性供外部调用（如 `clipboardWatcher`）——自管生命周期
- 单一入口、单一出口

### 解耦
- 视图与逻辑分离：Service/Manager 不依赖 NSView/NSWindow/NSViewController
- `PasteHelper`、`SelectedTextService`、`Translator`、`OCRService` 全部无视图依赖
- 跨模块通信走 `EventBus` pub/sub，禁止直接持有对方引用
- 单向依赖使用枚举 key 事件，一个 key 可多个 handler

### 复用
- 相同逻辑只写一次，不重复造轮子
- `Constants.swift` 集中管理共享类型（如 `PasteboardImageTypes.all`）
- `PasteHelper.schedulePaste(to:)` 供剪贴板和翻译面板共用
- `SelectedTextService` 封装 AX + 剪贴板兜底两路径，所有调用方统一入口

### 可单独调用
- 核心逻辑不依赖 UI 上下文，可直接从 CLI 或无头模式调用
- 例如：`Translator.translate()` 可独立调用于脚本，`OCRService.recognize()` 可仅返回文本

### 架构意识
- 设计模式优先：pub/sub、单例、策略、门面
- 优先组合而非继承
- 避免到处散落的外部引用——代之以依赖注入或 EventBus 通信

---

## 核心架构

| 组件 | 职责 |
|------|------|
| `AppDelegate` | 入口：注册 hotkey、初始化管理器 |
| `EventBus` | 线程安全 pub/sub（枚举 key 对应多 handler） |
| `ConfigManager` | YAML 配置加载/热重载 |
| `MenuBarManager` | NSStatusItem + NSMenu |
| `HotkeyManager` | Carbon RegisterEventHotKey |
| `ChatPanelController` | AI 对话面板：SSE 流式显示、选中文本预填、粘贴 |
| `AIChatService` | 对话服务：消息构建、system prompt 注入、流式请求生命周期 |
| `SSEParser` | SSE 帧解析器：`data:` 行 → content delta 回调 |
| `ClipboardPanelController` | 剪贴板面板 + clipboardStorage + clipboardWatcher（自管生命周期） |
| `TranslationPanelController` | 翻译面板 + 选中文本获取 |
| `StageWindowController` | Stage 暂存窗口 + StageDropMonitor（自管注册） |
| `TaskScheduler` | Timer + cron + 系统唤醒检测 |
| `TaskExecutor` | 外部脚本执行（sh/js/py） |
| `TaskStateDB` | GRDB 任务状态持久化 |
| `NotificationManager` | 本地通知 |
| `Translator` | OpenAI 兼容 API 翻译 |
| `OCRService` | Vision 帧捕获 + 文本识别 |
| `Database` | GRDB DatabaseQueue 单例 |
| `PasteHelper` | 粘贴到目标 app（osascript 子进程 + CGEventPost fallback） |
| `SelectedTextService` | AX Accessibility + 剪贴板兜底选中文本获取 |

---

## 关键技术约定

### Build
- Clean build: `rm -rf .build && swift build`
- 二进制：`.build/debug/utility` 或 `.build/arm64-apple-macosx/debug/utility`
- 验证改动进二进制：`strings .build/debug/utility | grep keyword`

### i18n
- JSON-dict 模式，`L10n + Bundle.module`
- `%@`（String）、`%ld`（Int）
- `refreshAllTitles()` 模式刷新运行时语言

### 并发
- `Task?.cancel()` + `guard isCancelled` 模式
- 翻译/对话用序列计数器（`chatSeq`/`translationSeq`）拒绝 stale 回调

### NSTableView
- `selectionHighlightStyle = .none` + manual frame + cell 子类 layout
- 避免 NSTableView 缓存 rowView 导致无限内存

### 粘贴
- osascript 子进程（避免 NSAppleScript 运行时内存泄漏）
- 浏览器 120ms / 原生 50ms 延迟
- CGEventPost fallback 双路保障
- `didActivateApplicationNotification` 激活检测

### Stage Drop
- `NSPasteboard(name: .drag)` cc 检测新拖拽
- `mouseDown` 快照 changeCount → `mouseUp` 对比
- `PasteboardImageTypes.all` 集中定义图片类型

### Config YAML
- 所有字段 `decodeIfPresent`（避免缺少 key 导致 crash）
- YAML key 必须与 struct property 名完全相同

### 文件删除
- 重要文件：`osascript Finder delete` 移废纸篓
- 临时/自建文件：`rm`
- 删除后记录到 `~/.hermes/edit_history/[YYYY-MM-DD].md`

---

## 内存基线

| 指标 | 值 |
|------|-----|
| RSS（空闲） | ~76 MB |
| Physical footprint（空闲） | ~22.5 MB |
| Physical footprint（回收后） | ~18.9 MB |
| Heap nodes | ~44,770 / ~6.8 MB |
| 粘贴后稳定 | ~30.4 MB（不再增长） |
| 粘贴方案 | NSTask + osascript，零 NSAppleScript 内存分配 |

---

## 版本

当前：**1.0.2**

---

## 相关技能

- `macos-menu-bar-app` — 完整 macOS 菜单栏应用开发指南
- `macos-swift-appkit` — AppKit 模式与陷阱（NSTableView、pasteboard、CGEventTap 等）
- `macos-native-dev` — Swift + AppKit 基础开发模式
