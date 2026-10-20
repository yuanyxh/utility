# Utility & MCP 合并计划

目标：Utility & MCP 都是个人的核心功能，计划将 MCP 整合进 Utility，方便管理。

Docker 资源消耗过大，尽可能剔除 Docker。

同时，计划在 Utility 实现 Agent 寄生模式，用于实现 Agent 的项目全局感知能力

MCP 移植进 utility，并实现查找项目依赖图/依赖图节点的 Tools，使 Agent 具有项目全局感知能力。

MCP 移植可以采用轻量移植方法，使用系统安装的 python3 相关工具，不改变底层架构

---

## Agent 寄生模式设计

### 核心概念

`utility -a` 是一个**通用启动器**，不限特定 Agent，任何终端形式调用的 Agent 都可接入。

### 运行模式

```
GUI 模式: Utility.app（菜单栏常驻）
├─ MCP 服务（Python 子进程，独立后台常驻）
├─ 剪切板/翻译/网速监控…
└─ 提供 MCP Tool 给连接的 Agent

CLI 模式: utility -a "<cmd>"
└─ 与 Agent 生命周期相同，stdout/stderr 直通，Agent 持有完整 TUI 控制权
```

### 接口

```sh
utility -a "claude -p '分析这个模块'"    # 通用 Agent 启动
utility -a "aider --model sonnet"        # 任何 CLI Agent
utility -a claude                         # 直接进入 TUI
utility --dir ~/projects/my-app -a claude # 指定项目目录
```

### CLI 生命周期

```
utility -a "claude -p '分析这个模块'"
  │
  ├─ parse args（--dir / CWD）
  │
  ├─ 检查 .utility/deps.sqlite
  │   ├─ 不存在 → 全量扫描
  │   └─ 存在   → 加载
  │
  ├─ 启动文件监听（background thread，实时更新依赖图）
  │
  ├─ 启动 Agent 子进程
  │   ├─ stdin/stdout/stderr 从父进程继承（直通 terminal）
  │   └─ Agent 获得完整 TUI 控制权
  │      └─ 可通过 MCP Tool 查询依赖图
  │
  ├─ Agent 退出
  │
  ├─ 停止文件监听
  └─ utility 退出
```

### 项目级配置

每个项目根目录下的 `.utility/config.json`，由用户控制：

```json
{
  "includes": ["**/*.swift", "**/*.ts", "**/*.py", "**/*.java"],
  "excludes": [".build/**", "node_modules/**", "dist/**"]
}
```

### 依赖图存储

- 存放在项目路径 `.utility/deps.sqlite`，每个项目独立
- 取不到则初始化扫描
- 不污染 Utility 全局数据库

### 设计要点

| 维度 | 方案 |
|------|------|
| 启动器通用性 | 不限定 Agent，任何 CLI 命令都可作为参数传入 |
| 生命周期 | `-a` 的生命周期与传入的 Agent 命令一致 |
| TUI 控制权 | 通过 stdin/stdout/stderr 直通，Agent 获得完整终端控制权 |
| `--dir` | 可选参数指定项目目录，未传则使用 CWD |
| 多实例 | 支持多 terminal 同时运行多个 `-a` 实例，互不干扰 |
| MCP 服务 | 独立后台常驻（由 GUI 进程管理），不随 `-a` 启停 |

---

## MCP 移植详细设计

### 架构

```
┌─────────────────────────────────────────────────┐
│  Utility.app                                      │
│                                                   │
│  ┌─────────────────┐    ┌──────────────────────┐  │
│  │  Swift 主进程    │    │  Python MCP 子进程     │  │
│  │                  │    │                        │  │
│  │  MCPProcessMgr   │───→│  Process(server.py)    │  │
│  │  (生命周期管理)   │    │  监听 localhost:9001   │  │
│  │                  │    │                        │  │
│  │  MCPClient       │←───│  HTTP MCP 协议         │  │
│  │  (API 调用)      │    │                        │  │
│  │                  │    │  ┌──────────────────┐  │  │
│  │  MCPMenuManager  │    │  │  mem0 → Qdrant   │  │  │
│  │  (菜单栏状态)     │    │  │  (热层记忆)       │  │  │
│  └─────────────────┘    │  ├──────────────────┤  │  │
│                          │  │  Qdrant 冷层     │  │  │
│                          │  │  (知识库 + 全文)  │  │  │
│                          │  ├──────────────────┤  │  │
│                          │  │  fastembed       │  │  │
│                          │  │  (向量嵌入)       │  │  │
│                          │  └──────────────────┘  │  │
│  ┌─────────────────┐    └──────────────────────────┘  │
│  │  Task Scheduler  │─── 每日触发 summarize.py        │
│  └─────────────────┘                                  │
│  ┌─────────────────┐                                  │
│  │  Config (YAML)   │── MCP 配置段                     │
│  └─────────────────┘                                  │
└─────────────────────────────────────────────────────────┘
```

