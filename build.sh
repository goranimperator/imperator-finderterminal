#!/bin/sh
# Build FinderTerminal.app: compile via SwiftPM, assemble a bundle, codesign so
# macOS TCC (Accessibility / Automation) grants persist across rebuilds.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONF="${1:-debug}"
IDENTITY="${CODESIGN_IDENTITY:-Imperator Dev}"
APP="$ROOT/build/Imperator FinderTerminal.app"
BIN="$ROOT/.build/$CONF/FinderTerminal"

swift build --package-path "$ROOT" -c "$CONF"

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
