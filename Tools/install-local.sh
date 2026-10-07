#!/bin/sh
# Install the already-built, verified app with an automatic rollback backup.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$ROOT/dist/nootch.app"
TARGET="/Applications/nootch.app"
STAGED="/Applications/.nootch-install-$$.app"
BACKUP="$(mktemp -d /tmp/nootch-backup.XXXXXX)"
codesign --verify --strict "$BUILT"
# A leftover directory is never reused or overwritten.
if [ -e "$STAGED" ]; then echo "staging path already exists" >&2; exit 1; fi
/usr/bin/ditto "$BUILT" "$STAGED"
codesign --verify --strict "$STAGED"
rollback() {
    if [ ! -d "$TARGET" ] && [ -d "$BACKUP/nootch.app" ]; then
        mv "$BACKUP/nootch.app" "$TARGET"
        open "$TARGET"
    fi
    if [ -d "$STAGED" ]; then rm -rf "$STAGED"; fi
}
trap rollback EXIT
# Stop only this installed app, not other Swift binaries or agent processes.
for APP_PID in $(pgrep -f '^/Applications/nootch\.app/Contents/MacOS/nootch($| )' || true); do
    kill "$APP_PID"
done
if [ -d "$TARGET" ]; then mv "$TARGET" "$BACKUP/nootch.app"; fi
mv "$STAGED" "$TARGET"
codesign --verify --strict "$TARGET"
printf '%s\n' "$BACKUP/nootch.app" > "$ROOT/.build/last-install-backup.txt"
open "$TARGET"
printf 'Installed: %s\nBackup: %s/nootch.app\n' "$TARGET" "$BACKUP"
