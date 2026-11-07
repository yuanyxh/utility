#!/bin/bash
# Local verification for this repo (Swift host + Swift-side i18n).
# Python tests, vector-cache invariants and the web-search checks moved to the agent-gateway
# repo together with the package; run them from that repo's root.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== 1/6 Examples parity ==="
python3 scripts/check-examples-parity.py

echo ""
echo "=== 2/6 i18n catalog ==="
python3 scripts/gen-l10n.py --check

echo ""
echo "=== 3/6 i18n contract ==="
python3 scripts/check-l10n-contract.py

echo ""
echo "=== 4/6 入口契约 ==="
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

GRAPH_CONTRACT=""
if [ -f Sources/Gateway/graph.json ]; then
    GRAPH_CONTRACT="Sources/Gateway/graph.json"
elif [ -f "${GATEWAY_REPO:-$(cd .. && pwd)/agent-gateway}/contracts/graph.json" ]; then
    GRAPH_CONTRACT="${GATEWAY_REPO:-$(cd .. && pwd)/agent-gateway}/contracts/graph.json"
fi
if [ -n "$GRAPH_CONTRACT" ]; then
    python3 scripts/check-graph-contract.py --contract "$GRAPH_CONTRACT"
else
    echo "跳过图库契约（未找到 graph.json）"
fi

echo ""
echo "=== 5/6 workspace-check ==="
BIN=".build/debug/utility"
if [ ! -x "$BIN" ]; then
    swift build >/dev/null
fi
TMP="$(mktemp -d)"
trap 'mv "$TMP" "${HOME}/.Trash/" 2>/dev/null || true' EXIT
printf '# probe\n\nbody\n' > "$TMP/note.md"
DIRTY_OUT="$("$BIN" workspace-check --dirty "$TMP/note.md")"
echo "$DIRTY_OUT" | grep -qx "baseline: false"
echo "$DIRTY_OUT" | grep -qx "appended: true"
echo "$DIRTY_OUT" | grep -qx "restored: false"
echo "$DIRTY_OUT" | grep -qx "crlf-equal: false"
cat > "$TMP/workspaces.json" <<'JSON'
{
  "version" : 1,
  "layout" : { "sidebarWidth" : 220, "rightPaneWidth" : 580, "fileListWidth" : 200, "subTerminalHeight" : 260, "subListWidth" : 180 },
  "workspaces" : [
    { "id" : "ws-probe", "name" : "probe", "path" : "/tmp", "subSessionIDs" : [ ] }
  ]
}
JSON
UI_OUT="$("$BIN" workspace-check --ui "$TMP/workspaces.json")"
echo "$UI_OUT" | grep -qx "version: 2"
echo "$UI_OUT" | grep -q "ui: list=files expanded=0 caret=0 scroll=0"
echo "[workspace-check] ok"

echo ""
echo "=== 6/6 archive-check ==="
ARCHIVE_OUT="$("$BIN" archive-check --roundtrip)"
echo "$ARCHIVE_OUT" | grep -qx "roundtrip: ok"
echo "[archive-check] ok"
SETUP_OUT="$("$BIN" setup-check)"
echo "$SETUP_OUT" | grep -q "^python:"
echo "$SETUP_OUT" | grep -q "^gateway:"
echo "[setup-check] ok"

echo ""
echo "=== All checks passed ==="
