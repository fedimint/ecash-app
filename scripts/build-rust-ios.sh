#!/usr/bin/env bash
# Build the Rust static library (libecashapp.a) for an iOS target.
#
# Usage:
#   scripts/build-rust-ios.sh [device] [profile]
#
#   profile: release-dev (default, fast) or release (shipping)
#
# Safe to invoke from anywhere, including inside `nix develop` — the script
# re-execs itself in a scrubbed environment (see below) before doing any work.
#
# Simulator (aarch64-apple-ios-sim) is intentionally unsupported — see
# ios/Flutter/Rust.xcconfig for the explanation.

set -euo pipefail

# iOS cross-compilation needs Apple's toolchain and rustup's iOS rust-std, and
# gets neither inside `nix develop`: the Nix shell ships an `xcrun`/`clang` that
# only know Nix's macOS SDK (exit 255 on `--sdk iphoneos`), a Rust toolchain
# without iOS targets, and a CARGO_TARGET_DIR pointing at the repo root — which
# silently strands the .a somewhere ios/Flutter/Rust.xcconfig never looks.
#
# Unsetting variables one by one loses that race every time a new one appears
# (CARGO_TARGET_DIR, LIBCLANG_PATH, CC, RUSTFLAGS, ...), so re-exec with an
# allowlisted environment instead. Nothing from the caller survives except the
# few things cargo and Xcode genuinely need.
if [ "${ECASHAPP_IOS_CLEAN_ENV:-}" != "1" ]; then
  exec /usr/bin/env -i \
    ECASHAPP_IOS_CLEAN_ENV=1 \
    HOME="$HOME" \
    USER="${USER:-$(id -un)}" \
    TERM="${TERM:-dumb}" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin" \
    DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
    "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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

PROFILE="${2:-release-dev}"
case "$PROFILE" in
  release-dev|release) ;;
  *) echo "error: unknown profile '$PROFILE' (expected 'release-dev' or 'release')" >&2; exit 1 ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Install rustup: https://rustup.rs" >&2
  exit 1
fi

if ! rustup target list --installed 2>/dev/null | grep -q "^${RUST_TARGET}$"; then
  echo "Installing Rust target ${RUST_TARGET}..."
  rustup target add "${RUST_TARGET}"
fi

export IPHONEOS_DEPLOYMENT_TARGET=16.0

# --target-dir is explicit (matching build-macos.sh) so the .a always lands
# where Rust.xcconfig's -force_load expects it, whatever CARGO_TARGET_DIR says.
TARGET_DIR="${ROOT}/rust/ecashapp/target"

echo "Building Rust for ${RUST_TARGET} (profile: ${PROFILE})..."
cargo build \
  --profile "${PROFILE}" \
  --manifest-path "${ROOT}/rust/ecashapp/Cargo.toml" \
  --target "${RUST_TARGET}" \
  --target-dir "${TARGET_DIR}"

echo "Built: ${TARGET_DIR}/${RUST_TARGET}/${PROFILE}/libecashapp.a"
