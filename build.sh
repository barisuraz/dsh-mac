#!/bin/bash
# Build "DeepSeek Harness.app" — a native macOS wrapper around `dsh web`.
#
# No dependencies beyond the Xcode Command Line Tools: swiftc compiles the whole
# app, the icon is rendered from vectors, and the bundle is assembled and
# ad-hoc signed in place. Nothing is downloaded.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/DeepSeek Harness.app"
BIN_NAME="DeepSeekHarness"
CACHE="$HERE/.build-cache"

command -v swiftc >/dev/null 2>&1 || {
	echo "error: swiftc not found. Install the Xcode Command Line Tools:" >&2
	echo "       xcode-select --install" >&2
	exit 1
}

mkdir -p "$CACHE"

# A built copy is a second "DeepSeek Harness" on the machine while the real one
# sits in /Applications. macOS indexes and registers any application bundle it
# finds, so the build output turns up in Spotlight and Launchpad as a duplicate
# icon, and can be launched in place of the installed app. This marker tells
# Spotlight to leave the build directory alone, which keeps local builds out of
# both. It goes in before the bundle exists so the app is never indexed.
mkdir -p "$HERE/build"
touch "$HERE/build/.metadata_never_index"

# -module-cache-path keeps clang's module cache inside the project: the default
# cache lives in the system temp directory, which a sandboxed shell may not write.
COMMON_FLAGS=(-O -swift-version 5 -module-cache-path "$CACHE/modules")

echo "==> compiling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# -swift-version 5 keeps the build free of strict-concurrency diagnostics on
# Swift 6 toolchains, where this AppKit delegate code is main-thread by construction.
#
# Both architectures are built and merged so the app also runs on Intel Macs.
# If the second slice cannot be produced the build falls back to the host
# architecture rather than failing, since a working native build is what matters.
TARGET_MIN="13.0"
SLICES=()
for arch in arm64 x86_64; do
	OUT="$CACHE/app-$arch"
	if swiftc \
		"${COMMON_FLAGS[@]}" \
		-target "$arch-apple-macos$TARGET_MIN" \
		-framework AppKit \
		-framework WebKit \
		-o "$OUT" \
		"$HERE/Sources/main.swift" 2>"$CACHE/compile-$arch.log"; then
		SLICES+=("$OUT")
		echo "     $arch ok"
	else
		echo "     $arch unavailable (see $CACHE/compile-$arch.log)"
	fi
done

if [ ${#SLICES[@]} -eq 0 ]; then
	echo "error: no architecture could be compiled" >&2
	exit 1
fi

if [ ${#SLICES[@]} -gt 1 ]; then
	lipo -create -output "$APP/Contents/MacOS/$BIN_NAME" "${SLICES[@]}"
	echo "     universal: $(lipo -archs "$APP/Contents/MacOS/$BIN_NAME")"
else
	cp "${SLICES[0]}" "$APP/Contents/MacOS/$BIN_NAME"
	echo "     single architecture: $(lipo -archs "$APP/Contents/MacOS/$BIN_NAME")"
fi

echo "==> assembling bundle"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> building icon"
if command -v iconutil >/dev/null 2>&1; then
	ICONSET="$CACHE/AppIcon.iconset"
	rm -rf "$ICONSET"
	swiftc "${COMMON_FLAGS[@]}" -o "$CACHE/make-icon" "$HERE/tools/make-icon.swift"
	"$CACHE/make-icon" "$ICONSET" "$HERE/tools/deepseek-whale.path" >/dev/null
	iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
	echo "     (iconutil unavailable; building without an icon)"
fi

echo "==> signing"
# Ad-hoc signing is enough for a locally built app, and it is what makes the
# app's storage container stable so the session cookie survives relaunches.
#
# Set DSH_SIGN_IDENTITY to sign for distribution instead:
#
#   DSH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
#
# The hardened runtime is enabled in both cases, so what you test locally is
# what gets notarized.
SIGN_IDENTITY="${DSH_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
	# Ad-hoc signatures cannot carry a secure timestamp.
	SIGN_ARGS+=(--timestamp=none)
else
	# Developer ID signatures must, or notarization is rejected.
	SIGN_ARGS+=(--timestamp)
fi

if [[ -f "$HERE/tools/entitlements.plist" ]]; then
	SIGN_ARGS+=(--entitlements "$HERE/tools/entitlements.plist")
fi

if codesign "${SIGN_ARGS[@]}" "$APP" >/dev/null 2>&1; then
	if [[ "$SIGN_IDENTITY" == "-" ]]; then
		echo "     ad-hoc signed (hardened runtime)"
	else
		echo "     signed as: $SIGN_IDENTITY"
	fi
else
	echo "     (signing skipped; the app still runs locally)"
fi

echo "==> built: $APP"
echo
echo "Launch it with:"
echo "  open \"$APP\""
echo
echo "Diagnostics:"
echo "  \"$APP/Contents/MacOS/$BIN_NAME\" --selftest        # what it resolved"
echo "  \"$APP/Contents/MacOS/$BIN_NAME\" --test-parser     # readiness-line parser"
echo "  \"$APP/Contents/MacOS/$BIN_NAME\" --test-update     # A/B slot and crash-loop logic"
echo "  \"$APP/Contents/MacOS/$BIN_NAME\" --install-harness # fetch a harness into a slot"
echo "  \"$APP/Contents/MacOS/$BIN_NAME\" --check-contract  # end-to-end harness check"
