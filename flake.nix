{
  inputs = {
    fedimint.url = "github:fedimint/fedimint?rev=55a144e5592fd5dc77997743e24ed414aac14e31";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, fedimint, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # Import the `devShells` from the fedimint flake
        devShells = fedimint.devShells.${system};
      in {
        devShells = {
          # You can expose all or specific shells from the original flake
          default = devShells.default.overrideAttrs (old: {
            nativeBuildInputs = old.nativeBuildInputs or [] ++ [
              fedimint.packages.${system}.devimint
              fedimint.packages.${system}.gateway-pkgs
            ];
          });
        };
      }
    );
}
