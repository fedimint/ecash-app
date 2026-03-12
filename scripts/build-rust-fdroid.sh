#!/usr/bin/env bash
#
# Builds Rust native library for Android (F-Droid build)
#
# This script is called by F-Droid's build process to compile the Rust
# code into a native library that gets bundled into the Flutter APK.
#
# Usage: ./scripts/build-rust-fdroid.sh
#
# Environment:
#   ANDROID_NDK_HOME - Path to Android NDK (required)
#

set -ex

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Validate NDK
if [[ -z "$ANDROID_NDK_HOME" ]]; then
    echo "Error: ANDROID_NDK_HOME not set"
    exit 1
fi

RUST_TARGET="aarch64-linux-android"

# Set up bindgen for cross-compilation
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include -I$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

# Create jniLibs directory
JNI_LIBS_DIR="$PROJECT_ROOT/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI_LIBS_DIR"

# Build Rust library
# Platform 28 required: aws-lc-sys uses getentropy() which needs Android API 28+
cd "$PROJECT_ROOT/rust/ecashapp"
cargo ndk -t arm64-v8a --platform 28 -o "$JNI_LIBS_DIR" build --release --target "$RUST_TARGET"

# Flatten .so files (cargo-ndk puts them in subdirs)
find "$JNI_LIBS_DIR" -mindepth 2 -type f -name '*.so' -exec mv {} "$JNI_LIBS_DIR" \;
find "$JNI_LIBS_DIR" -mindepth 1 -type d -empty -delete

# Copy libc++_shared.so (required for Android)
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$JNI_LIBS_DIR/" 2>/dev/null || true

echo "Rust library built successfully"
