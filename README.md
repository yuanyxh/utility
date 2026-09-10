# Utility — macOS 桌面工具集

菜单栏常驻、快捷键驱动的 macOS 工具集，包含剪切板管理、AI 翻译（含 OCR 区域截图）、
拖拽暂存、RSS 订阅、MCP 记忆服务、定时任务调度和实时网速监控七个核心功能。

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
  - [RSS 订阅](#rss-订阅)
  - [定时任务调度](#定时任务调度)
  - [MCP 记忆服务](#mcp-记忆服务)
  - [网速监控](#网速监控)
- [命令行接口](#命令行接口)
- [菜单栏](#菜单栏)
- [错误通知](#错误通知)
- [技术栈](#技术栈)
- [日志与调试](#日志与调试)

---

## 安装与启动

```bash
# 编译（首次需要下载依赖，约 1-2 分钟）
cd ~/Documents/it/project/utility && swift build -c release

# 启动（菜单栏出现图标即为成功）
.build/release/utility &

# 开机自启（菜单栏 → 开机自启，使用系统登录项）
```

---

## 配置

配置文件：**`~/.config/utility/config.yaml`**

首次启动自动生成默认配置。修改后通过菜单栏「重载配置」立即生效，无需重启 app。

语言切换：设置 `general.language` 为 `zh` 或 `en`，留空跟随系统语言。翻译面板的语种选择器以各语种母语显示，不受此设置影响。

### 完整配置项

```yaml
# ~/.config/utility/config.yaml

# ---------- 通用 ----------
general:
  # 界面语言。留空跟随系统，可选: zh / en
  language: ""

# ---------- 通知 ----------
notifications:
  enabled: true   # false 关闭所有通知

# ---------- AI ----------
ai:
  baseURL: "https://api.deepseek.com"
  apiKey: ""
  model: "deepseek-v4-flash"

# ---------- 剪切板 ----------
clipboard:
  maxDays: 3
  excludeApps:
    - "SecurityAgent"
    - "KeychainAccess"
  hotkey: "cmd+shift+c"
  pollInterval: 0.3

# ---------- 翻译 ----------
translation:
  hotkey: "option+d"
  hotkeyOCR: "option+s"
  sourceLang: "auto"
  targetLang: "auto"
  firstLang: "zh"
  secondLang: "en"
  prompt: ""

# ---------- 暂存 ----------
stage:
  moveOnDragOut: false

# ---------- RSS 订阅 ----------
rss:
  feeds:
    - name: "MDN Blog"
      url: "https://developer.mozilla.org/en-US/blog/rss.xml"

# ---------- 定时任务 ----------
tasks:
  - name: RSS 日报
    trigger: '0 10 * * *'
    exec:
      type: sh
      command: ~/.hermes/scripts/utility-rss-daily.sh
    enabled: true
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
  apiKey: "ollama"
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

<details>
<summary>MCP 记忆服务</summary>

```yaml
mcp:
  # 是否启用 MCP 记忆服务（需先安装 Python 依赖）
  enabled: false
  # MCP 服务端口
  port: 9001
  # Qdrant 向量数据库路径
  qdrantPath: "~/Documents/selfdata/database/qdrant_data"
  # 知识库路径（笔记目录）
  knowledgeBasePath: "~/Documents/selfdata/notes"
  # fastembed 模型缓存目录
  fastembedCacheDir: "~/.cache/fastembed_cache"
  # 嵌入模型
  embedderModel: "sentence-transformers/all-MiniLM-L6-v2"
  # 每日记忆总结
  summaryEnabled: true
  summaryHour: 17
  # true=仅统计报表，跳过 AI 总结
  summaryStatsOnly: false
```
</details>

<details>
<summary>模型代理（Token Proxy）</summary>

本地反向代理，将 Claude Code 的 API 请求转发到上游 provider 并记录 token 用量。
将 `ANTHROPIC_BASE_URL=http://localhost:8613/open/v1` 指向本代理即可接入。

```yaml
modelProxy:
  # 是否启用模型代理
  enabled: false
  # 兼容：providers 为空时的单一上游地址
  url: ""
  # 本地代理监听端口
  port: 8613
  # 模型路由表：body.model 精确匹配某 provider.models → 路由到该 provider；
  # 未匹配 → providers[0] 兜底（上游 model 用其 models[0]）。
  # apiFormat: anthropic | openai，客户端格式不同时自动做协议转换。
  # apiKey: 转发时替换的 provider key，为空则透传客户端 key。
  providers:
    - name: deepseek
      url: "https://api.deepseek.com/anthropic"
      apiFormat: anthropic
      apiKey: ""
      models:
        - deepseek-v4-flash
    - name: mimo
      url: "https://api.xiaomimimo.com/anthropic"
      apiFormat: anthropic
      apiKey: ""
      models:
        - mimo-v2.5-pro
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

---

## 功能说明

### 剪切板管理

复制任意内容后自动记录，快捷键弹出面板浏览/粘贴。

- **记录内容**：文本、文件（含多文件）、图片、网页 HTML
- **排除应用**：可配置不记录指定 app 的复制
- **自动清理**：按 `maxDays` 定期清理过期条目
- **存储**：SQLite

**面板操作：**

| 操作 | 效果 |
|------|------|
| `cmd+shift+c` | 打开面板，显示所有历史条目 |
| `↑` / `↓` | 选择条目 |
| `Enter` | 粘贴选中条目到原焦点应用并关闭 |
| `Esc` | 关闭面板 |

---

### 翻译

AI 驱动的文本翻译面板，带原文/译文双区布局。支持 26 种语言。

**方式一：选中即译**
1. 任意应用中选中文本
2. 按 `option+d` → 自动填入原文区并翻译

**方式二：手动输入**
1. 按 `option+d` → 空白面板
2. 输入文本，按 `cmd+Enter` 翻译

**翻译方向自动判定（`targetLang: "auto"`）：**
- 原文是 `firstLang` → 译到 `secondLang`
- 原文是 `secondLang` → 译到 `firstLang`
- 其他 → 译到 `firstLang`

---

### OCR 区域截图翻译

1. 按 `option+s`
2. 鼠标拖拽框选屏幕区域
3. 松开 → Vision OCR 识别 → 填入翻译面板并翻译
4. `Esc` 取消

---

### 拖拽暂存

类似 Yoink 的临时暂存功能，屏幕左下角浮动窗口。

- **存入**：拖拽文件/文本/网页到屏幕左下角窗口
- **取用**：从窗口拖出到目标应用，自动移除
- 有数据常驻显示，无数据时拖拽靠近才显示

---

### RSS 订阅

无界面 RSS 引擎，数据存入 SQLite。通过菜单栏或 CLI 手动触发抓取。

- **菜单栏**：显示未读数，可「抓取 RSS」或「全部已读」
- **CLI**：`utility rss --fetch` / `--unread` / `--mark-all-read`
- **存储**：SQLite（`rss_item` 表）

配合 Hermes Agent 可实现每日自动筛选总结（见下方定时任务）。

---

### MCP 记忆服务

基于 Mem0 + Qdrant 双层的个人知识记忆服务，通过后台 Python 子进程提供 MCP Tools。

**架构：**
- **热层**（Mem0 → Qdrant）：原始碎片记忆，自动提取/去重/冲突解决
- **冷层**（Qdrant 独立集合）：已归档知识索引，定期衰减热度
- **笔记搜索**：`grep` 兜底全文搜索本地 Markdown/TXT
- **项目依赖图**：SQLite FTS5 索引 Swift/JS/Python 符号定义（含起止行号，可定位代码范围）

**MCP Tools（通过 HTTP SSE 通道）：**
| Tool | 功能 |
|------|------|
| `remember` | 写入单条事实到热层 |
| `remember_batch` | 批量写入多条记忆 |
| `recall` | 搜索记忆库（热层 + 冷层 + 笔记全文） |
| `catch_up` | 获取最近记忆列表 |
| `forget` | 删除指定记忆 |
| `project_notes` | 语义搜索项目本地 .md 笔记文件（向量索引 + 增量缓存；目标路径无工程特征文件时降级为纯内存 keyword 搜索，不创建 `.utility` 缓存） |
| `project_search/structure/packages/exports` | 项目符号/结构/依赖/导出查询 |
| `tool_resource` | 返回已注册 skill 的附属资源内容（references/agents/scripts 目录） |

**每日总结流水线：** 定时（默认每日 17 点）从热层拉取 3 天记忆 → LLM 聚合去重/分类 → 关键词检索 `Extracts/` 已有笔记，同主题自动归并、全新主题新建 → 写入 `Extracts/` 目录 + 同步冷层。

**菜单栏：** 显示 MCP 运行状态（● 运行中 / ◐ 初始化 / ○ 已停止 / ✕ 崩溃），可重启服务。

**前置条件：**
```bash
# 安装 Python 依赖
cd Sources/MCPScripts && pip3 install -r requirements.txt
```

---

### 定时任务调度

基于 cron 表达式的 one-shot Timer 调度器，支持补触发和睡眠唤醒。

**触发模式：**

| mode | 说明 |
|------|------|
| `cron`（默认） | cron 定时调度，支持补触发 |
| `manual` | 仅手动触发，不参与 cron 调度。运行中菜单打 ✓，再点击终止进程 |

**触发方式：** 每天 60s 轮询改为精确到秒的 one-shot Timer。
**补触发：** 启动/重载/唤醒时检查上次触发时间，错过则补执行一次。
**并发：** 每个任务在后台队列独立执行，不阻塞调度循环。

**支持四种执行类型：**

| type | 说明 | 示例 |
|------|------|------|
| `sh` | Shell 脚本 | `command: ~/.hermes/scripts/cleanup.sh` |
| `js` | JXA (JavaScript for Automation) | `command: Application("Music").play()` |
| `shortcuts` | 快捷指令 | `command: 播放喜欢音乐` |
| `py` | Python 脚本 | `command: print("hello")` |

**配置示例：**

```yaml
tasks:
  - name: RSS 日报
    trigger: '0 10 * * *'
    exec:
      type: sh
      command: ~/.hermes/scripts/utility-rss-daily.sh
    enabled: true
    mode: cron     # cron（默认）或 manual

  - name: Alist 服务
    mode: manual   # 手动触发，菜单点击启动/终止
    exec:
      type: sh
      command: cd ~/Documents/alist && ./alist server
    enabled: true

  - name: 清理临时文件
    trigger: '0 3 * * 1'
    exec:
      type: sh
      command: rm -rf /tmp/myapp-*
    enabled: true
```

**Cron 表达式格式：** `分 时 日 月 周`（5 字段，标准 cron）

- **菜单栏**：`任务 (N)` 列出所有任务，点击即可立即触发；禁用项置灰不可点击

---

### 网速监控

菜单栏直接显示主网卡实时上行/下行速度，无需点击。每 2 秒刷新。

```
菜单栏：  ↑ 01.23M
          ↓ 00.08M
```

- **单位**：MB / GB，2 位小数
- **接口**：自动汇总所有 enX 网卡（WiFi + 以太网 + 雷电网桥）
- **布局**：上下两行，等宽数字右对齐，整数位自动补 0 保证宽度一致不跳
- **位置**：启动后 Cmd+拖拽到菜单栏左侧，`autosaveName` 固定位置
- **无网络时**：显示 `0.00M`，不会异常
- **内存占用**：增量 < 1MB（仅一个 Timer + getifaddrs 临时分配）

---

## 命令行接口

```bash
utility rss [选项]
```

| 选项 | 说明 |
|------|------|
| `--fetch`, `-f` | 抓取所有订阅源的新文章 |
| `--unread`, `-u` | 列出所有未读文章（JSON 格式） |
| `--mark-read <id>` | 按 ID 标记单篇已读 |
| `--mark-all-read` | 全部标记已读 |

**使用示例：**

```bash
# 抓取更新
utility rss --fetch

# 查看未读（JSON）
utility rss --unread

# 标记全部已读
utility rss --mark-all-read
```

---

## 菜单栏

菜单栏直接显示网速监控，点击弹出功能菜单：

```
重载配置 ⌘R
─────────
开机自启
─────────
RSS (3 未读)  ▸ 抓取 RSS
                 全部已读
─────────
● MCP        ▸ 运行中
                 重启服务
                 Qdrant: ~/Documents/selfdata/database/qdrant_data
                 知识库: ~/Documents/selfdata/notes
─────────
任务 (2)     ▸ RSS 日报
                清理临时文件（灰色，已禁用）
─────────
清空剪切板
─────────
退出 ⌘Q
```

- **重载配置**：热加载 `~/.config/utility/config.yaml`，同时刷新 RSS 未读数、任务列表和定时抓取间隔
- **开机自启**：通过系统登录项（SMAppService）自动启动
- **RSS**：显示未读数量，子菜单可手动触发抓取或全部已读
- **MCP**：显示服务运行状态，子菜单可重启服务、查看数据路径。未启用时显示「○ MCP（未启用）」
- **任务**：列出所有任务，点击立即执行一次；运行中打 ✓，再点击终止进程；禁用的任务置灰不可点击
- **清空剪切板**：删除所有剪切板记录
- **退出**：完全退出 app

---

## 通知

> 配置 `notifications.enabled: false` 可全局关闭所有通知。

| 场景 | 通知 |
|------|------|
| 启动时配置加载失败 | 「配置加载失败」 |
| 启动时数据库初始化失败 | 「数据库初始化失败」 |
| 菜单栏重载配置失败 | 「配置重载失败」 |
| 热键注册失败（格式错误/被占用） | 「热键注册/解析失败」 |
| 定时任务执行失败 | 「任务失败: \<name\>」 |
| 任务执行成功 | 「任务完成: \<name\>」 |
| MCP 进程崩溃超过重试阈值 | 「MCP 服务 — 连续崩溃 N 次，已停止」 |

---

## 技术栈

| 层面 | 选型 |
|------|------|
| 语言 | Swift 5.9+ / Python 3 |
| UI 框架 | AppKit（菜单栏 + NSPanel） |
| 存储 | GRDB（SQLite）+ Qdrant（向量数据库） |
| 配置 | Yams（YAML） |
| 热键 | Carbon EventHotKey |
| 翻译 API | OpenAI 兼容格式 |
| OCR | Vision（VNRecognizeTextRequest） |
| 暂存拖拽 | CGEventTap 全局监听 |
| 定时调度 | Timer + CronExpression |
| MCP 协议 | mcp.server + StreamableHTTPServerTransport |
| 记忆引擎 | Mem0（热层）+ fastembed + Qdrant（冷层） |
| 项目扫描 | AST + 正则 + FTS5 多语言符号提取（含符号起止行号，Swift/JS/Python/Java/Kotlin） |
| 通知 | UNUserNotificationCenter / NSUserNotificationCenter |
| 网速 | getifaddrs（POSIX 网卡字节计数） |
| 登录项 | SMAppService |
| CLI | swift-argument-parser |
| 依赖 | GRDB.swift, Yams, swift-argument-parser, mcp, qdrant-client, fastembed, mem0ai |

---

## 日志与调试

```bash
# 运行时追踪日志
tail -f ~/.cache/utility/debug.log

# 数据文件
~/.config/utility/config.yaml     # 配置文件
~/.config/utility/data.sqlite     # SQLite 数据库
~/.config/utility/task_state.yaml # 任务状态（已废弃，现在用 task_state 表）
~/.cache/utility/clip/            # 剪切板图片缓存
~/.cache/utility/stage/           # 暂存图片缓存

# MCP 服务日志
tail -f ~/Documents/selfdata/notes/logs/server.log      # MCP 服务
tail -f ~/Documents/selfdata/notes/logs/summarize.log   # 每日总结流水线
~/Documents/selfdata/notes/流水线错误日志.jsonl            # 总结流水线异常记录

# 查看数据库
sqlite3 ~/.config/utility/data.sqlite ".tables"
# clipboard_item  stage_item  rss_item  task_state
```
