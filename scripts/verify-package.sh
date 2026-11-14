#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-}"
if [ -z "$DMG" ]; then
  DMG="$(ls -t build/package/Quik-*.dmg 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
  echo "FAIL no DMG found; run scripts/package.sh or pass a DMG path" >&2
  exit 1
fi
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"

QUIK_WAS_RUNNING=0
pgrep -x Quik >/dev/null 2>&1 && QUIK_WAS_RUNNING=1
BEFORE_PIDS="$(pgrep -x Quik 2>/dev/null || true)"
MOUNT=""
TMPROOT=""
NEW_PIDS=""
MOUNTED=0
fail=0

cleanup() {
  if [ -n "$NEW_PIDS" ]; then
    for pid in $NEW_PIDS; do kill "$pid" >/dev/null 2>&1 || true; done
    sleep 1
    for pid in $NEW_PIDS; do kill -9 "$pid" >/dev/null 2>&1 || true; done
    NEW_PIDS=""
  fi
  if [ "$MOUNTED" = 1 ]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
    MOUNTED=0
  fi
  if [ -n "$MOUNT" ]; then rm -rf "$MOUNT"; fi
  if [ -n "$TMPROOT" ]; then rm -rf "$TMPROOT"; fi
  true
}
trap cleanup EXIT

pass() { echo "PASS $1"; }
warn() { echo "WARN $1"; }
failed() { echo "FAIL $1"; fail=1; }

MOUNT="$(mktemp -d /tmp/quik-verify-mount.XXXXXX)"
TMPROOT="$(mktemp -d /tmp/quik-verify-copy.XXXXXX)"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" >/dev/null
MOUNTED=1
APP="$MOUNT/Quik.app"
echo "dmg: $DMG"

if [ -d "$APP" ]; then pass "DMG contains Quik.app"; else failed "DMG is missing Quik.app"; fi
if [ -L "$MOUNT/Applications" ] && [ "$(readlink "$MOUNT/Applications")" = "/Applications" ]; then
  pass "DMG contains Applications -> /Applications"
else
  failed "DMG is missing the Applications symlink"
fi

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$BUNDLE_ID" = "dev.quik.app" ]; then
  pass "bundle id is dev.quik.app"
else
  failed "bundle id is '${BUNDLE_ID:-<missing>}', expected dev.quik.app"
fi

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Quik" 2>/dev/null || true)"
missing_arch=0
for arch in arm64 x86_64; do
  case " $ARCHS " in *" $arch "*) ;; *) missing_arch=1 ;; esac
done
if [ "$missing_arch" = 0 ]; then
  pass "architectures: $ARCHS"
else
  failed "missing arm64 or x86_64 (archs: ${ARCHS:-<missing>})"
fi

if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  pass "codesign --verify --deep --strict"
else
  failed "codesign --verify --deep --strict"
fi

GK_OUT="$(spctl -a -vv "$APP" 2>&1)" && GK_OK=1 || GK_OK=0
if [ "$GK_OK" = 1 ]; then
  pass "spctl accepts the app (notarized)"
  printf '%s\n' "$GK_OUT" | sed 's/^/  /'
else
  SIGNATURE="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p' || true)"
  if [ "$SIGNATURE" = "adhoc" ]; then
    warn "spctl rejects the ad-hoc signed app"
    printf '%s\n' "$GK_OUT" | sed 's/^/  /'
    echo "  first launch needs System Settings > Privacy & Security > Open Anyway"
  else
    failed "spctl rejects the app (signature: ${SIGNATURE:-<none>})"
    printf '%s\n' "$GK_OUT" | sed 's/^/  /'
  fi
fi

ditto "$APP" "$TMPROOT/Quik.app"
open -n "$TMPROOT/Quik.app"
tries=0
while [ "$tries" -lt 20 ] && [ -z "$NEW_PIDS" ]; do
  for pid in $(pgrep -x Quik 2>/dev/null || true); do
    case " $BEFORE_PIDS " in
      *" $pid "*) ;;
      *) NEW_PIDS="$NEW_PIDS $pid" ;;
    esac
  done
  NEW_PIDS="$(printf '%s\n' $NEW_PIDS | sort -u | tr '\n' ' ')"
  if [ -z "$NEW_PIDS" ]; then sleep 0.5; fi
  tries=$((tries + 1))
done

if [ -n "$NEW_PIDS" ]; then
  pass "packaged app launched (pid $(echo $NEW_PIDS))"
  for pid in $NEW_PIDS; do kill "$pid" >/dev/null 2>&1 || true; done
  sleep 1
  for pid in $NEW_PIDS; do kill -9 "$pid" >/dev/null 2>&1 || true; done
  NEW_PIDS=""
else
  failed "packaged app did not start a Quik process within 10s"
fi

if [ "$MOUNTED" = 1 ]; then
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  MOUNTED=0
fi

if [ "$QUIK_WAS_RUNNING" = 1 ]; then
  echo "Quik was running before; left it running"
else
  echo "Quik was not running before; no Quik process left"
fi
exit "$fail"
