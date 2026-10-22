#!/bin/sh
# Builds Pult.app: the SwiftUI front end with the daemon inside it.
#
# The daemon lives in the bundle rather than beside it so that macOS ties the
# Accessibility grant to a path that moves with the app, and so a DMG can ship
# one thing instead of two.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Pult.app"
CERT_NAME="akp03-deck local signing"

cd "$ROOT"
echo "==> daemon"
cargo build --release --quiet

echo "==> app"
(cd app && swift build -c release --quiet)

echo "==> icon"
ICONSET="$DIST/Pult.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
./target/release/mkicon "$ICONSET" >/dev/null

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Without this the build output shows up in Spotlight and Launchpad as a
# second copy of the app, next to the one in /Applications.
touch "$DIST/.metadata_never_index"

cp app/.build/release/Pult "$APP/Contents/MacOS/Pult"
cp target/release/pultd "$APP/Contents/MacOS/pultd"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Pult</string>
	<key>CFBundleDisplayName</key>
	<string>Pult</string>
	<key>CFBundleIdentifier</key>
	<string>dev.pult.Pult</string>
	<key>CFBundleExecutable</key>
	<string>Pult</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Pult</string>
</dict>
</plist>
PLIST

echo "==> signing"
# The daemon is signed with its own identifier: that identifier is half of the
# requirement macOS remembers when you allow it to send keystrokes.
codesign --force --sign "$CERT_NAME" --identifier dev.pult.daemon \
	"$APP/Contents/MacOS/pultd"
codesign --force --sign "$CERT_NAME" --identifier dev.pult.Pult \
	"$APP/Contents/MacOS/Pult"
codesign --force --sign "$CERT_NAME" --identifier dev.pult.Pult "$APP"
codesign --verify --deep --verbose=1 "$APP"

echo
echo "built $APP"
