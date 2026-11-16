#!/bin/bash
# Checks the floating window setting across launches and the hide/show path.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Quik.app"
BUNDLE_ID="dev.quik.app"
QUIK_WAS_RUNNING=0
pgrep -x Quik >/dev/null 2>&1 && QUIK_WAS_RUNNING=1
HUD_WAS="$(defaults read "$BUNDLE_ID" hudVisible 2>/dev/null || echo 1)"
[ "$HUD_WAS" = "1" ] && HUD_WAS=true || HUD_WAS=false
OUT=/tmp/quik-hud-check
mkdir -p "$OUT"
fail=0

caffeinate -d -u -t 180 &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT

hud_windows() {
  swift scripts/window-bounds.swift Quik 2>/dev/null \
    | sed -n 's/.*w:\([0-9]*\).*/\1/p' \
    | awk '$1 > 100 && $1 < 300' \
    | wc -l | tr -d ' '
}

launch() {
  pkill -x Quik 2>/dev/null || true
  rm -f /tmp/quik-hud-windowid.txt
  args=(-n --env QUIK_PREVIEW=fluid)
  for pair in "$@"; do
    args+=(--env "$pair")
  done
  open "${args[@]}" "$APP"
  sleep 3
}

expect_hud() {
  local name="$1" expected="$2"
  shift 2
  launch "$@"
  local count
  count="$(hud_windows)"
  if [ "$count" = "$expected" ]; then
    echo "PASS $name (hud windows=$count)"
  else
    echo "FAIL $name (hud windows=$count, expected $expected)"
    fail=1
  fi
}

defaults write "$BUNDLE_ID" hudVisible -bool false
expect_hud "关闭后重启不出现" 0

defaults write "$BUNDLE_ID" hudVisible -bool true
expect_hud "打开后重启出现" 1

expect_hud "运行中隐藏" 0 QUIK_HIDE_HUD=1

defaults write "$BUNDLE_ID" hudVisible -bool false
expect_hud "运行中再打开" 1 QUIK_SHOW_HUD=1
stored="$(defaults read "$BUNDLE_ID" hudVisible)"
if [ "$stored" = "1" ]; then
  echo "PASS 再打开会写回设置"
else
  echo "FAIL 再打开会写回设置 (hudVisible=$stored)"
  fail=1
fi

defaults write "$BUNDLE_ID" hudOriginX -float 600
defaults write "$BUNDLE_ID" hudOriginY -float 700
launch QUIK_CLOSE_PANEL=1
sleep 0.5
if swift scripts/window-bounds.swift Quik --no-overlap >/dev/null 2>&1; then
  echo "PASS 拖动到中间后面板仍不盖住悬浮窗"
else
  echo "FAIL 面板盖住了悬浮窗"
  fail=1
fi
sleep 3
late="$(swift scripts/window-bounds.swift Quik 2>/dev/null | awk '/^window=/' | sed -n 's/.*w:\([0-9]*\).*/\1/p' | awk '$1 > 100')"
if [ "$late" = "128" ]; then
  echo "PASS 面板关闭后悬浮窗还在"
else
  echo "FAIL 面板关闭后悬浮窗状态不对 (windows=$late)"
  fail=1
fi
defaults delete "$BUNDLE_ID" hudOriginX 2>/dev/null || true
defaults delete "$BUNDLE_ID" hudOriginY 2>/dev/null || true

rm -f /tmp/quik-hud-menu.txt
launch QUIK_HUD_MENU_DUMP=/tmp/quik-hud-menu.txt
sleep 1
if grep -q "打开面板" /tmp/quik-hud-menu.txt 2>/dev/null && grep -q "隐藏悬浮窗" /tmp/quik-hud-menu.txt 2>/dev/null; then
  echo "PASS 右击菜单有打开面板和隐藏悬浮窗"
else
  echo "FAIL 右击菜单内容不对"
  cat /tmp/quik-hud-menu.txt 2>/dev/null || true
  fail=1
fi

pkill -x Quik 2>/dev/null || true
defaults write "$BUNDLE_ID" hudVisible -bool "$HUD_WAS"
if [ "$QUIK_WAS_RUNNING" = "1" ]; then open "$APP"; fi
exit "$fail"
