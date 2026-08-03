#!/usr/bin/env bash
# Build Tessera in Release (universal: Apple silicon + Intel) and package it into a
# distributable Tessera.dmg with a drag-to-Applications layout.
#
# The app is unsigned/un-notarized on purpose (open-source self-build), so on a
# fresh Mac Gatekeeper will ask the user to right-click → Open the first time.
#
# Usage: scripts/make-dmg.sh [output.dmg]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="Tessera"
APP_NAME="Tessera.app"
VOL_NAME="Tessera"
OUT_DMG="${1:-$PROJECT_DIR/Tessera.dmg}"
BUILD_DIR="$PROJECT_DIR/build/dmg"
STAGE_DIR="$PROJECT_DIR/build/dmgroot"

# DEPLOYMENT_POSTPROCESSING + STRIP_INSTALLED_PRODUCT make xcodebuild strip the
# binary (and re-sign it) as an install/archive would — a plain `build` ships the
# full debug symbol table, roughly doubling the executable.
echo "Building ${SCHEME} (Release, universal) ..."
xcodebuild \
  -project "$PROJECT_DIR/Tessera.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
  build

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME"
if [[ ! -d "$APP" ]]; then
  echo "Build product not found at ${APP}" >&2
  exit 1
fi

# Stage a folder holding the app plus an /Applications symlink so the DMG window
# offers the usual drag-here target.
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "Packaging ${OUT_DMG} ..."
rm -f "$OUT_DMG"
# create-dmg (brew install create-dmg) gives a nicer window with fixed icon
# positions; fall back to plain hdiutil if it isn't installed.
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$VOL_NAME" \
    --window-size 540 380 \
    --icon-size 110 \
    --icon "$APP_NAME" 140 190 \
    --app-drop-link 400 190 \
    --no-internet-enable \
    "$OUT_DMG" "$STAGE_DIR" >/dev/null
else
  hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$OUT_DMG"
fi

echo "Done: $OUT_DMG"
echo "  Size: $(du -h "$OUT_DMG" | cut -f1)"
