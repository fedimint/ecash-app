#!/usr/bin/env bash

unset CC_aarch64_linux_android
unset CXX_aarch64_linux_android

PROFILE="${1:-release}"
cargo build --profile "$PROFILE" --manifest-path $ROOT/rust/ecashapp/Cargo.toml --target-dir $ROOT/rust/ecashapp/target

# Flutter Rust Bridge looks for the .so in target/release/.
# When using a custom profile, copy the library there so Flutter can find it.
if [ "$PROFILE" != "release" ]; then
    mkdir -p $ROOT/rust/ecashapp/target/release
    cp $ROOT/rust/ecashapp/target/$PROFILE/libecashapp.so $ROOT/rust/ecashapp/target/release/libecashapp.so
fi
