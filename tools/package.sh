#!/bin/sh
#
# Build and package a release, without notarizing.
#
# Used for ad-hoc releases, which are what this project publishes until there is
# a Developer ID certificate. For a notarized build use tools/notarize.sh, which
# packages with the same rules.
#
# Why this exists rather than a `zip` command: a release zip must not add
# anything to the bundle. `zip -r` stores extended attributes and resource forks
# as AppleDouble `._*` entries, which reappear inside the bundle when a user
# unpacks it, and any added file invalidates the code signature. The released
# v1.1 asset had exactly that problem: `codesign --verify` reported "a sealed
# resource is missing or invalid" and listed seven `._*` files that had been
# added. `ditto -c -k --keepParent` preserves the bundle exactly, so the
# signature still verifies after the download.

set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

APP="$HERE/build/DeepSeek Harness.app"
VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
[ -n "$VERSION" ] || {
	echo "error: could not read the bundle version; run ./build.sh first" >&2
	exit 1
}

ZIP="$HERE/build/dsh-mac-$VERSION.zip"
STABLE="$HERE/build/dsh-mac.zip"
SUMS="$HERE/build/SHA256SUMS"

echo "==> packaging DeepSeek Harness $VERSION"

# The bundle has to be valid before it is worth packaging: a broken signature
# here means a broken signature for everyone who downloads it.
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
	echo "error: the built app does not have a valid signature" >&2
	codesign --verify --verbose=4 "$APP" >&2 || true
	exit 1
fi
echo "  [ ok ] signature verifies"

# A macOS app must never be distributed carrying these.
if xattr -lr "$APP" 2>/dev/null | grep -q "com.apple.quarantine"; then
	echo "error: the bundle carries a quarantine flag" >&2
	exit 1
fi
echo "  [ ok ] no quarantine flag"

rm -f "$ZIP" "$STABLE" "$SUMS"

# COPYFILE_DISABLE stops the resource forks being written at all; ditto is what
# preserves symlinks and permissions inside the bundle.
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

# The stable name lets install.sh construct a download URL without knowing the
# version, which is what the README one-liner relies on.
cp "$ZIP" "$STABLE"

# Prove the round trip: unpack the way a user will and check that the signature
# survived. This is the check that would have caught the v1.1 defect.
CHECK=$(mktemp -d)
trap 'rm -rf "$CHECK"' EXIT INT TERM
/usr/bin/ditto -x -k "$ZIP" "$CHECK"
UNPACKED="$CHECK/DeepSeek Harness.app"
if [ ! -d "$UNPACKED" ]; then
	echo "error: the zip does not contain the app bundle" >&2
	exit 1
fi
if ! codesign --verify --deep --strict "$UNPACKED" 2>/dev/null; then
	echo "error: the signature does not survive unpacking" >&2
	codesign --verify --verbose=4 "$UNPACKED" >&2 || true
	exit 1
fi
if [ -n "$(find "$UNPACKED" -name '._*' -print -quit)" ]; then
	echo "error: AppleDouble files were added to the bundle" >&2
	exit 1
fi
echo "  [ ok ] signature survives unpacking"

( cd "$HERE/build" && shasum -a 256 "dsh-mac-$VERSION.zip" "dsh-mac.zip" > SHA256SUMS )

echo
echo "──────────────────────────────────────────"
echo "assets ready in build/, upload all three to the release:"
echo "  $ZIP"
echo "  $STABLE"
echo "  $SUMS"
echo
cat "$SUMS" | sed 's/^/  /'