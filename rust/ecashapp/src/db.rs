use std::time::SystemTime;

use bitcoin::hashes::sha256;
use fedimint_core::{
    config::{ClientConfig, FederationId},
    encoding::{Decodable, Encodable},
    impl_db_lookup, impl_db_record,
    util::SafeUrl,
};
use serde::{Deserialize, Serialize};

use crate::multimint::FederationMeta;

/// Local enum for DB backward compatibility after migration from fedimint 0.9.0 to 0.10.0.
/// Previously imported from fedimint_api_client::api::net::Connector.
///
/// This was originally used in build_client() to specify connection type (TCP/Tor),
/// but was removed in 681fa2a when invite codes were refactored out of the database.
/// The field remains in FederationConfig for schema compatibility with existing databases,
/// but is no longer read - connection behavior is now determined by ConnectorRegistry.
#[derive(
    Debug, Clone, Copy, Eq, PartialEq, Encodable, Decodable, Serialize, Deserialize, Default,
)]
pub(crate) enum Connector {
    #[default]
    Tcp,
    Tor,
}

#[repr(u8)]
#[derive(Clone, Debug)]
pub(crate) enum DbKeyPrefix {
    FederationConfig = 0x00,
    ClientDatabase = 0x01,
    SeedPhraseAck = 0x02,
    Nwc = 0x03,
    FederationMeta = 0x04,
    BtcPrice = 0x05,
    NostrRelays = 0x06,
    LightningAddress = 0x07,
    Display = 0x08,
    FederationBackup = 0x09,
    FederationOrder = 0x0A,
    FiatCurrency = 0x0B,
    BtcPrices = 0x0C,
    Contact = 0x0D,
    ContactSyncConfig = 0x10,
    SchemaVersion = 0x11,
    PinCodeHash = 0x12,
    RequirePinForSpending = 0x13,
    ShowMsats = 0x14,
    WalletV2PendingDeposit = 0x15,
    NwcV2 = 0x16,
    PinCredential = 0x17,
    PinAttempts = 0x18,
}

#[derive(Debug, Clone, Encodable, Decodable, Eq, PartialEq, Hash, Ord, PartialOrd)]
pub(crate) struct FederationConfigKey {
    pub(crate) id: FederationId,
}

#[derive(Debug, Clone, Eq, PartialEq, Encodable, Decodable, Serialize, Deserialize)]
pub(crate) struct FederationConfig {
    pub connector: Connector,
    pub federation_name: String,
    pub network: Option<String>,
    pub client_config: ClientConfig,
}

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct FederationConfigKeyPrefix;

impl_db_record!(
    key = FederationConfigKey,
    value = FederationConfig,
    db_prefix = DbKeyPrefix::FederationConfig,
);

