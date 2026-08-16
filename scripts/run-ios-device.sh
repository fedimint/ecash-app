#!/usr/bin/env bash
# Build the Rust static library and run the Flutter app on a connected iOS device.
#
# Usage:
#   scripts/run-ios-device.sh [extra flutter run args...]
#
#   IOS_DEVICE_ID=<udid>       target a specific device
#   IOS_RUST_PROFILE=release   build the Rust lib with the shipping profile
#
# This is the direct entry point — it needs neither `just` nor `nix develop`
# (`just` only exists inside the Nix shell, which is the one environment iOS
# cross-compilation cannot use). The script re-execs itself in a scrubbed
# environment, so invoking it from inside `nix develop` is also fine.
#
# Prerequisites:
#   - Xcode + Command Line Tools
#   - CocoaPods (`brew install cocoapods`)
#   - Flutter (`brew install flutter`)
#   - rustup with `aarch64-apple-ios` target installed
#   - cmake (`brew install cmake`) and bindgen-cli (`cargo install --locked bindgen-cli`)
#   - A connected, unlocked iOS device, trusted, with Developer Mode enabled
#     (Settings > Privacy & Security > Developer Mode)
#   - A signing team on the Runner Debug config (Xcode > Runner > Signing & Capabilities)

set -euo pipefail

# See the long comment in build-rust-ios.sh: the Nix shell's SDK, toolchain and
# CARGO_TARGET_DIR all break iOS builds, and unsetting them one at a time keeps
# missing new ones. Re-exec with an allowlisted environment instead.
if [ "${ECASHAPP_IOS_CLEAN_ENV:-}" != "1" ]; then
  exec /usr/bin/env -i \
    ECASHAPP_IOS_CLEAN_ENV=1 \
    HOME="$HOME" \
    USER="${USER:-$(id -un)}" \
    TERM="${TERM:-dumb}" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin" \
    DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
    ${IOS_DEVICE_ID:+IOS_DEVICE_ID="$IOS_DEVICE_ID"} \
    ${IOS_RUST_PROFILE:+IOS_RUST_PROFILE="$IOS_RUST_PROFILE"} \
    "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter not found on PATH. Install via 'brew install flutter'." >&2
  exit 1
fi

"$ROOT/scripts/build-rust-ios.sh" device "${IOS_RUST_PROFILE:-release-dev}"

# Rewrite ios/Flutter/Generated.xcconfig and install pods before the run. The
# Docker Android build mounts the repo at /workspace and leaves container paths
# behind (FLUTTER_ROOT=/opt/flutter), which makes the Podfile's flutter_root
# helper fail with a confusing "must exist" error. Note `flutter pub get` does
# NOT fix this — only an iOS build does, and --config-only is that without the
# build. It must run after the Rust lib exists, since pod install reads the
# xcconfigs that reference it.
echo "Updating iOS project configuration..."
flutter build ios --config-only --debug

# Skip auto-selection if the caller named a device themselves.
device_id="${IOS_DEVICE_ID:-}"
for arg in "$@"; do
  case "$arg" in
    -d|--device-id|-d=*|--device-id=*) device_id="explicit" ;;
  esac
done

if [ -z "$device_id" ]; then
  device_id="$(flutter devices --machine 2>/dev/null | python3 -c '
import json, subprocess, sys

raw = sys.stdin.read()
start, end = raw.find("["), raw.rfind("]")
devices = json.loads(raw[start:end + 1]) if start != -1 and end != -1 else []
ios = [d for d in devices
       if d.get("targetPlatform", "").startswith("ios") and not d.get("emulator")]

# Flutter reports wireless and wired devices identically in --machine output, so
# a stale Wi-Fi pairing (offline, but still remembered) can sort first and get
# picked. devicectl does distinguish them, so use it to subtract the wireless
# ones. Devices it cannot see at all — anything on iOS 16 or older, which
# predates CoreDevice — are simply never excluded, which is the behavior we want.
wireless = set()
try:
    out = subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", "-"],
                         capture_output=True, text=True, timeout=60).stdout
    for dev in json.loads(out).get("result", {}).get("devices", []):
        udid = dev.get("hardwareProperties", {}).get("udid")
        transport = dev.get("connectionProperties", {}).get("transportType")
        if udid and transport == "localNetwork":
            wireless.add(udid)
except Exception:
    pass

wired = [d for d in ios if d["id"] not in wireless]

if len(wired) == 1:
    print(wired[0]["id"])
    sys.exit(0)

if not ios:
    sys.stderr.write("error: no iOS device detected.\n")
elif not wired:
    sys.stderr.write("error: the only iOS devices detected are wireless/offline pairings:\n")
    for d in ios:
        sys.stderr.write("  {} ({})\n".format(d["name"], d["id"]))
else:
    sys.stderr.write("error: multiple iOS devices detected; pick one with IOS_DEVICE_ID=<udid>:\n")
    for d in wired:
        sys.stderr.write("  {} ({}) {}\n".format(d["name"], d["id"], d.get("sdk", "")))
sys.exit(1)
')" || {
    echo "       Plug in your iPhone, unlock it, trust this Mac, and enable Developer" >&2
    echo "       Mode (Settings > Privacy & Security > Developer Mode)." >&2
    exit 1
  }
fi

if [ "$device_id" = "explicit" ]; then
  exec flutter run "$@"
fi

echo "Running on device: $device_id"
exec flutter run -d "$device_id" "$@"
