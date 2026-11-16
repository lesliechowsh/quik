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
ADVANCED_WAS="$(defaults read "$BUNDLE_ID" advancedMode 2>/dev/null || echo 0)"
[ "$ADVANCED_WAS" = "1" ] && ADVANCED_WAS=true || ADVANCED_WAS=false
OUT=/tmp/quik-hud-check
mkdir -p "$OUT"
fail=0

caffeinate -d -u -t 180 &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT

hud_windows() {
  swift scripts/window-bounds.swift Quik 2>/dev/null \
    | sed -n 's/.*w:\([0-9]*\).*/\1/p' \
    | awk '$1 > 80 && $1 < 300' \
    | wc -l | tr -d ' '
}

# Width x height of the floating window. The panel is 400 wide, so the range
# below separates the two without knowing which order they are listed in.
hud_size() {
  swift scripts/window-bounds.swift Quik 2>/dev/null \
    | sed -n 's/.*cg=(x:-\{0,1\}[0-9]* y:-\{0,1\}[0-9]* w:\([0-9]*\) h:\([0-9]*\)).*/\1x\2/p' \
    | awk -F'x' '$1 > 80 && $1 < 300 { print; exit }'
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
defaults write "$BUNDLE_ID" advancedMode -bool false
expect_hud "打开后重启出现" 1
normal_size="$(hud_size)"
if [ "$normal_size" = "92x44" ]; then
  echo "PASS 普通模式悬浮窗 92x44"
else
  echo "FAIL 普通模式悬浮窗尺寸 $normal_size"
  fail=1
fi

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
late="$(hud_size)"
if [ "$late" = "92x44" ]; then
  echo "PASS 面板关闭后悬浮窗还在"
else
  echo "FAIL 面板关闭后悬浮窗状态不对 (windows=$late)"
  fail=1
fi

defaults write "$BUNDLE_ID" advancedMode -bool false
launch QUIK_TOGGLE_ADVANCED=1
sleep 1
advanced_size="$(hud_size)"
if [ "$advanced_size" = "148x50" ]; then
  echo "PASS 高级模式悬浮窗 148x50"
else
  echo "FAIL 高级模式悬浮窗尺寸 $advanced_size"
  fail=1
fi

# Narrow windows are the floating one, wide ones the panel.
frame_of() {
  swift scripts/window-bounds.swift Quik 2>/dev/null \
    | sed -n 's/^window=.*cg=(x:-\{0,1\}[0-9]* y:-\{0,1\}[0-9]* w:\([0-9]*\) h:\([0-9]*\)).*/\1 \2/p' \
    | awk -v lo="$1" -v hi="$2" '$1 > lo && $1 < hi { print; exit }'
}
hud_box() {
  swift scripts/window-bounds.swift Quik 2>/dev/null \
    | sed -n 's/^window=.*cg=(x:\(-\{0,1\}[0-9]*\) y:\(-\{0,1\}[0-9]*\) w:\([0-9]*\) h:\([0-9]*\)).*/\1 \2 \3 \4/p' \
    | awk '$3 > 80 && $3 < 300 { print; exit }'
}
panel_box() {
  swift scripts/window-bounds.swift Quik 2>/dev/null \
    | sed -n 's/^window=.*cg=(x:\(-\{0,1\}[0-9]*\) y:\(-\{0,1\}[0-9]*\) w:\([0-9]*\) h:\([0-9]*\)).*/\1 \2 \3 \4/p' \
    | awk '$3 > 300 { print; exit }'
}

defaults write "$BUNDLE_ID" advancedMode -bool false
launch
read -r hx hy hw hh <<<"$(hud_box)"
read -r px py pw ph <<<"$(panel_box)"
if [ -z "${ph:-}" ]; then
  echo "FAIL 悬浮窗与面板没有同时出现"
  fail=1
else
  swift scripts/window-input.swift drag $((hx + hw / 2)) $((hy + hh / 2)) \
    $((hx + hw / 2 - 120)) $((hy + hh / 2 - 20))
  sleep 1
  read -r hx2 hy2 _ _ <<<"$(hud_box)"
  read -r px2 py2 _ _ <<<"$(panel_box)"
  hud_dx=$((hx2 - hx)); hud_dy=$((hy2 - hy))
  panel_dx=$((px2 - px)); panel_dy=$((py2 - py))
  if [ "$hud_dx" = "0" ] && [ "$hud_dy" = "0" ]; then
    echo "SKIP 拖动悬浮窗带动面板 (系统没有把合成拖动交给窗口)"
  elif [ "$hud_dx" = "$panel_dx" ] && [ "$hud_dy" = "$panel_dy" ]; then
    echo "PASS 拖动悬浮窗带动面板 (${hud_dx},${hud_dy})"
  else
    echo "FAIL 悬浮窗移动 (${hud_dx},${hud_dy}) 面板移动 (${panel_dx},${panel_dy})"
    fail=1
  fi

  read -r px py pw ph <<<"$(panel_box)"
  swift scripts/window-input.swift drag $((px + 40)) $((py + 30)) $((px + 100)) $((py + 60))
  sleep 1
  read -r hx3 hy3 _ _ <<<"$(hud_box)"
  read -r px3 py3 _ _ <<<"$(panel_box)"
  panel_dx=$((px3 - px)); panel_dy=$((py3 - py))
  hud_dx=$((hx3 - hx2)); hud_dy=$((hy3 - hy2))
  if [ "$panel_dx" = "0" ] && [ "$panel_dy" = "0" ]; then
    echo "SKIP 拖动面板带动悬浮窗 (系统没有把合成拖动交给窗口)"
  elif [ "$hud_dx" = "$panel_dx" ] && [ "$hud_dy" = "$panel_dy" ]; then
    echo "PASS 拖动面板带动悬浮窗 (${panel_dx},${panel_dy})"
  else
    echo "FAIL 面板移动 (${panel_dx},${panel_dy}) 悬浮窗移动 (${hud_dx},${hud_dy})"
    fail=1
  fi

  read -r hx4 hy4 hw4 hh4 <<<"$(hud_box)"
  swift scripts/window-input.swift click $((hx4 + hw4 / 2)) $((hy4 + hh4 / 2))
  sleep 1
  if [ -z "$(frame_of 300 500)" ]; then
    echo "PASS 点击悬浮窗收起面板"
  else
    echo "FAIL 点击悬浮窗没有收起面板"
    fail=1
  fi
  swift scripts/window-input.swift click $((hx4 + hw4 / 2)) $((hy4 + hh4 / 2))
  sleep 1
  if [ -n "$(frame_of 300 500)" ]; then
    echo "PASS 再点悬浮窗展开面板"
  else
    echo "FAIL 再点悬浮窗没有展开面板"
    fail=1
  fi
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
defaults write "$BUNDLE_ID" advancedMode -bool "$ADVANCED_WAS"
if [ "$QUIK_WAS_RUNNING" = "1" ]; then open "$APP"; fi
exit "$fail"