impl_db_lookup!(
    key = FederationConfigKey,
    query_prefix = FederationConfigKeyPrefix
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct SeedPhraseAckKey;

impl_db_record!(
    key = SeedPhraseAckKey,
    value = (),
    db_prefix = DbKeyPrefix::SeedPhraseAck,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct NostrWalletConnectKey {
    pub(crate) federation_id: FederationId,
}

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct NostrWalletConnectKeyPrefix;

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct NostrWalletConnectConfig {
    pub(crate) secret_key: [u8; 32],
    pub(crate) relay: String,
}

impl_db_record!(
    key = NostrWalletConnectKey,
    value = NostrWalletConnectConfig,
    db_prefix = DbKeyPrefix::Nwc,
);

impl_db_lookup!(
    key = NostrWalletConnectKey,
    query_prefix = NostrWalletConnectKeyPrefix,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct NostrWalletConnectV2Key {
    pub(crate) federation_id: FederationId,
}

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct NostrWalletConnectV2KeyPrefix;

/// NWC pairing state, with the two independent keypairs NIP-47 calls for.
///
/// The wallet service keeps `service_secret_key` and never discloses it; the
/// connection URI carries `client_secret_key` instead. Only the public key
/// derived from `client_secret_key` is accepted as a request author, which is
/// what stops an arbitrary relay observer from spending.
///
/// This replaces the [`DbKeyPrefix::Nwc`] records, which stored a single
/// keypair used as *both* identities — so every connection URI ever issued
/// contained the wallet service's own secret key. Those records are purged
/// rather than migrated: a leaked service key cannot be un-leaked, so the only
/// way to revoke it is to make the user pair again.
#[derive(Debug, Encodable, Decodable)]
pub(crate) struct NostrWalletConnectV2Config {
    pub(crate) service_secret_key: [u8; 32],
    pub(crate) client_secret_key: [u8; 32],
    pub(crate) relay: String,
}

impl_db_record!(
    key = NostrWalletConnectV2Key,
    value = NostrWalletConnectV2Config,
    db_prefix = DbKeyPrefix::NwcV2,
);

impl_db_lookup!(
    key = NostrWalletConnectV2Key,
    query_prefix = NostrWalletConnectV2KeyPrefix,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct FederationMetaKey {
    pub(crate) federation_id: FederationId,
}

impl_db_record!(
    key = FederationMetaKey,
    value = FederationMeta,
    db_prefix = DbKeyPrefix::FederationMeta,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct FederationMetaKeyPrefix;

impl_db_lookup!(
    key = FederationMetaKey,
    query_prefix = FederationMetaKeyPrefix,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct BtcPriceKey;

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct BtcPrice {
    pub(crate) price: u64,
    pub(crate) last_updated: SystemTime,
}

impl_db_record!(
    key = BtcPriceKey,
    value = BtcPrice,
    db_prefix = DbKeyPrefix::BtcPrice,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct BtcPricesKey;

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct BtcPrices {
    pub(crate) usd: u64,
    pub(crate) eur: u64,
    pub(crate) gbp: u64,
    pub(crate) cad: u64,
    pub(crate) chf: u64,
    pub(crate) aud: u64,
    pub(crate) jpy: u64,
    pub(crate) last_updated: SystemTime,
}

impl_db_record!(
    key = BtcPricesKey,
    value = BtcPrices,
    db_prefix = DbKeyPrefix::BtcPrices,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct NostrRelaysKey {
    pub uri: String,
}

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct NostrRelaysKeyPrefix;

impl_db_record!(
    key = NostrRelaysKey,
    value = SystemTime,
    db_prefix = DbKeyPrefix::NostrRelays,
);

impl_db_lookup!(key = NostrRelaysKey, query_prefix = NostrRelaysKeyPrefix,);

#[derive(Debug, Encodable, Decodable)]
pub struct LightningAddressKey {
    pub federation_id: FederationId,
}

#[derive(Debug, Encodable, Decodable)]
pub struct LightningAddressKeyPrefix;

#[derive(Debug, Clone, Encodable, Decodable, Serialize)]
pub struct LightningAddressConfig {
    pub username: String,
    pub domain: String,
    pub recurringd_api: SafeUrl,
    pub ln_address_api: SafeUrl,
    pub lnurl: String,
    pub authentication_token: String,
}

impl_db_record!(
    key = LightningAddressKey,
    value = LightningAddressConfig,
    db_prefix = DbKeyPrefix::LightningAddress,
);

impl_db_lookup!(
    key = LightningAddressKey,
    query_prefix = LightningAddressKeyPrefix,
);

#[derive(Debug, Clone, Encodable, Decodable, Serialize)]
pub enum BitcoinDisplay {
    Bip177,
    Sats,
    Nothing,
    Symbol,
}

#[derive(Debug, Encodable, Decodable)]
pub struct BitcoinDisplayKey;

impl_db_record!(
    key = BitcoinDisplayKey,
    value = BitcoinDisplay,
    db_prefix = DbKeyPrefix::Display,
);

#[derive(Debug, Clone, Encodable, Decodable, Serialize)]
pub enum FiatCurrency {
    Usd,
    Eur,
    Gbp,
    Cad,
    Chf,
    Aud,
    Jpy,
}

#[derive(Debug, Encodable, Decodable)]
pub struct FiatCurrencyKey;

impl_db_record!(
    key = FiatCurrencyKey,
    value = FiatCurrency,
    db_prefix = DbKeyPrefix::FiatCurrency,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct FederationBackupKey {
    pub(crate) federation_id: FederationId,
}

impl_db_record!(
    key = FederationBackupKey,
    value = SystemTime,
    db_prefix = DbKeyPrefix::FederationBackup,
);

#[derive(Debug, Encodable, Decodable)]
pub struct FederationOrderKey;

#[derive(Debug, Clone, Encodable, Decodable, Serialize)]
pub struct FederationOrder {
    pub order: Vec<FederationId>,
}

impl_db_record!(
    key = FederationOrderKey,
    value = FederationOrder,
    db_prefix = DbKeyPrefix::FederationOrder,
);

// Contact - stores Nostr profile data for address book
#[derive(Debug, Clone, Encodable, Decodable, Eq, PartialEq, Hash, Ord, PartialOrd)]
pub struct ContactKey {
    pub npub: String,
}

#[derive(Debug, Encodable, Decodable)]
pub struct ContactKeyPrefix;

#[derive(Debug, Clone, Encodable, Decodable, Serialize, Deserialize)]
pub struct Contact {
    pub npub: String,
    pub name: Option<String>,
    pub display_name: Option<String>,
    pub picture: Option<String>,
    pub lud16: Option<String>, // Lightning Address
    pub nip05: Option<String>,
    pub nip05_verified: bool,
    pub about: Option<String>,
    pub created_at: u64,           // Unix timestamp in milliseconds
    pub last_paid_at: Option<u64>, // Unix timestamp in milliseconds
}

// ContactCursor - used for paginated contact queries
#[derive(Debug, Clone, Encodable, Decodable, Serialize, Deserialize)]
pub struct ContactCursor {
    pub last_paid_at: Option<u64>,
    pub created_at: u64,
    pub npub: String,
}

impl_db_record!(
    key = ContactKey,
    value = Contact,
    db_prefix = DbKeyPrefix::Contact,
);

impl_db_lookup!(key = ContactKey, query_prefix = ContactKeyPrefix,);

// ContactSyncConfig - stores configuration for automatic contact syncing from Nostr
#[derive(Debug, Encodable, Decodable)]
pub struct ContactSyncConfigKey;

#[derive(Debug, Clone, Encodable, Decodable, Serialize, Deserialize)]
pub struct ContactSyncConfig {
    pub npub: String,              // The npub to sync contacts from
    pub last_sync_at: Option<u64>, // Unix timestamp in milliseconds
    pub sync_enabled: bool,        // Whether auto-sync is active
}

impl_db_record!(
    key = ContactSyncConfigKey,
    value = ContactSyncConfig,
    db_prefix = DbKeyPrefix::ContactSyncConfig,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct SchemaVersionKey;

impl_db_record!(
    key = SchemaVersionKey,
    value = u64,
    db_prefix = DbKeyPrefix::SchemaVersion,
);

/// Legacy PIN storage: a bare, unsalted, single-round SHA-256 of the PIN.
///
/// A PIN is 4-6 digits, so there are at most 1.1M candidates — anyone who could
/// read the database file recovered the PIN by table lookup. Superseded by
/// [`PinCredentialKey`].
///
/// This is deliberately still defined and still read. A SHA-256 digest cannot be
/// turned into an Argon2 hash without the plaintext PIN, and the plaintext only
/// exists at unlock time, so there is nothing a startup migration could do here
/// except delete the record and lock users out of their own wallets. Instead
/// `Multimint::verify_pin` verifies against this record when it is the only one
/// present and rewrites it as a [`PinCredentialKey`] in the same transaction.
#[derive(Debug, Encodable, Decodable)]
pub(crate) struct PinCodeHashKey;

impl_db_record!(
    key = PinCodeHashKey,
    value = sha256::Hash,
    db_prefix = DbKeyPrefix::PinCodeHash,
);

/// The PIN as an Argon2id PHC string, e.g.
/// `$argon2id$v=19$m=19456,t=2,p=1$<b64 salt>$<b64 hash>`.
///
/// The PHC string carries its own parameters and salt, so raising the Argon2
/// cost later needs no schema change: existing records keep verifying under the
/// parameters they were written with.
///
/// Argon2 does not make a 6-digit PIN a strong secret. At the current
/// parameters one guess costs ~12 ms on a 2026 laptop, so the full 10^6
/// keyspace is a few CPU-hours — hours instead of milliseconds, and the 19 MiB
/// working set is what keeps that from collapsing on a GPU, but it is not a
/// wall. Only encrypting the database keeps a stolen copy of it out of reach;
/// that is tracked separately. What actually stops guessing *on the device* is
/// the backoff in [`PinAttempts`].
#[derive(Debug, Encodable, Decodable)]
pub(crate) struct PinCredentialKey;

impl_db_record!(
    key = PinCredentialKey,
    value = String,
    db_prefix = DbKeyPrefix::PinCredential,
);

/// Consecutive failed PIN entries, and when entry reopens.
///
/// Persisted rather than held in memory so that force-quitting the app does not
/// reset the backoff — otherwise the throttle would be worth nothing against
/// someone holding the device.
#[derive(Debug, Clone, Encodable, Decodable)]
pub(crate) struct PinAttempts {
    pub(crate) consecutive_failures: u32,
    /// Unix epoch milliseconds; `0` means "not currently locked out".
    pub(crate) locked_until_ms: u64,
}

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct PinAttemptsKey;

impl_db_record!(
    key = PinAttemptsKey,
    value = PinAttempts,
    db_prefix = DbKeyPrefix::PinAttempts,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct RequirePinForSpendingKey;

impl_db_record!(
    key = RequirePinForSpendingKey,
    value = (),
    db_prefix = DbKeyPrefix::RequirePinForSpending,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct ShowMsatsKey;

impl_db_record!(
    key = ShowMsatsKey,
    value = (),
    db_prefix = DbKeyPrefix::ShowMsats,
);

/// Tracks every walletv2 receive (peg-in) address we have handed out, which is
/// the source of truth for the deposit-address list shown in the UI. Unlike
/// walletv1, walletv2 creates no client operation at address-allocation time
/// (the module's background scanner only records a deposit once it is already
/// confirmed), so there is nothing in the Fedimint client DB to enumerate these
/// from.
///
/// The value is the deposited amount in sats once the federation has recorded
/// the deposit, or `None` while the address is still unfunded. A `None` entry
/// also tells the startup rescan to re-spawn the esplora poller that surfaces
/// the mempool/awaiting-confirmation UI; entries are never deleted, so funded
/// addresses keep showing in the list.
///
/// `federation_id` is encoded first so `WalletV2PendingDepositFederationPrefix`
/// is a valid key prefix for per-federation lookups.
#[derive(Debug, Clone, Encodable, Decodable, Eq, PartialEq, Hash, Ord, PartialOrd)]
pub(crate) struct WalletV2PendingDepositKey {
    pub(crate) federation_id: FederationId,
    pub(crate) address: String,
}

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct WalletV2PendingDepositFederationPrefix {
    pub(crate) federation_id: FederationId,
}

impl_db_record!(
    key = WalletV2PendingDepositKey,
    value = Option<u64>,
    db_prefix = DbKeyPrefix::WalletV2PendingDeposit,
);

impl_db_lookup!(
    key = WalletV2PendingDepositKey,
    query_prefix = WalletV2PendingDepositFederationPrefix,
);