### Python 源码打包

Utility 项目中新增目录：

```
Sources/
├── MCP/
│   ├── MCPProcessManager.swift    ← 子进程生命周期管理
│   ├── MCPClient.swift            ← HTTP 调用封装
│   └── MCPMenuManager.swift       ← 菜单栏状态集成
├── Resources/
│   └── mcp/                       ← Python 源码（打包进 .app）
│       ├── server.py              ← MCP 服务主入口
│       ├── summarize.py           ← 每日总结管线
│       └── requirements.txt       ← 依赖清单
└── ...
```

Python 相关文件放在 `Sources/Resources/mcp/` 目录，SPM 通过 `.process("Resources")` 自动打包进 `.app/Contents/Resources/`。

### 配置（合并进 config.yaml）

新增 `mcp:` 配置段，所有路径/参数可配置：

```yaml
# ---------- MCP 记忆服务 ----------
mcp:
  enabled: true
  port: 9001

  # 数据存储路径
  qdrantPath: "~/.config/utility/data/qdrant"
  knowledgeBasePath: "~/.config/utility/notes"

  # fastembed 模型缓存
  fastembedCacheDir: "~/.cache/fastembed_cache"
  embedderModel: "sentence-transformers/all-MiniLM-L6-v2"

  # 记忆生命周期
  hotRetentionDays: 180
  archiveDays: 90

  # 每日总结
  summaryEnabled: true
  summaryHour: 17

  # 进程守护
  maxRestarts: 3               # 连续崩溃上限，超限停止
  restartDelayMs: 2000         # 重启间隔
```

`ai.apiKey`、`ai.baseURL`、`ai.model` 直接从现有 `ai:` 段读取，不做冗余配置。优先级：环境变量 > config.yaml > 默认值。

### 进程生命周期管理（MCPProcessManager）

| 阶段 | 行为 |
|------|------|
| **App 启动** | 自动启动 Python 子进程 |
| **App 退出** | 发 SIGTERM → 等待 3s → SIGKILL |
| **进程崩溃** | 自动重启（记录次数），达上限后停止并通知 |
| **重载配置** | 发送 SIGTERM 后重启子进程（传新环境变量） |
| **进程保活** | 主进程声明周期内持续运行 |

```swift
// 核心逻辑：进程守护
final class MCPProcessManager {
    private var process: Process?
    private var crashCount = 0
    private let maxRestarts: Int    // 从配置读取

    func start() { /* 创建 venv → 启动 server.py → 监测就绪 */ }
    func stop()  { /* SIGTERM → 等待 → SIGKILL */ }
    func restart() { stop(); start() }

    // 崩溃检测
    private func onProcessExited(reason: Process.TerminationReason) {
        guard reason == .uncaughtSignal else { return }

        crashCount += 1
        if crashCount >= maxRestarts {
            // 连续崩溃三次 → 发送通知 → 不再重启
            NotificationManager.post("MCP 服务连续崩溃，已停止")
            state = .crashed
            return
        }

        state = .restarting
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay) {
            self.start()
            self.crashCount = 0  // 成功运行后重置
        }
    }

    // 成功运行后重置崩溃计数
    private func onHealthCheckPassed() {
        crashCount = 0
    }
}
```

### 状态感知（菜单栏集成）

MCP 服务的运行状态实时显示在菜单栏，状态机定义：

```
stopped → initializing → running
                        → downloading_model → running
                        → restarting
         → crashed (终止态)
```

菜单栏展示：

```
网速监控  |  ● MCP  |  翻译  |  剪贴板
              ├─ ● 运行中  (green)
              │  ● 初始化… (yellow, downloading/creating venv)
              │  ○ 已停止  (gray)
              │  ✕ 崩溃    (red, 带通知)
              ├─ ──────
              ├─ 重启服务
              ├─ ──────
              ├─ 数据路径…
              │   ├─ Qdrant: ~/.config/utility/data/qdrant
              │   ├─ 知识库:   ~/.config/utility/notes
              │   └─ 模型缓存: ~/.cache/fastembed_cache
              └─ 更多信息…
```

