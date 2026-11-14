#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Quik.xcodeproj -scheme Quik -configuration Release \
  -derivedDataPath build build | tail -3
APP="build/Build/Products/Release/Quik.app"
codesign --force --deep --sign - "$APP"
echo "built: $APP"
