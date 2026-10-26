# Gateway 资源目录（生成物）

打包脚本 `scripts/package-utility.sh` 与 `make gateway` 把 `agent-gateway` 的
wheel、prompts 拷到这里，再由 `Package.swift` 的 `.copy("Gateway")` 带进 app。

- 目录内容不入库：`*.whl`、`prompts/` 已加入 `.gitignore`
- 开发期不填充也可：`GatewayResources` 会回退到同级 `../agent-gateway/src/agent_gateway`
- 运行时路径唯一入口：`Sources/Core/GatewayResources.swift`
