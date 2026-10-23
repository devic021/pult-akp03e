#!/bin/sh
# Builds Pult.app: the SwiftUI front end with the daemon inside it.
#
# The daemon lives in the bundle rather than beside it so that macOS ties the
# Accessibility grant to a path that moves with the app, and so a DMG can ship
# one thing instead of two.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"

# PULT_DEBUG=1 builds the unoptimised binaries into a bundle of their own, so
# a change can be looked at in a real window — with the Info.plist that
# location and the icon need — without disturbing the installed copy or
# spending two minutes on an optimised build nobody is going to keep.
if [ -n "${PULT_DEBUG:-}" ]; then
	APP="$DIST/Pult-debug.app"
	PROFILE="debug"
	CARGO_FLAGS=""
	SWIFT_FLAGS=""
else
	APP="$DIST/Pult.app"
	PROFILE="release"
	CARGO_FLAGS="--release"
	SWIFT_FLAGS="-c release"
fi
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

if [ -n "${PULT_DEBUG:-}" ]; then
	CERT_NAME="${PULT_IDENTITY:-$LOCAL_CERT}"
	if [ -z "${PULT_IDENTITY:-}" ] \
		&& security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
		CERT_NAME="$(security find-identity -v -p codesigning \
			| grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')"
	fi
	RELEASE=0
elif [ -n "${PULT_IDENTITY:-}" ]; then
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
echo "==> daemon ($PROFILE)"
cargo build $CARGO_FLAGS --quiet

echo "==> app ($PROFILE)"
(cd app && swift build $SWIFT_FLAGS --quiet)

echo "==> icon"
ICONSET="$DIST/Pult.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
"./target/$PROFILE/mkicon" "$ICONSET" >/dev/null

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Without this the build output shows up in Spotlight and Launchpad as a
# second copy of the app, next to the one in /Applications.
touch "$DIST/.metadata_never_index"

cp "app/.build/$PROFILE/Pult" "$APP/Contents/MacOS/Pult"
cp "target/$PROFILE/pultd" "$APP/Contents/MacOS/pultd"
# The vitals helper rides along beside the daemon. A shell feed names it as
# {bin}/vitals, which the daemon fills in from its own path, so the app works
# wherever it has been dragged.
cp "target/$PROFILE/vitals" "$APP/Contents/MacOS/vitals"
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

	<!-- Only ever asked for when somebody presses "find me" on the Feeds
	     pane, and only to a kilometre: the weather hosts round to a grid of
	     their own, and the coordinates can always be typed in by hand
	     instead. -->
	<key>NSLocationWhenInUseUsageDescription</key>
	<string>Pult asks where you are so the dock can show your local weather. Nothing leaves this Mac but a latitude and longitude rounded to about a hundred metres, sent to the open-meteo weather service.</string>

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
codesign --force --sign "$CERT_NAME" $SIGN_FLAGS --identifier dev.pult.vitals \
	"$APP/Contents/MacOS/vitals"
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
