#!/usr/bin/env bash

# Detect host OS for NDK path
if [[ "$OSTYPE" == "darwin"* ]]; then
  NDK_HOST="darwin-x86_64"
else
  NDK_HOST="linux-x86_64"
fi

cd $ROOT/rust/ecashapp
export CC_aarch64_linux_android=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/bin/aarch64-linux-android21-clang
export CXX_aarch64_linux_android=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/bin/aarch64-linux-android21-clang++
cargo ndk -t arm64-v8a -o $ROOT/android/app/src/main/jniLibs build --release --target aarch64-linux-android
cp $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so $ROOT/android/app/src/main/jniLibs/arm64-v8a/
