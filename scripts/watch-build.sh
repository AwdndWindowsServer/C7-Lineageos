#!/usr/bin/env bash
#
# 监控 GitHub Actions 构建进度（终端用）
#
# GitHub 的日志 API 对进行中的任务只随机返回缓存快照，单次请求可能拿到
# 几十分钟前的旧进度。本脚本的策略：每次循环并发抓多份日志，取进度数值
# 最大（最新）的那份，画出进度条。
#
# 用法：
#   bash scripts/watch-build.sh                # 自动找最新 in_progress run
#   bash scripts/watch-build.sh 31111590830    # 指定 run id
#   bash scripts/watch-build.sh --once         # 只刷一次就退出（配合 watch 用）
#
# 需要已登录 gh（GH_TOKEN / gh auth login）。
set -euo pipefail

REPO="AwdndWindowsServer/C7-Lineageos"
RUN_ID="${1:-}"
SNAPSHOTS=3
POLL_SECONDS=45
ONCE=0
[ "${1:-}" = "--once" ] && { ONCE=1; RUN_ID=""; }

if [ -z "$RUN_ID" ]; then
  RUN_ID="$(timeout 30 gh api "repos/$REPO/actions/runs?per_page=8" \
    --jq '.workflow_runs[] | select(.status=="in_progress") | .id' | head -1 || true)"
  if [ -z "$RUN_ID" ]; then
    echo "未找到进行中的 run。手动指定: bash scripts/watch-build.sh <run_id>" >&2
    exit 1
  fi
fi

JOB_ID="$(timeout 30 gh api "repos/$REPO/actions/runs/$RUN_ID/jobs" \
  --jq '.jobs[] | select(.status=="in_progress") | .id' | head -1 || true)"
if [ -z "$JOB_ID" ]; then
  JOB_ID="$(timeout 30 gh api "repos/$REPO/actions/runs/$RUN_ID/jobs" --jq '.jobs[0].id')"
fi

echo "run : https://github.com/$REPO/actions/runs/$RUN_ID"
echo "job : https://github.com/$REPO/actions/runs/$RUN_ID/job/$JOB_ID"
echo

draw_bar() {
  local pct="$1" width=40 filled i
  filled=$(( pct * width / 100 ))
  printf '['
  for i in $(seq 1 "$width"); do
    [ "$i" -le "$filled" ] && printf '#' || printf ' '
  done
  printf '] %s%%\n' "$pct"
}

fetch_snapshot() {
  timeout 15 curl -sL --max-time 12 -H "Authorization: Bearer $(gh auth token)" \
    "https://api.github.com/repos/$REPO/actions/jobs/$JOB_ID/logs?z=$RANDOM$RANDOM" 2>/dev/null || true
}

while true; do
  status="$(timeout 25 gh api "repos/$REPO/actions/jobs/$JOB_ID" --jq '.status // "unknown"' 2>/dev/null || echo unknown)"
  concl="$(timeout 25 gh api "repos/$REPO/actions/jobs/$JOB_ID" --jq '.conclusion // ""' 2>/dev/null || echo "")"

  best_pct=0; best_num=0; best_total=0; best_stamp=""
  for n in $(seq 1 "$SNAPSHOTS"); do
    snap="$(fetch_snapshot)"
    line="$(printf '%s' "$snap" | grep -oE '\[ *[0-9]+% +[0-9]+/[0-9]+\]' | sed -E 's/\[ *([0-9]+)% +([0-9]+)\/([0-9]+)\]/\1 \2 \3/' | sort -k2 -n | tail -1)"
    stamp="$(printf '%s' "$snap" | grep -oE '2026-08-0[67]T[0-9:]+' | tail -1)"
    [ -z "$line" ] && continue
    read -r pct num total <<< "$line"
    if [ "$num" -gt "$best_num" ]; then
      best_pct=$pct; best_num=$num; best_total=$total; best_stamp=$stamp
    fi
  done

  now="$(date -u +%H:%M:%S)"
  if [ "$status" = "completed" ]; then
    printf '%s  完成! conclusion=%s\n' "$now" "${concl:-unknown}"
    [ -n "$best_stamp" ] && printf '最后快照: %s%% (%s/%s) @ %s\n' "$best_pct" "$best_num" "$best_total" "$best_stamp"
    exit 0
  fi

  if [ "$best_total" -gt 0 ]; then
    printf '\r%s  %-9s  %6s/%-6s   ' "$now" "$status" "$best_num" "$best_total"
    draw_bar "$best_pct"
  else
    printf '\r%s  %-9s  尚未产出进度行\n' "$now" "$status"
  fi

  [ "$ONCE" = "1" ] && exit 0
  sleep "$POLL_SECONDS"
done
