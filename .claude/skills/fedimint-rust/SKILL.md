---
name: "fedimint-rust"
description: "Guide Claude on Ecash App's Rust backend architecture, Fedimint SDK integration patterns, multimint wallet management, error handling, async operations, and database schema patterns"
allowed-tools: ["Read", "Grep", "Bash"]
---

# Fedimint Rust Architecture for Ecash App

You are assisting with the Ecash App Rust codebase. Understand these key patterns:

## Core Architecture

### Global State Management (rust/ecashapp/src/lib.rs)

The application uses `OnceCell` for global state initialization:

- **MULTIMINT** - Main wallet instance managing multiple federation clients
- **DATABASE** - RocksDB database for persistent storage
- **NOSTR** - Nostr client for federation discovery and backup
- **EVENT_BUS** - Event publishing system for UI updates
- **RECOVERY_RELAYS** - Nostr relays for backup/recovery operations

These are initialized once and accessed via getter functions like `get_multimint()`, `get_database()`, `get_nostr_client()`, `get_event_bus()`.

### Multimint Core (rust/ecashapp/src/multimint.rs)

The `Multimint` struct is the heart of the wallet (~4000+ lines):

**Key Responsibilities:**
- Managing multiple Fedimint federation clients
- Building and caching federation clients
- Handling all payment operations (Lightning LNv1/LNv2, on-chain, ecash)
- Gateway selection and fee computation
- Running background tasks for monitoring payments, deposits, and backups
- Caching federation metadata and BTC prices

**Important Methods:**
- `new()` - Initialize with existing or new mnemonic
- `join_federation()` - Join a new federation via invite code
- `receive()`, `send()` - Lightning payment operations
- `receive_ecash()`, `send_ecash()` - Ecash operations
- `allocate_deposit_address()`, `withdraw()` - On-chain operations

### Nostr Integration (rust/ecashapp/src/nostr.rs)

Handles:
- Federation discovery via Nostr events (kind 38000)
- Backup/recovery of federation invite codes to Nostr relays
- Lightning Address registration via Nostr
- Nostr Wallet Connect (NWC) for external app integrations

### Database Schema (rust/ecashapp/src/db.rs)

RocksDB key/value types:
- `FederationConfigKey`, `FederationConfigKeyPrefix` - Federation configurations
- `LightningAddressKey`, `LightningAddressKeyPrefix` - Lightning Address configs
- `FederationMetaKey` - Federation metadata cache
- `BtcPriceKey`, `BtcPricesKey` - BTC price cache
- `BitcoinDisplayKey`, `FiatCurrencyKey` - User preferences
- `SeedPhraseAckKey` - Seed phrase acknowledgment status

### Event Bus (rust/ecashapp/src/event_bus.rs)

Publishes `MultimintEvent` to Flutter UI:
- `Lightning` - Lightning payment events
- `Ecash` - Ecash payment events
- `Deposit` - On-chain deposit events
- `Log` - Log messages for UI
- `Recovery` - Recovery progress updates
- `NostrRecovery` - Nostr backup recovery events

## Key Patterns When Reviewing Code

### 1. Error Handling

**Always use:**
```rust
use anyhow::{Result, Context};

pub async fn some_operation() -> Result<T> {
    let result = risky_operation()
        .await
        .context("Failed to perform risky operation")?;

    // For user-visible errors
    error_to_flutter("User-friendly error message").await;

    Ok(result)
}
```

**Key functions:**
- `error_to_flutter()` - Publish error to UI via event bus
- `info_to_flutter()` - Publish info message to UI
- `.context()` - Add context to errors for better debugging

### 2. Async Operation Patterns

**Payment operations should:**
1. Return `OperationId` immediately
2. Spawn background task to monitor completion
3. Publish events via `EVENT_BUS` for UI updates

Example pattern:
```rust
pub async fn receive() -> Result<(String, OperationId, String, String, BigInt)> {
    // Create operation
    let operation_id = client.receive_payment(...).await?;

    // Spawn background monitoring task
    spawn_await_receive(federation_id, operation_id);

    // Return immediately
    Ok((invoice, operation_id, ...))
}
```

### 3. Flutter Rust Bridge Integration

**Functions exposed to Dart:**
- Must have `#[frb]` attribute
- Use compatible types (primitives, String, Vec, structs with `#[derive(Serialize)]`)
- Return `Result<T>` for error handling
- Avoid lifetimes in public API

**Example:**
```rust
#[frb]
pub async fn create_new_multimint(path: String) -> Result<()> {
    // Implementation
}
```

### 4. Fedimint SDK Integration (v0.9.0)

**Available Modules:**
- `fedimint-mint-client` - Ecash mint operations (reissuing notes)
- `fedimint-ln-client` - Lightning v1 (legacy, for older gateways)
- `fedimint-lnv2-client` - Lightning v2 (preferred, modern gateways)
- `fedimint-wallet-client` - On-chain Bitcoin operations (peg-in/peg-out)
- `fedimint-meta-client` - Federation metadata

**Key Concepts:**
- **Federation** - A mint (set of guardians) users join via invite codes
- **Multimint** - Managing multiple federations in one wallet
- **Gateway** - Lightning node that routes payments for a federation
- **Operation** - Async payment operation tracked by `OperationId`
- **Client** - Per-federation client instance (`ClientHandleArc`)

### 5. Database Operations

**Always:**
- Use proper key types from `db.rs`
- Use database transactions for atomic operations
- Avoid direct RocksDB access, use abstraction methods

**Example:**
```rust
let config = db.begin_transaction()
    .await
    .get_value(&FederationConfigKey(federation_id))
    .await?;
```

## Development Workflow

When modifying Rust code:

1. **Add/modify functions** with `#[frb]` attribute if exposing to Dart
2. **Run code generation**: `nix develop -c just generate`
3. **Verify bindings**: Check `lib/lib.dart` and `lib/multimint.dart` for errors
4. **Test changes**: `nix develop -c just run` on Linux

## Common Pitfalls

1. **Missing `#[frb]` attribute** - Public functions won't be exposed to Dart
2. **Incompatible return types** - Use FRB-compatible types only
3. **Blocking async operations** - Always spawn background tasks for long-running ops
4. **Direct error propagation** - Use `error_to_flutter()` for user-visible errors
5. **Bypassing database abstractions** - Always use defined key types
6. **Not handling recovery** - Background tasks must handle federation recovery state

## Federation Client Lifecycle

1. **Building**: `build_client()` creates new client from invite code
2. **Caching**: Clients cached in `Multimint.clients` HashMap
3. **Recovery**: Clients may be in recovery mode, check before operations
4. **Background Tasks**: Each client has monitoring tasks for operations

## Gateway Selection

- **LNv1**: Uses `lnv1_select_gateway()` with fee comparison
- **LNv2**: Uses `lnv2_select_gateway()` with routing hints
- **Caching**: Gateway metadata cached with periodic updates
- **Fee Computation**: Calculate send/receive amounts with gateway fees

## Testing Considerations

- Mock database with `MemDatabase` for unit tests
- Use testnet federations for integration tests
- Verify event publishing in background tasks
- Check recovery progress updates
