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
APP_LANGUAGE_WAS="$(defaults read "$BUNDLE_ID" appLanguage 2>/dev/null || true)"
fail=0

caffeinate -d -u -t 300 &
CAFFEINATE_PID=$!
cleanup() {
  kill "$CAFFEINATE_PID" 2>/dev/null || true
  wait "$CAFFEINATE_PID" 2>/dev/null || true
  pkill -x Quik 2>/dev/null || true
  # The switch check writes a language choice, so put the user's back even
  # when the run fails partway.
  if [ -n "$APP_LANGUAGE_WAS" ]; then
    defaults write "$BUNDLE_ID" appLanguage -string "$APP_LANGUAGE_WAS"
  else
    defaults delete "$BUNDLE_ID" appLanguage 2>/dev/null || true
  fi
}
trap cleanup EXIT

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
  # A stored in-app choice beats -AppleLanguages by design, so clear it here or
  # every capture would show the user's pick instead of the language under test.
  defaults delete "$BUNDLE_ID" appLanguage 2>/dev/null || true

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

  # Every page carries the language picker in its top right corner: a compact
  # capsule with a globe, the current language, and a chevron. Size, position,
  # and a tinted fill behind it make it read as a control, not a label. Probes
  # read one pixel each because a 7 percent fill sits below the ink threshold.
  local region_x=$(( 260 * scale )) region_y=$(( 20 * scale ))
  local region_w=$(( 150 * scale )) region_h=$(( 45 * scale ))
  local chip cx cy cw ch
  chip="$(swift scripts/image-ink.swift "$png" --inset "$inset" \
    --region "$region_x,$region_y,$region_w,$region_h")"
  read -r cx cy cw ch <<<"$(sed -n 's/.*bbox=(\([0-9]*\),\([0-9]*\) \([0-9]*\)x\([0-9]*\)).*/\1 \2 \3 \4/p' <<<"$chip")"
  if [ -z "${ch:-}" ]; then
    problems+=("no language control in the top right")
  else
    local chip_right=$(( cx + cw ))
    local mid=$(( cy + ch / 2 ))
    { [ "$cw" -ge $(( 40 * scale )) ] && [ "$cw" -le $(( 70 * scale )) ]; } \
      || problems+=("language control ${cw}px wide")
    { [ "$ch" -ge $(( 10 * scale )) ] && [ "$ch" -le $(( 18 * scale )) ]; } \
      || problems+=("language control ${ch}px tall")
    { [ "$chip_right" -ge $(( 370 * scale )) ] && [ "$chip_right" -le $(( 400 * scale )) ]; } \
      || problems+=("language control ends at ${chip_right}px")
    { [ "$cy" -ge $(( 28 * scale )) ] && [ "$cy" -le $(( 42 * scale )) ]; } \
      || problems+=("language control starts at ${cy}px")
    local fill inside outside
    fill="$(swift scripts/image-ink.swift "$png" \
      --probe "$(( cx - 4 * scale )),$mid" --probe "$(( cx - 20 * scale )),$mid")"
    read -r inside outside <<<"$(sed -n 's/^probe [0-9-]*,[0-9-]*=\([0-9.]*\)$/\1/p' <<<"$fill" | tr '\n' ' ')"
    [ "$(awk -v v="${inside:-1}" 'BEGIN { print (v < 0.98) ? 1 : 0 }')" = "1" ] \
      || problems+=("language control has no tinted fill")
    [ "$(awk -v v="${outside:-0}" 'BEGIN { print (v > 0.99) ? 1 : 0 }')" = "1" ] \
      || problems+=("background beside the language control is tinted")
  fi

  if [ "${#problems[@]}" -gt 0 ]; then
    echo "FAIL $language $view: ${problems[*]} ($ink)"
    fail=1
  else
    echo "PASS $language $view (ink ${pct}% margins ${x}/${y}/${right}/${bottom}px chip ${cx},${cy} ${cw}x${ch})"
  fi
  pkill -x Quik 2>/dev/null || true
}

for language in $LANGUAGES; do
  check_view "$language" panel stalled "" false
  check_view "$language" advanced stalled "" true
  check_view "$language" agent stalled "--env QUIK_PREVIEW_AGENT=1" false
done

ink_percent() {
  local file="$1" wide scale
  wide="$(swift scripts/image-ink.swift "$file" | sed -n 's/^ink [0-9.]*% (\([0-9]*\)x.*$/\1/p')"
  scale=$(( wide / 426 ))
  [ "$scale" -ge 1 ] || scale=1
  swift scripts/image-ink.swift "$file" --inset $(( SIDE_POINTS * scale )) \
    | sed -n 's/^ink \([0-9.]*\)%.*$/\1/p'
}

# Matching ink density within this run means the same text was drawn. The gap
# between any two of the five languages is above a full point.
same_ink() {
  awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit (d <= t) ? 0 : 1 }'
}

