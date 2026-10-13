#!/bin/bash
# search.sh — 统一搜索引擎入口
# 用法: search.sh [--engine=<bing|google|duckduckgo|brave|all>] <关键词...>
# 输出: 结构化搜索结果到 stdout
#
# 默认尝试顺序: Bing → Google → DuckDuckGo → Brave
# 如果指定了 --engine，则只使用该引擎
# 如果指定了 --engine=all，则使用所有引擎并合并结果
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认引擎顺序
ENGINES=("bing" "google" "duckduckgo" "brave")
ENGINE_MODE="cascade"  # cascade = 依次尝试直到成功, all = 全部使用

# 解析参数
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
  echo "用法: search.sh [--engine=<bing|google|duckduckgo|brave|all>] <关键词...>" >&2
  exit 1
fi

QUERY="$*"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# 单引擎模式
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
      echo "错误: 未知引擎 '$ENGINE'. 可用: bing, google, duckduckgo, brave" >&2
      exit 1
      ;;
  esac
  exit 0
fi

# 全部引擎模式
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

# 级联模式（默认）：依次尝试直到有结果
TOTAL_RESULTS=0
for engine in "${ENGINES[@]}"; do
  echo "--- 尝试 $engine ---" >&2
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

    # 如果结果足够（>=5条），停止尝试
    if [ $RESULT_COUNT -ge 5 ]; then
      echo "--- $engine 提供了 $RESULT_COUNT 条结果，足够使用 ---" >&2
      break
    fi
  fi
done

if [ $TOTAL_RESULTS -eq 0 ]; then
  echo "错误: 所有搜索引擎都未返回结果" >&2
  exit 1
fi
