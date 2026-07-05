#!/bin/bash
# Build the SpriteKit wallpaper with Command Line Tools only (no full Xcode, no SwiftPM —
# SPM's manifest step is broken under CLT, so we invoke swiftc directly). Wraps the binary
# into a runnable .app bundle. Run this ON THE MAC (it needs the macOS SDK).
#   ./build.sh [run]      # build; pass "run" to relaunch the app afterwards
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build
swiftc -O \
    -o .build/Spyhop \
    Sources/Spyhop/*.swift \
    -framework AppKit -framework SpriteKit \
    -target arm64-apple-macosx13.0

# App icon: render the tray whale onto an ocean gradient .icns (needs iconutil).
swiftc -O -o .build/generate-icon generate-icon.swift -framework AppKit
.build/generate-icon .build/AppIcon.icns

APP="Spyhop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/Spyhop "$APP/Contents/MacOS/Spyhop"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $(pwd)/$APP"

if [ "${1:-}" = "run" ]; then
    pkill -x Spyhop 2>/dev/null || true
    sleep 0.5
    open "$APP"
    echo "launched Spyhop.app"
fi
