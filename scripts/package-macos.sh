#!/bin/bash
set -e

# Clean previous build artifacts
rm -rf build/macos *.dmg

# Build Rust library (works fine inside Nix)
cargo build --release \
  --manifest-path rust/ecashapp/Cargo.toml \
  --target-dir rust/ecashapp/target

# Rewrite Nix store library paths to system equivalents so the dylib works
# outside the Nix sandbox (e.g. in a macOS .app bundle).
DYLIB="rust/ecashapp/target/release/libecashapp.dylib"
if otool -L "$DYLIB" | grep -q '/nix/store/'; then
  for nix_path in $(otool -L "$DYLIB" | grep '/nix/store/' | awk '{print $1}'); do
    lib_name=$(basename "$nix_path")
    install_name_tool -change "$nix_path" "/usr/lib/$lib_name" "$DYLIB"
  done
fi

# Find system (non-Nix) Flutter — Nix's Flutter copies frameworks with
# read-only Nix store permissions that break Xcode's lipo
FLUTTER_CMD=$(which -a flutter 2>/dev/null | grep -v '/nix/' | head -1)
if [ -z "$FLUTTER_CMD" ]; then
  FLUTTER_CMD="flutter"
fi

# Strip Nix paths from PATH so the system Xcode toolchain is used
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/nix' | tr '\n' ':' | sed 's/:$//')

# Unset Nix build env vars that interfere with Xcode's toolchain
unset CC CXX LD AR NM RANLIB
unset NIX_CC NIX_CFLAGS_COMPILE NIX_LDFLAGS NIX_ENFORCE_PURITY
unset SDKROOT MACOSX_DEPLOYMENT_TARGET LD_LIBRARY_PATH

# Build Flutter macOS app (triggers Xcode's "Embed Rust Library" build phase)
"$FLUTTER_CMD" pub get
"$FLUTTER_CMD" build macos --release

VERSION=$(grep "^version:" pubspec.yaml | cut -d" " -f2)
ARCH=$(uname -m)
APP_PATH="build/macos/Build/Products/Release/ecashapp.app"

# Code signing (if MACOS_SIGN_IDENTITY is set)
if [ -n "$MACOS_SIGN_IDENTITY" ]; then
  echo "Signing app with: $MACOS_SIGN_IDENTITY"
  codesign --deep --force --options runtime \
    --sign "$MACOS_SIGN_IDENTITY" "$APP_PATH"
fi

# Create DMG with drag-to-install layout using create-dmg
DMG_NAME="ecash-app-${VERSION}-${ARCH}.dmg"
create-dmg \
  --volname "Ecash App" \
  --window-pos 200 120 \
  --window-size 540 380 \
  --icon-size 128 \
  --icon "ecashapp.app" 140 175 \
  --app-drop-link 400 175 \
  --no-internet-enable \
  "$DMG_NAME" \
  "$APP_PATH"

# Sign DMG (if MACOS_SIGN_IDENTITY is set)
if [ -n "$MACOS_SIGN_IDENTITY" ]; then
  echo "Signing DMG"
  codesign --force --sign "$MACOS_SIGN_IDENTITY" "$DMG_NAME"
fi

# Notarize (if MACOS_NOTARIZE_APPLE_ID is set)
if [ -n "$MACOS_NOTARIZE_APPLE_ID" ]; then
  echo "Submitting for notarization..."
  xcrun notarytool submit "$DMG_NAME" \
    --apple-id "$MACOS_NOTARIZE_APPLE_ID" \
    --team-id "$MACOS_NOTARIZE_TEAM_ID" \
    --password "$MACOS_NOTARIZE_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG_NAME"
fi

echo "Created: $DMG_NAME"
