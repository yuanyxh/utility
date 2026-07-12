---
date: 2026-07-12
tags: [utility, mcp, merge, milestone]
---

## MCP 记忆服务合并完成

Utility & MCP 合并计划（transplant-mcp-service.md）全部阶段已完成：

### P0-P5 阶段
- **P0** 项目准备：目录结构、空壳文件
- **P1** 扫描引擎：SQLite 结构、SwiftExtractor、ManifestParser、ScannerConfig
- **P2** MCP daemon：server.py/summarize.py 移植、MCPProcessManager 进程管理、config 驱动生命周期、TaskScheduler 内部任务注册
- **P3** CLI -a 模式：AgentRunner、FileWatcher（FSEvents+3s防抖）、--agent/--dir 参数
- **P4** GUI 菜单集成：MCP 子菜单、状态指示器（●/◐/○/✕）
- **P5** 多语言符号提取：JSTSExtractor、PythonExtractor

### 关键架构事实
- server.py 通过 MCPProcessManager 子进程启动，所有配置从环境变量读取（buildEnv()）
- summarize.py 作为 TaskScheduler 内部任务注册，5 个环境变量内联传入
- MCP 配置热重载完整实现（onConfigReloaded 处理所有状态转换）
- M2 Pro GPU 对 fastembed 无实际收益（30-50ms CPU 推理已足够）
- EventBus string key "mcp_state_changed" 用于菜单状态更新
- SceneKit Tool 嵌入因 Apple Silicon 缺少 GPU 支持和编译问题暂未实现
