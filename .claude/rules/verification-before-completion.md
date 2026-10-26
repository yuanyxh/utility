# 完成前验证

- 声称「完成 / 修好 / 通过」前必须实跑命令，没跑就直说没跑，禁止用「应该」「大概」。
- 按改动域选最小集（命令全文见 `AGENTS.md` → Verification）：
  Swift → `swift build`；l10n → `gen-l10n.py --check` + `check-l10n-contract.py`；
  examples → `check-examples-parity.py`；打包 → `package-utility.sh`。
  Python 侧（unittest / 向量缓存 / web-search）在 `agent-gateway` 仓内验证，本仓不再有 Python 源码。
- 失败必须贴退出码与原始输出尾部，禁止只给结论；修复后重跑同一组，不跳项。
- 未获明确要求，不提交、不推送、不部署；部署后验证需覆盖包内资源与运行中进程。
