# Flutter Version Management

Nix drives the Flutter version. Docker and CI follow.

## How it works

- `nixpkgs` in `flake.nix` determines the Flutter version for local dev
- `.flutter-version` tells Docker and CI which version to use
- When bumping nixpkgs, update `.flutter-version` to match

## Bump workflow

1. Update nixpkgs in `flake.nix` (e.g. `nixos-25.11` to `nixos-26.05`)
2. `nix flake update nixpkgs`
3. `nix develop` then `flutter --version` to see the new version
4. Update `.flutter-version` to match
5. `REBUILD_IMAGE=1 just build-debug-apk` to verify Docker builds
6. Push and verify CI passes
7. Fix any breakage (Kotlin, SDK platforms, pubspec.lock)
