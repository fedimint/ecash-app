{
  description = "Dev environment for developing the flutter application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true; # Needed for Android Studio / some Flutter deps
        };

        # Rust with rust-src for flutter_rust_bridge codegen
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" ];
        };

        # Flutter (from nixpkgs, comes with Dart)
        flutter = pkgs.flutter;

        # Justfile runner
        just = pkgs.just;
      in {
        devShells.default = pkgs.mkShell {
          name = "flutter-rust-dev";
          packages = [
            rustToolchain
            flutter
            just
          ];

          # Setup environment for Flutter and Rust bridge codegen
          shellHook = ''
            export PATH="$PATH:${flutter}/bin"
            export RUST_SRC_PATH="${rustToolchain}/lib/rustlib/src/rust/library"
            echo "🌟 Dev shell ready with Flutter, Rust, and Just"
          '';
        };
      });
}

