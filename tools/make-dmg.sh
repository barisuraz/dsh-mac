#!/bin/sh
#
# Build a disk image containing the app.
#
#   tools/make-dmg.sh "build/DeepSeek Harness.app" build/dsh-mac-1.2.dmg
#
# A disk image is used because GitHub release assets are single files, so a
# .app bundle cannot be uploaded directly. A DMG is also the ordinary way macOS
# software is distributed, and it mounts as a volume the user can browse.
#
# The image is built from a staging directory that also contains a symlink to
# /Applications, so dragging the app across installs it in the usual way. The
# bundle is copied with `ditto` rather than `cp`, because anything added to a
# bundle invalidates its code signature.

set -eu

if [ "$#" -ne 2 ]; then
	echo "usage: $0 <app bundle> <output dmg>" >&2
	exit 2
fi

APP="$1"
OUT="$2"

[ -d "$APP" ] || {
	echo "error: $APP is not a bundle" >&2
	exit 1
}

VOLUME="DeepSeek Harness"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM

# COPYFILE_DISABLE stops resource forks being written as AppleDouble files.
COPYFILE_DISABLE=1 /usr/bin/ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
# UDZO is compressed and read-only, which is what a release wants. The image is
# built in one pass: `hdiutil create -srcfolder` needs no mounted volume, so
# there is nothing to clean up if it fails.
hdiutil create \
	-volname "$VOLUME" \
	-srcfolder "$STAGE" \
	-ov -format UDZO -quiet \
	"$OUT"

[ -f "$OUT" ] || {
	echo "error: hdiutil did not produce $OUT" >&2
	exit 1
}

echo "  [ ok ] $(basename "$OUT") ($(du -h "$OUT" | cut -f1))"
