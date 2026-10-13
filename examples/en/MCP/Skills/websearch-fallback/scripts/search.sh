#!/bin/bash
# search.sh — unified search engine entry point
# Usage: search.sh [--engine=<bing|google|duckduckgo|brave|all>] <keywords...>
# Output: structured search results to stdout
#
# Default attempt order: Bing → Google → DuckDuckGo → Brave
# If --engine is specified, only that engine is used
# If --engine=all is specified, all engines are used and their results merged
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default engine order
ENGINES=("bing" "google" "duckduckgo" "brave")
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
  echo "Usage: search.sh [--engine=<bing|google|duckduckgo|brave|all>] <keywords...>" >&2
  exit 1
fi

QUERY="$*"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Single-engine mode
if [ "$ENGINE_MODE" = "single" ]; then
  case $ENGINE in
    bing)
      bash "$SCRIPT_DIR/bing_search.sh" "$QUERY" > "$TMPDIR/result.html"
      python3 "$SCRIPT_DIR/parse_bing.py" "$TMPDIR/result.html"
      ;;
    google)
      bash "$SCRIPT_DIR/google_search.sh" "$QUERY" > "$TMPDIR/result.html"
      python3 "$SCRIPT_DIR/parse_google.py" "$TMPDIR/result.html"
      ;;
    duckduckgo)
      bash "$SCRIPT_DIR/duckduckgo_search.sh" "$QUERY" > "$TMPDIR/result.html"
      python3 "$SCRIPT_DIR/parse_duckduckgo.py" "$TMPDIR/result.html"
      ;;
    brave)
      bash "$SCRIPT_DIR/brave_search.sh" "$QUERY" > "$TMPDIR/result.html"
      python3 "$SCRIPT_DIR/parse_brave.py" "$TMPDIR/result.html"
      ;;
    *)
      echo "Error: unknown engine '$ENGINE'. Available: bing, google, duckduckgo, brave" >&2
      exit 1
      ;;
  esac
  exit 0
fi

# All-engines mode
if [ "$ENGINE_MODE" = "all" ]; then
  ALL_RESULTS=""
  for engine in "${ENGINES[@]}"; do
    echo "--- $engine ---" >&2
    case $engine in
      bing)
        bash "$SCRIPT_DIR/bing_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || continue
        RESULT=$(python3 "$SCRIPT_DIR/parse_bing.py" "$TMPDIR/result.html" 2>/dev/null || true)
        ;;
      google)
        bash "$SCRIPT_DIR/google_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || continue
        RESULT=$(python3 "$SCRIPT_DIR/parse_google.py" "$TMPDIR/result.html" 2>/dev/null || true)
        ;;
      duckduckgo)
        bash "$SCRIPT_DIR/duckduckgo_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || continue
        RESULT=$(python3 "$SCRIPT_DIR/parse_duckduckgo.py" "$TMPDIR/result.html" 2>/dev/null || true)
        ;;
      brave)
        bash "$SCRIPT_DIR/brave_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || continue
        RESULT=$(python3 "$SCRIPT_DIR/parse_brave.py" "$TMPDIR/result.html" 2>/dev/null || true)
        ;;
    esac
    if [ -n "$RESULT" ]; then
      ALL_RESULTS="${ALL_RESULTS}${RESULT}\n\n"
    fi
  done
  echo -e "$ALL_RESULTS"
  exit 0
fi

# Cascade mode (default): try one after another until there are results
TOTAL_RESULTS=0
for engine in "${ENGINES[@]}"; do
  echo "--- trying $engine ---" >&2
  case $engine in
    bing)
      bash "$SCRIPT_DIR/bing_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || continue
      RESULT=$(python3 "$SCRIPT_DIR/parse_bing.py" "$TMPDIR/result.html" 2>/dev/null || true)
      ;;
    google)
      bash "$SCRIPT_DIR/google_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || continue
      RESULT=$(python3 "$SCRIPT_DIR/parse_google.py" "$TMPDIR/result.html" 2>/dev/null || true)
      ;;
    duckduckgo)
      bash "$SCRIPT_DIR/duckduckgo_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || continue
      RESULT=$(python3 "$SCRIPT_DIR/parse_duckduckgo.py" "$TMPDIR/result.html" 2>/dev/null || true)
      ;;
    brave)
      bash "$SCRIPT_DIR/brave_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || continue
      RESULT=$(python3 "$SCRIPT_DIR/parse_brave.py" "$TMPDIR/result.html" 2>/dev/null || true)
      ;;
  esac

  if [ -n "$RESULT" ]; then
    RESULT_COUNT=$(echo "$RESULT" | grep -c "^\[" || true)
    TOTAL_RESULTS=$((TOTAL_RESULTS + RESULT_COUNT))
    echo "$RESULT"

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
