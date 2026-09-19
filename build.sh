#!/bin/sh
# Build FinderTerminal.app: compile via SwiftPM, assemble a bundle, codesign so
# macOS TCC (Accessibility / Automation) grants persist across rebuilds.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONF="${1:-debug}"
IDENTITY="${CODESIGN_IDENTITY:-Imperator Dev}"
APP="$ROOT/build/Imperator FinderTerminal.app"
BIN="$ROOT/.build/$CONF/FinderTerminal"

# Stamp the binary with the newest installed SDK while leaving the deployment
# target alone. AppKit picks which generation of every control to draw from the
# `sdk` field in LC_BUILD_VERSION, and SwiftPM otherwise stamps it with the
# deployment target from `platforms:` -- which made the app draw macOS 14 era
# controls on macOS 27, most visibly a switch with a round knob instead of the
# system's oval one. Read the version rather than hardcoding it, so the next
# macOS needs no edit here. Verify with:
#   otool -l <binary> | awk '/LC_BUILD_VERSION/,/^$/' | grep -E "minos|sdk"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_VERSION="14.0"

swift build --package-path "$ROOT" -c "$CONF" \
    -Xlinker -platform_version -Xlinker macos \
    -Xlinker "$MIN_VERSION" -Xlinker "$SDK_VERSION"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FinderTerminal"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# SwiftTerm's Metal renderer loads its shader from the SPM resource bundle, so it
# has to travel with the app.
for b in "$ROOT/.build/$CONF"/*_SwiftTerm.bundle; do
    [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

codesign --force --sign "$IDENTITY" \
    --entitlements "$ROOT/Resources/FinderTerminal.entitlements" \
    "$APP"

echo "Built $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority" || true
otool -l "$APP/Contents/MacOS/FinderTerminal" \
    | awk '/LC_BUILD_VERSION/,/^$/' | grep -E "minos|sdk" || true