状态信息通过 `EventBus` 广播到 `MCPMenuManager` 更新菜单栏。

### 首次启动流程

```
App 启动
  │
  ├─ 检查 ~/Library/Application Support/utility/.venv/
  │
  ├─ 不存在 → 初始化（状态: initializing）
  │   ├─ python3 -m venv .venv                          ~5s
  │   ├─ pip install -r requirements.txt                ~30s
  │   └─ 检查 fastembed 缓存                              ~1s
  │
  ├─ 缓存不存在 → 下载模型（状态: downloading_model）
  │   └─ fastembed 自动下载 all-MiniLM-L6-v2            ~30s (174MB)
  │
  ├─ 启动 server.py（状态: running）
  │   ├─ 端口就绪检测（loop: GET http://localhost:9001/health）
  │   ├─ 超时 10s → 失败通知 + 重试
  │   └─ 就绪 → 标记 running，重置崩溃计数
  │
  └─ 菜单栏显示 ● MCP
```

### 失败通知

| 场景 | 通知内容 | 行为 |
|------|----------|------|
| Python 未安装 | 「MCP 服务启动失败：需要 Python 3」 | 停止 + 通知 |
| venv 创建失败 | 「MCP 环境初始化失败」 | 停止 + 通知 |
| 首次安装依赖慢 | 状态显示「正在安装依赖…」 | 异步，不阻塞 app |
| 连续崩溃 3 次 | 「MCP 服务已停止：连续崩溃 3 次」 | 进入 crashed 态 |
| 端口超时 | 「MCP 服务启动超时，正在重试」 | 自动重试 |
| 磁盘空间不足 | 「MCP 服务异常：请检查磁盘空间」 | 通知 + 停止 |

### Python 进程环境变量注入

Utility 启动 `server.py` 时传入环境变量（映射自 config.yaml）：

```
QDRANT_PATH=~/.config/utility/data/qdrant
KNOWLEDGE_BASE_PATH=~/.config/utility/notes
FASTEMBED_CACHE_DIR=~/.cache/fastembed_cache
EMBEDDER_MODEL=sentence-transformers/all-MiniLM-L6-v2
AI_API_KEY=sk-xxx
SUMMARY_MODEL=your-model
SUMMARY_API_URL=https://api.example.com
SUMMARY_TEMPERATURE=0.1
MCP_PORT=9001
```

这样 `server.py` 无需硬编码任何路径，完全由 Utility 配置驱动。

### Package.swift 调整

```swift
.executableTarget(
    name: "utility",
    dependencies: [/* 不变 */],
    resources: [
        .process("Resources"),            // 已有：i18n / icon / config
        .copy("Resources/mcp"),           // 新增：打包 Python 源码
    ]
)
```

Build 时 `Sources/Resources/mcp/` 目录会完整拷贝到 `.app/Contents/Resources/mcp/`，运行时通过 `Bundle.module.resourceURL!` 读取。

---

## 项目依赖图设计

### 核心定位

> **让 Agent 知道「这个项目有什么可用」**，而不是「文件引用关系如何」。

Agent 场景：
- "新功能该放哪个模块？" → `project_structure`
- "有没有日期格式化工具？" → `project_search "date format"`
- "这项目用什么发请求？" → `project_packages`
- "auth 模块暴露了什么 API？" → `project_exports "Sources/Auth"`

### MCP Tool 定义

| Tool | 输入 | 返回 | 场景 |
|------|------|------|------|
| `project_structure [path]` | 可选子路径 | 目录树 + 各目录文件/模块摘要 | 了解项目分层和模块职责 |
| `project_search <query>` | 关键词 | 匹配的符号/文件/导出项 | 找现成的工具函数 |
| `project_packages [type]` | 可选类型筛选 | 三方包列表 + 用途 | 选型参考 |
| `project_exports <path>` | 文件/目录路径 | 该模块暴露的公共接口 | 了解模块 API |

### 三层搜索提升命中率

