#!/bin/bash
# End-to-end check for agent mode and the gateway-owned project graph.
# Runs the real binary under a throwaway HOME, so the user's config, cache and
# running app are untouched. Verifies initial sync, watcher increment and queries.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_ROOT="$PWD"
REAL_HOME="$HOME"
GATEWAY_REPO="${GATEWAY_REPO:-$(cd .. && pwd)/agent-gateway}"
PYTHON="${PYTHON:-$GATEWAY_REPO/.venv/bin/python}"
SESSION_SECONDS="${SESSION_SECONDS:-25}"
KEEP_TEMP="${KEEP_TEMP:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"

[ -d "$GATEWAY_REPO/src/agent_gateway" ] || {
    echo "gateway source not found: $GATEWAY_REPO/src/agent_gateway (set GATEWAY_REPO)"
    exit 2
}
[ -x "$PYTHON" ] || {
    echo "python not found: $PYTHON (set PYTHON)"
    exit 2
}
[ -x "$GATEWAY_REPO/.venv/bin/python" ] || {
    echo "gateway venv not found: $GATEWAY_REPO/.venv/bin/python"
    exit 2
}

if [ "$SKIP_BUILD" != "1" ]; then
    swift build >/dev/null
fi
BIN_DIR="$(swift build --show-bin-path)"
BIN="$BIN_DIR/utility"
[ -x "$BIN" ] || {
    echo "utility binary not found: $BIN"
    exit 2
}

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
WORK="$(mktemp -d "$TMP_BASE/utility-e2e.XXXXXX")"
HOME_DIR="$WORK/home"
PROJECT="$WORK/project"
DB="$PROJECT/.agent-gateway/graph.sqlite"
LOG="$WORK/agent.log"
RUNNER=""

cleanup_on_error() {
    local rc=$?
    trap - ERR
    echo "E2E failed (exit $rc); artifacts kept at $WORK"
    if [ -n "$RUNNER" ] && kill -0 "$RUNNER" 2>/dev/null; then
        kill "$RUNNER" 2>/dev/null || true
        wait "$RUNNER" 2>/dev/null || true
    fi
    tail -40 "$LOG" 2>/dev/null || true
    exit "$rc"
}
trap cleanup_on_error ERR

db_scalar() {
    "$PYTHON" - "$DB" "$1" <<'PY'
import sqlite3, sys
db, sql = sys.argv[1], sys.argv[2]
with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as conn:
    print(conn.execute(sql).fetchone()[0])
PY
}

wait_for_count() {
    local desc=$1 expected=$2 sql=$3 value=-1 i
    for i in $(seq 1 60); do
        value=$(db_scalar "$sql" 2>/dev/null || echo -1)
        [ "$value" = "$expected" ] && return 0
        sleep 0.5
    done
    echo "timeout waiting for $desc: expected $expected, got $value"
    return 1
}

echo "=== 1/4 Isolated setup ==="
mkdir -p "$HOME_DIR/.config/utility" "$PROJECT"
ln -s "$GATEWAY_REPO/.venv" "$HOME_DIR/.config/utility/mcp-venv"
cat > "$PROJECT/alpha.swift" <<'SWIFT'
func beta() -> Int {
    return 42
}

func alpha() -> Int {
    return beta()
}
SWIFT
cat > "$PROJECT/alpha.py" <<'PY'
def helper():
    return 1


def entry():
    return helper()
PY
echo "workspace: $WORK"

echo "=== 2/4 Initial sync ==="
HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" \
    "$BIN" -a "sleep $SESSION_SECONDS" --dir "$PROJECT" > "$LOG" 2>&1 &
RUNNER=$!

wait_for_count "graph database" 1 "select count(*) from sqlite_master where type='table' and name='files'"
wait_for_count "files" 2 "select count(*) from files"
wait_for_count "symbols" 4 "select count(*) from symbols"
wait_for_count "edges" 2 "select count(*) from edges"
wait_for_count "unresolved" 0 "select count(*) from unresolved"
[ -f "$HOME_DIR/.config/utility/agent-gateway.yaml" ] || { echo "isolated config missing"; false; }
[ -f "$HOME_DIR/.config/utility/data.sqlite" ] || { echo "isolated app database missing"; false; }
[ ! -e "$PROJECT/.utility" ] || { echo "legacy .utility directory created"; false; }
echo "initial graph: 4 symbols / 2 edges"

echo "=== 3/4 Watcher increment ==="
cat >> "$PROJECT/alpha.swift" <<'SWIFT'

func gamma() -> Int {
    return beta()
}

func delta() -> Int {
    return gamma()
}
SWIFT
wait_for_count "gamma symbol" 1 "select count(*) from symbols where name='gamma'"
wait_for_count "delta symbol" 1 "select count(*) from symbols where name='delta'"
wait_for_count "symbols after increment" 6 "select count(*) from symbols"
echo "incremental graph: 6 symbols"

echo "=== 4/4 Queries ==="
GATEWAY_HOME="$HOME_DIR/.config/utility" PYTHONPATH="$GATEWAY_REPO/src" \
    "$PYTHON" - "$PROJECT" <<'PY'
import sys

from agent_gateway.services.mcp.graph_tools import tool_project_impact, tool_project_lookup

project = sys.argv[1]
lookup = tool_project_lookup(project, "delta")
assert lookup["status"] == "ok", lookup
assert [r["name"] for r in lookup["results"]] == ["delta"], lookup

impact = tool_project_impact(project, "beta", direction="callers", depth=1)
assert impact["status"] == "ok", impact
callers = {item["symbol"] for group in impact["groups"] for item in group["items"]}
assert callers == {"alpha", "gamma"}, impact
assert impact["stale"] == 0, impact
print("lookup/impact: ok")
PY

set +e
wait "$RUNNER"
RC=$?
set -e
RUNNER=""
[ "$RC" -eq 0 ] || { echo "agent mode exited with $RC"; false; }
grep -q "Agent exited (exit code: 0)" "$LOG" || { echo "missing agent exit banner"; false; }

echo ""
echo "=== E2E passed ==="
if [ "$KEEP_TEMP" = "1" ]; then
    echo "artifacts kept at $WORK"
else
    TRASH="$REAL_HOME/.Trash/utility-e2e-$(date +%Y%m%d%H%M%S)-$$"
    mkdir -p "$REAL_HOME/.Trash"
    mv "$WORK" "$TRASH"
    echo "artifacts moved to $TRASH"
fi
