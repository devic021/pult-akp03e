#!/bin/sh
# Packs Pult.app into a disk image you can hand to someone.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Pult.app"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"
DMG="$DIST/Pult-$VERSION.dmg"

[ -d "$APP" ] || "$ROOT/scripts/build-app.sh"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
# The usual drag-to-install arrangement.
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read me.txt" <<'NOTE'
Pult

1. Drag Pult into Applications.
2. Open it. It will offer to start the background service that drives the dock.
3. Keys bound to a keystroke need permission: System Settings >
   Privacy & Security > Device Control and Data Access (called Accessibility
   before macOS 27). Tick pultd there.

The dock itself stores nothing but its boot logo; everything else lives on
this Mac, in ~/.config/pult/config.toml.
NOTE

rm -f "$DMG"
hdiutil create \
	-volname "Pult" \
	-srcfolder "$STAGE" \
	-ov -format UDZO \
	"$DMG" >/dev/null

echo "built $DMG"
ls -lh "$DMG" | awk '{print $5, $9}'
