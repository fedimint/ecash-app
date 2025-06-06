generate:
  flutter_rust_bridge_codegen generate --rust-input=crate --rust-root=$ROOT/rust/carbine_fedimint --dart-output=$ROOT/lib/
  # `freezed_annotation` requires this build step, which gives us rust-like pattern matching in dart's codegen
  flutter pub run build_runner build --delete-conflicting-outputs

build-android-x86_64:
  $ROOT/scripts/build-android.sh

build-android-arm:
  $ROOT/scripts/build-arm-android.sh

build-linux:
  $ROOT/scripts/build-linux.sh

run:
  nix run --impure github:guibou/nixGL flutter run
