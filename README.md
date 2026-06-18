# Utility — macOS 桌面工具集

菜单栏常驻、快捷键驱动的 macOS 工具集，包含剪切板管理、AI 翻译（含 OCR 区域截图）、
拖拽暂存和 RSS 订阅四个核心功能。

---

## 目录

- [安装与启动](#安装与启动)
- [配置](#配置)
- [快捷键一览](#快捷键一览)
- [功能说明](#功能说明)
  - [剪切板管理](#剪切板管理)
  - [翻译](#翻译)
  - [OCR 区域截图翻译](#ocr-区域截图翻译)
  - [拖拽暂存](#拖拽暂存)
  - [RSS 订阅（CLI）](#rss-订阅cli)
- [命令行接口](#命令行接口)
- [菜单栏](#菜单栏)
- [技术栈](#技术栈)
- [日志与调试](#日志与调试)

---

## 安装与启动

```bash
# 编译（首次需要下载依赖，约 1-2 分钟）
cd ~/Documents/it/project/utility && swift build -c release

# 启动（菜单栏出现图标即为成功）
.build/release/utility &

# 开机自启（可选，添加到登录项）
# 系统设置 → 通用 → 登录项 → 添加 .build/release/utility
```

---

## 配置

配置文件：**`~/.config/utility/config.yaml`**

首次启动自动生成默认配置。修改后通过菜单栏「重载配置」立即生效，无需重启 app。

### 完整配置项

```yaml
# ~/.config/utility/config.yaml

# ---------- AI ----------
ai:
  # OpenAI 兼容 API 地址
  baseURL: "https://api.deepseek.com"
  # API 密钥（必填，翻译功能需要）
  apiKey: ""
  # 模型名
  model: "deepseek-v4-flash"

# ---------- 剪切板 ----------
clipboard:
  # 保留天数，超过自动清理
  maxDays: 3
  # 排除的应用（这些 app 内的复制不记录）
  excludeApps:
    - "SecurityAgent"
    - "KeychainAccess"
  # 弹出剪切板面板的快捷键
  hotkey: "cmd+shift+c"
  # 轮询间隔（秒）。越小响应越快，CPU 占用略增
  pollInterval: 0.3

# ---------- 翻译 ----------
translation:
  # 弹出翻译面板的快捷键
  hotkey: "option+d"
  # OCR 截图翻译的快捷键
  hotkeyOCR: "option+s"
  # 默认源语言（"auto" = 自动检测）
  sourceLang: "auto"
  # 默认目标语言（"auto" = 根据 firstLang/secondLang 自动判断翻译方向）
  targetLang: "auto"
  # 第一语言（targetLang=auto 时，检测到 firstLang 则译到 secondLang）
  firstLang: "zh"
  # 第二语言（targetLang=auto 时，检测到 secondLang 则译到 firstLang）
  secondLang: "en"
  # 自定义翻译提示词（选填）
  # 为空则使用内置默认提示词
  # 支持 {source} 和 {target} 变量替换
  prompt: ""

# ---------- 暂存 ----------
stage:
  # 拖出到 Finder/桌面时是否移动源文件（默认 false，仅从暂存区移除）
  # true: Finder 执行移动后从暂存移除
  # false: 仅从暂存区移除条目，源文件保留
  moveOnDragOut: false

# ---------- RSS 订阅 ----------
rss:
  # 订阅源列表
  feeds:
    # - name: "示例博客"
    #   url: "https://example.com/feed.xml"
    #   tags: ["tech", "blog"]
  # 建议更新间隔（分钟），供外部调度参考
  updateInterval: 30

# ---------- AI 提示词模板 ----------
prompts:
  # 自定义提示词模板，键为功能名，值为提示词内容
  # 内置 translate、translate_auto、summarize、rewrite 四个默认模板
  # 此处可覆盖
  templates: {}
```

### 配置示例：接入不同 AI 服务

<details>
<summary>DeepSeek</summary>

```yaml
ai:
  baseURL: "https://api.deepseek.com"
  apiKey: "sk-你的key"
  model: "deepseek-v4-flash"
```
</details>

<details>
<summary>OpenAI</summary>

```yaml
ai:
  baseURL: "https://api.openai.com"
  apiKey: "sk-你的key"
  model: "gpt-4o-mini"
```
</details>

<details>
<summary>本地 Ollama</summary>

```yaml
ai:
  baseURL: "http://localhost:11434"
  apiKey: "ollama"  # Ollama 不需要真实 key，但不能为空
  model: "llama3.2"
```
</details>

<details>
<summary>自定义翻译提示词</summary>

```yaml
translation:
  prompt: "你是一个专业的技术翻译。将{source}翻译成{target}。\n规则：\n1. 保留代码、变量名、命令行不翻译\n2. 技术术语首次出现保留英文括号标注\n3. 只返回翻译结果，不要解释"
```
</details>

<details>
<summary>自定义提示词模板</summary>

内置模板名：`translate`（固定源→目标）、`translate_auto`（自动判断方向）、`summarize`、`rewrite`。

```yaml
prompts:
  templates:
    summarize: "请用中文总结以下内容的要点，保持简洁，标注关键数字"
    rewrite: "请用更专业的语气重写以下文本"
```
</details>

---

## 快捷键一览

| 快捷键 | 功能 | 配置项 |
|--------|------|--------|
| `cmd+shift+c` | 弹出剪切板面板 | `clipboard.hotkey` |
| `option+d` | 弹出翻译面板 | `translation.hotkey` |
| `option+s` | OCR 区域截图翻译 | `translation.hotkeyOCR` |
| **拖拽文件/文本到屏幕左下角** | 自动暂存 | 全局拖拽监听，无需快捷键 |

### 翻译面板内快捷键

| 快捷键 | 功能 |
|--------|------|
| `Enter` | 粘贴译文到原焦点应用并关闭 |
| `cmd+Enter` | 翻译原文 |
| `shift+Enter` | 换行 |
| `Esc` | 关闭面板 |
| `cmd+c` / `cmd+x` / `cmd+v` | 复制 / 剪切 / 粘贴 |
| `cmd+a` | 全选 |
| `cmd+z` | 撤销 |
| 切换语种下拉 | 自动重新翻译（有内容时） |

### 快捷键格式

`modifier+key`，支持修饰键：

| 修饰符 | 写法 |
|--------|------|
| Command | `cmd` / `command` |
| Option | `option` / `alt` |
| Shift | `shift` |
| Control | `ctrl` / `control` |

例如：`cmd+shift+c`、`option+d`、`ctrl+shift+1`

---

## 功能说明

### 剪切板管理

复制任意内容后自动记录，快捷键弹出面板浏览/粘贴。

- **记录内容**：文本、文件（含多文件）、图片、网页 HTML
- **排除应用**：可配置不记录指定 app 的复制
- **自动去重**：相同内容复制只更新时间戳，不重复存储
- **自动清理**：按 `maxDays` 定期清理过期条目
- **存储**：SQLite，约 1000 条不到 1MB

**面板操作：**

| 操作 | 效果 |
|------|------|
| `cmd+shift+c` | 打开面板，显示所有历史条目 |
| `↑` / `↓` | 选择条目 |
| `Enter` | 粘贴选中条目到原焦点应用并关闭 |
| `Esc` | 关闭面板 |

面板特性：
- 智能定位：根据鼠标位置选择最佳弹出位置（右下→左下→右上→左上）
- 条目编号圆圈：选中高亮蓝色，超过 99 条显示白点
- 文件/HTML 条目显示图标，文本条目仅显示编号和内容
- 翻译面板打开时粘贴到剪切板面板会插入原文区而非目标应用
- 粘贴后自动恢复原焦点应用

---

### 翻译

AI 驱动的文本翻译面板，带原文/译文双区布局。

**两种触发方式：**

**方式一：选中即译**
1. 在任意应用中选中文本
2. 按 `option+d` → 选中文本自动填入原文区并触发翻译
3. 按 `Enter` 粘贴译文到原应用

**方式二：手动输入**
1. 无选中文本时按 `option+d` → 空白面板
2. 输入文本，按 `cmd+Enter` 翻译
3. `shift+Enter` 换行，`Esc` 关闭

**特性：**
- **翻译中保护**：翻译过程中 `Enter`、`Esc` 等操作静默取消旧任务再执行新操作
- **序列号防竞态**：快速切换语言产生的旧翻译回调自动丢弃
- **语言切换自动翻译**：切换语种时有内容则自动重新翻译
- **翻译遮罩**：译文区显示半透明加载动画 / 错误信息

**面板布局：**

```
┌─ 原文 ──────────────┬─ [自动检测 ▾] ─┐
│ (可编辑输入框)                        │
├─ ─────────────────────────────────── ┤
│ 译文 ───────────────┬─ [中文 ▾] ─────│
│ (只读显示框，翻译中显示加载动画)       │
└──────────────────────────────────────┘
```

**支持的 26 种语言：**

自动检测、中文、英文、西班牙文、印地文、阿拉伯文、孟加拉文、葡萄牙文、
俄文、日文、旁遮普文、德文、爪哇文、韩文、法文、泰卢固文、马拉地文、
泰米尔文、乌尔都文、越南文、意大利文、泰文、马来文、土耳其文、荷兰文、
波兰文、乌克兰文

**翻译方向自动判定（`targetLang: "auto"`）：**
- 检测到原文是 `firstLang` → 翻译到 `secondLang`
- 检测到原文是 `secondLang` → 翻译到 `firstLang`
- 检测到原文是其他语言 → 翻译到 `firstLang`

---

### OCR 区域截图翻译

截取屏幕任意区域并识别文字，自动进入翻译流程。

1. 按 `option+s`
2. 屏幕变成半透明遮罩层
3. **鼠标拖拽框选**要识别的区域
4. 松开鼠标 → Vision OCR 识别 → 文字填入翻译面板并触发翻译
5. 按 `Esc` 取消框选

**实现细节：**
- 使用 Vision `VNRecognizeTextRequest`（accurate 模式）
- 识别语言：中文简体 + 英文
- 遮罩层 `.nonactivatingPanel` + CGEventTap 拦截 ESC
- `CGDisplayCreateImage` 在后台线程执行
- 选区渲染：暗灰 0.5pt 边框 + 半透明高亮 + 尺寸标注
- ESC 释放：`CGEventTap` passRetained + `perform:afterDelay:0`

---

### 拖拽暂存

类似 Yoink 的临时暂存功能，通过屏幕左下角浮动窗口收纳文件、文本和网页片段。

**存入方式：**
- 从任意应用拖拽内容到屏幕左下角的暂存窗口（自动显示）

**窗口行为：**
- 有暂存数据时窗口常驻显示
- 无数据时窗口自动隐藏，拖拽靠近屏幕左下角区域（窗口 + 40px 容差）时自动显示
- 左上角「清空」按钮删除所有暂存条目
- 每条目有「×」按钮可单独删除

**取用方式：**
- 拖出条目到任意目标（Finder / 浏览器 / 微信等）
- 拖出后条目自动从暂存区移除

**支持内容类型：**
- 文件（单个 / 多个）
- 纯文本
- 网页 HTML（富文本）
- URL 链接
- 图片（写临时文件后统一为 fileURL）

---

### RSS 订阅（CLI）

无界面 RSS 引擎，通过命令行管理订阅源。

配置 RSS 源后，数据自动存入 SQLite：

```yaml
# config.yaml
rss:
  feeds:
    - name: "酷壳"
      url: "https://coolshell.cn/feed"
    - name: "V2EX"
      url: "https://www.v2ex.com/index.xml"
```

---

## 命令行接口

```bash
utility rss [选项]
```

| 选项 | 说明 |
|------|------|
| `--fetch`, `-f` | 抓取所有订阅源的新文章，去重存入 SQLite |
| `--unread`, `-u` | 列出所有未读文章 |
| `--mark-read <id>` | 按 ID 标记单篇已读 |
| `--mark-all-read` | 全部标记已读 |
| `--help` | 显示帮助 |

**使用示例：**

```bash
# 抓取更新
utility rss --fetch
# → ✅ 抓取完成: 12 条新内容

# 查看未读
utility rss --unread
# → [酷壳] 技术领导力
#   https://coolshell.cn/articles/12345.html
#   2026/6/16 14:30
#   → 共 12 条未读

# 标记已读
utility rss --mark-all-read
# → ✅ 全部标记为已读
```

**配合 Hermes Agent 自动筛选：**

```bash
# 抓取新文章，输出给 AI 做摘要
utility rss --fetch --unread | llm -s "筛选出 AI/LLM 相关文章，输出摘要"
```

---

## 菜单栏

点击菜单栏图标（方形网格图标）显示菜单：

```
重载配置 ⌘R
─────────
清空剪切板
─────────
退出 ⌘Q
```

- **重载配置**：热加载 `~/.config/utility/config.yaml`，无需重启
- **清空剪切板**：删除 SQLite 中所有剪切板记录
- **退出**：完全退出 app

---

## 技术栈

| 层面 | 选型 |
|------|------|
| 语言 | Swift 5.9+ |
| UI 框架 | AppKit（菜单栏 + NSPanel） |
| 存储 | GRDB（SQLite） |
| 配置 | Yams（YAML） |
| 热键 | Carbon EventHotKey |
| 翻译 API | OpenAI 兼容格式 |
| OCR | Vision（VNRecognizeTextRequest） |
| 暂存拖拽 | CGEventTap 全局监听 |
| CLI | swift-argument-parser |
| 依赖 | GRDB.swift, Yams, swift-argument-parser |

---

## 日志与调试

Debug 模式下日志输出到 stdout，可在终端看到 `[Utility]`、`[Config]`、`[Clipboard]` 等标记的消息。
粘贴操作的详细日志写入 `~/Library/Logs/utility-paste.log`。

```bash
# 查看粘贴日志
tail -f ~/Library/Logs/utility-paste.log

# 数据文件位置
~/.config/utility/config.yaml     # 配置文件
~/.config/utility/data.sqlite     # SQLite 数据库（剪切板+暂存+RSS）
~/.cache/utility/clip/            # 剪切板图片临时缓存
~/.cache/utility/stage/           # 暂存图片临时缓存
```

```bash
# 查看数据库
sqlite3 ~/.config/utility/data.sqlite
.tables
# clipboard_item  stage_item  rss_item
```
