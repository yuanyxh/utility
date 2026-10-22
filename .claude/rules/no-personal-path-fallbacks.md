# 禁止个人化路径回退

- 代码与默认配置不得硬编码个人目录（如 `~/Documents/selfdata/...`）。
- 用户数据路径必须来自显式配置；配置为空时，只能从已配置的根目录派生（如 `mcp.knowledgeBasePath` / `PythonScriptRunner.resolvedNotesDir()`）。
- 派生根缺失时必须显式失败、禁用功能或记录错误，不得静默回退到个人路径。
- 新增路径配置项：默认值留空，并在 `default-config.yaml` 注释中写明派生规则。
