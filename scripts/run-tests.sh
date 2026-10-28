#!/bin/bash
# Local verification for this repo (Swift host + Swift-side i18n).
# Python tests, vector-cache invariants and the web-search checks moved to the agent-gateway
# repo together with the package; run them from that repo's root.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== 1/4 Examples parity ==="
python3 scripts/check-examples-parity.py

echo ""
echo "=== 2/4 i18n catalog ==="
python3 scripts/gen-l10n.py --check

echo ""
echo "=== 3/4 i18n contract ==="
python3 scripts/check-l10n-contract.py

echo ""
echo "=== 4/4 入口契约 ==="
ENTRIES=""
if [ -f Sources/Gateway/entries.json ]; then
    ENTRIES="Sources/Gateway/entries.json"
elif [ -f "${GATEWAY_REPO:-$(cd .. && pwd)/agent-gateway}/contracts/entries.json" ]; then
    ENTRIES="${GATEWAY_REPO:-$(cd .. && pwd)/agent-gateway}/contracts/entries.json"
fi
if [ -n "$ENTRIES" ]; then
    python3 scripts/check-gateway-entries.py --entries "$ENTRIES"
else
    echo "跳过入口契约（未找到 entries.json）"
fi

echo ""
echo "=== All checks passed ==="