```
Agent Query
    │
    ├─ Layer 1: FTS5 全文搜索
    │   匹配: 符号名 / 签名 / 注释文本 / 包名
    │   ├─ ✓ 命中 → 返回
    │   └─ ✗ 命中差 → 进入 Layer 2
    │
    ├─ Layer 2: 编程同义词扩展
    │   ┌──────────────┬──────────────────────┐
    │   │ 搜索词         │ 扩展匹配              │
    │   ├──────────────┼──────────────────────┤
    │   │ http/请求/网络 │ fetch, request, api   │
    │   │ 日期/时间     │ date, time, calendar   │
    │   │ 格式/解析     │ format, parse, stringify│
    │   │ 排序/过滤     │ sort, filter, order    │
    │   │ 缓存/存储     │ cache, store, persist  │
    │   │ 认证/登录     │ auth, login, token     │
    │   │ 错误/异常     │ error, exception, fault│
    │   └──────────────┴──────────────────────┘
    │   ← 内置映射表，轻量无依赖
    │   ├─ ✓ 命中 → 返回
    │   └─ ✗ 仍无结果 → 进入 Layer 3
    │
    └─ Layer 3: 语义向量搜索（依赖 MCP）
         Agent query → fastembed 向量 → Qdrant 相似度搜索
         无论怎么描述都能匹配意图相近的符号
         MCP 不可用时 skip，静默回退 Layer 1
```

### SQLite 数据结构

```sql
-- .utility/deps.sqlite

-- 目录模块树
CREATE TABLE directories (
    path TEXT PRIMARY KEY,
    module_name TEXT,
    parent_path TEXT,
    file_count INTEGER,
    has_package_manifest INTEGER
);

-- 文件索引
CREATE TABLE files (
    path TEXT PRIMARY KEY,
    dir_path TEXT,
    name TEXT,
    ext TEXT,
    sym_count INTEGER
);

-- 导出符号（类/函数/类型/常量）
CREATE TABLE symbols (
    id INTEGER PRIMARY KEY,
    file_path TEXT,
    name TEXT,
    kind TEXT,           -- class/struct/enum/func/const/type
    signature TEXT,      -- func format(_ date: Date) -> String
    doc_comment TEXT,
    visibility TEXT      -- public/internal/private
);

-- 三方包
CREATE TABLE packages (
    name TEXT PRIMARY KEY,
    version TEXT,
    type TEXT,           -- spm/npm/pip/gradle
    description TEXT,
    source_url TEXT
);

-- FTS5 全文搜索
CREATE VIRTUAL TABLE symbols_fts USING fts5(name, signature, doc_comment, content=symbols);
```

### 符号提取（按语言适配）

不追求完美 AST，够用即可：

| 语言 | 匹配模式 |
|------|---------|
| Swift | public/internal struct/class/enum/func/var |
| JS/TS | export (function\|class\|const\|interface\|type) |
| Python | def / class 定义 |

### 实现优先级

| 适配器 | 优先级 | 理由 |
|--------|--------|------|
| Swift | 🥇 | Utility 自身项目，先自举 |
| JS/TS | 🥇 | 前端项目，Agent 高频使用 |
| Python | 🥈 | MCP 服务本身是 Python 项目 |
| Java/Kotlin | 🥉 | 按需添加 |

### 扫描策略

```
全量扫描（首次或配置变更）
  ├─ 遍历目录树 → directories + files
  ├─ 检测特征文件 → 确定项目类型
  ├─ 解析 manifest → packages
  └─ 按类型提取导出符号 → symbols + FTS

增量更新（文件监听，后台线程，3s debounce）
  └─ 文件变更 → 取前 8KB + 文件大小计算哈希 → 哈希不变跳过 → 重解析 → diff 符号集

### 符号提取策略

优先语言原生 AST 脚本（精确），回退改进版 Regex（兜底）：

```
├─ 精确路径（语言原生 AST 辅助脚本，打包在 Resources/mcp/ 下）
│   ├─ extract_python.py   ← import ast
│   ├─ extract_jsts.mjs    ← @babel/parser
│   └─ Swift 先用改进版 regex 打底，后续按需升级
│
└─ 默认路径（改进版 Regex + brace-depth tracking）
    ├─ 简单 case → 快速命中 ~90%
    └─ 复杂 case → 返回空（不伪造结果），写入 failed_files
