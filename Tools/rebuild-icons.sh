#!/bin/sh
# Regenerate NootchIcon.png (source) and Nootch.icns (all sizes) from the
# existing source image, applying a proper macOS squircle mask.
#
# Usage: Tools/rebuild-icons.sh <source-image.png>
#
# Requires make-squircle-icon.swift (sibling script) and `iconutil` (macOS).

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/Sources/Nootch/Resources/NootchIcon.png}"
RES="$ROOT/Sources/Nootch/Resources"
TOOL="$ROOT/Tools/make-squircle-icon.swift"

if [ ! -f "$SRC" ]; then
    echo "source image not found: $SRC" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 1. Generate 1024×1024 masked source PNG (used by SwiftUI at runtime).
swift "$TOOL" "$SRC" "$STAGE/NootchIcon.png" 1024

# 2. Build a full iconset directory with every size macOS wants for .icns.
ICONSET="$STAGE/Nootch.iconset"
mkdir -p "$ICONSET"

# name             pixel-size
sizes="
icon_16x16.png    16
icon_16x16@2x.png 32
icon_32x32.png    32
icon_32x32@2x.png 64
icon_128x128.png  128
icon_128x128@2x.png 256
icon_256x256.png  256
icon_256x256@2x.png 512
icon_512x512.png  512
icon_512x512@2x.png 1024
"

# Render each size from the ORIGINAL source (not the 1024 masked one) so the
# squircle is drawn cleanly at each resolution — avoids compounded scaling
# artifacts.
echo "$sizes" | while read name size; do
    [ -z "$name" ] && continue
    swift "$TOOL" "$SRC" "$ICONSET/$name" "$size" >/dev/null
done

# 3. Compile into .icns.
iconutil -c icns "$ICONSET" -o "$STAGE/Nootch.icns"

# 4. Install into resources.
cp "$STAGE/NootchIcon.png" "$RES/NootchIcon.png"
cp "$STAGE/Nootch.icns"    "$RES/Nootch.icns"

echo "✅ Rebuilt icons from $SRC"
ls -la "$RES/NootchIcon.png" "$RES/Nootch.icns"
