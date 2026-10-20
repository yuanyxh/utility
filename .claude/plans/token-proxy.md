# Token 代理监控系统

## 背景

Claude Code 的 token 消耗完全不可见：sessions/*.jsonl 无 usage 字段，/cost 仅当前会话有效，第三方代理 api.example.com 无仪表盘。需要自建本地 HTTP 代理拦截每次 API 请求的 usage 数据，同时记录丰富的请求上下文作为 prompt 优化数据源。

## 架构

```
Claude Code
    ↓ ANTHROPIC_BASE_URL=http://localhost:8080/v1
token_proxy.py (aiohttp, utility 主进程守护)
    ├── 转发请求 → api.example.com（或配置的 modelProxy.url）
    ├── 智能解析 usage 字段（首次用主模型识别路径并缓存，取不到时刷新）
    ├── 记录请求上下文（类型、输入预览、输出预览、有效性）
    ├── 写入 SQLite（队列串行化，不阻塞转发）
    ├── 结构化日志（请求/响应/解析/错误）
    └── 三个月自动清理
    ↓
~/.config/utility/token_usage.sqlite
```

## 实施步骤

### Phase 1: 配置层

**1.1 新增 ModelProxyConfig**

文件：`Sources/Core/ConfigTypes.swift`

```swift
public struct ModelProxyConfig: Codable {
    var enabled: Bool = false
    var url: String = ""       // 上游 API 地址，为空则用 ai.baseURL
    var port: Int = 8080       // 本地代理监听端口
}
```

在 `AppConfig` 中新增：
```swift
var modelProxy: ModelProxyConfig? = nil
```

**1.2 更新 default-config.yaml**

文件：`Sources/Resources/default-config.yaml`

新增 `modelProxy` 段落（默认禁用）。

**1.3 配置优先级**

```
modelProxy.url（上游地址）
    ↓ 为空时
ai.baseURL
    ↓ 为空时
环境变量 ANTHROPIC_BASE_URL
```

Claude Code 的 API Key 由 Claude Code 自身管理，代理只做透明转发（header 原样传递），不涉及 key 配置。

在 `TokenProxyManager` 中注入 `MODEL_PROXY_URL` 和 `MODEL_PROXY_PORT` 环境变量供 Python 使用。

### Phase 2: Python 代理服务

**2.1 新增 token_proxy.py**

文件：`Sources/MCPScripts/token_proxy.py`

核心组件：

- `UsageFieldResolver`：智能 usage 字段解析
  - 首次遇到未知格式 → 调用主模型识别字段路径 → 缓存到 SQLite
  - 后续请求用缓存路径取值
  - 如果缓存路径取到的值无效（None/0/非数字）→ 重新调用模型刷新缓存
  - 刷新后仍无效 → 标记为 `unknown`，本次不记录 token 数
- `TokenRecorder`：数据记录
  - 请求上下文提取（request_type, input_preview, output_preview）
  - 归一化为统一 TokenUsage 结构
  - 写入 SQLite（fire-and-forget，失败不影响转发）
- `ProxyServer`：aiohttp 反向代理
  - 监听 localhost:8080，路由前缀 `/v1`
  - 转发到目标 API
  - 流式响应处理（SSE chunk 提取最后一个 chunk 的 usage）
  - `/health` 健康检查端点
- `Logger`：结构化日志
  - 使用 Python `logging` 模块，JSON 格式输出到文件 `~/.cache/utility/token_proxy.log`
  - 日志级别：DEBUG（请求详情）、INFO（转发成功）、WARNING（解析失败）、ERROR（转发失败）
  - 包含：timestamp, method, path, status, latency_ms, model, tokens
  - 按大小轮转（10MB 保留 3 个），避免磁盘膨胀

**2.2 SQLite 数据表**

```sql
-- API 用量记录
CREATE TABLE api_usage (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    session_id TEXT,
    project_path TEXT,
    request_type TEXT,           -- 'conversation', 'tool_use', 'tool_result', 'agent_spawn'
    context_summary TEXT,        -- 输入前 100 字
    input_preview TEXT,          -- 用户消息前 200 字
    input_message_count INTEGER,
    has_tool_result INTEGER DEFAULT 0,
    output_preview TEXT,         -- 模型回复前 200 字
    output_type TEXT,            -- 'text', 'tool_use', 'mixed'
    stop_reason TEXT,
    response_valid INTEGER DEFAULT 1,
    model TEXT,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cache_read_tokens INTEGER DEFAULT 0,
    cache_write_tokens INTEGER DEFAULT 0,
    estimated_cost_usd REAL DEFAULT 0,
    latency_ms INTEGER DEFAULT 0,
    api_format TEXT              -- 'anthropic', 'openai', 'unknown'
);

-- usage 字段路径缓存
CREATE TABLE usage_field_cache (
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    input_path TEXT,
    output_path TEXT,
    cache_read_path TEXT,
    cache_write_path TEXT,
    updated_at TEXT,
    PRIMARY KEY (provider, model)
);
```

索引：`idx_api_usage_timestamp`, `idx_api_usage_session`, `idx_api_usage_project`。

**2.3 自动清理**

启动时执行：
```sql
DELETE FROM api_usage WHERE timestamp < datetime('now', '-3 months');
```

**2.4 日志格式**

输出到 `~/.cache/utility/token_proxy.log`，JSON Lines 格式：

```json
{"ts": "2026-07-27T10:00:00", "level": "INFO", "msg": "proxy_request", "method": "POST", "path": "/v1/messages", "status": 200, "latency_ms": 1234, "model": "<model>", "input_tokens": 5432, "output_tokens": 256}
{"ts": "2026-07-27T10:00:01", "level": "WARNING", "msg": "usage_parse_fallback", "model": "<model>", "reason": "cached_path_returned_none", "refreshed": true}
{"ts": "2026-07-27T10:00:02", "level": "ERROR", "msg": "proxy_error", "path": "/v1/messages", "status": 502, "error": "upstream_timeout"}
```

### Phase 3: Swift 进程管理

**3.1 新增 TokenProxyManager**

文件：`Sources/MCP/TokenProxyManager.swift`

参考 `MCPProcessManager` 模式，但更轻量：
- 单例 `TokenProxyManager.shared`
- 状态机：`stopped / running / crashed`
- `start()`：检查 `modelProxy.enabled`，启动 `python3 token_proxy.py` 子进程
- `stop()`：terminate 子进程
- 环境变量注入：`MODEL_PROXY_PORT`, `MODEL_PROXY_URL`, `UTILITY_DATA_DIR`
- 健康检查：轮询 `http://localhost:{port}/health`
- 崩溃恢复：terminationHandler 自动重启（最多 3 次）
- 就绪检测：轮询 `/health` 端点，不依赖 stderr

**3.2 AppDelegate 集成**

- `applicationDidFinishLaunching` 中，在 MCP 启动后调用 `TokenProxyManager.shared.start()`
- `applicationWillTerminate` 中，调用 `TokenProxyManager.shared.stop()`
- 配置重载时，`forceRestart()`

**3.3 环境变量注入**

Claude Code 启动时需要设置：
```
ANTHROPIC_BASE_URL=http://localhost:8080/v1
```

这需要用户手动设置，或通过 utility 的 shell wrapper 脚本自动注入。

### Phase 4: 数据查询与展示

**4.1 查询 API**

文件：`Sources/MCP/TokenProxyManager.swift` 扩展

```swift
// 今日消耗
func todayCost() -> Double
// 按项目分组
func costByProject() -> [(project: String, cost: Double)]
// cache 命中率
func cacheHitRate() -> Double
// 按请求类型分组
func costByRequestType() -> [(type: String, cost: Double)]
// 今日概览
func todaySummary() -> (input: Int, output: Int, cache: Int, cost: Double, requests: Int)
```

**4.2 菜单栏展示**

在 `MenuBarManager.buildMenu()` 中，MCP 子菜单**下方**新增独立的 Token 子菜单：

```
MCP        ▸  ● Running | Restart | ...
Token      ▸  今日: 12.3K in / 2.4K out / $0.85
             ├─ 按项目: utility $0.42, tms-front $0.31
             ├─ Cache 命中率: 68%
             ├─ 今日请求: 47 次
             └─ 无效请求: 2 次 (4%)
```

- 标题显示今日费用摘要（`Token $0.85`）
- 子菜单展开显示详情
- `menuWillOpen` 时刷新数据

### Phase 5: Prompt 优化数据源

**5.1 上下文提取逻辑**

从 Claude Code 的请求 body 中提取：
- `request_type`：根据请求结构判断（有 tools → tool_use，有 tool_result → tool_result，否则 → conversation）
- `context_summary`：最后一条 user message 前 100 字
- `input_preview`：所有 user messages 前 200 字拼接
- `output_preview`：assistant response 前 200 字
- `response_valid`：stop_reason == 'end_turn' ? 1 : 0

**5.2 无效请求识别**

- `stop_reason = 'max_tokens'`：输出被截断，prompt 可能过长
- `stop_reason = 'error'`：请求失败
- `output_tokens = 0`：空响应
- `latency_ms > 60000`：超时请求

这些数据可用于识别 prompt 优化机会。

## 文件变更清单

| 文件 | 变更 |
|------|------|
| `Sources/Core/ConfigTypes.swift` | 新增 `ModelProxyConfig`，`AppConfig` 新增 `modelProxy` 字段 |
| `Sources/Resources/default-config.yaml` | 新增 `modelProxy` 配置段 |
| `Sources/MCPScripts/token_proxy.py` | **新建**：Python 代理服务 |
| `Sources/MCP/TokenProxyManager.swift` | **新建**：Swift 进程管理 |
| `Sources/App/AppDelegate.swift` | 集成 TokenProxyManager 生命周期 |
| `Sources/Core/MenuBarManager.swift` | MCP 下方新增 Token 子菜单 |
| `Sources/MCPScripts/log_utils.py` | **新建**：共享 Python 日志模块 |
| `Sources/MCPScripts/server.py` | 替换 `_setup_logging()` 为 `log_utils` |
| `Sources/MCPScripts/summarize.py` | 替换 `_setup_logging()` 为 `log_utils` |
| `Sources/Core/Constants.swift` | 新增 `AppPaths.tokenUsageDB` |
| `CLAUDE.md` | 更新架构说明 |

### Phase 6: 共享 Python 日志模块

现状：server.py 和 summarize.py 各自实现几乎完全相同的 `_setup_logging()`，日志散落在不同路径。token_proxy.py 需要新增日志。将公共部分抽取到共享模块。

**6.1 新增 `Sources/MCPScripts/log_utils.py`**

```python
"""所有 Python 子进程共享的日志模块。
使用方式：
    from log_utils import setup_logging, write_error_log
    logger = setup_logging("server")       # → ~/.cache/utility/server.log
    logger = setup_logging("token_proxy", json_format=True)  # → JSON Lines
"""

import json
import logging
import logging.handlers
import os
from datetime import datetime, timezone

_CACHE_BASE = os.path.expanduser("~/.cache/utility")


def setup_logging(name: str, level=logging.INFO, json_format=False):
    os.makedirs(_CACHE_BASE, exist_ok=True)

    root = logging.getLogger(name)
    root.setLevel(level)
    if root.handlers:
        return root

    log_path = os.path.join(_CACHE_BASE, f"{name}.log")
    fh = logging.handlers.TimedRotatingFileHandler(
        filename=log_path,
        when="midnight",
        interval=1,
        backupCount=30,
        encoding="utf-8",
    )

    if json_format:
        fh.setFormatter(logging.Formatter("%(message)s"))
    else:
        fh.setFormatter(logging.Formatter(
            "%(asctime)s [%(levelname)s] %(message)s"
        ))

    root.addHandler(fh)

    # 静默第三方库，避免噪音
    for lib in ("httpx", "httpcore", "uvicorn.access", "uvicorn.error"):
        logging.getLogger(lib).setLevel(logging.WARNING)

    return root


def write_error_log(log_path: str, entry: dict):
    entry["timestamp"] = datetime.now(timezone.utc).isoformat()
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
```

关键设计约束：
- **禁止 StreamHandler**：MCPProcessManager / TaskExecutor 在启动检测完成后停止读 pipe，写 stderr 会导致 buffer 积满 → `write()` 阻塞 → 进程卡死
- `TimedRotatingFileHandler`：midnight 轮转，保留 30 天
- 日志路径统一为 `~/.cache/utility/[name].log`，由 `TokenProxyManager.buildEnv()` 中 `LOG_DIR` 不再需要

**6.2 替换 server.py**

```python
# 删除 _setup_logging() 整个函数和末尾的 _setup_logging() 调用
# 文件顶部新增：
from log_utils import setup_logging

# 文件中替换所有 logging 调用为 logger：
logger = setup_logging("server")
logger.info("Mem0 (hot layer) initialized")   # 原 logging.info(...)
logger.warning("Hot layer init failed: %s", e) # 原 logging.warning(...)
logger.error("Cold layer init failed: %s", e)  # 原 logging.error(...)
logger.critical("HOT LAYER FATAL: ...")         # 保留，唯一触发 sys.exit(1) 的路径
```

**6.3 替换 summarize.py**

```python
# 删除 _setup_logging() 整个函数
# 文件顶部新增：
from log_utils import setup_logging, write_error_log

# logging 调用替换为 logger（同 server.py）
logger = setup_logging("summarize")

# write_error_log 路径更新：
# 原: write_error_log(os.path.join(LOG_DIR, "流水线错误日志.jsonl"), ...)
# 改: write_error_log(os.path.join(_CACHE_BASE, "流水线错误日志.jsonl"), ...)
#      _CACHE_BASE = ~/.cache/utility（从 log_utils 导入）

# print() 保持不动 —— 这些是给用户看的终端输出，不是日志
```

**6.4 token_proxy.py 直接使用共享模块**

```python
from log_utils import setup_logging, write_error_log

logger = setup_logging("token_proxy", json_format=True)
logger.info(json.dumps({"msg": "proxy_request", "path": "/v1/messages", "status": 200}))
```

**6.5 不改动的文件**

- `ast_extractor.py`：`print()` 是 IPC 协议（JSON stdin/stdout），不是日志，不动
- `synonyms.py`：无输出，不动

**6.6 旧日志文件清理**

迁移完成后，旧位置的日志文件可手动删除：
```
rm ~/.config/utility/notes/logs/server.log*
rm ~/.config/utility/notes/logs/summarize.log*
```

## 验证方式

1. 启动 utility，确认 `modelProxy.enabled = true` 时 token_proxy.py 子进程启动
2. 设置 `ANTHROPIC_BASE_URL=http://localhost:8080/v1`，使用 Claude Code 发送请求
3. 检查 `~/.config/utility/token_usage.sqlite` 中 `api_usage` 表有新记录
4. 验证 usage 字段正确解析（input_tokens > 0）
5. 验证菜单栏 MCP 下方显示 Token 子菜单及今日消耗数据
6. 杀掉 token_proxy.py 进程，确认自动重启
7. 检查 `~/.cache/utility/token_proxy.log` 日志输出格式正确
8. 等待 3 个月后验证过期数据自动清理
9. 启动 MCP（server.py），确认 `~/.cache/utility/server.log` 有日志输出
10. 运行 summarize.py，确认 `~/.cache/utility/summarize.log` 有日志输出
11. 确认旧日志路径 `~/.config/utility/notes/logs/` 不再有新写入
12. 确认无进程因 pipe buffer 死锁卡死（无 StreamHandler）
