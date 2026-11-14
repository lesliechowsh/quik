#!/bin/bash
# Oscillating-load check for display stability.
# Repeats a burst of CPU load and an idle gap, then counts how often the panel's
# state, top culprit and top cause changed. Run before and after a stabilizer
# change to compare.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Quik.app"
QUIK_WAS_RUNNING=0
pgrep -x Quik >/dev/null 2>&1 && QUIK_WAS_RUNNING=1
[ -d "$APP" ] || { echo "run scripts/build.sh first" >&2; exit 1; }

LOG=/tmp/quik-debug.log
CYCLES="${CYCLES:-5}"
ON="${ON:-6}"
OFF="${OFF:-6}"
WORKERS="${WORKERS:-12}"

rm -f "$LOG"
pkill -x Quik 2>/dev/null || true
open -n --env QUIK_DEBUG=1 "$APP"
sleep 4

for _ in $(seq 1 "$CYCLES"); do
  worker_pids=()
  for _ in $(seq 1 "$WORKERS"); do
    yes > /dev/null &
    worker_pids+=("$!")
  done
  sleep "$ON"
  for pid in "${worker_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  sleep "$OFF"
done

pkill -x Quik 2>/dev/null || true
sleep 1
status=0
python3 scripts/analyze-flapping.py "$LOG" || status=$?
if [ "$QUIK_WAS_RUNNING" = "1" ]; then open "$APP"; fi
exit "$status"
