---
name: "frb-integration"
description: "Guide Claude on Flutter Rust Bridge bidirectional communication patterns, code generation workflow, type mapping, event streams, and common integration pitfalls in the Ecash app"
allowed-tools: ["Read", "Grep"]
---

# Flutter Rust Bridge (FRB) Integration

This skill teaches the bidirectional communication patterns between Flutter (Dart) and Rust in the Ecash App.

## Architecture Overview

The bridge enables two-way communication:

1. **Dart → Rust**: Direct function calls to Rust backend
2. **Rust → Dart**: Event streaming via `EventBus`

## Dart → Rust: Function Calls

### Exposing Rust Functions to Dart

Functions marked with `#[frb]` in Rust are automatically exposed to Dart:

**Rust Side (rust/ecashapp/src/lib.rs or multimint.rs):**
```rust
#[frb]
pub async fn create_new_multimint(path: String) -> Result<()> {
    // Implementation
}

#[frb]
pub async fn join_federation(
    invite_code: String,
    recover: bool,
) -> Result<FederationSelector> {
    // Implementation
}
```

**Generated Dart Side (lib/lib.dart):**
```dart
Future<void> createNewMultimint({required String path}) =>
    RustLib.instance.api.crateCreateNewMultimint(path: path);

Future<FederationSelector> joinFederation({
  required String inviteCode,
  required bool recover,
}) => RustLib.instance.api.crateJoinFederation(
  inviteCode: inviteCode,
  recover: recover,
);
```

### Struct Methods

For `impl` methods on structs:

**Rust Side:**
```rust
#[frb]
pub struct Multimint { ... }

#[frb]
impl Multimint {
    pub async fn balance(&self, federation_id: FederationId) -> Result<BigInt> {
        // Implementation
    }
}
```

**Generated Dart Side (lib/multimint.dart):**
```dart
abstract class Multimint implements RustOpaqueInterface {
  Future<BigInt> balance({required FederationId federationId});
}
```

## Rust → Dart: Event Streaming

### Event Bus Pattern

Rust publishes events to Dart via the `EventBus`:

**Rust Side (rust/ecashapp/src/lib.rs):**
```rust
// Publishing events
get_event_bus()
    .publish(MultimintEvent::Lightning(
        federation_id,
        LightningEventKind::InvoicePaid(payment_info)
    ))
    .await;
```

**Dart Side (lib/app.dart):**
```dart
// Subscribe to event stream
events = subscribeMultimintEvents().asBroadcastStream();
_subscription = events.listen((event) async {
    if (event is MultimintEvent_Lightning) {
        // Handle Lightning event
        final ln = event.field0.$2;
        if (ln is LightningEventKind_InvoicePaid) {
            // Update UI
        }
    } else if (event is MultimintEvent_Ecash) {
        // Handle Ecash event
    }
    // ... other event types
});
```

### Available Event Types

**MultimintEvent variants:**
- `Lightning(FederationId, LightningEventKind)` - Lightning payment events
- `Ecash(FederationId, u64)` - Ecash received (federation_id, amount_msats)
- `Deposit(FederationId, DepositEventKind)` - On-chain deposit events
- `Log(LogLevel, String)` - Log messages for UI
- `Recovery(FederationId, RecoveryProgress)` - Recovery progress
- `NostrRecovery(usize, usize, Option<FederationSelector>)` - Nostr recovery progress

## Type Mapping

### Compatible Types (Rust → Dart)

| Rust Type | Dart Type |
|-----------|-----------|
| `String` | `String` |
| `u64`, `i64` | `BigInt` |
| `u32`, `i32`, `u16`, `i16`, `u8`, `i8` | `int` |
| `bool` | `bool` |
| `Vec<T>` | `List<T>` |
| `Option<T>` | `T?` |
| `Result<T>` | `Future<T>` (throws on Err) |
| Structs with `#[derive(Serialize)]` | Dart classes |
| Enums | Freezed unions |

### Complex Type Example

**Rust:**
```rust
#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct PaymentPreview {
    pub amount_msats: u64,
    pub payment_hash: String,
    pub network: String,
    pub invoice: String,
    pub gateway: String,
    pub amount_with_fees: u64,
    pub is_lnv2: bool,
}
```

**Dart (generated):**
```dart
class PaymentPreview {
  final BigInt amountMsats;
  final String paymentHash;
  final String network;
  final String invoice;
  final String gateway;
  final BigInt amountWithFees;
  final bool isLnv2;
}
```

## Code Generation Workflow

### When to Run Code Generation

Run `just generate` after:

1. **Modifying Rust API:**
   - Adding/removing `#[frb]` functions
   - Changing function signatures
   - Adding new structs/enums exposed to Dart
   - Modifying struct fields

2. **Modifying Freezed Classes:**
   - Changing `@freezed` annotated Dart classes
   - Adding new data classes

### Code Generation Command

```bash
nix develop -c just generate
```

This runs:
1. `flutter_rust_bridge_codegen` - Generates Dart/Rust FFI bindings
2. `flutter pub run build_runner build` - Generates freezed classes

### Generated Files (DO NOT EDIT MANUALLY)

