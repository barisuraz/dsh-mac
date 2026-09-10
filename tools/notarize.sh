#!/bin/bash
#
# Sign, notarize, and staple a release build of DeepSeek Harness.app.
#
# Notarization is what lets other people open the app without a Gatekeeper
# warning. It requires a paid Apple Developer account; there is no way around
# that, and nothing in this repo can substitute for it.
#
# One-time setup
# --------------
#
# 1. Join the Apple Developer Program (99 USD/year) and note your Team ID:
#    https://developer.apple.com/account  ->  Membership Details
#
# 2. Create a "Developer ID Application" certificate. Easiest route is Xcode:
#    Settings -> Accounts -> select your Apple ID -> Manage Certificates...
#    -> + -> Developer ID Application.
#    Confirm it landed in your keychain:
#      security find-identity -v -p codesigning
#
# 3. Create an app-specific password for notarytool (your normal Apple ID
#    password will not work):
#      https://account.apple.com  ->  Sign-In and Security  ->  App-Specific Passwords
#
# 4. Store those credentials in the keychain, once:
#      xcrun notarytool store-credentials "dsh-mac" \
#        --apple-id "you@example.com" \
#        --team-id "YOURTEAMID" \
#        --password "abcd-efgh-ijkl-mnop"
#
# Then, for every release:
#
#   DSH_SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
#     ./tools/notarize.sh
#
# Usage:
#   tools/notarize.sh [--check]
#
#   --check   verify prerequisites only; build and upload nothing
#
# Environment:
#   DSH_SIGN_IDENTITY    required; the codesigning identity to use
#   DSH_NOTARY_PROFILE   keychain profile from store-credentials (default: dsh-mac)

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HERE/build/DeepSeek Harness.app"
PROFILE="${DSH_NOTARY_PROFILE:-dsh-mac}"
IDENTITY="${DSH_SIGN_IDENTITY:-}"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

fail() {
	echo
	echo "error: $1"
	[[ -n "${2:-}" ]] && echo "       $2"
	exit 1
}

# ── prerequisites ────────────────────────────────────────────────────────────

echo "notarization prerequisites"

if [[ -z "$IDENTITY" ]]; then
	fail "DSH_SIGN_IDENTITY is not set" \
		'use: DSH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./tools/notarize.sh'
fi

if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
	echo "  [FAIL] signing identity not found in the keychain:"
	echo "         $IDENTITY"
	echo
	echo "  Available identities:"
	security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /' | head -20
	fail "no matching Developer ID certificate" \
		"Create one in Xcode: Settings -> Accounts -> Manage Certificates -> + -> Developer ID Application"
fi
echo "  [ ok ] signing identity: $IDENTITY"

case "$IDENTITY" in
"Developer ID Application"*) ;;
*)
	fail "that is not a Developer ID Application identity" \
		"Only Developer ID certificates can be notarized; an Apple Development cert cannot."
	;;
esac
echo "  [ ok ] identity is a Developer ID certificate"

if ! xcrun --find notarytool >/dev/null 2>&1; then
	fail "notarytool not found" "It ships with Xcode 13 or later: xcode-select --install"
fi
echo "  [ ok ] notarytool is available"

# A stored profile keeps the app-specific password out of your shell history.
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
	echo "  [ ok ] notary credentials profile: $PROFILE"
else
	fail "notary credentials profile '$PROFILE' is missing or invalid" \
		"create it with: xcrun notarytool store-credentials \"$PROFILE\" --apple-id you@example.com --team-id YOURTEAMID --password <app-specific-password>"
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
	echo
	echo "prerequisites look good; nothing was built or uploaded"
	exit 0
fi

# ── build and sign ───────────────────────────────────────────────────────────

echo
echo "building and signing"
DSH_SIGN_IDENTITY="$IDENTITY" "$HERE/build.sh" >/dev/null

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$HERE/build/dsh-mac-$VERSION.zip"

# Confirm the signature really is what notarization requires before uploading.
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
	fail "the signature does not verify"
fi
echo "  [ ok ] signature verifies"

AUTHORITY=$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')
if [[ "$AUTHORITY" != "$IDENTITY" ]]; then
	fail "the app was signed by '$AUTHORITY', not the requested identity" \
		"a stale build may have been reused; delete build/ and retry"
