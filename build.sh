#!/usr/bin/env bash
# Build, sign and install Tile.
#
#   ./build.sh install   build release, sign, install to ~/Applications, relaunch
#   ./build.sh test      run the unit tests
#   ./build.sh release   build release, sign with Developer ID, notarize, staple,
#                        write dist/Tile-<version>.zip + .sha256 for the Homebrew cask
#
# Signing uses a stable identity on purpose: macOS ties the Accessibility grant to
# the code signature, and an ad-hoc signature changes on every build.
#
# Environment:
#   TILE_SIGN_IDENTITY   codesign identity. install: Apple Development; release: the
#                        Developer ID Application certificate in the keychain.
#   TILE_NOTARY_PROFILE  notarytool keychain profile (default tile-notary), created with
#                        xcrun notarytool store-credentials tile-notary --apple-id ... --team-id ...
#   TILE_NOTARIZE=0      release without notarizing (local testing only; Gatekeeper
#                        refuses the result on any other machine)
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="Tile"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
DEV_IDENTITY="Apple Development: Thomas Duquemin (3367SAF32Q)"
INSTALL_DIR="$HOME/Applications"
NOTARY_PROFILE="${TILE_NOTARY_PROFILE:-tile-notary}"

# developer_id: the Developer ID Application identity in the keychain, or nothing
developer_id() {
  security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1
}

# bundle <output dir> <timestamp flag>: builds and signs <output dir>/Tile.app
bundle() {
  local out="$1" timestamp="$2" identity="$3"
  swift build -c release --product "$APP_NAME"
  local bin
  bin="$(swift build -c release --show-bin-path)/$APP_NAME"

  local app="$out/$APP_NAME.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/$APP_NAME"
  sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Support/Info.plist > "$app/Contents/Info.plist"

  codesign --force --options runtime "$timestamp" --sign "$identity" "$app"
  codesign --verify --strict "$app"
  echo "Built $app ($VERSION, build $BUILD_NUMBER), signed by $identity"
}

# package <zip>: zips dist/Tile.app into <zip> and writes <zip>.sha256
package() {
  local zip="$1"
  rm -f "$zip" "$zip.sha256"
  ditto -c -k --keepParent "dist/$APP_NAME.app" "$zip"
  (cd dist && shasum -a 256 "$(basename "$zip")" | tee "$(basename "$zip").sha256")
}

case "${1:-install}" in
  install)
    bundle .build/app --timestamp=none "${TILE_SIGN_IDENTITY:-$DEV_IDENTITY}"
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
    identity="${TILE_SIGN_IDENTITY:-$(developer_id)}"
    if [[ -z "$identity" ]]; then
      echo "release: no Developer ID Application certificate in the keychain." >&2
      echo "Create one in Xcode > Settings > Accounts > Manage Certificates, or set TILE_SIGN_IDENTITY." >&2
      exit 1
    fi
    mkdir -p dist
    bundle dist --timestamp "$identity"
    zip="dist/$APP_NAME-$VERSION.zip"
    package "$zip"

    if [[ "${TILE_NOTARIZE:-1}" == "0" ]]; then
      echo "Skipped notarization (TILE_NOTARIZE=0). This zip only runs on this machine."
      exit 0
    fi
    if [[ "$identity" != Developer\ ID\ Application:* ]]; then
      echo "release: '$identity' is not a Developer ID Application identity; Apple won't notarize it." >&2
      echo "Set TILE_NOTARIZE=0 for a local-only build." >&2
      exit 1
    fi

    # Notarize the zip, then staple the ticket to the app. Stapling changes the bundle,
    # so the zip and its sha256 are rebuilt afterwards. Gatekeeper reads the ticket
    # from the app itself, so an offline first launch works too.
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
    xcrun stapler staple "dist/$APP_NAME.app"
    xcrun stapler validate "dist/$APP_NAME.app"
    package "$zip"
    spctl --assess --type execute --verbose=2 "dist/$APP_NAME.app"
    echo "Notarized and stapled $zip"
    ;;
  *)
    echo "usage: $0 [install|test|release]" >&2
    exit 64
    ;;
esac
