#!/usr/bin/env bash
# Build the Rust static library and run the Flutter app on a connected iOS device.
#
# Run OUTSIDE of `nix develop`. Uses system Flutter (e.g. `brew install flutter`)
# and rustup-managed Rust. The Nix environment's SDKROOT and toolchain conflict
# with Xcode's iOS SDK, the same way it does for the macOS run script.
#
# Prerequisites:
#   - Xcode + Command Line Tools
#   - CocoaPods (`brew install cocoapods`)
#   - rustup with `aarch64-apple-ios` target installed
#   - cmake (`brew install cmake`) and bindgen-cli (`cargo install --locked bindgen-cli`)
#   - A connected, unlocked iOS device with developer mode enabled
#   - A signing team configured in Xcode (open ios/Runner.xcworkspace once and
#     set Runner > Signing & Capabilities > Team to your free Apple ID)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter not found on PATH. Install via 'brew install flutter'." >&2
  exit 1
fi

# Strip Nix env vars that conflict with the Xcode toolchain.
unset SDKROOT DEVELOPER_DIR NIX_CFLAGS_COMPILE NIX_LDFLAGS NIX_CFLAGS_LINK || true

"$ROOT/scripts/build-rust-ios.sh" device

# Pick the first physical iOS device reported by `flutter devices`.
device_id="$(flutter devices --machine 2>/dev/null \
  | python3 -c 'import sys,json; ds=json.load(sys.stdin); print(next((d["id"] for d in ds if d.get("targetPlatform","").startswith("ios") and not d.get("emulator")), ""))')"

if [ -z "$device_id" ]; then
  echo "error: no physical iOS device detected. Plug in your iPhone, unlock it," >&2
  echo "       trust this Mac, and ensure Developer Mode is enabled (Settings >" >&2
  echo "       Privacy & Security > Developer Mode)." >&2
  exit 1
fi

echo "Running on device: $device_id"
exec flutter run -d "$device_id"
