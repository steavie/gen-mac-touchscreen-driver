#!/bin/bash
# Baut Touchscreen-Treiber.app aus den Quellen in Sources/.
#
# -swift-version 5 ist nötig: die C-Callbacks von IOHIDManager und
# CoreGraphics sind Funktionszeiger und können nichts einfangen, greifen also
# auf globale Variablen zu. Swift 6 würde das als Concurrency-Verstoß werten.
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

echo "Kompiliere …"
swiftc -swift-version 5 -O \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/$EXECUTABLE" \
    -framework Cocoa \
    -framework IOKit \
    -framework ServiceManagement

echo "Signiere mit '$SIGN_IDENTITY' …"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"

echo
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Format|Signature|Authority" || true
echo
echo "Designated Requirement:"
codesign -d -r- "$APP" 2>&1 | tail -1
echo
echo "Fertig: $(pwd)/$APP"
