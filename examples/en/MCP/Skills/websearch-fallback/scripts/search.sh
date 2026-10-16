#!/bin/bash
# search.sh — unified search engine entry point
# Usage: search.sh [--engine=<bing|sogou|so360|duckduckgo|brave|all>] <keywords...>
# Output: structured search results to stdout
#
# Default cascade order: Bing → Sogou → 360 → DuckDuckGo → Brave
# --engine=<name> uses only that engine; --engine=all merges all of them
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Order = priority. As of 2026-10 no engine is structurally reliable: Bing degrades
# Chinese long queries into single-character dictionary pages, DuckDuckGo returns a 202
# challenge page, Brave flaps (the few also rate-limit in turns). Sogou / 360 are the
# steadiest for Chinese and barely overlap with the rest.
#
# Google has been removed: it runs a JS challenge for unauthenticated requests — the first
# response is always a /httpservice/retry/enablejs interstitial (92KB, no result data) and
# only a JS-capable client (a browser) reaches the result page. curl cannot execute JS, so
# it is structurally out of reach.
#
# Every engine's output passes through filter_results.py, which drops results unrelated to
# the query. Bing answers multi-word queries with single-character dictionary pages, and
# without the filter the cascade would take those for "enough results" and stop.
ENGINES=("bing" "sogou" "so360" "duckduckgo" "brave")
ENGINE_MODE="cascade"  # cascade = try one after another until success, all = use all

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --engine=*)
      ENGINE_MODE="single"
      ENGINE="${1#*=}"
      shift
      ;;
    --all)
      ENGINE_MODE="all"
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -eq 0 ]; then
  echo "Usage: search.sh [--engine=<bing|sogou|so360|duckduckgo|brave|all>] <keywords...>" >&2
  exit 1
fi

QUERY="$*"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Fetch + parse one engine; prints structured results, empty on failure.
run_engine() {
  local engine="$1"
  local html="$TMPDIR/result.html"
  case $engine in
    bing)
      bash "$SCRIPT_DIR/bing_search.sh" "$QUERY" > "$html" 2>/dev/null || return 0
      python3 "$SCRIPT_DIR/parse_bing.py" "$html" 2>/dev/null || true
      ;;
    sogou)
      bash "$SCRIPT_DIR/sogou_search.sh" "$QUERY" > "$html" 2>/dev/null || return 0
      # Sogou hrefs are /link?url= jump links that issue no HTTP redirect — --resolve
      # fetches each one and reads the window.location.replace target out of it.
      python3 "$SCRIPT_DIR/parse_sogou.py" --resolve "$html" 2>/dev/null || true
      ;;
    so360)
      bash "$SCRIPT_DIR/so360_search.sh" "$QUERY" > "$html" 2>/dev/null || return 0
      python3 "$SCRIPT_DIR/parse_so360.py" "$html" 2>/dev/null || true
      ;;
    duckduckgo)
      bash "$SCRIPT_DIR/duckduckgo_search.sh" "$QUERY" > "$html" 2>/dev/null || return 0
      python3 "$SCRIPT_DIR/parse_duckduckgo.py" "$html" 2>/dev/null || true
      ;;
    brave)
      bash "$SCRIPT_DIR/brave_search.sh" "$QUERY" > "$html" 2>/dev/null || return 0
      python3 "$SCRIPT_DIR/parse_brave.py" "$html" 2>/dev/null || true
      ;;
    *)
      echo "Error: unknown engine '$engine'. Available: bing, sogou, so360, duckduckgo, brave" >&2
      return 1
      ;;
  esac
}

# Each engine numbers its results from [1], so concatenated output needs renumbering
renumber() {
  awk '/^\[[0-9]+\] /{n++; sub(/^\[[0-9]+\]/, "[" n "]")} {print}'
}

# Single-engine mode
if [ "$ENGINE_MODE" = "single" ]; then
  run_engine "$ENGINE" | python3 "$SCRIPT_DIR/filter_results.py" "$QUERY" || exit 1
  exit 0
fi

# All-engines mode
if [ "$ENGINE_MODE" = "all" ]; then
  ALL_RESULTS=""
  for engine in "${ENGINES[@]}"; do
    echo "--- $engine ---" >&2
    RESULT=$(run_engine "$engine" | python3 "$SCRIPT_DIR/filter_results.py" "$QUERY" || true)
    if [ -n "$RESULT" ]; then
      ALL_RESULTS="${ALL_RESULTS}${RESULT}"$'\n\n'
    fi
  done
  echo "$ALL_RESULTS" | renumber
  exit 0
fi

# Cascade mode (default): try one after another until there are results
ACCUM=""
TOTAL_RESULTS=0
for engine in "${ENGINES[@]}"; do
  echo "--- trying $engine ---" >&2
  RESULT=$(run_engine "$engine" | python3 "$SCRIPT_DIR/filter_results.py" "$QUERY" || true)
  if [ -n "$RESULT" ]; then
    RESULT_COUNT=$(echo "$RESULT" | grep -c "^\[" || true)
    TOTAL_RESULTS=$((TOTAL_RESULTS + RESULT_COUNT))
    ACCUM="${ACCUM}${RESULT}"$'\n'

    # If there are enough results (>=5), stop trying more engines
    if [ $RESULT_COUNT -ge 5 ]; then
      echo "--- $engine returned $RESULT_COUNT results, enough to use ---" >&2
      break
    fi
  fi
done

if [ $TOTAL_RESULTS -eq 0 ]; then
  echo "Error: all search engines returned no results" >&2
  exit 1
fi

echo "$ACCUM" | renumber
