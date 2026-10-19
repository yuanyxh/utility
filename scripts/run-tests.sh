#!/bin/bash
# Unified local verification: unit tests + cross-language contracts.
# Vector-cache checks need numpy, so the app's MCP venv is preferred over system python3.
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON="${PYTHON:-$HOME/.config/utility/mcp-venv/bin/python3}"
if [ ! -x "$PYTHON" ]; then
    PYTHON="$(command -v python3)"
    echo "警告: 未找到 MCP venv,使用 $PYTHON（向量缓存检查可能因缺 numpy 失败）"
fi

echo "=== 1/5 Unit tests ==="
"$PYTHON" -m unittest discover -s tests/python -v

echo ""
echo "=== 2/5 i18n catalog ==="
"$PYTHON" scripts/gen-l10n.py --check

echo ""
echo "=== 3/5 i18n contract ==="
"$PYTHON" scripts/check-l10n-contract.py

echo ""
echo "=== 4/5 Cross-language contract ==="
"$PYTHON" scripts/check-router-config-contract.py

echo ""
echo "=== 5/5 Runtime invariants ==="
"$PYTHON" scripts/check-search-cache-invariants.py
"$PYTHON" scripts/check-web-search.py

echo ""
echo "=== All checks passed ==="
