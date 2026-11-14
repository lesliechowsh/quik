#!/bin/bash
# Ends a real process through the same code path the panel button uses.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Quik.app"
QUIK_WAS_RUNNING=0
pgrep -x Quik >/dev/null 2>&1 && QUIK_WAS_RUNNING=1
rm -f /tmp/quik-quit-result.txt
pkill -x Quik 2>/dev/null || true
sleep 1

/usr/bin/nc -l 0 >/dev/null 2>&1 &
probe=$!
sleep 1

open -n --env QUIK_QUIT_PID="$probe" "$APP"

for _ in $(seq 1 60); do
  [ -f /tmp/quik-quit-result.txt ] && break
  perl -e 'select(undef,undef,undef,0.1)'
done
pkill -x Quik 2>/dev/null || true

result="$(cat /tmp/quik-quit-result.txt 2>/dev/null || echo missing)"
if kill -0 "$probe" 2>/dev/null; then alive=yes; else alive=no; fi
echo "probe pid=$probe alive=$alive result=$result"
if [ "$alive" = "no" ] && [ "$result" = "true" ]; then
  echo "PASS quit signal reached the process and it exited"
else
  echo "FAIL quit did not reach the process"
  kill -9 "$probe" 2>/dev/null || true
  if [ "$QUIK_WAS_RUNNING" = "1" ]; then open "$APP"; fi
  exit 1
fi
if [ "$QUIK_WAS_RUNNING" = "1" ]; then open "$APP"; fi
