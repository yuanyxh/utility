---
name: skill_creator
description: 当用户说：创建 skill, 新建 skill, 拉取 skill, 装个 skill, 找个 skill, 适配 skill, skill-creator, create skill, fetch skill, install skill, 推荐 skill, 有什么 skill 时触发。查/拉/建/适配 Skill：先前置检查(查重、命名、来源)，再改造适配。
---

> **强制资源获取协议**：加载 `references/`、`scripts/`、`agents/` 下的资源时必须：
> 1. 调 `tool_resource`，传 `parentName: skill_creator`、`path: <子目录>/<文件名>`；
> 2. 以其返回内容为准，禁止凭记忆或猜测代替；
> 3. scripts 先取其内容，再在本地执行。`tool_resource` 是唯一获取通道。

# Skill Creator: 查 → 拉/建 → 适配 → 落地

## 目标

把外部或自创的 skill 变成**本项目可注册**的 skill，落地后作为 MCP 工具可被调用。

## 落地位置（唯一判据）

- **无附属资源** → `[notes]/MCP/Skills/autonomous/<name>.md`（单个 .md）
- **有附属资源** → `[notes]/MCP/Skills/<skill-dir>/SKILL.md`，附属放 `references/`、`scripts/`、`agents/`
- `[notes]` = config `mcp.knowledgeBasePath`
- 注册名取 SKILL.md frontmatter 的 `name`，**与目录名无关**

## 执行步骤

### 1. 前置检查

- 扫 `Skills/`（含 `autonomous/`）下已有 skill，列出各自 `name`
- 目标名已存在 → 报告冲突，问用户是覆盖还是改名，**不静默覆盖**

### 2. 来源决策

- 用户给了 GitHub / URL → 拉取：调 `scripts/fetch_skill.sh <url>`
- 无外部来源 → 新建：按 `references/skill-spec.md` 从零写

### 3. 改造适配本项目

- frontmatter 必含 `name`（snake_case）与 `description`（中文触发词，写清"用户说什么话触发"）
- 正文中文化；代码与命令保留原文
- 去掉外部专有依赖；路径改成本项目可用形式
- 若引用了附属资源 → 正文加「强制资源获取协议」块（模板见 `references/skill-spec.md`）

### 4. 落地

按「落地位置」写入

### 5. 校验

调 `scripts/validate_skill.py <path>`；报错则修到通过

### 6. 确认注册

skill 应出现在 MCP 工具列表；不在则重启 MCP 服务并查 `~/.cache/utility/server.log`
