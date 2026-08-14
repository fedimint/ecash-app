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

  # Sign inside-out: nested code first, the outer bundle last.
  #
  # `codesign --deep` is documented as a convenience for *verification*, not a
  # signing strategy. Used to sign, it applies the outer bundle's entitlements
  # (app-sandbox included) to every nested binary and seals them in an order
  # Apple does not guarantee, which yields bundles that codesign reports as
  # signed and Gatekeeper still rejects.
  FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
  if [ -d "$FRAMEWORKS_DIR" ]; then
    # Loose dylibs first — libecashapp.dylib lands here via the Xcode "Embed
    # Rust Library" build phase — along with any dylib vendored inside a
    # framework, so the framework seal below covers an already-signed payload.
    while IFS= read -r -d '' dylib; do
      echo "  signing $(basename "$dylib")"
      codesign --force --timestamp --options runtime \
        --sign "$MACOS_SIGN_IDENTITY" "$dylib"
    done < <(find "$FRAMEWORKS_DIR" -type f -name '*.dylib' -print0)

    # `-depth` gives post-order traversal, so a framework nested inside another
    # framework is signed before its parent.
    while IFS= read -r -d '' framework; do
      # Versioned bundles must be signed at the version directory, not the
      # framework root.
      target="$framework"
      [ -d "$framework/Versions/A" ] && target="$framework/Versions/A"
      echo "  signing $(basename "$framework")"
      codesign --force --timestamp --options runtime \
        --sign "$MACOS_SIGN_IDENTITY" "$target"
    done < <(find "$FRAMEWORKS_DIR" -depth -type d -name '*.framework' -print0)
  fi

  # Outer bundle last. This is the only signature that carries entitlements.
  codesign --force --timestamp --options runtime \
    --entitlements macos/Runner/Release.entitlements \
    --sign "$MACOS_SIGN_IDENTITY" "$APP_PATH"

  # Verify immediately rather than at the end: a bad nested signature is far
  # easier to read here than as a Gatekeeper rejection on a user's machine.
  echo "Verifying app signature"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"

  # `codesign --verify` is satisfied by an ad-hoc or self-signed signature, and
  # neither gets a user past Gatekeeper. Confirm the signer is the real thing.
  if ! codesign --display --verbose=4 "$APP_PATH" 2>&1 \
      | grep -q '^Authority=Developer ID Application'; then
    echo "Error: $APP_PATH is not signed by a Developer ID Application certificate" >&2
    exit 1
  fi
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
  codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$DMG_NAME"
  codesign --verify --strict --verbose=2 "$DMG_NAME"
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

  # Everything below needs a notarization ticket to pass, which is why it runs
  # only here and not on pull requests. Pull requests still get the codesign
  # verification above, so a broken signing path is caught before a tag depends
  # on it.
  echo "Validating notarization ticket"
  xcrun stapler validate "$DMG_NAME"

  echo "Checking Gatekeeper acceptance of the DMG"
  spctl --assess --type open --context context:primary-signature \
    --verbose=2 "$DMG_NAME"

  # The check that mirrors what a user actually does: mount the DMG and assess
  # the app inside it. The stapled ticket means this resolves offline, exactly
  # as it will on first launch on their machine.
  echo "Checking Gatekeeper acceptance of the app inside the DMG"
  MOUNT_POINT=$(mktemp -d)
  hdiutil attach "$DMG_NAME" -nobrowse -readonly -mountpoint "$MOUNT_POINT"
  trap 'hdiutil detach "$MOUNT_POINT" -quiet || true; rmdir "$MOUNT_POINT" 2>/dev/null || true' EXIT
  codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/ecashapp.app"
  spctl --assess --type execute --verbose=2 "$MOUNT_POINT/ecashapp.app"
  hdiutil detach "$MOUNT_POINT" -quiet
  trap - EXIT
  rmdir "$MOUNT_POINT" 2>/dev/null || true

  echo "Signature and notarization verified"
fi

echo "Created: $DMG_NAME"
