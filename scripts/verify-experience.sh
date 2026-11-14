#!/bin/bash
# Controlled-load validation for the experience probe.
# Baseline -> known CPU load -> recovery, then asserts the probe separates them.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Quik.app"
QUIK_WAS_RUNNING=0
pgrep -x Quik >/dev/null 2>&1 && QUIK_WAS_RUNNING=1
[ -d "$APP" ] || { echo "run scripts/build.sh first" >&2; exit 1; }

LOG=/tmp/quik-debug.log
SEGMENT_SECONDS="${SEGMENT_SECONDS:-12}"
LOAD_WORKERS="${LOAD_WORKERS:-12}"

rm -f "$LOG" /tmp/quik-baseline.log /tmp/quik-load.log /tmp/quik-recover.log
pkill -x Quik 2>/dev/null || true

open -n --env QUIK_DEBUG=1 "$APP"

echo "baseline ${SEGMENT_SECONDS}s"
sleep "$SEGMENT_SECONDS"
cp "$LOG" /tmp/quik-baseline.log

echo "load: ${LOAD_WORKERS} busy workers for ${SEGMENT_SECONDS}s"
worker_pids=()
for _ in $(seq 1 "$LOAD_WORKERS"); do
  yes > /dev/null &
  worker_pids+=("$!")
done
sleep "$SEGMENT_SECONDS"
cp "$LOG" /tmp/quik-load.log
for pid in "${worker_pids[@]}"; do
  kill "$pid" 2>/dev/null || true
done
wait 2>/dev/null || true

echo "recovery ${SEGMENT_SECONDS}s"
sleep "$SEGMENT_SECONDS"
cp "$LOG" /tmp/quik-recover.log
pkill -x Quik 2>/dev/null || true

status=0
python3 scripts/analyze-bench.py /tmp/quik-baseline.log /tmp/quik-load.log /tmp/quik-recover.log || status=$?
if [ "$QUIK_WAS_RUNNING" = "1" ]; then open "$APP"; fi
exit "$status"
