#!/usr/bin/env bash
# Build, sign and install Tile.
#
#   ./build.sh install   build release, sign, install to ~/Applications, relaunch
#   ./build.sh test      run the unit tests
#   ./build.sh release   build release, sign, write dist/Tile-<version>.zip + .sha256
#
# Signing uses a stable identity on purpose: macOS ties the Accessibility grant to
# the code signature, and an ad-hoc signature changes on every build.
# Override with TILE_SIGN_IDENTITY="..." (e.g. a Developer ID for distribution).
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="Tile"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
SIGN_IDENTITY="${TILE_SIGN_IDENTITY:-Apple Development: Thomas Duquemin (3367SAF32Q)}"
INSTALL_DIR="$HOME/Applications"

# bundle <output dir> <timestamp flag>: builds and signs <output dir>/Tile.app
bundle() {
  local out="$1" timestamp="$2"
  swift build -c release --product "$APP_NAME"
  local bin
  bin="$(swift build -c release --show-bin-path)/$APP_NAME"

  local app="$out/$APP_NAME.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/$APP_NAME"
  sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Support/Info.plist > "$app/Contents/Info.plist"

  codesign --force --options runtime "$timestamp" --sign "$SIGN_IDENTITY" "$app"
  codesign --verify --strict "$app"
  echo "Built $app ($VERSION, build $BUILD_NUMBER)"
}

case "${1:-install}" in
  install)
    bundle .build/app --timestamp=none
    pkill -x "$APP_NAME" || true
    while pgrep -x "$APP_NAME" > /dev/null; do sleep 0.1; done
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    ditto .build/app/"$APP_NAME".app "$INSTALL_DIR/$APP_NAME.app"
    open "$INSTALL_DIR/$APP_NAME.app"
    echo "Installed and launched $INSTALL_DIR/$APP_NAME.app"
    ;;
  test)
    swift test
    ;;
  release)
    mkdir -p dist
    bundle dist --timestamp
    zip="dist/$APP_NAME-$VERSION.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "dist/$APP_NAME.app" "$zip"
    shasum -a 256 "$zip" | tee "$zip.sha256"
    ;;
  *)
    echo "usage: $0 [install|test|release]" >&2
    exit 64
    ;;
esac
