#!/bin/bash
# Builds the installer package Touchscreen-Treiber.pkg.
#
# Note: the package is UNSIGNED. A Gatekeeper-accepted package would need a
# "Developer ID Installer" certificate from Apple; a self-signed code signing
# certificate is not enough. macOS therefore warns on a double click — use
# right click → Open instead.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Touchscreen-Treiber"
IDENTIFIER="de.aronax.touchscreen-driver"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD_DIR="build"
STAGING="$BUILD_DIR/pkgroot"
PKG="$BUILD_DIR/$APP_NAME-$VERSION.pkg"

# the app has to be built first
if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
    echo "App missing — run ./build-app.sh first." >&2
    exit 1
fi

rm -rf "$STAGING" "$PKG"
mkdir -p "$STAGING"
cp -R "$BUILD_DIR/$APP_NAME.app" "$STAGING/"

chmod +x pkg-scripts/postinstall

echo "Building package (version $VERSION) …"
pkgbuild \
    --root "$STAGING" \
    --install-location /Applications \
    --scripts pkg-scripts \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    "$PKG"

echo
echo "Contents:"
pkgutil --payload-files "$PKG" | head -5
echo
echo "Done: $(pwd)/$PKG"
echo
echo "To install: right click the package -> Open (it is unsigned, so a"
echo "double click would be blocked by Gatekeeper)."