# The language control's own bbox is a fingerprint of the language it shows:
# every endonym has a different width, and the geometry does not move with the
# system locale. It identifies the language far more sharply than ink density.
chip_box() {
  local file="$1" wide scale
  wide="$(swift scripts/image-ink.swift "$file" | sed -n 's/^ink [0-9.]*% (\([0-9]*\)x.*$/\1/p')"
  scale=$(( wide / 426 ))
  [ "$scale" -ge 1 ] || scale=1
  swift scripts/image-ink.swift "$file" --inset $(( SIDE_POINTS * scale )) \
    --region $(( 260 * scale )),$(( 20 * scale )),$(( 150 * scale )),$(( 45 * scale )) \
    | sed -n 's/.*bbox=(\([0-9]*\),\([0-9]*\) \([0-9]*\)x\([0-9]*\)).*/\1 \2 \3 \4/p'
}

same_chip() {
  awk -v ax="$1" -v ay="$2" -v aw="$3" -v bx="$4" -v by="$5" -v bw="$6" -v t="$7" \
    'BEGIN { d1 = ax - bx; d2 = ay - by; d3 = aw - bw; if (d1 < 0) d1 = -d1; if (d2 < 0) d2 = -d2; if (d3 < 0) d3 = -d3; exit (d1 <= t && d2 <= t && d3 <= t) ? 0 : 1 }'
}

# Picking a language must redraw the open panel without a relaunch, save the
# choice, and beat the system language at the next launch. The pixel probe can
# not read the text, so it compares the ink density against the same languages
# captured in the loop above.
check_language_switch() {
  local from="$1" to="$2"
  local from_base="$OUT/lang-$from-panel.png" to_base="$OUT/lang-$to-panel.png"
  if [ ! -f "$from_base" ] || [ ! -f "$to_base" ]; then
    echo "SKIP language switch $from -> $to (captures missing)"
    return
  fi

  pkill -x Quik 2>/dev/null || true
  rm -f /tmp/quik-panel-windowid.txt
  defaults delete "$BUNDLE_ID" appLanguage 2>/dev/null || true
  defaults write "$BUNDLE_ID" advancedMode -bool false
  defaults write "$BUNDLE_ID" hudVisible -bool false
  open -n --env QUIK_PREVIEW=stalled --env QUIK_NO_HUD=1 \
    --env QUIK_SWITCH_LANGUAGE="$to" "$APP" --args -AppleLanguages "($from)"
  for _ in $(seq 1 100); do
    [ -f /tmp/quik-panel-windowid.txt ] && break
    perl -e 'select(undef,undef,undef,0.1)'
  done
  if [ ! -f /tmp/quik-panel-windowid.txt ]; then
    echo "FAIL language switch $from -> $to: panel window not recorded"
    fail=1
    return
  fi

  local window_id before after
  window_id="$(cat /tmp/quik-panel-windowid.txt)"
  before="$OUT/switch-$from-before.png"
  after="$OUT/switch-$from-$to.png"
  perl -e 'select(undef,undef,undef,1.2)'
  screencapture -x -l "$window_id" -o "$before"
  perl -e 'select(undef,undef,undef,3)'
  screencapture -x -l "$window_id" -o "$after"

  local from_ink to_ink before_ink after_ink
  from_ink="$(ink_percent "$from_base")"
  to_ink="$(ink_percent "$to_base")"
  before_ink="$(ink_percent "$before")"
  after_ink="$(ink_percent "$after")"
  if [ -z "$from_ink" ] || [ -z "$to_ink" ] || [ -z "$before_ink" ] || [ -z "$after_ink" ]; then
    echo "FAIL language switch $from -> $to: could not measure the captures"
    fail=1
    return
  fi

  local fx fy fw fh tx ty tw th bx by bw bh ax ay aw ah
  read -r fx fy fw fh <<<"$(chip_box "$from_base")"
  read -r tx ty tw th <<<"$(chip_box "$to_base")"
  read -r bx by bw bh <<<"$(chip_box "$before")"
  read -r ax ay aw ah <<<"$(chip_box "$after")"

  local problems=()
  same_chip "$bx" "$by" "$bw" "$fx" "$fy" "$fw" 3 \
    || problems+=("before the switch the control is not $from")
  same_chip "$ax" "$ay" "$aw" "$tx" "$ty" "$tw" 3 \
    || problems+=("after the switch the control is not $to")
  same_ink "$before_ink" "$from_ink" 0.35 \
    || problems+=("before the switch ${before_ink}% is not $from (${from_ink}%)")
  same_ink "$after_ink" "$to_ink" 0.35 \
    || problems+=("after the switch ${after_ink}% is not $to (${to_ink}%)")
  [ "$(defaults read "$BUNDLE_ID" appLanguage 2>/dev/null || true)" = "$to" ] \
    || problems+=("the choice was not saved")

  pkill -x Quik 2>/dev/null || true
  rm -f /tmp/quik-panel-windowid.txt
  open -n --env QUIK_PREVIEW=stalled --env QUIK_NO_HUD=1 "$APP" --args -AppleLanguages "($from)"
  for _ in $(seq 1 100); do
    [ -f /tmp/quik-panel-windowid.txt ] && break
    perl -e 'select(undef,undef,undef,0.1)'
  done
  local persisted="$OUT/switch-$to-persisted.png"
  if [ -f /tmp/quik-panel-windowid.txt ]; then
    perl -e 'select(undef,undef,undef,1.5)'
    screencapture -x -l "$(cat /tmp/quik-panel-windowid.txt)" -o "$persisted"
    local persisted_ink px py pw ph
    persisted_ink="$(ink_percent "$persisted")"
    same_ink "$persisted_ink" "$to_ink" 0.35 \
      || problems+=("relaunch shows ${persisted_ink}% instead of $to (${to_ink}%)")
    read -r px py pw ph <<<"$(chip_box "$persisted")"
    same_chip "$px" "$py" "$pw" "$tx" "$ty" "$tw" 3 \
      || problems+=("relaunch shows another language's control")
  else
    problems+=("relaunch did not open a panel")
    persisted_ink="?"
  fi
  pkill -x Quik 2>/dev/null || true

  if [ "${#problems[@]}" -gt 0 ]; then
    echo "FAIL language switch $from -> $to: ${problems[*]}"
    fail=1
  else
    echo "PASS language switch $from -> $to (${before_ink}% -> ${after_ink}%, relaunch ${persisted_ink}%)"
  fi
}

