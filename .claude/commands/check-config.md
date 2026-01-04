---
description: "Verify NDK versions, build configuration, and dependency consistency"
allowed-tools: ["Read", "Grep"]
---

Check configuration consistency across the project:

1. NDK Versions:
   - android/app/build.gradle.kts (should be 27.3.13750724)
   - flake.nix (currently 27.0.12077973)
   - Report any mismatches

2. Build Configuration:
   - ABI filter (should be arm64-v8a only)
   - Min SDK version
   - Signing configuration

3. Dependencies:
   - Fedimint SDK version in rust/ecashapp/Cargo.toml (should be 0.9.0)
   - Flutter dependencies in pubspec.yaml
   - Flutter Rust Bridge version consistency (should be 2.9.0)

Report all findings with specific file:line references.
