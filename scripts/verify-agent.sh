#!/bin/bash
# Checks the agent surface end to end: a normal launch installs nothing, the
# opt-in install and remove actions converge on disk, and the bundled CLI reads
# the status file in both modes.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Quik.app"
CLI="$APP/Contents/Library/quik"
STATUS="$HOME/Library/Application Support/Quik/status.json"
SUPPORT="$HOME/Library/Application Support/Quik"
SKILL_RESOURCE="$APP/Contents/Resources/quik-skill.md"
ACTION=/tmp/quik-agent-action.txt
JSON_OUT=/tmp/quik-agent-check/status.json
fail=0

QUIK_WAS_RUNNING=0
pgrep -x Quik >/dev/null 2>&1 && QUIK_WAS_RUNNING=1

# The script drives the install off and on again, so remember whether the user
# had installed it. Leaving the machine in the default state is only correct
# for someone who started there.
RESTORE_INSTALL=0
if [ -f "$HOME/.agents/skills/quik/SKILL.md" ] \
  && [ -f "$HOME/.claude/skills/quik/SKILL.md" ] \
  && [ -x "$HOME/.local/bin/quik" ]; then
  RESTORE_INSTALL=1
fi

restore_install() {
  [ "$RESTORE_INSTALL" = "1" ] || return 0
  [ -x "$APP/Contents/Library/quik" ] || return 0
  rm -f "$ACTION"
  open -n --env QUIK_AGENT_ACTION=install "$APP" >/dev/null 2>&1 || true
  for _ in $(seq 1 100); do
    [ -f "$ACTION" ] && break
    perl -e 'select(undef,undef,undef,0.1)'
  done
  rm -f "$ACTION"
  pkill -x Quik 2>/dev/null || true
}

cleanup() {
  if [ "$QUIK_WAS_RUNNING" = "0" ]; then
    pkill -x Quik 2>/dev/null || true
  fi
  rm -rf "$HOME/.agents/skills/quik" "$HOME/.claude/skills/quik"
  rm -f "$HOME/.local/bin/quik"
  restore_install
  [ "$RESTORE_INSTALL" = "1" ] && echo "restored the install that was present before the run"
}
trap cleanup EXIT

mkdir -p /tmp/quik-agent-check

[ -x "$CLI" ] || { echo "FAIL cli missing at $CLI"; exit 1; }
echo "PASS cli exists in the app bundle"

pkill -x Quik 2>/dev/null || true
sleep 1
rm -rf "$HOME/.agents/skills/quik" "$HOME/.claude/skills/quik"
rm -f "$HOME/.local/bin/quik"
rm -f "$ACTION" "$STATUS"
code=0
"$CLI" --json >/dev/null 2>&1 || code=$?
[ "$code" = "3" ] && echo "PASS missing status file exits 3" || { echo "FAIL missing file exit=$code"; fail=1; }

open -n "$APP"
sleep 5
[ -f "$STATUS" ] && echo "PASS app writes the status file" || { echo "FAIL status file missing"; fail=1; }

if [ ! -e "$HOME/.agents/skills/quik" ] \
  && [ ! -e "$HOME/.claude/skills/quik" ] \
  && [ ! -e "$HOME/.local/bin/quik" ]; then
  echo "PASS default launch installs nothing"
else
  echo "FAIL default launch wrote into the home directory"; fail=1
fi

"$CLI" --json > "$JSON_OUT"
python3 -I - "$JSON_OUT" <<'EOF' || fail=1
import json, sys
j = json.load(open(sys.argv[1]))
assert j.get('schema') == 2, j.get('schema')
assert j.get('level') in ('fluid', 'sluggish', 'stalled'), j.get('level')
assert isinstance(j.get('summary'), str) and j['summary'], j.get('summary')
assert isinstance(j.get('culprits'), list), j.get('culprits')
assert isinstance(j.get('causes'), list), j.get('causes')
print('PASS json has schema, level, summary, causes, culprits')
EOF

TEXT="$("$CLI")"
# The status file's labels are the English agent contract by design, so text
# mode names the state in English; the Chinese names stay accepted in case the
# contract ever localizes again.
case "$TEXT" in
  Fluid*|Sluggish*|Stalled*|流畅*|有点卡*|卡住了*) echo "PASS text mode names the state first" ;;
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

# The install button is a SwiftUI control, so the app exposes the same code path
# through QUIK_AGENT_ACTION for this script.
pkill -x Quik 2>/dev/null || true
sleep 1
rm -f "$ACTION"
open -n --env QUIK_AGENT_ACTION=install "$APP"
for _ in $(seq 1 100); do
  [ -f "$ACTION" ] && break
  perl -e 'select(undef,undef,undef,0.1)'
done
[ "$(cat "$ACTION" 2>/dev/null)" = "install=1" ] \
  && echo "PASS install action ran" \
  || { echo "FAIL install action marker missing"; fail=1; }

for dir in ".agents/skills/quik" ".claude/skills/quik"; do
  if [ -f "$HOME/$dir/SKILL.md" ]; then
    echo "PASS install writes ~/$dir"
    cmp -s "$HOME/$dir/SKILL.md" "$SKILL_RESOURCE" \
      && echo "PASS ~/$dir matches the bundled skill" \
      || { echo "FAIL ~/$dir differs from the bundle"; fail=1; }
  else
    echo "FAIL skill missing at ~/$dir"; fail=1
  fi
done
if [ -x "$HOME/.local/bin/quik" ]; then
  echo "PASS install writes ~/.local/bin/quik"
  cmp -s "$HOME/.local/bin/quik" "$CLI" \
    && echo "PASS installed command matches the bundle" \
    || { echo "FAIL installed command differs from the bundle"; fail=1; }
else
  echo "FAIL ~/.local/bin/quik missing after install"; fail=1
fi

pkill -x Quik 2>/dev/null || true
sleep 1
rm -f "$ACTION"
open -n --env QUIK_AGENT_ACTION=remove "$APP"
for _ in $(seq 1 100); do
  [ -f "$ACTION" ] && break
  perl -e 'select(undef,undef,undef,0.1)'
done
[ "$(cat "$ACTION" 2>/dev/null)" = "remove=1" ] \
  && echo "PASS remove action ran" \
  || { echo "FAIL remove action marker missing"; fail=1; }

if [ ! -e "$HOME/.agents/skills/quik" ] \
  && [ ! -e "$HOME/.claude/skills/quik" ] \
  && [ ! -e "$HOME/.local/bin/quik" ]; then
  echo "PASS remove deletes the skill and the command"
else
  echo "FAIL remove left something behind"; fail=1
fi
[ -d "$SUPPORT" ] \
  && echo "PASS remove keeps the app data directory" \
  || { echo "FAIL remove deleted the app data directory"; fail=1; }

pkill -x Quik 2>/dev/null || true
sleep 1
if [ -e "$HOME/.agents/skills/quik" ] \
  || [ -e "$HOME/.claude/skills/quik" ] \
  || [ -e "$HOME/.local/bin/quik" ]; then
  echo "FAIL remove left files behind at the end of the run"; fail=1
elif [ "$RESTORE_INSTALL" = "1" ]; then
  echo "PASS remove clears the install (the earlier install is restored on exit)"
else
  echo "PASS machine left in the default state"
fi

if [ "$fail" = "0" ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi
