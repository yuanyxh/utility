# 项目记忆

## 长期事实

| 事实 | 来源 | 适用范围 | 日期 |
| --- | --- | --- | --- |
| 基座按 agent-vibe 1.4.0 对齐，`seed_version: 1.4.0` | `.agent/profile.yaml` | 项目 | 2026-11-03 |
| 配置唯一来源是 `Sources/Resources/default-config.yaml`，用户配置只做覆盖 | `Sources/Core/ConfigTypes.swift` | 配置 | 2026-11-03 |
| RSS 解析失败统一存 `RSSItem.unknownDate`，并记录 feed 与原始串 | `Sources/RSS/RSSParser.swift` | RSS | 2026-11-03 |
| 项目索引只有 `.utility/graph.sqlite`，`deps.sqlite` 链已移除 | `.claude/docs/architecture/project-graph.md` | 项目图 | 2026-11-02 |

## 用户偏好

| 偏好 | 来源 | 是否仍然有效 |
| --- | --- | --- |
| 提交、推送、删除前必须取得明确授权 | AGENTS.md / 全局守则 | 是 |
| 一律使用中文，时区以上海为准 | 全局守则 | 是 |

## 领域约束

| 约束 | 来源 | 影响 |
| --- | --- | --- |
| 不得硬编码个人目录 | `.claude/rules/no-personal-path-fallbacks.md` | 路径配置必须可派生或显式失败 |
| 检索排序禁止固化单机拟合阈值 | `.claude/rules/retrieval-no-fitted-thresholds.md` | 调参需评测脚本支撑 |

## 待验证

| 线索 | 需要的证据 |
| --- | --- |
| 1.1.41 工作区改动尚未提交 | 用户授权后按主题拆分提交 |
| RSS 历史未知日期条目已读状态 | 迁移与查询行为在真实库上的结果 |

## 规则

- 一条记录只写一个事实。
- 与当前事实冲突时以当前事实为准，并在原条目标注。
- 项目细节不得进入跨项目记忆或种子库。
