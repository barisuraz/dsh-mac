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

echo
echo "packaging for submission"
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
# The ticket must be stapled to the .app, then repackaged: a stapled app opens
# without a network round trip, which is what makes the first launch clean.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

if ! spctl --assess --type execute --verbose=2 "$APP" 2>&1 | grep -q "accepted"; then
	fail "Gatekeeper still rejects the app" "the staple did not take effect"
fi
echo "  [ ok ] Gatekeeper accepts the app"

# Repackage now that the ticket is stapled inside the bundle.
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

# A stable asset name lets install.sh build a plain download URL that does not
# need to know the version, and it is what the README one-liner relies on.
STABLE="$HERE/build/dsh-mac.zip"
cp "$ZIP" "$STABLE"

# Checksums let install.sh catch a corrupted or substituted download.
SUMS="$HERE/build/SHA256SUMS"
( cd "$HERE/build" && shasum -a 256 "dsh-mac-$VERSION.zip" "dsh-mac.zip" > "$(basename "$SUMS")" )

echo
echo "──────────────────────────────────────────"
echo "notarized and stapled: DeepSeek Harness $VERSION"
echo
echo "Release assets, ready to upload:"
echo "  $ZIP"
echo "  $STABLE   (stable name, used by install.sh)"
echo "  $SUMS"
echo
echo "Anyone can now open it after downloading, with no xattr workaround."
