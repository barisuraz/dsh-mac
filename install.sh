#!/bin/sh
#
# Install the latest dsh-mac release into /Applications and clear the
# quarantine flag that macOS puts on anything downloaded.
#
#   curl -fsSL https://raw.githubusercontent.com/barisuraz/dsh-mac/main/install.sh | sh
#
# The build is ad-hoc signed rather than notarized, which is why the quarantine
# flag has to be cleared: Gatekeeper rejects it otherwise. Notarizing needs a
# paid Apple Developer account, so this script is the difference in the
# meantime. Read it before running it, as you should with any script piped into
# a shell.
#
# Environment:
#   DSH_INSTALL_DIR   where to install (default: /Applications)
#   DSH_VERSION       a specific tag, e.g. v1.1 (default: the newest release)
#   DSH_NO_OPEN       set to skip launching the app when done

set -eu

REPO="barisuraz/dsh-mac"
APP_NAME="DeepSeek Harness.app"
INSTALL_DIR="${DSH_INSTALL_DIR:-/Applications}"
NO_OPEN="${DSH_NO_OPEN:-}"

say() { printf '  %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found"
}

need curl
need unzip
need shasum

[ "$(uname -s)" = "Darwin" ] || die "this installs a macOS app, and this is not macOS"

TARGET="$INSTALL_DIR/$APP_NAME"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- find the release -------------------------------------------------------

if [ -n "${DSH_VERSION:-}" ]; then
    TAG="$DSH_VERSION"
    say "release: $TAG (requested)"
else
    say "looking up the latest release"
    TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n 1)
    [ -n "$TAG" ] || die "could not determine the latest release; set DSH_VERSION to pick one"
    say "release: $TAG"
fi

# --- download ---------------------------------------------------------------

# The stable name is preferred so this works without knowing the version; the
# versioned name is the fallback for releases published before that existed.
BASE="https://github.com/$REPO/releases/download/$TAG"
ZIP="$TMP/dsh-mac.zip"

say "downloading"
if curl -fsSL "$BASE/dsh-mac.zip" -o "$ZIP" 2>/dev/null; then
    :
else
    VERSION="${TAG#v}"
    curl -fsSL "$BASE/dsh-mac-$VERSION.zip" -o "$ZIP" \
        || die "no .zip asset found on release $TAG"
fi

BYTES=$(wc -c < "$ZIP" | tr -d ' ')
[ "$BYTES" -gt 100000 ] || die "the download looks truncated ($BYTES bytes)"
say "downloaded $(echo "$BYTES" | awk '{printf "%.1f MB", $1/1048576}')"

# --- verify -----------------------------------------------------------------

# Honest caveat: this compares the download against a checksum published in the
# same release, so it catches a corrupted or truncated transfer, not a
# compromised release. A signature from a Developer ID certificate is the
# thing that would prove origin, and that is what notarization adds.
if curl -fsSL "$BASE/SHA256SUMS" -o "$TMP/SHA256SUMS" 2>/dev/null; then
    EXPECTED=$(sed -n "s/^\([0-9a-f]\{64\}\)[[:space:]].*dsh-mac\.zip$/\1/p" "$TMP/SHA256SUMS" | head -n 1)
    if [ -n "$EXPECTED" ]; then
        ACTUAL=$(shasum -a 256 "$ZIP" | awk '{print $1}')
        if [ "$EXPECTED" = "$ACTUAL" ]; then
            say "checksum verified"
        else
            die "checksum mismatch
  expected $EXPECTED
  actual   $ACTUAL
Refusing to install. The release may have been replaced mid-download; try again."
        fi
    else
        say "no dsh-mac.zip entry in SHA256SUMS; skipping the check"
    fi
else
    say "release publishes no SHA256SUMS; skipping the checksum check"
fi

# --- unpack -----------------------------------------------------------------

mkdir -p "$TMP/unpacked"
unzip -q "$ZIP" -d "$TMP/unpacked" || die "could not unpack the download"
SRC="$TMP/unpacked/$APP_NAME"
[ -d "$SRC" ] || die "the download does not contain $APP_NAME"

# The bundle must at least be intact and self-consistent. This cannot establish
# who built it, but it does catch a tampered or damaged download.
if codesign --verify --deep --strict "$SRC" 2>/dev/null; then
    AUTHORITY=$(codesign -dv "$SRC" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
    say "signature valid${AUTHORITY:+ ($AUTHORITY)}"
else
    die "the downloaded app is not correctly signed; refusing to install it"
fi

# --- stop a running copy ----------------------------------------------------

# Only a copy running from the destination is in the way. A copy running from
# somewhere else is left alone.
if pgrep -f "$TARGET/Contents/MacOS/" >/dev/null 2>&1; then
    say "quitting the running copy"
    osascript -e 'quit app "DeepSeek Harness"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$TARGET/Contents/MacOS/" >/dev/null 2>&1 || break
        sleep 0.5
    done
    if pgrep -f "$TARGET/Contents/MacOS/" >/dev/null 2>&1; then
        die "the app is still running; quit it and run this again"
    fi
fi

# --- install ----------------------------------------------------------------

if [ ! -w "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR is not writable. Re-run with sudo, or set DSH_INSTALL_DIR to somewhere you own."
fi

# Copy to a temporary name in the destination, then swap it in, so a failure
# part-way leaves the previous install usable rather than half-deleted.
STAGED="$INSTALL_DIR/.$APP_NAME.new"
rm -rf "$STAGED"
cp -R "$SRC" "$STAGED" || die "could not copy the app into $INSTALL_DIR"

# --- trust ------------------------------------------------------------------

# This is the step that makes the app launchable: the flag is set on the
# downloaded archive's contents, and clearing it is what Gatekeeper objects to.
xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true

if [ -d "$TARGET" ]; then
    rm -rf "$TARGET" || die "could not remove the existing app"
fi
mv "$STAGED" "$TARGET" || die "could not move the app into place"
say "cleared the quarantine flag"

VERSION_IN_BUNDLE=$(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
say "installed $APP_NAME $VERSION_IN_BUNDLE to $INSTALL_DIR"

if [ -z "$NO_OPEN" ]; then
    open "$TARGET" 2>/dev/null || true
    say "launched"
fi

printf '\nDone. Your existing ~/.dsh sessions are used as they are.\n'