fi
echo "  [ ok ] signed by: $AUTHORITY"

if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "flags=.*runtime"; then
	fail "the hardened runtime is not enabled" "notarization always rejects apps without it"
fi
echo "  [ ok ] hardened runtime enabled"

if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "^Timestamp="; then
	fail "the signature has no secure timestamp" "Developer ID signatures must be timestamped"
fi
echo "  [ ok ] secure timestamp present"

# ── submit ───────────────────────────────────────────────────────────────────

# The app and the disk image are notarized separately, on purpose. Submitting
# the image alone would notarize everything inside it, but only the image would
# carry a staple. install.sh copies the app out of the image into /Applications,
# and the app is then assessed on its own, so it needs its own ticket to launch
# without a network round trip. Notarizing both costs one extra submission and
# makes each artifact self-sufficient.

echo
echo "packaging the app for submission"
# ditto preserves symlinks and metadata; plain zip can corrupt a bundle.
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
echo "  [ ok ] $ZIP ($(du -h "$ZIP" | cut -f1))"

echo
echo "submitting to Apple (this usually takes a few minutes)"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait; then
	echo
	echo "Notarization failed. To see why:"
	echo "  xcrun notarytool log <submission-id> --keychain-profile $PROFILE"
	fail "Apple rejected the submission"
fi

# ── staple ───────────────────────────────────────────────────────────────────

echo
echo "stapling the ticket to the app"
# The ticket is stapled before the image is built, so the copy of the app that
# ends up inside the image already carries it.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

if ! spctl --assess --type execute --verbose=2 "$APP" 2>&1 | grep -q "accepted"; then
	fail "Gatekeeper still rejects the app" "the staple did not take effect"
fi
echo "  [ ok ] Gatekeeper accepts the app"

# ── disk image ───────────────────────────────────────────────────────────────
# The release asset is a DMG: GitHub release assets are single files, so a .app
# bundle cannot be uploaded directly. It is built from the already-stapled app,
# so the ticket is inside the bundle the image carries.

echo
echo "building the disk image"
DMG="$HERE/build/dsh-mac-$VERSION.dmg"
STABLE="$HERE/build/dsh-mac.dmg"
rm -f "$DMG" "$STABLE"
"$HERE/tools/make-dmg.sh" "$APP" "$DMG"

# The image itself has to be signed, not just the app inside it. Apple requires
# that a signed disk image be notarized, and a notarized one be stapled; signing
# it is what ties the image to the same Developer ID as the app.
echo
echo "signing the disk image"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if ! codesign --verify --verbose=2 "$DMG" 2>&1 | grep -q "valid on disk"; then
	fail "the disk image signature does not verify"
fi
echo "  [ ok ] signed by: $IDENTITY"

cp "$DMG" "$STABLE"

# Notarize the image rather than the app a second time. Submitting a DMG
# notarizes everything inside it, so one submission covers both, and stapling
# the image attaches a ticket that Gatekeeper reads when the image is mounted.
echo
echo "notarizing the disk image"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait; then
	fail "Apple rejected the disk image"
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

if ! spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | grep -q "accepted"; then
	fail "Gatekeeper rejects the disk image" "the staple did not take effect"
fi
echo "  [ ok ] Gatekeeper accepts the disk image"

# Verify by mounting it, which is what a user will do.
MOUNT=$(mktemp -d)
hdiutil attach "$STABLE" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
if ! codesign --verify --deep --strict "$MOUNT/DeepSeek Harness.app" 2>/dev/null; then
	hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
	fail "the app inside the disk image does not verify"
fi
hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
rm -rf "$MOUNT"
echo "  [ ok ] the app inside the image verifies"

# Checksums let install.sh catch a corrupted or substituted download.
SUMS="$HERE/build/SHA256SUMS"
( cd "$HERE/build" && shasum -a 256 "dsh-mac-$VERSION.dmg" "dsh-mac.dmg" > SHA256SUMS )

echo
echo "──────────────────────────────────────────"
echo "notarized and stapled: DeepSeek Harness $VERSION"
echo
echo "Release assets, ready to upload:"
echo "  $DMG"
echo "  $STABLE   (stable name, used by install.sh)"
echo "  $SUMS"
echo
echo "Anyone can now open it after downloading, with no xattr workaround."
sed 's/^/  /' "$SUMS"
