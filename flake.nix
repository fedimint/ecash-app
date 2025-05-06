{
  inputs = {
    fedimint.url = "github:fedimint/fedimint?rev=b983d25d4c3cce1751c54e3ad0230fc507e3aeec";
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, fedimint, flake-utils, nixpkgs, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        # Import the `devShells` from the fedimint flake
        devShells = fedimint.devShells.${system};

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
        devShells = {
          # You can expose all or specific shells from the original flake
          default = devShells.default.overrideAttrs (old: {
            nativeBuildInputs = old.nativeBuildInputs or [] ++ [
              pkgs.flutter
              pkgs.just
              pkgs.zlib
              flutter_rust_bridge_codegen
            ];
          });
        };
      }
    );
}
