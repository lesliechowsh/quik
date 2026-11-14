#!/bin/bash
# Headless UI check: inject a deterministic state, screenshot the real panel, OCR it, assert content.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Quik.app"
BUNDLE_ID="dev.quik.app"
QUIK_WAS_RUNNING=0
pgrep -x Quik >/dev/null 2>&1 && QUIK_WAS_RUNNING=1
ADVANCED_WAS="$(defaults read "$BUNDLE_ID" advancedMode 2>/dev/null || echo 0)"
[ "$ADVANCED_WAS" = "1" ] && ADVANCED_WAS=true || ADVANCED_WAS=false
HUD_WAS="$(defaults read "$BUNDLE_ID" hudVisible 2>/dev/null || echo 1)"
[ "$HUD_WAS" = "1" ] && HUD_WAS=true || HUD_WAS=false
OUT=/tmp/quik-ui
mkdir -p "$OUT"
fail=0

# Window capture fails silently when the display is asleep, so hold it awake for the run.
caffeinate -d -u -t 300 &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT

check_state() {
  local state="$1"
  shift
  local expects=("$@")
  local level_label="${expects[${#expects[@]}-1]}"

  pkill -x Quik 2>/dev/null || true
  defaults write "$BUNDLE_ID" hudVisible -bool true
  rm -f /tmp/quik-panel-windowid.txt /tmp/quik-hud-windowid.txt
  open -n --env QUIK_PREVIEW="$state" "$APP"

  for _ in $(seq 1 100); do
    [ -f /tmp/quik-panel-windowid.txt ] && [ -f /tmp/quik-hud-windowid.txt ] && break
    perl -e 'select(undef,undef,undef,0.1)'
  done
  if [ ! -f /tmp/quik-panel-windowid.txt ]; then
    echo "FAIL $state: panel window not recorded"
    fail=1
    pkill -x Quik 2>/dev/null || true
    return
  fi

  perl -e 'select(undef,undef,undef,0.5)'
  if ! swift scripts/window-bounds.swift Quik --assert > "$OUT/$state-bounds.txt" 2>&1; then
    echo "FAIL $state: window off-screen"
    sed -n '2,6p' "$OUT/$state-bounds.txt"
    fail=1
  fi
  local window_id
  window_id="$(cat /tmp/quik-panel-windowid.txt)"
  screencapture -x -l "$window_id" -o "$OUT/$state.png"
  screencapture -x -l "$(cat /tmp/quik-hud-windowid.txt)" -o "$OUT/$state-hud.png"
  swift scripts/ocr.swift "$OUT/$state.png" > "$OUT/$state.txt" 2>/dev/null || true
  swift scripts/ocr.swift "$OUT/$state-hud.png" > "$OUT/$state-hud.txt" 2>/dev/null || true

  local missing=0
  local text_norm
  text_norm="$(tr -d ' ()（）' < "$OUT/$state.txt")"
  for needle in "${expects[@]}"; do
    local needle_norm
    needle_norm="$(tr -d ' ()（）' <<< "$needle")"
    if ! grep -qF "$needle_norm" <<< "$text_norm"; then
      echo "FAIL $state: missing '$needle'"
      missing=1
      fail=1
    fi
  done
  local hud_norm
  hud_norm="$(tr -d ' ()（）' < "$OUT/$state-hud.txt")"
  if ! grep -qF "$(tr -d ' ()（）' <<< "$level_label")" <<< "$hud_norm"; then
    echo "FAIL $state: HUD missing '$level_label'"
    missing=1
    fail=1
  fi
  [ "$missing" -eq 0 ] && echo "PASS $state ($(wc -l < "$OUT/$state.txt" | tr -d ' ') text lines, HUD ok)"
  pkill -x Quik 2>/dev/null || true
}

defaults write "$BUNDLE_ID" advancedMode -bool false
check_state fluid "现在用起来是流畅的" "流畅" "流畅"
check_state sluggish "有点卡" "硬盘太忙了" "先处理这个" "Slack" "页面渲染" "隐藏悬浮窗" "有点卡"
check_state stalled "卡住了" "内存不够用了" "Slack" "页面渲染" "结束 Slack" "卡住了"

defaults write "$BUNDLE_ID" advancedMode -bool true
check_state stalled "内存严重不足" "31% CPU" "先处理这个" "卡住了" "卡住了"

check_agent_install() {
  pkill -x Quik 2>/dev/null || true
  # The entry lives in plain mode, so exercise the path a real user takes.
  defaults write "$BUNDLE_ID" advancedMode -bool false
  defaults write "$BUNDLE_ID" hudVisible -bool true
  rm -f /tmp/quik-panel-windowid.txt
  printf 'quik-ui-check-sentinel' | pbcopy
  open -n --env QUIK_PREVIEW=fluid --env QUIK_PREVIEW_AGENT=1 "$APP"
  for _ in $(seq 1 100); do
    [ -f /tmp/quik-panel-windowid.txt ] && break
    perl -e 'select(undef,undef,undef,0.1)'
  done
  if [ ! -f /tmp/quik-panel-windowid.txt ]; then
    echo "FAIL agent install: panel window not recorded"
    fail=1
    pkill -x Quik 2>/dev/null || true
    return
  fi
  # The popover settles into its pinned position for a moment before all text lands.
  perl -e 'select(undef,undef,undef,1.5)'
  local window_id
  window_id="$(cat /tmp/quik-panel-windowid.txt)"
  screencapture -x -l "$window_id" -o "$OUT/agent.png"
  swift scripts/ocr.swift "$OUT/agent.png" > "$OUT/agent.txt" 2>/dev/null || true
  local text_norm
  text_norm="$(tr -d ' ()（）' < "$OUT/agent.txt")"
  local missing=0
  for needle in "让AI助手帮你盯着电脑" "已复制" "返回"; do
    if ! grep -qF "$(tr -d ' ()（）' <<< "$needle")" <<< "$text_norm"; then
      echo "FAIL agent install: missing '$needle'"
      missing=1
      fail=1
    fi
  done
  if pbpaste | grep -q "name: quik" && pbpaste | grep -q "Contents/Library/quik"; then
    echo "PASS agent install (view renders, prompt copied with frontmatter and cli path)"
  else
    echo "FAIL agent install: clipboard does not hold the prompt"
    missing=1
    fail=1
  fi
  pkill -x Quik 2>/dev/null || true
}

check_agent_install

pkill -x Quik 2>/dev/null || true
sleep 1
defaults write "$BUNDLE_ID" advancedMode -bool false
rm -rf "$OUT/icons"
mkdir -p "$OUT/icons"
open -n --env QUIK_EXPORT_ICON="$OUT/icons" "$APP"
for _ in $(seq 1 80); do
  [ -f "$OUT/icons/stalled.png" ] && break
  perl -e 'select(undef,undef,undef,0.1)'
done
pkill -x Quik 2>/dev/null || true
if ! swift scripts/icon-check.swift "$OUT/icons"; then
  fail=1
fi
if ! swift scripts/icon-check.swift "$OUT/icons" --advanced; then
  fail=1
fi

echo "artifacts: $OUT"
defaults write "$BUNDLE_ID" advancedMode -bool "$ADVANCED_WAS"
defaults write "$BUNDLE_ID" hudVisible -bool "$HUD_WAS"
if [ "$QUIK_WAS_RUNNING" = "1" ]; then open "$APP"; fi
exit "$fail"
