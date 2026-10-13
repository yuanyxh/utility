#!/usr/bin/env bash
# 把 URL 抓取为 Markdown。
#
# 隐私优先的级联：
#   默认（不带 --use-proxy）：仅用本地提取器。URL 绝不发给第三方。
#   已 pip 安装 readability-lxml + html2text 时质量最佳；否则退化为仅用
#   标准库的剥离器。
#
#   带 --use-proxy 时：先本地，再 defuddle.md，再 r.jina.ai。
#   用于重 JS 的页面、X/Twitter、付费墙，或本地提取器够不到的内容。注意：
#   URL 会被发送给这些第三方服务，并可能被缓存或记录。绝不要把敏感 URL
#   走 --use-proxy。
#
# 每一层都会输出一行结构化 stderr 信息：
#   [fetch] tier=<local|defuddle|jina> status=<ok|fail|skip> reason="..."
#
# 特别感谢 joeseesun 的 qiaomu-markdown-proxy 项目，本代理级联的设计受其启发：
# https://github.com/joeseesun/qiaomu-markdown-proxy
#
# 用法：
#   fetch.sh <url> [proxy_url]
#   fetch.sh --use-proxy <url> [proxy_url]
set -euo pipefail

USE_PROXY=0
if [ "${1:-}" = "--use-proxy" ]; then
  USE_PROXY=1
  shift
fi

URL="${1:?用法: fetch.sh [--use-proxy] <url> [proxy_url]}"
PROXY="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_ERR="$(mktemp)"
trap 'rm -f "$LOCAL_ERR"' EXIT

# shellcheck disable=SC2329,SC2317  # 经 _with_retry / _try_once 间接触发
_curl() {
  if [ -n "$PROXY" ]; then
    https_proxy="$PROXY" http_proxy="$PROXY" curl -sfL --connect-timeout 10 --max-time 30 "$@"
  else
    curl -sfL --connect-timeout 10 --max-time 30 "$@"
  fi
}

_has_content() {
  local content="$1"
  [ "$(printf '%s' "$content" | wc -l)" -gt 5 ] || return 1
  # 拒绝那些被登录墙、验证码或机器人挑战主导、否则能通过行数检查的页面。
  # 在此处添加新标记，而不是新增分支。
  if printf '%s' "$content" | grep -qE "Don't miss what's happening|Sign in to continue|Please sign in|Log in to continue|请登录|登录后查看|机器人验证|人机验证|Just a moment\.\.\.|Checking your browser" 2>/dev/null; then
    return 1
  fi
  return 0
}

_try_once() {
  local out
  out=$("$@" 2>/dev/null || true)
  if _has_content "$out"; then echo "$out"; return 0; fi
  return 1
}

_with_retry() {
  _try_once "$@" && return 0
  sleep 2
  _try_once "$@" && return 0
  return 1
}

# 第 1 层：本地提取器。总是最先尝试。
if OUT=$(python3 "$SCRIPT_DIR/fetch_local.py" "$URL" 2>"$LOCAL_ERR"); then
  cat "$LOCAL_ERR" >&2 2>/dev/null || true
  echo "$OUT"
  exit 0
fi
cat "$LOCAL_ERR" >&2 2>/dev/null || true

# 未带 --use-proxy 时到此为止。URL 绝不离开本机。
if [ "$USE_PROXY" -eq 0 ]; then
  echo "[fetch] status=fail reason=\"本地提取器失败；请用 --use-proxy 重试，以尝试 defuddle.md 和 r.jina.ai（URL 将被发送给这些服务）\"" >&2
  exit 1
fi

# 第 2 层：defuddle.md（第三方；用户已通过 --use-proxy 选择启用）。
if OUT=$(_with_retry _curl "https://defuddle.md/$URL"); then
  echo "[fetch] tier=defuddle status=ok" >&2
  echo "$OUT"
  exit 0
fi
echo "[fetch] tier=defuddle status=fail reason=\"响应为空或疑似付费墙\"" >&2

# 第 3 层：r.jina.ai（第三方；用户已通过 --use-proxy 选择启用）。
if OUT=$(_with_retry _curl "https://r.jina.ai/$URL"); then
  echo "[fetch] tier=jina status=ok" >&2
  echo "$OUT"
  exit 0
fi
echo "[fetch] tier=jina status=fail reason=\"响应为空或疑似付费墙\"" >&2

echo "[fetch] status=fail reason=\"所有层级（local、defuddle、jina）对 $URL 均失败\"" >&2
exit 1
