#!/bin/bash
# search.sh — 统一搜索引擎入口
# 用法: search.sh [--engine=<bing|sogou|so360|duckduckgo|brave|all>] <关键词...>
# 输出: 结构化搜索结果到 stdout
#
# 默认尝试顺序: Bing → 搜狗 → 360 → DuckDuckGo → Brave
# 如果指定了 --engine，则只使用该引擎
# 如果指定了 --engine=all，则使用所有引擎并合并结果
#
# 引擎取舍（2026-10 实测）:
#   - Bing     对中文长查询会退化成字词词典页（搜「端到端原则」给「端」字词典），短词尚可
#   - 搜狗/360 对中文最稳，结果集与 Bing/DDG/Brave 基本不重叠 —— 主力
#   - DDG      常返 HTTP 202 挑战页；Brave 时通时断；几家都会轮流限流
#   - Google   对未登录请求做 JS 挑战，curl 只能拿到 enablejs 中间页、拿不到结果，故已移除
#
# 每家的输出都会过一遍 filter_results.py：与查询词无关的条目直接丢弃。Bing 会用单字
# 词典页回答多词查询，不过滤就会被当成「足够的结果」而让级联提前停下
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENGINES=("bing" "sogou" "so360" "duckduckgo" "brave")
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
  echo "用法: search.sh [--engine=<bing|sogou|so360|duckduckgo|brave|all>] <关键词...>" >&2
  exit 1
fi

QUERY="$*"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# 抓取并解析单个引擎：$1=引擎名，结构化结果写 stdout；抓取失败返回非零
run_engine() {
  local engine="$1"
  case $engine in
    bing)
      bash "$SCRIPT_DIR/bing_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || return 1
      python3 "$SCRIPT_DIR/parse_bing.py" "$TMPDIR/result.html" 2>/dev/null || true
      ;;
    sogou)
      bash "$SCRIPT_DIR/sogou_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || return 1
      # --resolve:搜狗结果的 href 常是 /link?url= 跳转链（它不发 HTTP 重定向，
      # 而是回一个小页面执行 location.replace），解出站点真实地址才能直接 read
      python3 "$SCRIPT_DIR/parse_sogou.py" --resolve "$TMPDIR/result.html" 2>/dev/null || true
      ;;
    so360)
      bash "$SCRIPT_DIR/so360_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || return 1
      python3 "$SCRIPT_DIR/parse_so360.py" "$TMPDIR/result.html" 2>/dev/null || true
      ;;
    duckduckgo)
      bash "$SCRIPT_DIR/duckduckgo_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || return 1
      python3 "$SCRIPT_DIR/parse_duckduckgo.py" "$TMPDIR/result.html" 2>/dev/null || true
      ;;
    brave)
      bash "$SCRIPT_DIR/brave_search.sh" "$QUERY" > "$TMPDIR/result.html" 2>/dev/null || return 1
      python3 "$SCRIPT_DIR/parse_brave.py" "$TMPDIR/result.html" 2>/dev/null || true
      ;;
    *)
      echo "错误: 未知引擎 '$engine'. 可用: bing, sogou, so360, duckduckgo, brave" >&2
      return 1
      ;;
  esac
}

# 多引擎拼接后各自的编号都从 [1] 开始，输出前统一重排
renumber() {
  awk '/^\[[0-9]+\] /{n++; sub(/^\[[0-9]+\]/, "[" n "]")} {print}'
}

# 单引擎模式
if [ "$ENGINE_MODE" = "single" ]; then
  run_engine "$ENGINE" | python3 "$SCRIPT_DIR/filter_results.py" "$QUERY"
  exit 0
fi

# 全部引擎模式
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

# 级联模式（默认）：依次尝试直到有结果
ACCUM=""
TOTAL_RESULTS=0
for engine in "${ENGINES[@]}"; do
  echo "--- 尝试 $engine ---" >&2
  RESULT=$(run_engine "$engine" | python3 "$SCRIPT_DIR/filter_results.py" "$QUERY" || true)

  if [ -n "$RESULT" ]; then
    RESULT_COUNT=$(echo "$RESULT" | grep -c "^\[" || true)
    TOTAL_RESULTS=$((TOTAL_RESULTS + RESULT_COUNT))
    ACCUM="${ACCUM}${RESULT}"$'\n'

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

echo "$ACCUM" | renumber
