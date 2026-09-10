#!/bin/sh
#
# Build and package a release as a disk image, without notarizing.
#
# Used for ad-hoc releases, which are what this project publishes until there is
# a Developer ID certificate. tools/notarize.sh produces a notarized image and
# uses the same builder.
#
# The packaging here is careful for a specific reason. The v1.1 release was a zip
# made by `zip`/`unzip`, which store extended attributes as AppleDouble `._*`
# entries; those reappear inside the bundle on unpacking, and any added file
# invalidates the code signature. `codesign --verify` on a downloaded v1.1 app
# reported "a sealed resource is missing or invalid". This script therefore
# mounts its own output and checks the signature survived and that no files were
# added, which is the check that would have caught it.

set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

APP="$HERE/build/DeepSeek Harness.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || true)
[ -n "$VERSION" ] || {
	echo "error: could not read the bundle version; run ./build.sh first" >&2
	exit 1
}

DMG="$HERE/build/dsh-mac-$VERSION.dmg"
STABLE="$HERE/build/dsh-mac.dmg"
SUMS="$HERE/build/SHA256SUMS"

echo "==> packaging DeepSeek Harness $VERSION"

# The bundle has to be sound before it is worth distributing: a broken signature
# here is a broken signature for everyone who downloads it.
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
	echo "error: the built app does not have a valid signature" >&2
	codesign --verify --verbose=4 "$APP" >&2 || true
	exit 1
fi
echo "  [ ok ] signature verifies"

if xattr -r "$APP" 2>/dev/null | grep -q "com.apple.quarantine"; then
	echo "error: the bundle carries a quarantine flag" >&2
	exit 1
fi
echo "  [ ok ] no quarantine flag"

for stale in "$DMG" "$STABLE" "$SUMS"; do rm -f "$stale"; done

"$HERE/tools/make-dmg.sh" "$APP" "$DMG"

# A stable name means a download URL does not have to know the version, which
# is what the README one-liner relies on.
cp "$DMG" "$STABLE"

# ── prove the round trip ─────────────────────────────────────────────────────
# Mount the image the way a user will and confirm the app inside is intact.

MOUNT=$(mktemp -d)
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rm -rf "$MOUNT"' EXIT INT TERM

hdiutil attach "$STABLE" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null

UNPACKED="$MOUNT/DeepSeek Harness.app"
if [ ! -d "$UNPACKED" ]; then
	echo "error: the image does not contain the app bundle" >&2
	exit 1
fi

if ! codesign --verify --deep --strict "$UNPACKED" 2>/dev/null; then
	echo "error: the signature does not survive the disk image" >&2
	codesign --verify --verbose=4 "$UNPACKED" >&2 || true
	exit 1
fi

ADDED=$(find "$UNPACKED" \( -name '._*' -o -name '.DS_Store' \) -print -quit)
if [ -n "$ADDED" ]; then
	echo "error: extra files were added inside the bundle: $ADDED" >&2
	exit 1
fi
echo "  [ ok ] signature survives mounting, nothing added to the bundle"

if [ ! -L "$MOUNT/Applications" ]; then
	echo "error: the image has no Applications shortcut" >&2
	exit 1
fi
echo "  [ ok ] includes an Applications shortcut"

( cd "$HERE/build" && shasum -a 256 "dsh-mac-$VERSION.dmg" "dsh-mac.dmg" > SHA256SUMS )

echo
echo "──────────────────────────────────────────"
echo "assets ready in build/, upload all three to the release:"
echo "  $DMG"
echo "  $STABLE"
echo "  $SUMS"
echo
sed 's/^/  /' "$SUMS"