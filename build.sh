#!/bin/sh
# Build FinderTerminal.app: compile via SwiftPM, assemble a bundle, codesign so
# macOS TCC (Accessibility / Automation) grants persist across rebuilds.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONF="${1:-debug}"
IDENTITY="${CODESIGN_IDENTITY:-Imperator Dev}"
APP="$ROOT/build/Imperator FinderTerminal.app"
BIN="$ROOT/.build/$CONF/FinderTerminal"

# Stamp the binary with an SDK newer than the deployment target, leaving the
# deployment target alone. AppKit picks which generation of every control to
# draw from the `sdk` field in LC_BUILD_VERSION, and SwiftPM otherwise stamps it
# with the deployment target from `platforms:` -- which made the app draw macOS
# 14 era controls on macOS 27, most visibly a switch with a round knob instead
# of the system's oval one. Verify with:
#   otool -l <binary> | awk '/LC_BUILD_VERSION/,/^$/' | grep -E "minos|sdk"
#
# 26.0, not the newest installed SDK. Stamped 27.0, every `NSHostingView` in
# this app redraws once from an `@AppStorage` change and then stops for the rest
# of the process: the value is written and acted on, the owning view's body runs
# with the new value, and its children are never asked for a body again, so the
# radios and switches keep showing whatever the first change left. It hits the
# Settings window as much as the menu bar panel; `SettingsView` only looks
# healthy because its `GeometryReader` preference loop forces a layout pass
# every time. Stamped 15.0 or 26.0 the same binary tracks every click. The panel
# and the switches render byte-identically under 26.0 and 27.0 (`cmp` on
# `screencapture -o -l` of each), so the newer stamp buys nothing and costs
# every control its redraw.
#
# Ruled out as the cause, each measured on its own: the panel's window traits
# (level, collection behaviour, `hidesOnDeactivate`, borderless, clear
# background, `NSPanel` vs `NSWindow`, `defer:`), the visual effect view, when
# the hosting view is built, `CloseGuard`'s event tap, the pre-warmed SwiftTerm
# session, the Carbon hotkey, the status item, the forced dark appearance and
# the accent override. A standalone SwiftUI app stamped 27.0 keeps redrawing
# with all of those, so the trigger is the stamp plus something still unnamed in
# this app.
SDK_VERSION="${SDK_VERSION:-26.0}"
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
