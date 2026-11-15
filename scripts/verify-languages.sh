#!/bin/bash
# Launch the real app once per interface language and assert the panel draws
# inside its window with a margin on every side. Translated copy is longer than
# the Chinese original, and a clipped or overflowing line shows up as ink at the
# window edge. Text is not read: the PNGs stay in /tmp/quik-ui for a person.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Quik.app"
BUNDLE_ID="dev.quik.app"
LANGUAGES="${LANGUAGES:-zh-Hans en de fr ja}"
OUT=/tmp/quik-ui
mkdir -p "$OUT"
[ -d "$APP" ] || { echo "run scripts/build.sh first" >&2; exit 1; }

QUIK_RUNNING_FROM="$(pgrep -x Quik | head -n 1 | xargs -I{} ps -o command= -p {} 2>/dev/null \
  | sed -n 's|/Contents/MacOS/Quik.*||p' || true)"
ADVANCED_WAS="$(defaults read "$BUNDLE_ID" advancedMode 2>/dev/null || echo 0)"
[ "$ADVANCED_WAS" = "1" ] && ADVANCED_WAS=true || ADVANCED_WAS=false
HUD_WAS="$(defaults read "$BUNDLE_ID" hudVisible 2>/dev/null || echo 1)"
[ "$HUD_WAS" = "1" ] && HUD_WAS=true || HUD_WAS=false
fail=0

caffeinate -d -u -t 300 &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT

# A popover window is the 400 point panel plus a 13 point shadow border on each
# side, so 426 points wide. The capture's width over 426 gives the backing scale.
# The inset skips that border, the popover arrow drawn in it, and the rounded
# corner shading that bleeds a few pixels into the content. The 24 point margin
# requirement is still below the 16 point content padding plus the border, so a
# passing check means the copy itself had room inside the panel.
BORDER_POINTS=13
SIDE_POINTS=23
MARGIN_POINTS=24

check_view() {
  local language="$1" view="$2" state="$3" extra_env="$4" advanced="$5"
  pkill -x Quik 2>/dev/null || true
  rm -f /tmp/quik-panel-windowid.txt
  defaults write "$BUNDLE_ID" advancedMode -bool "$advanced"
  defaults write "$BUNDLE_ID" hudVisible -bool false

  # The floating window is a child of the panel's window, so a window capture
  # that includes it would be measured here. Off for this check.
  # shellcheck disable=SC2086
  open -n --env QUIK_PREVIEW="$state" --env QUIK_NO_HUD=1 $extra_env "$APP" \
    --args -AppleLanguages "($language)"

  for _ in $(seq 1 100); do
    [ -f /tmp/quik-panel-windowid.txt ] && break
    perl -e 'select(undef,undef,undef,0.1)'
  done
  if [ ! -f /tmp/quik-panel-windowid.txt ]; then
    echo "FAIL $language $view: panel window not recorded"
    fail=1
    pkill -x Quik 2>/dev/null || true
    return
  fi
  perl -e 'select(undef,undef,undef,1.5)'

  if ! swift scripts/window-bounds.swift Quik --assert > "$OUT/lang-$language-$view-bounds.txt" 2>&1; then
    echo "FAIL $language $view: window off-screen"
    sed -n '2,6p' "$OUT/lang-$language-$view-bounds.txt"
    fail=1
  fi

  local png="$OUT/lang-$language-$view.png"
  screencapture -x -l "$(cat /tmp/quik-panel-windowid.txt)" -o "$png"

  local probe
  if ! probe="$(swift scripts/image-ink.swift "$png" 2>&1)"; then
    echo "FAIL $language $view: cannot read capture ($probe)"
    fail=1
    pkill -x Quik 2>/dev/null || true
    return
  fi
  local pct width height
  read -r pct width height <<<"$(sed -n 's/^ink \([0-9.]*\)% (\([0-9]*\)x\([0-9]*\).*$/\1 \2 \3/p' <<<"$probe")"
  if [ -z "${height:-}" ]; then
    echo "FAIL $language $view: blank window ($probe)"
    fail=1
    pkill -x Quik 2>/dev/null || true
    return
  fi
  local scale=$(( width / 426 ))
  [ "$scale" -ge 1 ] || scale=1
  local inset=$(( SIDE_POINTS * scale ))
  local margin=$(( MARGIN_POINTS * scale ))
  local ink
  ink="$(swift scripts/image-ink.swift "$png" --inset "$inset")"
  local x y w h
  read -r x y w h <<<"$(sed -n 's/.*bbox=(\([0-9]*\),\([0-9]*\) \([0-9]*\)x\([0-9]*\)).*/\1 \2 \3 \4/p' <<<"$ink")"
  if [ -z "${h:-}" ]; then
    echo "FAIL $language $view: nothing drawn inside the panel ($ink)"
    fail=1
    pkill -x Quik 2>/dev/null || true
    return
  fi

  local right=$(( width - x - w ))
  local bottom=$(( height - y - h ))
  local problems=()
  [ "$(awk -v p="$pct" 'BEGIN { print (p < 1 || p > 60) ? 1 : 0 }')" = "1" ] && problems+=("ink ${pct}% outside 1..60")
  [ "$x" -ge "$margin" ] || problems+=("left margin ${x}px < ${margin}px")
  [ "$y" -ge "$margin" ] || problems+=("top margin ${y}px < ${margin}px")
  [ "$right" -ge "$margin" ] || problems+=("right margin ${right}px < ${margin}px")
  [ "$bottom" -ge "$margin" ] || problems+=("bottom margin ${bottom}px < ${margin}px")

  if [ "${#problems[@]}" -gt 0 ]; then
    echo "FAIL $language $view: ${problems[*]} ($line)"
    fail=1
  else
    echo "PASS $language $view (ink ${pct}% margins ${x}/${y}/${right}/${bottom}px)"
  fi
  pkill -x Quik 2>/dev/null || true
}

for language in $LANGUAGES; do
  check_view "$language" panel stalled "" false
  check_view "$language" advanced stalled "" true
  check_view "$language" agent stalled "--env QUIK_PREVIEW_AGENT=1" false
done

echo "artifacts: $OUT"
defaults write "$BUNDLE_ID" advancedMode -bool "$ADVANCED_WAS"
defaults write "$BUNDLE_ID" hudVisible -bool "$HUD_WAS"
if [ -n "$QUIK_RUNNING_FROM" ]; then open "$QUIK_RUNNING_FROM"; fi
exit "$fail"