**Always auto-generated:**
- `lib/lib.dart` - Top-level Rust function bindings
- `lib/multimint.dart` - Multimint struct method bindings
- `lib/frb_generated.dart` - Core FFI implementation
- `lib/frb_generated.io.dart` - Platform-specific (native)
- `lib/frb_generated.web.dart` - Platform-specific (web)
- `lib/*.freezed.dart` - Freezed immutable data classes
- `rust/ecashapp/src/frb_generated.rs` - Rust FFI glue code

### Verification Steps

After running code generation:

1. **Check for errors** in generated Dart files
2. **Verify imports** resolve correctly
3. **Run Flutter analyzer**: `flutter analyze`
4. **Test compilation**: `nix develop -c just build-linux`

## Common Integration Patterns

### Pattern 1: Immediate Return + Background Monitoring

**Use for:** Long-running operations (payments, on-chain transactions)

```rust
#[frb]
pub async fn send(
    federation_id: FederationId,
    invoice: String,
) -> Result<OperationId> {
    let operation_id = multimint.send_payment(federation_id, invoice).await?;

    // Spawn background task
    spawn_await_send(federation_id, operation_id);

    // Return immediately
    Ok(operation_id)
}

// Dart receives OperationId, subscribes to events for completion
```

### Pattern 2: Direct Return

**Use for:** Quick operations (queries, configuration)

```rust
#[frb]
pub async fn balance(federation_id: FederationId) -> Result<BigInt> {
    let balance = get_multimint().balance(federation_id).await?;
    Ok(balance.msats.into())
}
```

### Pattern 3: Error Reporting to UI

```rust
#[frb]
pub async fn risky_operation() -> Result<()> {
    match some_operation().await {
        Ok(result) => Ok(result),
        Err(e) => {
            // Log to Flutter UI
            error_to_flutter(format!("Operation failed: {}", e)).await;
            Err(e)
        }
    }
}
```

## Common Pitfalls and Solutions

### Pitfall 1: Missing `#[frb]` Attribute

**Problem:**
```rust
pub async fn my_function() -> Result<String> {
    // Not exposed to Dart!
}
```

**Solution:**
```rust
#[frb]
pub async fn my_function() -> Result<String> {
    // Now exposed to Dart
}
```

### Pitfall 2: Incompatible Return Types

**Problem:**
```rust
#[frb]
pub async fn get_data() -> Result<&str> {
    // Lifetime not compatible with FFI
}
```

**Solution:**
```rust
#[frb]
pub async fn get_data() -> Result<String> {
    // Owned String works
}
```

### Pitfall 3: Blocking Long Operations

**Problem:**
```rust
#[frb]
pub async fn send_payment() -> Result<PaymentResult> {
    // Blocks Dart until complete (bad UX)
    client.send_and_wait().await
}
```

**Solution:**
```rust
#[frb]
pub async fn send_payment() -> Result<OperationId> {
    let op_id = client.send().await?;
    spawn_background_monitor(op_id); // Monitor in background
    Ok(op_id) // Return immediately
}
```

### Pitfall 4: Not Publishing Events

**Problem:**
```rust
// Payment completes in background, Dart never knows
async fn background_task() {
    let result = wait_for_payment().await;
    // No event published!
}
```

**Solution:**
```rust
async fn background_task() {
    let result = wait_for_payment().await;

    // Publish event to Dart
    get_event_bus()
        .publish(MultimintEvent::Lightning(fed_id, result))
        .await;
}
```

### Pitfall 5: Forgetting to Run Code Generation

**Problem:** Modified Rust API but Dart still uses old signatures

**Solution:** Always run `just generate` after Rust API changes

## File Organization

### Rust Side

- `rust/ecashapp/src/lib.rs` - Top-level functions (`create_new_multimint`, `join_federation`, etc.)
- `rust/ecashapp/src/multimint.rs` - `Multimint` struct and impl methods
- `rust/ecashapp/src/event_bus.rs` - Event publishing infrastructure
- `rust/ecashapp/src/frb_generated.rs` - **AUTO-GENERATED** FFI glue

### Dart Side

- `lib/lib.dart` - **AUTO-GENERATED** Top-level function bindings
- `lib/multimint.dart` - **AUTO-GENERATED** Multimint method bindings
- `lib/frb_generated.dart` - **AUTO-GENERATED** FFI core
- `lib/app.dart` - Event subscription and handling
- `lib/*.freezed.dart` - **AUTO-GENERATED** Freezed classes

## Integration Checklist

When adding new Rust functionality:

- [ ] Add `#[frb]` attribute to public functions
- [ ] Use FRB-compatible types (no lifetimes, use owned types)
- [ ] For long operations: return `OperationId`, spawn background task
- [ ] Publish events via `EVENT_BUS` for UI updates
- [ ] Use `error_to_flutter()` for user-visible errors
- [ ] Run `just generate` to update bindings
- [ ] Verify generated Dart code compiles
- [ ] Update Dart UI to handle new functions/events
- [ ] Test end-to-end flow

## Debugging Tips

1. **Check generated files** for compilation errors first
2. **Verify type compatibility** - use simple types for FFI boundary
3. **Test event flow** - ensure events reach Dart listener
4. **Use logging** - `info_to_flutter()` for debugging
5. **Inspect FRB errors** - codegen errors point to incompatible types
