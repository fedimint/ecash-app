generate:
  flutter_rust_bridge_codegen generate --rust-input=crate --rust-root=$ROOT/rust/carbine_fedimint --dart-output=$ROOT/lib/
  cargo build --release --manifest-path $ROOT/rust/carbine_fedimint/Cargo.toml --target-dir $ROOT/rust/carbine_fedimint/target

run:
  nix run --impure github:guibou/nixGL flutter run
