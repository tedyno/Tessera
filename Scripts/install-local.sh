#!/usr/bin/env bash
# Build Tessera in Release and install it into /Applications for daily personal use.
# Unsigned/un-notarized on purpose — this is a self-built local app, so Gatekeeper
# does not quarantine it. Do not distribute the resulting binary.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="Tessera"
APP_NAME="Tessera.app"
DEST="/Applications"

echo "Building ${SCHEME} (Release) ..."
xcodebuild \
  -project "$PROJECT_DIR/Tessera.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  build

BUILT_DIR="$(xcodebuild -project "$PROJECT_DIR/Tessera.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')"
SRC="$BUILT_DIR/$APP_NAME"

if [[ ! -d "$SRC" ]]; then
  echo "Build product not found at ${SRC}" >&2
  exit 1
fi

echo "Installing to ${DEST}/${APP_NAME} ..."
# Quit a running instance so we can overwrite it.
osascript -e 'tell application "Tessera" to quit' 2>/dev/null || true
rm -rf "$DEST/$APP_NAME"
cp -R "$SRC" "$DEST/$APP_NAME"

echo "Installed ${DEST}/${APP_NAME}"
echo "  Launch it from Spotlight/Dock like any other app."
