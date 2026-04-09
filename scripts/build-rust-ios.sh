#!/usr/bin/env bash
# Build the Rust static library (libecashapp.a) for an iOS target.
# Must be run OUTSIDE of `nix develop` — it uses system rustup-managed Rust and
# Xcode's iOS SDK. The Nix environment ships a Rust toolchain without iOS
# rust-std and overrides SDKROOT to the macOS SDK, both of which break iOS
# cross-compilation.
#
# Usage:
#   scripts/build-rust-ios.sh device  # aarch64-apple-ios (physical device)
#
# Simulator (aarch64-apple-ios-sim) is intentionally unsupported — see
# ios/Flutter/Rust.xcconfig for the explanation.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Force the system Xcode toolchain to the front of PATH and clear any
# Nix-injected SDK env. When this script is invoked from `just` inside
# `nix develop`, the Nix shell ships its own `xcrun`/`clang` that only
# know about Nix's macOS SDK and fail with exit 255 on `--sdk iphoneos`.
# We need Apple's real toolchain for iOS cross-compilation.
unset SDKROOT DEVELOPER_DIR NIX_CFLAGS_COMPILE NIX_LDFLAGS NIX_CFLAGS_LINK \
      NIX_CC NIX_BINTOOLS NIX_HARDENING_ENABLE 2>/dev/null || true
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export PATH="/usr/bin:${DEVELOPER_DIR}/usr/bin:${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

# Sanity-check that xcrun can locate the iOS SDK before letting cargo run.
if ! /usr/bin/xcrun --show-sdk-path --sdk iphoneos >/dev/null 2>&1; then
  echo "error: xcrun cannot find the iOS SDK." >&2
  echo "       Open Xcode > Settings > Components and install the iOS platform." >&2
  exit 1
fi

target="${1:-device}"
case "$target" in
  device) RUST_TARGET="aarch64-apple-ios" ;;
  *) echo "error: unknown target '$target' (only 'device' is supported)" >&2; exit 1 ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
  if [ -x "$HOME/.cargo/bin/cargo" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  else
    echo "error: cargo not found. Install rustup: https://rustup.rs" >&2
    exit 1
  fi
fi

if ! rustup target list --installed 2>/dev/null | grep -q "^${RUST_TARGET}$"; then
  echo "Installing Rust target ${RUST_TARGET}..."
  rustup target add "${RUST_TARGET}"
fi

export IPHONEOS_DEPLOYMENT_TARGET=16.0

echo "Building Rust for ${RUST_TARGET}..."
cargo build --release \
  --manifest-path "${ROOT}/rust/ecashapp/Cargo.toml" \
  --target "${RUST_TARGET}"

echo "Built: ${ROOT}/rust/ecashapp/target/${RUST_TARGET}/release/libecashapp.a"
