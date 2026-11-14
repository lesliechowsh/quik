#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Build/Products/Release/Quik.app"
[ -d "$APP" ] || { echo "run scripts/build.sh first" >&2; exit 1; }
pkill -x Quik 2>/dev/null || true
open "$APP"
echo "launched: $APP"
