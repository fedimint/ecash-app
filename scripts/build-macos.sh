#!/usr/bin/env bash

# Must match MACOSX_DEPLOYMENT_TARGET in macos/Runner.xcodeproj and the Podfile
# platform. `nix develop` exports 14.0, which would make the dylib refuse to load
# on the macOS versions the app claims to support.
export MACOSX_DEPLOYMENT_TARGET=12.0

cargo build --release --manifest-path $ROOT/rust/ecashapp/Cargo.toml --target-dir $ROOT/rust/ecashapp/target

# Rewrite Nix store library paths to system equivalents so the dylib works
# outside the Nix sandbox (e.g. in a macOS .app bundle).
# Note: on modern macOS, system libs live in the dyld shared cache and aren't
# visible as files on disk, but the dynamic linker still resolves /usr/lib/ paths.
DYLIB="$ROOT/rust/ecashapp/target/release/libecashapp.dylib"
if otool -L "$DYLIB" | grep -q '/nix/store/'; then
  for nix_path in $(otool -L "$DYLIB" | grep '/nix/store/' | awk '{print $1}'); do
    lib_name=$(basename "$nix_path")
    install_name_tool -change "$nix_path" "/usr/lib/$lib_name" "$DYLIB"
  done
fi
