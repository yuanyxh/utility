# 审查遗留项修复任务清单

- [x] T1 knowledge_expand 动态分配 max_tokens（依赖：无，规模：S）
- [x] T2 固化「未传维度不参与过滤」语义（依赖：无，规模：XS）
- [x] T3 下载 reranker 并接入 recall（依赖：无，规模：S）
- [x] T4 归档导入失败回滚核心与外部文件（依赖：无，规模：M）
- [x] T5 supersede 与代码冲突的记忆（依赖：无，规模：XS）
- [x] T6 发布脚本从 VERSION 生成提交信息（依赖：无，规模：XS）
- [x] T7 runSync 超时标记 outputIncomplete（依赖：T4，规模：XS）
- [x] T8 评测脚本统一隔离 GATEWAY_CACHE（依赖：无，规模：S）
- [x] T9 核实两个 sqlite 的保留策略（依赖：无，规模：XS）
- [x] T10 更新 assumptions.md（依赖：无，规模：XS）

## 检查点 A（T1-T3）

- [ ] gateway 测试通过
- [ ] recall trace `reranked=true`
- [ ] 知识补货无 length 截断

## 检查点 B（T4-T7）

- [ ] `swift build` 通过
- [ ] `swift test` 通过
- [ ] 归档回滚手工验证

## 检查点 C（T8-T10）

- [ ] 评测日志不再写生产目录
- [ ] assumptions.md 自检通过
- [ ] 两仓工作区仅本次改动
