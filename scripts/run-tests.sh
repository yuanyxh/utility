#!/bin/bash
# Local verification for this repo (Swift host + Swift-side i18n).
# Python tests, vector-cache invariants and the web-search checks moved to the agent-gateway
# repo together with the package; run them from that repo's root.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== 1/3 Examples parity ==="
python3 scripts/check-examples-parity.py

echo ""
echo "=== 2/3 i18n catalog ==="
python3 scripts/gen-l10n.py --check

echo ""
echo "=== 3/3 i18n contract ==="
GATEWAY_SRC="${GATEWAY_REPO:-$(cd .. && pwd)/agent-gateway}/src/agent_gateway"
if [ -d "$GATEWAY_SRC" ]; then
    python3 scripts/check-l10n-contract.py --python-root "$GATEWAY_SRC"
else
    echo "跳过 Python 侧断言（未找到 $GATEWAY_SRC）"
    python3 scripts/check-l10n-contract.py
fi

echo ""
echo "=== All checks passed ==="
