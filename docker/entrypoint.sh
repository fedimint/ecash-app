#!/bin/bash
set -e

# This script builds the APK inside the Docker container
# It mirrors the GitHub Actions workflow

echo "==================================="
echo "Building Ecash App APK"
echo "==================================="

BUILD_MODE="${1:-debug}"

if [[ "$BUILD_MODE" != "debug" && "$BUILD_MODE" != "release" ]]; then
    echo "Error: Build mode must be 'debug' or 'release'"
    echo "Usage: $0 [debug|release]"
    exit 1
fi

echo "Build mode: $BUILD_MODE"
echo ""

# Conditional cleaning based on CLEAN flag
if [[ "${CLEAN}" == "1" ]]; then
    echo "CLEAN=1 enabled - wiping all build caches..."
    flutter clean
    rm -rf android/.gradle android/build build
    rm -rf rust/ecashapp/target
else
    echo "Quick build - using incremental build caches..."
fi
echo ""

# Setup gradle properties (matching GitHub Actions)
echo "Configuring Gradle..."
mkdir -p android
cat > android/gradle.properties <<EOF
org.gradle.daemon=false
org.gradle.parallel=false
org.gradle.configureondemand=true
org.gradle.workers.max=2
org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G -XX:ReservedCodeCacheSize=512m -XX:+HeapDumpOnOutOfMemoryError
android.useAndroidX=true
android.enableJetifier=true
android.ndkVersion=27.3.13750724
EOF

# Get Flutter dependencies
echo "Getting Flutter dependencies..."
flutter pub get

# Build Rust library for Android
echo "Building Rust library for aarch64-linux-android..."
RUST_DIR="/workspace/rust/ecashapp"
JNI_LIBS_DIR="/workspace/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI_LIBS_DIR"

# Set up environment variables for cross-compilation (matching GitHub Actions)
export CC_aarch64_linux_android="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang"
export CXX_aarch64_linux_android="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang++"
export AR_aarch64_linux_android="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang"
export CFLAGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
export CXXFLAGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include -I$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export ANDROID_NDK="$ANDROID_NDK_HOME"

cd "$RUST_DIR"
cargo ndk -t arm64-v8a -o "$JNI_LIBS_DIR" build --release --target aarch64-linux-android

# Move .so files to correct location
find "$JNI_LIBS_DIR" -type f -name '*.so' -exec mv {} "$JNI_LIBS_DIR" \;
find "$JNI_LIBS_DIR" -type d -empty -delete

# Copy libc++_shared.so (required for Android)
cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$JNI_LIBS_DIR/" 2>/dev/null || true

cd /workspace

# Build Flutter APK
echo "Building Flutter APK..."
flutter build apk --$BUILD_MODE

# Rename APK with version and timestamp
APP_NAME=$(grep '^name:' pubspec.yaml | sed 's/name: //')
VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OLD_APK="build/app/outputs/flutter-apk/app-${BUILD_MODE}.apk"
NEW_APK="build/app/outputs/flutter-apk/${APP_NAME}-${VERSION}-${BUILD_MODE}-${TIMESTAMP}.apk"

mv "$OLD_APK" "$NEW_APK"

echo ""
echo "==================================="
echo "Build complete!"
echo "==================================="
echo "APK location: $NEW_APK"
