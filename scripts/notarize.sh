#!/bin/sh
# Has Apple notarise the app and the disk image, then staples both.
#
# Notarisation is what lets a Mac that has never seen your certificate open
# this without being argued with. It is a separate step from signing: Apple
# scans the binary, and on success issues a ticket.
#
# Both get stapled, not just the image. Stapling the image alone leaves the
# application without a ticket of its own once it is dragged out, so a Mac that
# is offline the first time it opens it has nothing to check against and
# refuses. Stapling both costs one extra submission and removes that case.
#
# Before the first run, store the credentials once:
#
#     xcrun notarytool store-credentials pult \
#         --apple-id <your Apple ID> \
#         --team-id <your team id> \
#         --password <app-specific password>
#
# The password is not your Apple ID password: make one at
# appleid.apple.com > Sign-In and Security > App-Specific Passwords.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Pult.app"
PROFILE="${PULT_NOTARY_PROFILE:-pult}"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"
DMG="$DIST/Pult-$VERSION.dmg"

[ -d "$APP" ] || "$ROOT/scripts/build-app.sh"

# --verbose=2, not the default: `codesign -dv` on its own stops short of the
# Authority lines, so this read a correctly signed build as unsigned and
# refused to submit it.
if ! codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Developer ID Application"; then
	echo "This build is not signed with a Developer ID Application certificate," >&2
	echo "so there is nothing Apple will notarise. Create one in Xcode under" >&2
	echo "Settings > Accounts > Manage Certificates > + > Developer ID" >&2
	echo "Application, then build again." >&2
	exit 1
fi

echo "==> notarising the app"
ZIP="$DIST/Pult.zip"
rm -f "$ZIP"
# ditto, not zip: a plain zip loses the symlinks and extended attributes a
# bundle needs, and the submission is rejected for a damaged archive.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "==> rebuilding the disk image around the stapled app"
"$ROOT/scripts/make-dmg.sh"

echo "==> notarising the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo
echo "==> checking it the way another Mac will"
spctl --assess --type open --context context:primary-signature -vv "$DMG" || true
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$DMG"

echo
echo "done: $DMG"
