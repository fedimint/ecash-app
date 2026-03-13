#!/usr/bin/env bash
set -euo pipefail

# Find system (non-Nix) Flutter — Nix's Flutter copies frameworks with
# read-only Nix store permissions that break Xcode's lipo
FLUTTER_CMD=$(which -a flutter 2>/dev/null | grep -v '/nix/' | head -1)
if [ -z "$FLUTTER_CMD" ]; then
  echo "Error: No system Flutter found. Install via: brew install flutter"
  exit 1
fi

# Strip Nix paths from PATH so the system Xcode toolchain is used
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/nix' | tr '\n' ':' | sed 's/:$//')

# Unset Nix build env vars that interfere with Xcode's toolchain
unset CC CXX LD AR NM RANLIB
unset NIX_CC NIX_CFLAGS_COMPILE NIX_LDFLAGS NIX_ENFORCE_PURITY
unset SDKROOT MACOSX_DEPLOYMENT_TARGET LD_LIBRARY_PATH

"$FLUTTER_CMD" run -d macos
