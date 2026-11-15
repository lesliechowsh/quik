#!/bin/bash
# Headless UI check: inject a deterministic state, screenshot the real panel, and
# assert it stays on screen and drew something. Text is not read.
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

  pkill -x Quik 2>/dev/null || true
  defaults write "$BUNDLE_ID" hudVisible -bool true
  rm -f /tmp/quik-panel-windowid.txt /tmp/quik-hud-windowid.txt
  open -n --env QUIK_PREVIEW="$state" "$APP"

  for _ in $(seq 1 100); do
    [ -f /tmp/quik-panel-windowid.txt ] && break
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

  # Text is not read here: OCR on small UI text gave false confidence, and a
  # screencapture of the floating window returned the panel's pixels instead of
  # its own. The capture only has to prove the view drew something; the PNGs
  # stay in /tmp/quik-ui for a person to look at. Floating window visibility and
  # placement are covered end to end by verify-hud.sh and window-bounds.swift.
  local ink
  if ink="$(swift scripts/image-ink.swift "$OUT/$state.png" 1 60 2>&1)"; then
    echo "PASS $state (panel $ink)"
  else
    echo "FAIL $state: blank window or unreadable capture ($ink)"
    fail=1
  fi
  pkill -x Quik 2>/dev/null || true
}

defaults write "$BUNDLE_ID" advancedMode -bool false
check_state fluid
check_state sluggish
check_state stalled

defaults write "$BUNDLE_ID" advancedMode -bool true
check_state stalled

check_agent_install() {
  pkill -x Quik 2>/dev/null || true
  # The entry lives in plain mode, so exercise the path a real user takes.
  defaults write "$BUNDLE_ID" advancedMode -bool false
  defaults write "$BUNDLE_ID" hudVisible -bool true
  rm -f /tmp/quik-panel-windowid.txt
  open -n --env QUIK_PREVIEW=fluid --env QUIK_PREVIEW_AGENT=1 "$APP"
  for _ in $(seq 1 100); do
    [ -f /tmp/quik-panel-windowid.txt ] && break
    perl -e 'select(undef,undef,undef,0.1)'
  done
  if [ ! -f /tmp/quik-panel-windowid.txt ]; then
    echo "FAIL agent view: panel window not recorded"
    fail=1
    pkill -x Quik 2>/dev/null || true
    return
  fi
  # The popover settles into its pinned position for a moment before all text lands.
  perl -e 'select(undef,undef,undef,1.5)'
  local window_id
  window_id="$(cat /tmp/quik-panel-windowid.txt)"
  screencapture -x -l "$window_id" -o "$OUT/agent.png"
  # The view must draw something. Its copy and its disk effect are asserted in
  # the unit tests and verify-agent.sh, not by reading the pixels.
  local ink
  if ink="$(swift scripts/image-ink.swift "$OUT/agent.png" 1 60 2>&1)"; then
    echo "PASS agent view (the install page renders, $ink)"
  else
    echo "FAIL agent view: blank window or unreadable capture ($ink)"
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
