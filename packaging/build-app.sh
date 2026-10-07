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
# The resource bundle is not optional: without it every logo and the app icon
# silently disappear. Fail here rather than shipping a DMG that is missing them.
BUNDLE="$ROOT/.build/release/${APP_NAME}_Nootch.bundle"
if [ ! -d "$BUNDLE" ]; then
    echo "error: $BUNDLE not found; cannot package without resources" >&2
    exit 1
fi
# Keep resources under Contents/Resources. Placing the bundle at the app root to
# satisfy SwiftPM's Bundle.module would leave unsealed contents there, which
# invalidates the signature and stops Keychain "Always Allow" from ever
# sticking. ResourceBundle.swift looks here instead.
cp -R "$BUNDLE" "$DIST/$APP_NAME.app/Contents/Resources/"

# DSH uses multi-frame Zstandard. Bundle the public libzstd ABI so the installed
# app works without Homebrew/Node. Override for Intel or custom build machines.
ZSTD_LIBRARY_PATH="${ZSTD_LIBRARY_PATH:-/opt/homebrew/lib/libzstd.1.dylib}"
if [ ! -f "$ZSTD_LIBRARY_PATH" ]; then
    echo "error: set ZSTD_LIBRARY_PATH to a libzstd.1.dylib for this architecture" >&2
    exit 1
fi
mkdir -p "$DIST/$APP_NAME.app/Contents/Frameworks"
cp -L "$ZSTD_LIBRARY_PATH" "$DIST/$APP_NAME.app/Contents/Frameworks/libzstd.1.dylib"
install_name_tool -id '@rpath/libzstd.1.dylib' "$DIST/$APP_NAME.app/Contents/Frameworks/libzstd.1.dylib"
cp "$ROOT/packaging/ZSTD-LICENSE" "$DIST/$APP_NAME.app/Contents/Resources/ZSTD-LICENSE"

# Sign with a real Developer ID when one is available, so the app has a stable
# code signing identity across releases. Keychain ACL entries are keyed on that
# identity; an ad-hoc signature falls back to the binary's cdhash, which changes
# on every build and silently voids any previous "Always Allow" grant.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
# Sign executable dependencies before sealing the enclosing app.
if [ "$CODESIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$DIST/$APP_NAME.app/Contents/Frameworks/libzstd.1.dylib"
else
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$DIST/$APP_NAME.app/Contents/Frameworks/libzstd.1.dylib"
fi
# --deep is deprecated by Apple and unnecessary here: the only nested bundle is
# nootch_Nootch.bundle, which holds resources and no executable code, so it is
# covered by the app's own resource seal.
if [ "$CODESIGN_IDENTITY" = "-" ]; then
    # Ad-hoc, as before. The hardened runtime is skipped here because it only
    # buys anything alongside notarization, which needs a real identity.
    codesign --force --sign - "$DIST/$APP_NAME.app"
else
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$DIST/$APP_NAME.app"
fi
# A bundle that fails verification has no usable code requirement, so Keychain
# prompts return on every read. Catch that here instead of in the wild.
codesign --verify --strict --verbose=2 "$DIST/$APP_NAME.app"

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$DIST/$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "nootch" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$APP_NAME-$VERSION.dmg"

echo "Built $DIST/$APP_NAME-$VERSION.dmg"
