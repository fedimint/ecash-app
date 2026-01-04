---
description: "Review Rust code changes for proper #[frb] annotations and patterns"
argument-hint: "[file-path]"
allowed-tools: ["Read", "Grep"]
---

Review Rust API changes in: $1

Check for:

1. **FRB Integration**:
   - Functions exposed to Dart have `#[frb]` attribute
   - Return types are FRB-compatible
   - No `pub` functions missing `#[frb]` that should have it

2. **Error Handling**:
   - Using `anyhow::Result` for error returns
   - Calling `error_to_flutter()` for user-visible errors
   - Proper context added with `.context()`

3. **Async Patterns**:
   - Payment operations return `OperationId` immediately
   - Long-running tasks use background spawning
   - Proper use of `MultimintEvent` for UI updates

4. **Database Operations**:
   - Using proper key types from db.rs
   - Transactions used where needed
   - No direct RocksDB access bypassing abstractions

Provide specific feedback with line numbers.
