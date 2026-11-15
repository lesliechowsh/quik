#!/bin/bash
# Checks the agent surface end to end: the status file appears while the app
# runs, the bundled CLI reads it in both modes, and it reports no data after
# the app quits.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Quik.app"
CLI="$APP/Contents/Library/quik"
STATUS="$HOME/Library/Application Support/Quik/status.json"
JSON_OUT=/tmp/quik-agent-check/status.json
fail=0

QUIK_WAS_RUNNING=0
pgrep -x Quik >/dev/null 2>&1 && QUIK_WAS_RUNNING=1

cleanup() {
  if [ "$QUIK_WAS_RUNNING" = "0" ]; then
    pkill -x Quik 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p /tmp/quik-agent-check

[ -x "$CLI" ] || { echo "FAIL cli missing at $CLI"; exit 1; }
echo "PASS cli exists in the app bundle"

pkill -x Quik 2>/dev/null || true
sleep 1
rm -f "$STATUS"
code=0
"$CLI" --json >/dev/null 2>&1 || code=$?
[ "$code" = "3" ] && echo "PASS missing status file exits 3" || { echo "FAIL missing file exit=$code"; fail=1; }

open -n "$APP"
sleep 5
[ -f "$STATUS" ] && echo "PASS app writes the status file" || { echo "FAIL status file missing"; fail=1; }

if [ -x "$HOME/.local/bin/quik" ]; then
  echo "PASS app installs the quik command into ~/.local/bin"
  cmp -s "$HOME/.local/bin/quik" "$CLI" \
    && echo "PASS installed command matches the bundle" \
    || { echo "FAIL installed command differs from the bundle"; fail=1; }
else
  echo "FAIL ~/.local/bin/quik missing after launch"; fail=1
fi

"$CLI" --json > "$JSON_OUT"
python3 -I - "$JSON_OUT" <<'EOF' || fail=1
import json, sys
j = json.load(open(sys.argv[1]))
assert j.get('schema') == 1, j.get('schema')
assert j.get('level') in ('fluid', 'sluggish', 'stalled'), j.get('level')
assert isinstance(j.get('summary'), str) and j['summary'], j.get('summary')
assert isinstance(j.get('culprits'), list), j.get('culprits')
assert isinstance(j.get('causes'), list), j.get('causes')
print('PASS json has schema, level, summary, causes, culprits')
EOF

TEXT="$("$CLI")"
case "$TEXT" in
  流畅*|有点卡*|卡住了*) echo "PASS text mode names the state first" ;;
  *) echo "FAIL unexpected text output: $TEXT"; fail=1 ;;
esac

age=$(python3 -I - "$JSON_OUT" <<'EOF'
import datetime, json, sys
j = json.load(open(sys.argv[1]))
at = datetime.datetime.fromisoformat(j['at'].replace('Z', '+00:00'))
print(int((datetime.datetime.now(datetime.timezone.utc) - at).total_seconds()))
EOF
)
[ "${age:-99}" -le 5 ] && echo "PASS snapshot is fresh (age ${age}s)" || { echo "FAIL snapshot age ${age}s"; fail=1; }

# Quit the way a user would so applicationWillTerminate runs; SIGTERM bypasses
# the delegate and would leave the status file behind by design.
if [ "$QUIK_WAS_RUNNING" = "0" ]; then
  osascript -e 'tell application "Quik" to quit' >/dev/null 2>&1 || pkill -x Quik
  sleep 6
  code=0
  "$CLI" --json >/dev/null 2>&1 || code=$?
  [ "$code" = "3" ] && echo "PASS quit app exits 3" || { echo "FAIL quit exit=$code"; fail=1; }
  [ ! -f "$STATUS" ] && echo "PASS quit removes the status file" || { echo "FAIL status file survived quit"; fail=1; }
fi

if [ "$fail" = "0" ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi
