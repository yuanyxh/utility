#!/usr/bin/env bash
# 自动探测并运行项目验证（lint + typecheck + 测试）。
# 从项目根运行。失败时以非零退出。
set -euo pipefail

if [ -f Cargo.toml ]; then
  cargo check && cargo test
elif [ -f tsconfig.json ]; then
  npx tsc --noEmit && npm test
elif [ -f package.json ] && grep -q '"test"' package.json; then
  npm test
elif [ -f Makefile ] && grep -q '^test:' Makefile; then
  make test
elif [ -f pytest.ini ] || [ -f pyproject.toml ] || find . -maxdepth 2 -name "test_*.py" | grep -q .; then
  pytest
else
  echo "(未检测到测试命令 - 请向用户询问验证命令)"
  exit 1
fi
