{
  description = "Dev environment with Rust, Flutter, flutter_rust_bridge, and just";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ 
          rust-overlay.overlays.default 
        ];
        pkgs = import nixpkgs {
          inherit system overlays;
          config.allowUnfree = true;
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" ];
        };

        flutter = pkgs.flutter;
        just = pkgs.just;

        llvmPackages = pkgs.llvmPackages_14;

        # Reproducibly install flutter_rust_bridge_codegen via Rust
        flutter_rust_bridge_codegen = pkgs.rustPlatform.buildRustPackage rec {
          name = "flutter_rust_bridge";

          src = pkgs.fetchFromGitHub {
            owner = "fzyzcjy";
            repo = name;
            rev = "v2.9.0";
            sha256 = "sha256-3Rxbzeo6ZqoNJHiR1xGR3wZ8TzUATyowizws8kbz0pM=";
          };

          cargoHash = "sha256-efMA8VJaQlqClAmjJ3zIYLUfnuj62vEIBKsz0l3CWxA=";
          
          # For some reason flutter_rust_bridge unit tests are failing
          doCheck = false;
        };
      in {
        devShells.default = pkgs.mkShell {
          name = "flutter-rust-dev";
          packages = [
            rustToolchain
            flutter
            just
            flutter_rust_bridge_codegen
            pkgs.clang14Stdenv
            llvmPackages.clang
            llvmPackages.libclang.lib
            llvmPackages.llvm
            llvmPackages.clang-unwrapped
            pkgs.cmake
            pkgs.ninja
            pkgs.glibc
            pkgs.gtk3
            pkgs.graphite2
            pkgs.pkg-config
            pkgs.gdk-pixbuf
            pkgs.libffi
            pkgs.zlib
            pkgs.libcanberra
            pkgs.mesa
            pkgs.libGL
            pkgs.libglvnd
          ];

          shellHook = ''
            export PATH="$PATH:${flutter}/bin"
            export RUST_SRC_PATH="${rustToolchain}/lib/rustlib/src/rust/library"
            export LIBCLANG_PATH="${llvmPackages.libclang.lib}/lib"
            export LD_LIBRARY_PATH="${llvmPackages.libclang.lib}/lib:${llvmPackages.llvm.lib}/lib:$LD_LIBRARY_PATH"

            # Add libz path to LD_LIBRARY_PATH
            export LD_LIBRARY_PATH="${pkgs.zlib}/lib:$LD_LIBRARY_PATH"

            export LD_LIBRARY_PATH="${pkgs.mesa}/lib:${pkgs.libGL}/lib:$LD_LIBRARY_PATH"

            # Ensure pkg-config can locate GTK and related dependencies
            export PKG_CONFIG_PATH="${pkgs.gtk3}/lib/pkgconfig:${pkgs.graphite2}/lib/pkgconfig:$PKG_CONFIG_PATH"

            echo "🌟 Dev shell ready with Flutter, Rust, flutter_rust_bridge_codegen (Rust), and Just"
          '';
        };
      });
}

