#!/bin/sh
#
# Install the latest dsh-mac release into /Applications and trust it.
#
#   curl -fsSL https://raw.githubusercontent.com/barisuraz/dsh-mac/main/install.sh | sh
#
# It downloads the release disk image, checks its checksum and signature, copies
# the app into /Applications, and clears the quarantine flag so Gatekeeper will
# open it. The build is ad-hoc signed rather than notarized, which is why that
# last step is needed: notarizing requires a paid Apple Developer account, so
# this script is the difference in the meantime. Read it before running it, as
# you should with any script piped into a shell.
#
# Environment:
#   DSH_INSTALL_DIR   where to install (default: /Applications)
#   DSH_VERSION       a specific tag, e.g. v1.2 (default: the newest release)
#   DSH_NO_OPEN       set to skip launching the app when done
#   DSH_SOURCE_DIR    a directory holding a locally built dsh-mac.dmg to use
#                     instead of downloading (used by the tests)

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
need shasum
need hdiutil
need ditto

[ "$(uname -s)" = "Darwin" ] || die "this installs a macOS app, and this is not macOS"

TARGET="$INSTALL_DIR/$APP_NAME"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- find the release -------------------------------------------------------

# DSH_SOURCE_DIR installs a locally built disk image instead of downloading one.
# It exists so this script can be tested end to end without publishing a
# release, which is what CI does.
LOCAL=""
if [ -n "${DSH_SOURCE_DIR:-}" ]; then
    LOCAL="$DSH_SOURCE_DIR/dsh-mac.dmg"
    [ -f "$LOCAL" ] || die "DSH_SOURCE_DIR is set but $LOCAL does not exist"
    say "using the local image at $LOCAL"
    TAG="local"
elif [ -n "${DSH_VERSION:-}" ]; then
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
DMG="$TMP/dsh-mac.dmg"

if [ -n "$LOCAL" ]; then
    cp "$LOCAL" "$DMG"
else
    say "downloading"
    if curl -fsSL "$BASE/dsh-mac.dmg" -o "$DMG" 2>/dev/null; then
        :
    else
        VERSION="${TAG#v}"
        curl -fsSL "$BASE/dsh-mac-$VERSION.dmg" -o "$DMG" \
            || die "release $TAG has no disk image to install"
    fi
fi

BYTES=$(wc -c < "$DMG" | tr -d ' ')
[ "$BYTES" -gt 100000 ] || die "the download looks truncated ($BYTES bytes)"
say "downloaded $(echo "$BYTES" | awk '{printf "%.1f MB", $1/1048576}')"

# --- verify -----------------------------------------------------------------

# Honest caveat: this compares the download against a checksum published in the
# same release, so it catches a corrupted or truncated transfer, not a
# compromised release. A signature from a Developer ID certificate is the
# thing that would prove origin, and that is what notarization adds.
if [ -z "$LOCAL" ] && curl -fsSL "$BASE/SHA256SUMS" -o "$TMP/SHA256SUMS" 2>/dev/null; then
    EXPECTED=$(sed -n "s/^\([0-9a-f]\{64\}\)[[:space:]].*dsh-mac\.dmg$/\1/p" "$TMP/SHA256SUMS" | head -n 1)
    if [ -n "$EXPECTED" ]; then
        ACTUAL=$(shasum -a 256 "$DMG" | awk '{print $1}')
        if [ "$EXPECTED" = "$ACTUAL" ]; then
            say "checksum verified"
        else
            die "checksum mismatch
  expected $EXPECTED
  actual   $ACTUAL
Refusing to install. The release may have been replaced mid-download; try again."
        fi
    else
        say "no dsh-mac.dmg entry in SHA256SUMS; skipping the check"
    fi
elif [ -n "$LOCAL" ]; then
    say "local build; skipping the checksum check"
else
    say "release publishes no SHA256SUMS; skipping the checksum check"
fi

# --- mount ------------------------------------------------------------------

# The app is installed from the disk image, which is why the release asset is a
# DMG: GitHub release assets are single files, so a .app bundle cannot be
# uploaded directly, and a DMG is what macOS users expect to download.
MOUNT="$TMP/mnt"
mkdir -p "$MOUNT"
# Detached on any exit path, so a failure does not leave a volume mounted.
detach() { hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; }
trap 'detach; rm -rf "$TMP"' EXIT INT TERM

say "mounting"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null \
    || die "could not mount the disk image"

SRC="$MOUNT/$APP_NAME"
[ -d "$SRC" ] || die "the disk image does not contain $APP_NAME"

# The bundle must at least be intact and self-consistent. This cannot establish
# who built it, but it does catch a tampered or damaged download.
if codesign --verify --deep --strict "$SRC" 2>/dev/null; then
    AUTHORITY=$(codesign -dv "$SRC" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
    say "signature valid${AUTHORITY:+ ($AUTHORITY)}"
else
    codesign --verify --verbose=2 "$SRC" 2>&1 | sed 's/^/    /' >&2 || true
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

# A directory that does not exist is not writable, so create it first: pointing
# DSH_INSTALL_DIR at a fresh path is a reasonable thing to do.
if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR" 2>/dev/null || die "could not create $INSTALL_DIR"
fi

if [ ! -w "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR is not writable. Re-run with sudo, or set DSH_INSTALL_DIR to somewhere you own."
fi

# Copy to a temporary name in the destination, then swap it in, so a failure
# part-way leaves the previous install usable rather than half-deleted.
# `ditto` rather than `cp -R`: it preserves the bundle exactly, including the
# symlinks inside frameworks, so the signature still verifies afterwards.
STAGED="$INSTALL_DIR/.$APP_NAME.new"
rm -rf "$STAGED"
ditto "$SRC" "$STAGED" || die "could not copy the app into $INSTALL_DIR"

# --- trust ------------------------------------------------------------------

# This is the step that makes the app launchable. Gatekeeper refuses an app that
# is not notarized when it carries the quarantine flag, and clearing it is the
# documented way to say you trust this build. It is needed because the app is
# ad-hoc signed; a notarized release would not need it.
xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true

if [ -d "$TARGET" ]; then
    rm -rf "$TARGET" || die "could not remove the existing app"
fi
mv "$STAGED" "$TARGET" || die "could not move the app into place"
say "trusted: quarantine flag cleared"

VERSION_IN_BUNDLE=$(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
say "installed $APP_NAME $VERSION_IN_BUNDLE to $INSTALL_DIR"

if [ -z "$NO_OPEN" ]; then
    open "$TARGET" 2>/dev/null || true
    say "launched"
fi

printf '\nDone. Your existing ~/.dsh sessions are used as they are.\n'