# A system language Quik does not ship must land on English, not on whichever
# localization happens to come first.
check_english_fallback() {
  local base="$OUT/lang-en-panel.png"
  if [ ! -f "$base" ]; then
    echo "SKIP English fallback (en capture missing)"
    return
  fi
  pkill -x Quik 2>/dev/null || true
  rm -f /tmp/quik-panel-windowid.txt
  defaults delete "$BUNDLE_ID" appLanguage 2>/dev/null || true
  defaults write "$BUNDLE_ID" advancedMode -bool false
  defaults write "$BUNDLE_ID" hudVisible -bool false
  open -n --env QUIK_PREVIEW=stalled --env QUIK_NO_HUD=1 "$APP" --args -AppleLanguages "(ko)"
  for _ in $(seq 1 100); do
    [ -f /tmp/quik-panel-windowid.txt ] && break
    perl -e 'select(undef,undef,undef,0.1)'
  done
  if [ ! -f /tmp/quik-panel-windowid.txt ]; then
    echo "FAIL English fallback: panel window not recorded"
    fail=1
    return
  fi
  perl -e 'select(undef,undef,undef,1.5)'
  local png="$OUT/fallback-ko.png"
  screencapture -x -l "$(cat /tmp/quik-panel-windowid.txt)" -o "$png"
  pkill -x Quik 2>/dev/null || true
  local en_ink ko_ink ex ey ew eh kx ky kw kh
  en_ink="$(ink_percent "$base")"
  ko_ink="$(ink_percent "$png")"
  read -r ex ey ew eh <<<"$(chip_box "$base")"
  read -r kx ky kw kh <<<"$(chip_box "$png")"
  if [ -z "$en_ink" ] || [ -z "$ko_ink" ] || [ -z "$ew" ] || [ -z "$kw" ]; then
    echo "FAIL English fallback: could not measure the captures"
    fail=1
    return
  fi
  local problems=()
  same_chip "$kx" "$ky" "$kw" "$ex" "$ey" "$ew" 3 \
    || problems+=("the control is not the English one")
  # Cross-locale text shaping moves the ink density by up to a third of a
  # point, so this only catches a gross mismatch.
  same_ink "$ko_ink" "$en_ink" 0.45 \
    || problems+=("ko rendered ${ko_ink}% instead of en ${en_ink}%")
  if [ "${#problems[@]}" -gt 0 ]; then
    echo "FAIL English fallback: ${problems[*]}"
    fail=1
  else
    echo "PASS English fallback (ko renders as en, ${ko_ink}%, control ${kw}px)"
  fi
}

check_english_fallback

case " $LANGUAGES " in
  *" ja "*)
    case " $LANGUAGES " in
      *" de "*) check_language_switch ja de ;;
      *) echo "SKIP language switch (de is not in LANGUAGES)" ;;
    esac
    ;;
  *) echo "SKIP language switch (ja is not in LANGUAGES)" ;;
esac

echo "artifacts: $OUT"
defaults write "$BUNDLE_ID" advancedMode -bool "$ADVANCED_WAS"
defaults write "$BUNDLE_ID" hudVisible -bool "$HUD_WAS"
if [ -n "$QUIK_RUNNING_FROM" ]; then open "$QUIK_RUNNING_FROM"; fi
exit "$fail"
