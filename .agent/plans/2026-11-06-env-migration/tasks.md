# 换机迁移与首启安装引导任务清单

- [x] T1 归档类型、范围与外部目录枚举（依赖：无，规模：M）
- [x] T2 导出引擎（依赖：T1，规模：M）
- [x] T3 导入校验与核心数据应用（依赖：T2，规模：M）
- [x] T4 外部目录恢复与配置路径改写（依赖：T3，规模：M）
- [x] T5 `archive-check` CLI 与 run-tests 接入（依赖：T4，规模：S）
- [x] T6 设置内导出面板（依赖：T2，规模：M）
- [x] T7 环境探测与 GatewayInstaller 改造（依赖：无，规模：M）
- [x] T8 依赖安装执行器与 Homebrew 拉起（依赖：T7，规模：M）
- [x] T9 首启向导骨架与导入步骤（依赖：T4、T6，规模：M）
- [x] T10 检测、安装与完成页（依赖：T8、T9，规模：M）
- [x] T11 文档、状态与打包验证（依赖：T10，规模：S）

## 检查点 A（T1–T5）

- [x] `swift build` 通过
- [x] `archive-check roundtrip` 输出 `roundtrip: ok`
- [x] `--remap notes=<tmp>` 后配置路径改写正确
- [x] `bash scripts/run-tests.sh` 全过
- [x] 导出包内无 venv、WAL、SHM

## 检查点 B（T6）

- [x] 设置可导出含笔记目录的数据包（代码路径，L1）
- [x] 选项按配置启停显示，笔记项显示体积（代码路径，L1）
- [x] 密钥默认剥离（L2，roundtrip 断言）
- [ ] 设置界面手动导出一次（待 L3）

## 检查点 C（T7–T10）

- [x] 隔离 HOME 首启出现向导（L3 截图，1/4 导入页）
- [x] 导入后记忆、知识库与笔记可读（L2 archive roundtrip）
- [ ] 外部路径缺失可改选，冲突可选跳过/覆盖（仅代码路径）
- [x] 依赖可检测（L2 `setup-check` 六项）
- [ ] 依赖可安装、可重试（未执行真实安装）
- [ ] Homebrew 缺失可打开 Terminal 安装（未触发）
- [x] 已有配置不出现向导（L3 隔离启动）

## 检查点 D（T11）

- [x] 文档与实现一致（README 双语文档、portability.md、CLAUDE 索引）
- [x] 打包产物自检通过（`Utility-1.1.90.dmg`，包内二进制 roundtrip/setup-check 通过）
- [ ] 用户 L3 手测通过
