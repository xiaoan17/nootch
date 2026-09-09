#!/bin/sh
# Assembles nootch.app from the release build and wraps it in an install DMG.
# Usage: packaging/build-app.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/packaging/Info.plist")"
APP_NAME="nootch"
DIST="$ROOT/dist"
STAGE="$DIST/dmgroot"

swift build -c release --package-path "$ROOT"

rm -rf "$DIST"
mkdir -p "$STAGE" "$DIST/$APP_NAME.app/Contents/MacOS" "$DIST/$APP_NAME.app/Contents/Resources"

cp "$ROOT/.build/release/$APP_NAME" "$DIST/$APP_NAME.app/Contents/MacOS/"
cp "$ROOT/packaging/Info.plist" "$DIST/$APP_NAME.app/Contents/"
# Change the resource name when the icon changes so an upgrade does not reuse
# the previous icon's resource name in Launch Services / Dock caches.
ICON_SOURCE="$ROOT/Sources/Nootch/Resources/Nootch.icns"
ICON_HASH="$(shasum -a 256 "$ICON_SOURCE" | cut -c 1-16)"
ICON_NAME="Nootch-$ICON_HASH.icns"
cp "$ICON_SOURCE" "$DIST/$APP_NAME.app/Contents/Resources/$ICON_NAME"
plutil -replace CFBundleIconFile -string "$ICON_NAME" "$DIST/$APP_NAME.app/Contents/Info.plist"
if [ -d "$ROOT/.build/release/${APP_NAME}_Nootch.bundle" ]; then
    cp -R "$ROOT/.build/release/${APP_NAME}_Nootch.bundle" "$DIST/$APP_NAME.app/Contents/Resources/"
fi

# Ad-hoc sign so Gatekeeper treats the bundle like the previous release.
codesign --force --deep --sign - "$DIST/$APP_NAME.app"

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$DIST/$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "nootch" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$APP_NAME-$VERSION.dmg"

echo "Built $DIST/$APP_NAME-$VERSION.dmg"