```

解析失败记录表管理：文件初次失败跳过；同一文件连续 3 次失败后暂停重试；用户修改后文件监听触发新事件 → 自动重试。

### MCP 连接项目 DB

MCP Tool 通过 `dbPath` 参数直接连接项目数据库，不存全局状态，不污染文件系统：

```json
{
  "query": "date format",
  "dbPath": "<project>/.utility/deps.sqlite"
}
```

Agent 侧通过环境变量 `$UTILITY_PROJECT_DB` 读取路径，每次请求携带。

| 优点 | 说明 |
|------|------|
| 零全局污染 | 不写 session 文件，不存状态 |
| 完美多实例 | 每个 `-a` 进程传自己的路径，互不干扰 |
| 实现简单 | MCP 端只做只读 SQLite 查询，无状态管理 |

Agent 不依赖环境变量传递路径，tools 描述直接说明 `dbPath` 是 `.utility/deps.sqlite` 相对于当前工作目录的路径，Agent 可自行拼接。

---

## 实施路线图

### 依赖关系

```
P0 项目准备
  │
  ├──→ P1 扫描引擎 (P0→P1→P3→P4)
  │        │
  │        ├──→ P2 MCP daemon (P0→P2→P3→P4)
  │        │         │
  │        └─────→ P3 CLI -a ──→ P4 GUI 集成
  │                    │
  │                    └──→ P5 多语言支持 (依赖 P1 框架，可并行)
  │
  └──→ P5 多语言支持
```

### P0 — 项目准备（1 天）

```
Sources/
├── CLI/                      ← 新增：CLI 参数解析
│   └── UtilityCLI.swift
├── MCP/                      ← 新增：MCP 管理模块（空壳）
│   ├── MCPProcessManager.swift
│   ├── MCPClient.swift
│   └── MCPMenuManager.swift
├── Scanner/                  ← 新增：项目扫描引擎（空壳）
│   ├── ProjectScanner.swift
│   └── extractors/
├── Resources/
│   └── mcp/                  ← 拷贝：Python 源码
└── ... 现有文件
```

产出：`swift build` 通过，.app bundle 内含 `mcp/` 目录。

### P1 — 项目扫描引擎（2-3 天）

- 定义 SQLite 表结构（directories / files / symbols / packages / symbols_fts / failed_files）
- 目录递归扫描 → 写入 directories + files
- Swift 符号提取（改进版 Regex + brace-depth tracking）
- Manifest 解析（Package.swift / package.json / pyproject.toml 等）
- `.utility/config.json` 读取 + includes/excludes 过滤
- 输出：`utility --init` 扫描 CWD 生成 `.utility/deps.sqlite`

```
╰─$ cd my-project && utility --init
  Scanning:  ████████████████ 100%
  Found:     86 files, 312 symbols, 23 packages
  Written:   .utility/deps.sqlite (384 KB)
```

### P2 — MCP daemon + project Tools（2-3 天）

- MCPProcessManager：venv 创建检查 → Python 子进程启停 → 崩溃恢复（连续 3 次停止）
- 首次启动流程：初始化状态感知（initializing / downloading_model / running / crashed）
- 修改 server.py 注册 project 系列 Tool（dbPath 参数驱动）
- 实现三层搜索：FTS5 → 同义词表 → 语义向量（已有）
- 输出：MCP 服务运行，Agent 可查询项目

### P3 — CLI -a 模式（2 天）

- 解析 `-a` / `--dir` 参数
- 启动流程：检查 `.utility/deps.sqlite` → 不存在则 init → 启动文件侦听 → spawn Agent
- 文件侦听：FSEvents 3s debounce，前 8KB + 大小哈希去重，增量更新 symbols
- 解析失败处理：写入 failed_files，连续 3 次失败暂停重试，修改后自动恢复
- 生命周期：Agent 退出 → 停侦听 → utility 退出
- 多实例：互不干扰
- 输出：`utility -a claude` 可用，Agent 能感知项目全局

### P4 — GUI 菜单集成（1 天）

- MCPMenuManager：菜单栏状态显示 ●/○/✕ + 启停操作
- 状态同步到 EventBus -> AppDelegate 刷新菜单
- 输出：菜单栏可见 MCP 服务状态

### P5 — 多语言符号提取（2-3 天，可随时插入）

- JS/TS：`extract_jsts.mjs`（@babel/parser），含 Vue SFC 的 `<script>` 块
- Python：`extract_python.py`（import ast）
- Manifest 多语言包信息提取
- 按项目类型自动选择适配器
- 输出：Agent 在 Vue/React/Python 等项目中也具备感知能力

```