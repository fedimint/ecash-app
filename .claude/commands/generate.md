---
description: "Generate Flutter Rust Bridge bindings and run Flutter codegen"
allowed-tools: ["Bash", "Read", "Grep"]
---

Run code generation for the Ecash App:

! nix develop -c just generate

After completion, verify:
1. Check for errors in generated lib/lib.dart and lib/multimint.dart
2. Verify lib/*.freezed.dart files were created
3. Look for any compilation errors

Report any issues found.
