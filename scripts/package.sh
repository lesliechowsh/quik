#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Release/Quik.app"
PKG_DIR="build/package"
STAGE="$PKG_DIR/dmg-root"
SIGN_IDENTITY="${QUIK_SIGN_IDENTITY:-}"
REAL_IDENTITY=0
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  REAL_IDENTITY=1
fi
MOUNT=""

# Notarization credentials live in a file rather than the login keychain,
# because the keychain gets rebuilt and takes the profile with it.
NOTARY_ENV="${QUIK_NOTARY_ENV:-$HOME/.config/quik/notary.env}"
if [ -f "$NOTARY_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$NOTARY_ENV"
  set +a
fi
NOTARY_MODE="none"
if [ -n "${QUIK_NOTARY_APPLE_ID:-}" ] && [ -n "${QUIK_NOTARY_TEAM_ID:-}" ] && [ -n "${QUIK_NOTARY_PASSWORD:-}" ]; then
  NOTARY_MODE="env"
elif [ -n "${QUIK_NOTARY_PROFILE:-}" ]; then
  NOTARY_MODE="profile"
fi

# @env: keeps the password out of the process list; notarytool reads the
# variable itself.
NOTARY_ARGS=()
if [ "$NOTARY_MODE" = "env" ]; then
  NOTARY_ARGS=(--apple-id "$QUIK_NOTARY_APPLE_ID" --team-id "$QUIK_NOTARY_TEAM_ID" --password "@env:QUIK_NOTARY_PASSWORD")
elif [ "$NOTARY_MODE" = "profile" ]; then
  NOTARY_ARGS=(--keychain-profile "$QUIK_NOTARY_PROFILE")
fi

cleanup() {
  if [ -n "$MOUNT" ]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
    rm -rf "$MOUNT"
    MOUNT=""
  fi
  true
}
trap cleanup EXIT

# A credentials file that exists but is incomplete would silently ship an
# unnotarized build, so treat it as an error rather than a no-op.
if [ -f "$NOTARY_ENV" ] && [ "$NOTARY_MODE" = "none" ]; then
  echo "$NOTARY_ENV exists but is incomplete; fill in QUIK_NOTARY_APPLE_ID and QUIK_NOTARY_PASSWORD" >&2
  exit 1
fi

# notarytool blocks on a prompt when the credentials are missing instead of
# failing, which once cost an hour of a release run. Check them before the
# build starts, with stdin closed so a prompt cannot hang.
if [ "$NOTARY_MODE" != "none" ]; then
  [ "$REAL_IDENTITY" = 1 ] || {
    echo "notarization is configured but QUIK_SIGN_IDENTITY is not a Developer ID identity" >&2
    exit 1
  }
  if ! xcrun notarytool history "${NOTARY_ARGS[@]}" </dev/null >/dev/null 2>&1; then
    echo "notary credentials are missing or rejected; nothing was built" >&2
    echo "fill in $NOTARY_ENV (QUIK_NOTARY_APPLE_ID, QUIK_NOTARY_TEAM_ID, QUIK_NOTARY_PASSWORD)" >&2
    exit 1
  fi
fi

mkdir -p "$PKG_DIR"
rm -rf "$STAGE"
xcodegen generate >/dev/null

BUILD_LOG="$PKG_DIR/xcodebuild.log"
if ! xcodebuild -project Quik.xcodeproj -scheme Quik -configuration Release \
  -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build \
  >"$BUILD_LOG" 2>&1; then
  tail -n 80 "$BUILD_LOG" >&2
  echo "universal Release build failed; full log: $BUILD_LOG" >&2
  exit 1
fi
[ -d "$APP" ] || { echo "build succeeded but $APP is missing" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ -n "$VERSION" ] || { echo "missing CFBundleShortVersionString in built app" >&2; exit 1; }
DMG="$PKG_DIR/Quik-$VERSION.dmg"
ZIP="$PKG_DIR/Quik-$VERSION.zip"

# Defense in depth: no DWARF in shipped binaries, so machine paths can never
# travel inside them even if a build setting changes later. Runs before
# signing because any later change to the binary breaks the signature.
strip -S "$APP/Contents/MacOS/Quik" "$APP/Contents/Library/quik"

if [ "$REAL_IDENTITY" = 1 ]; then
  # codesign --deep re-signs only the nested locations it knows (Frameworks,
  # PlugIns, XPCServices). The CLI sits in Contents/Library, so it needs an
  # explicit Developer ID signature before the outer bundle seals over it.
  if [ -f "$APP/Contents/Library/quik" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP/Contents/Library/quik"
  fi
  codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
else
  if [ -f "$APP/Contents/Library/quik" ]; then
    codesign --force --sign - "$APP/Contents/Library/quik"
  fi
  codesign --force --deep --sign - "$APP"
fi

BUILT_ARCHS="$(lipo -archs "$APP/Contents/MacOS/Quik")"
for arch in arm64 x86_64; do
  case " $BUILT_ARCHS " in
    *" $arch "*) ;;
    *) echo "FAIL missing $arch slice (archs: $BUILT_ARCHS)" >&2; exit 1 ;;
  esac
