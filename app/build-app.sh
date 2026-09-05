#!/bin/bash
# Builds Touchscreen-Treiber.app from the sources in Sources/.
#
# -swift-version 5 is required: the IOHIDManager and CoreGraphics callbacks are
# C function pointers and cannot capture anything, so they reach global
# variables. Swift 6 would treat that as a concurrency violation.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Touchscreen-Treiber"
EXECUTABLE="TouchscreenDriver"
SIGN_IDENTITY="${SIGN_IDENTITY:-Aronax Local Codesign}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"

echo "Compiling …"
swiftc -swift-version 5 -O \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/$EXECUTABLE" \
    -framework Cocoa \
    -framework IOKit \
    -framework ServiceManagement

echo "Signing with '$SIGN_IDENTITY' …"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"

echo
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Format|Signature|Authority" || true
echo
echo "Designated requirement:"
codesign -d -r- "$APP" 2>&1 | tail -1
echo
echo "Done: $(pwd)/$APP"
