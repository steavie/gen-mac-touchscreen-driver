#!/bin/bash
# Baut das Installationspaket Touchscreen-Treiber.pkg.
#
# Hinweis: Das Paket ist UNSIGNIERT. Für ein von Gatekeeper akzeptiertes
# Paket bräuchte es ein "Developer ID Installer"-Zertifikat von Apple; ein
# selbstsigniertes Codesignatur-Zertifikat reicht dafür nicht. Beim
# Doppelklick warnt macOS deshalb - Rechtsklick auf das Paket und "Öffnen"
# wählen, dann lässt es sich installieren.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Touchscreen-Treiber"
IDENTIFIER="de.aronax.touchscreen-driver"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD_DIR="build"
STAGING="$BUILD_DIR/pkgroot"
PKG="$BUILD_DIR/$APP_NAME-$VERSION.pkg"

# App muss vorher gebaut sein
if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
    echo "App fehlt - erst ./build-app.sh ausführen." >&2
    exit 1
fi

rm -rf "$STAGING" "$PKG"
mkdir -p "$STAGING"
cp -R "$BUILD_DIR/$APP_NAME.app" "$STAGING/"

chmod +x pkg-scripts/postinstall

echo "Baue Paket (Version $VERSION) …"
pkgbuild \
    --root "$STAGING" \
    --install-location /Applications \
    --scripts pkg-scripts \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    "$PKG"

echo
echo "Inhalt:"
pkgutil --payload-files "$PKG" | head -5
echo
echo "Fertig: $(pwd)/$PKG"
echo
echo "Installation: Rechtsklick auf das Paket -> Öffnen (das Paket ist"
echo "unsigniert, ein Doppelklick würde von Gatekeeper blockiert)."
