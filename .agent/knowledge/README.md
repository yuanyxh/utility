# 知识索引

按任务主题加载，单次 1~3 篇，不整册注入。知识是参考，冲突时以项目规则为准。

| 主题 | 来源 | 触发 |
| --- | --- | --- |
| 测试策略 | agent-vibe `seeds/knowledge/testing.md` | 设计验证或补回归 |
| 可观测性 | agent-vibe `seeds/knowledge/observability.md` | 线上问题难定位 |
| 自动更新 | agent-vibe `seeds/knowledge/auto-update.md` | 设计分发与升级 |
| 配置化 | agent-vibe `seeds/knowledge/configuration.md` | 配置分散或频繁改代码 |
| 代码设计与模式 | agent-vibe `seeds/knowledge/design-patterns.md` | 抽象失控或复制增多 |
| 缺陷类型与调试手段 | agent-vibe `seeds/knowledge/debugging-playbook.md` | 卡顿、内存、卡死、慢查询、UI 显示与交互 |

## 项目内知识

| 文件 | 内容 |
| --- | --- |
| `.agent/domains/macos-desktop-app.md` | 窗口、焦点、权限、打包 |
| `.agent/domains/terminal-integration.md` | 终端能力、输入编码、通知 |
| `.claude/docs/architecture/*.md` | 模块级实现细节与历史踩坑 |
| `.agent/lessons.md` | 本项目的验证与重构教训 |

## 加载规则

先读本索引，再按触发读具体文件；引用时写明来源与版本。