done

mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Quik.app"
ln -s /Applications "$STAGE/Applications"
if [ "$REAL_IDENTITY" = 1 ]; then
cat > "$STAGE/安装说明.txt" <<'EOF'
Quik 安装说明

1. 把 Quik 拖到右边的 Applications 文件夹。
2. 从 Applications 打开 Quik。这个安装包已通过 Apple 公证，可以直接打开。

Install

1. Drag Quik into the Applications folder.
2. Open Quik from Applications. This build is notarized by Apple and opens directly.
EOF
else
cat > "$STAGE/安装说明.txt" <<'EOF'
Quik 安装说明

1. 把 Quik 拖到右边的 Applications 文件夹。
2. 从 Applications 打开 Quik。
3. 第一次打开时 macOS 会提示无法验证开发者。这个版本没有做 Apple 公证，提示是正常的。
   打开「系统设置 > 隐私与安全性」，在「安全性」一栏点「仍要打开」，再确认一次。
   macOS 14 上可以右键 Quik，选择「打开」。
4. 之后打开不会再提示。

Install

1. Drag Quik into the Applications folder.
2. Open Quik from Applications.
3. The first launch warns that the developer cannot be verified. This build is not notarized.
   Open System Settings > Privacy & Security, click "Open Anyway" in the Security section, then confirm.
   On macOS 14, Control-click Quik and choose Open.
4. Later launches do not ask.
EOF
fi

rm -f "$DMG" "$ZIP"
# SHA256SUMS is written at the very end, after stapling changes the DMG. Delete
# any stale list now so a run that fails midway cannot leave last version's
# checksums behind for a release to pick up.
rm -f "$PKG_DIR/SHA256SUMS"
hdiutil create -volname Quik -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$NOTARY_MODE" != "none" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  SUBMIT_OUT="$(xcrun notarytool submit "$DMG" --wait "${NOTARY_ARGS[@]}" </dev/null 2>&1)" || {
    echo "$SUBMIT_OUT" >&2
    echo "notarytool submit failed" >&2
    exit 1
  }
  echo "$SUBMIT_OUT"
  if ! printf '%s\n' "$SUBMIT_OUT" | grep -q "status: Accepted"; then
    echo "notarization did not finish Accepted" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG" || { echo "stapler staple failed" >&2; exit 1; }
fi

(cd "$PKG_DIR" && shasum -a 256 "Quik-$VERSION.dmg" "Quik-$VERSION.zip" > SHA256SUMS)

if ! codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo "FAIL codesign --verify --deep --strict" >&2
  exit 1
fi

MOUNT="$(mktemp -d /tmp/quik-dmg.XXXXXX)"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" >/dev/null
[ -d "$MOUNT/Quik.app" ] || { echo "FAIL DMG is missing Quik.app" >&2; exit 1; }
[ -f "$MOUNT/安装说明.txt" ] || { echo "FAIL DMG is missing the install note" >&2; exit 1; }
if [ ! -L "$MOUNT/Applications" ] || [ "$(readlink "$MOUNT/Applications")" != "/Applications" ]; then
  echo "FAIL DMG is missing the Applications symlink" >&2
  exit 1
fi
# spctl on the DMG itself reports "does not seem to be an app"; assess the app
# inside, which is what Gatekeeper checks when the user opens it.
APP_GK_OK=0
APP_GK_OUT="$(spctl -a -vv "$MOUNT/Quik.app" 2>&1)" && APP_GK_OK=1 || true
hdiutil detach "$MOUNT" >/dev/null
rm -rf "$MOUNT"
MOUNT=""

echo "version: $VERSION"
echo "architectures: $BUILT_ARCHS"
echo "DMG: $(pwd)/$DMG ($(du -h "$DMG" | awk '{print $1}'))"
echo "ZIP: $(pwd)/$ZIP ($(du -h "$ZIP" | awk '{print $1}'))"
echo "checksums: $(pwd)/$PKG_DIR/SHA256SUMS"
if [ "$APP_GK_OK" = 1 ]; then
  echo "gatekeeper: accepted"
else
  echo "gatekeeper: rejected"
  printf '%s\n' "$APP_GK_OUT" | sed 's/^/  /'
fi
if [ "$REAL_IDENTITY" != 1 ]; then
  echo "First launch needs System Settings > Privacy & Security > Open Anyway."
fi
