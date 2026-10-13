# Skill 规范（本项目）

## 文件形态

- **扁平**：`Skills/autonomous/<name>.md` —— 无附属资源
- **目录**：`Skills/<skill-dir>/SKILL.md` + `references/`、`scripts/`、`agents/` —— 有附属资源

## frontmatter

```yaml
---
name: snake_case_名字
description: 当用户说：<中文触发词，逗号分隔>…时触发。<一句话说明做什么>
---
```

- `name`：小写字母开头，仅 `[a-z0-9_]`；**注册名以它为准**，与目录名无关
- `description`：决定模型何时调用，必须写清"用户说什么话触发"

## 附属资源获取协议（引用了附属资源时必须加）

> **强制资源获取协议**：加载 `references/`、`scripts/`、`agents/` 下的资源时：
> 1. 调 `tool_resource`，传 `parentName: <本 skill 的 name>`、`path: <子目录>/<文件名>`；
> 2. 以其返回内容为准，禁止凭记忆或猜测代替；
> 3. scripts 先取其内容，再在本地执行。`tool_resource` 是唯一获取通道。

## 注册行为（server `_scan_skills`）

- 目录含 `SKILL.md` → 只注册 SKILL.md 本身，跳过 `references/scripts/agents`
- 无 SKILL.md 的普通目录 → 其内所有 `.md` 各自注册为一个 skill（`autonomous/` 即此模式）
