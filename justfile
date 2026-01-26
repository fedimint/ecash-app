generate:
  flutter_rust_bridge_codegen generate --rust-input=crate --rust-root=$ROOT/rust/ecashapp --dart-output=$ROOT/lib/
  # `freezed_annotation` requires this build step, which gives us rust-like pattern matching in dart's codegen
  flutter pub run build_runner build --delete-conflicting-outputs

build-android-x86_64:
  $ROOT/scripts/build-android.sh

build-android-arm:
  $ROOT/scripts/build-arm-android.sh

build-linux:
  $ROOT/scripts/build-linux.sh

build-debug-apk:
  $ROOT/docker/build-apk.sh debug

build-appimage:
  $ROOT/docker/build-appimage.sh

run-appimage-nixos path:
  # This is needed in NixOS, if you are on another OS you can simply open the AppImage
  appimage-run {{path}}

run: build-linux
  flutter run

test:
  flutter test
