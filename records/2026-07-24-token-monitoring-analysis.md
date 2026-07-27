# Token 用量监控分析

日期：2026-07-24

---

## 问题

每天使用 Agent（Claude Code），token 用量是黑洞：
- 无法感知消耗了多少
- 不能通过感知进行限制或优化
- 不知道为什么花了这些钱

---

## 现状排查

### Claude Code 本地数据

| 数据源 | 是否有 token 用量 | 说明 |
|--------|-----------------|------|
| `~/.claude/sessions/*.json` | ❌ 无 | 只有 sessionId、cwd、startedAt，无 usage |
| `~/.claude/projects/**/*.jsonl` | ❌ 无 | 会话转录，522MB / 1335 个文件，不含 token 计数 |
| `~/.claude/history.jsonl` | ❌ 无 | 只有命令历史（/status、sessionId） |
| Claude Code `/cost` 命令 | ⚠️ 仅当前会话 | 退出即失，不持久化 |

### API 代理层

- 当前使用第三方代理：`api.xiaomimimo.com`
- 不走 Anthropic 官方计费，官方仪表盘不可用
- 模型：`mimo-v2.5-pro`

**结论：Claude Code 本身不持久化 token 用量数据，第三方代理层也无可见的用量追踪。**

---

## 方案对比

### 方案一：查 API 代理仪表盘

检查 `api.xiaomimimo.com` 是否提供用量 dashboard 或调用日志。

- 难度：最低
- 局限：依赖代理方是否提供

### 方案二：自建 token 记录代理（推荐）

本地起轻量 HTTP 代理，转发到 `api.xiaomimimo.com`，同时记录每次请求的 `usage` 字段。

```
Claude Code → localhost:8080 (本地代理) → api.xiaomimimo.com
                     ↓
              记录 input_tokens / output_tokens / model
              写入 SQLite
```

改 `ANTHROPIC_BASE_URL` 指向本地代理即可，不侵入 Claude Code。

**数据结构：**

```sql
CREATE TABLE api_usage (
    id INTEGER PRIMARY KEY,
    timestamp TEXT,
    session_id TEXT,
    model TEXT,
    input_tokens INTEGER,
    output_tokens INTEGER,
    cache_read_tokens INTEGER,
    cache_write_tokens INTEGER,
    estimated_cost_usd REAL,
    project_path TEXT
);
```

**能回答的问题：**
- 今天花了多少？→ `SUM(estimated_cost_usd) WHERE date = 'today'`
- 哪个项目最烧钱？→ `GROUP BY project_path`
- cache 命中率？→ `cache_read / input_tokens`
- Orchestrate 模式消耗？→ 按 session 聚合

- 难度：中等
- 优势：数据在自己手里，可按项目/天/模型分析，可加预算告警

### 方案三：解析现有转录文件（事后估算）

现有 1335 个 JSONL 转录文件（522MB），通过统计消息长度估算 token 消耗。

- 难度：中等
- 局限：估算不精确，无 cache 命中数据

### 方案四：/cost 命令

当前会话中 `/cost` 可看本次用量。

- 难度：最低
- 局限：退出即失，不适合长期追踪

---

## 决策

**选定方案二：自建 token 记录代理**

理由：
1. 一次投入，持续收益 —— 所有 API 调用自动记录
2. 数据在自己手里 —— 可按项目/天/模型分析
3. 不侵入 Claude Code —— 只改一个环境变量
4. 可加预算告警 —— 每日/每月 token 上限提醒

待后续实施。
