# Utility — macOS 桌面工具集

菜单栏常驻、快捷键驱动的 macOS 工具集，包含剪切板管理、翻译（含 OCR 区域截图）、
拖拽暂存和 RSS 订阅四个核心功能，预留 AI 自定义扩展架构。

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
- [扩展架构（远期预留）](#扩展架构远期预留)
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

修改后通过菜单栏「重载配置」立即生效，无需重启 app。

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
  # 第二语言（用于自动判断翻译方向）
  secondLang: "en"
  # 自定义翻译提示词（选填）
  # 为空则使用内置默认提示词
  # 支持 {source} 和 {target} 变量替换
  # 示例: "你是一个专业的技术文档翻译，保留代码和专有名词不翻译"
  prompt: ""

# ---------- 暂存 ----------
stage:
  # 拖出到有效目标时，文件是否为「移动」(默认 false，复制)
  # true: 拖出成功 → 备份到 ~/.cache/utility/stage/ → 移源文件入废纸篓
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
  # 内置翻译、总结、重写三个模板，此处可覆盖
  templates:
    # 翻译默认提示词
    translate: ""
    summarize: "请用中文总结以下内容的要点，保持简洁"
    rewrite: "请用更专业的语气重写以下文本"
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

---

## 快捷键一览

| 快捷键 | 功能 | 配置项 |
|--------|------|--------|
| `cmd+shift+c` | 弹出剪切板面板 | `clipboard.hotkey` |
| `option+d` | 弹出翻译面板 | `translation.hotkey` |
| `option+s` | OCR 区域截图翻译 | `translation.hotkeyOCR` |
| **拖拽文件/文本到菜单栏** | 自动暂存 | 无快捷键，拖拽即用 |

### 翻译面板内快捷键

| 快捷键 | 功能 |
|--------|------|
| `Enter` | 粘贴译文到原焦点应用并关闭（翻译中静默忽略） |
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

复制任意内容后自动记录，快捷键弹出面板浏览/搜索/粘贴。

- **记录内容**：文本、文件、图片
- **排除应用**：可配置不记录密码、钥匙串等敏感 app 的复制
- **自动清理**：按天数和数量上限自动清理旧条目
- **存储**：SQLite，约 1000 条不到 1MB

**面板操作：**

| 操作 | 效果 |
|------|------|
| `cmd+shift+c` | 打开面板 |
| `↑` / `↓` | 选择条目 |
| `Enter` | 粘贴选中条目并关闭 |
| `cmd+f` | 聚焦搜索框 |
| 输入文字 | 实时过滤 |
| `Esc` | 关闭面板 |

---

### 翻译

AI 驱动的文本翻译面板。

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
- **取消重翻**：翻译中修改内容后按 `Enter` → 旧翻译静默取消，新翻译立即开始
- **语言切换自动翻译**：切换源语种或目标语种时，有内容则自动重新翻译
- **翻译中保护**：翻译进行中按 `cmd+Enter`、关闭面板等操作静默取消，不中断用户操作

**面板布局：**

```
┌─ 原文 ──────────────┬─ [自动检测 ▾] ─┐
│ (可编辑输入框)                        │
├─ ─────────────────────────────────── ┤
│ 译文 ───────────────┬─ [中文 ▾] ─────│
│ (只读显示框)                          │
└──────────────────────────────────────┘
```

**支持的 26 种语言：**

自动检测、中文、英文、西班牙文、印地文、阿拉伯文、孟加拉文、葡萄牙文、
俄文、日文、旁遮普文、德文、爪哇文、韩文、法文、泰卢固文、马拉地文、
泰米尔文、乌尔都文、越南文、意大利文、泰文、马来文、土耳其文、荷兰文、
波兰文、乌克兰文

---

### OCR 区域截图翻译

截取屏幕任意区域并识别文字，自动进入翻译流程。

1. 按 `option+s`
2. 屏幕变成半透明遮罩层
3. **鼠标拖拽框选**要识别的区域
4. 松开鼠标 → 自动 OCR 识别 → 文字填入翻译面板
5. 按 `Enter` 翻译
6. 按 `Esc` 取消框选

---

### 拖拽暂存

类似 Yoink，但触发方式不同——**拖拽到菜单栏图标**即可自动暂存文件或文本。

取用方式：
- 菜单栏 → 「查看暂存」→ 列表显示所有暂存项目
- 双击项目：文件在 Finder 中定位，文本复制到剪切板
- 菜单栏 → 「清空暂存」删除所有条目

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
AI: deepseek-v4-flash | 剪切板: 3天 | 翻译: auto→zh
──────────────────────────────
暂存: 5                          ← 当前暂存数
剪切板管理 ✓                     ← 状态提示
──────────────────────────────
查看暂存                          ← 打开暂存面板
清空暂存                          ← 清空所有暂存
──────────────────────────────
重载配置 ⌘R                      ← 热加载 config.yaml
退出 ⌘Q
```

---

## 扩展架构（远期预留）

项目定义了 `AppModule` 协议，后续 AI 扩展功能（如：划词调用 AI 脚本、
自定义快捷键触发 AI 操作、定时后台服务）通过该协议插拔。

```swift
public protocol AppModule {
    var name: String { get }
    func setup() throws
    func registerHotkeys(using manager: HotkeyManager) throws
    func onConfigReload() throws
    func teardown()
}
```

远期 `config.yaml` 扩展示例（**当前未实现**）：

```yaml
scripts:
  - name: "总结选中文本"
    hotkey: "cmd+shift+s"
    prompt_template: "summarize"
    action: "replace_selection"
```

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
| 构建 | SPM |
| 依赖 | GRDB.swift, Yams, swift-argument-parser |

---

## 日志与调试

启动时的日志输出到 stdout，可以在终端看到 `[Utility]`、`[Config]`、`[Clipboard]` 等标记的消息。

```bash
# 前台运行查看日志
cd ~/Documents/it/project/utility && .build/release/utility

# 数据文件位置
~/.config/utility/config.yaml     # 配置文件
~/.config/utility/data.sqlite     # SQLite 数据库（剪切板+暂存+RSS）
```

如需修改数据库内容，可以使用：

```bash
sqlite3 ~/.config/utility/data.sqlite
.tables
# clipboard_item  stage_item  rss_item
```
