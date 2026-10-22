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
# Which certificate to sign with.
#
# A Developer ID Application certificate is what lets another Mac open this
# without being told to; it also has to be paired with the hardened runtime and
# a secure timestamp, or notarisation refuses the submission. Without one we
# fall back to the local certificate, which is enough for this Mac and keeps
# the permission grant stable across rebuilds, but no other Mac will accept it.
#
# PULT_IDENTITY overrides the search, for a machine with more than one.
LOCAL_CERT="akp03-deck local signing"

if [ -n "${PULT_IDENTITY:-}" ]; then
	CERT_NAME="$PULT_IDENTITY"
	RELEASE=1
elif security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
	CERT_NAME="$(security find-identity -v -p codesigning \
		| grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')"
	RELEASE=1
else
	CERT_NAME="$LOCAL_CERT"
	RELEASE=0
fi

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

# The interface is set in Inter, registered from here at launch.
mkdir -p "$APP/Contents/Resources/Fonts"
cp app/Sources/Pult/Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
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

	<key>UTExportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>dev.pult.keyslot</string>
			<key>UTTypeDescription</key>
			<string>Pult key</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.data</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "==> signing as: $CERT_NAME"
# The hardened runtime and a secure timestamp are what notarisation requires;
# neither is any use without a Developer ID, and the timestamp needs the
# network, so a local build does without both.
#
# No entitlements file. The daemon talks to a HID device and posts key events,
# and neither needs one: this is not sandboxed, so device access is open, and
# pressing keys is governed by the Accessibility grant rather than by an
# entitlement. Asking for entitlements it does not need would only widen what
# the signature claims.
if [ "$RELEASE" = "1" ]; then
	SIGN_FLAGS="--options runtime --timestamp"
else
	SIGN_FLAGS=""
fi

# Inside out: a nested binary signed after its container invalidates the
# container's seal.
# The daemon carries its own identifier: that identifier is half of the
# requirement macOS remembers when you allow it to send keystrokes.
codesign --force --sign "$CERT_NAME" $SIGN_FLAGS --identifier dev.pult.daemon \
	"$APP/Contents/MacOS/pultd"
codesign --force --sign "$CERT_NAME" $SIGN_FLAGS --identifier dev.pult.Pult \
	"$APP/Contents/MacOS/Pult"
codesign --force --sign "$CERT_NAME" $SIGN_FLAGS --identifier dev.pult.Pult "$APP"
codesign --verify --deep --verbose=1 "$APP"

if [ "$RELEASE" = "1" ]; then
	echo
	echo "signed for distribution; now have it notarised:"
	echo "    scripts/notarize.sh"
	echo
	echo "NOTE: the signature changed, so the permission macOS remembers no"
	echo "longer applies. Tick pultd once more under System Settings >"
	echo "Privacy & Security > Device Control and Data Access. It then holds"
	echo "for every later build signed with the same certificate."
fi

echo
echo "built $APP"
