use std::time::SystemTime;

use bitcoin::hashes::sha256;
use fedimint_core::{
    config::{ClientConfig, FederationId},
    encoding::{
        decode_legacy_system_time_from_finite_reader, encode_legacy_system_time, Decodable,
        DecodeError, Encodable,
    },
    impl_db_lookup, impl_db_record,
    module::registry::ModuleDecoderRegistry,
    util::SafeUrl,
};
use serde::{Deserialize, Serialize};

use crate::multimint::FederationMeta;

/// A `SystemTime` persisted in our database.
///
/// fedimint used to supply blanket `Encodable`/`Decodable` impls for
/// `SystemTime` and removed them in `b975ac4d`, because the blanket impls let
/// any derived type silently pick up a codec whose precision and range are
/// platform-dependent (Unix keeps nanoseconds, Windows truncates to 100ns
/// ticks). Wallets in the field already have timestamps on disk written that
/// way, so this re-supplies the encoding through the legacy
/// `(seconds, nanoseconds)` helpers upstream kept for exactly this case. The
/// bytes are unchanged and existing databases keep reading.
///
/// The portability argument that motivated the removal upstream does not really
/// reach these records — they are local RocksDB state on a single device, not
/// consensus or wire data — so preserving the stored format is the priority.
///
/// This is a newtype rather than hand-written impls on each record so that
/// adding a field to one of those records cannot silently drift from its
/// encoding: the derive keeps working.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Timestamp(pub(crate) SystemTime);

impl Encodable for Timestamp {
    fn consensus_encode<W: std::io::Write>(&self, writer: &mut W) -> Result<(), std::io::Error> {
        encode_legacy_system_time(&self.0, writer)
    }
}

impl Decodable for Timestamp {
    fn consensus_decode_partial_from_finite_reader<D: std::io::Read>(
        decoder: &mut D,
        modules: &ModuleDecoderRegistry,
    ) -> Result<Self, DecodeError> {
        Ok(Self(decode_legacy_system_time_from_finite_reader(
            decoder, modules,
        )?))
    }
}

impl From<SystemTime> for Timestamp {
    fn from(time: SystemTime) -> Self {
        Self(time)
    }
}

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
    NwcLimits = 0x19,
    NwcSpendWindow = 0x1A,
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
    pub(crate) last_updated: Timestamp,
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
    pub(crate) last_updated: Timestamp,
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
    value = Timestamp,
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
    value = Timestamp,
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

/// The single record holding every user-set bound on wallet-connect spending.
///
/// Absent means nothing has been changed from the built-in defaults. Readers
/// fall back to those defaults rather than to "no limit", so a missing record
/// can never widen what a paired app may spend.
#[derive(Debug, Encodable, Decodable)]
pub(crate) struct NwcLimitsKey;

/// Bounds on what a paired wallet-connect client may spend.
#[derive(Debug, Clone, Encodable, Decodable)]
pub(crate) struct NwcLimits {
    /// Ceiling on a single payment, in millisatoshis.
    pub(crate) max_payment_msats: u64,
    /// Ceiling on everything spent within one budget window, in millisatoshis.
    /// Bounds the relationship rather than the request: without it a client can
    /// repeat a payment at the per-payment ceiling indefinitely.
    pub(crate) daily_budget_msats: u64,
}

impl_db_record!(
    key = NwcLimitsKey,
    value = NwcLimits,
    db_prefix = DbKeyPrefix::NwcLimits,
);

#[derive(Debug, Encodable, Decodable)]
pub(crate) struct NwcSpendWindowKey;

/// How much wallet-connect has spent in the window that began at `started_at`.
///
/// Runtime state rather than user config, so it is kept apart from
/// [`NwcLimits`] — changing a limit must not disturb the running tally, and
/// clearing the tally must not touch the user's settings.
#[derive(Debug, Clone, Encodable, Decodable)]
pub(crate) struct NwcSpendWindow {
    pub(crate) started_at: Timestamp,
    pub(crate) spent_msats: u64,
}

impl_db_record!(
    key = NwcSpendWindowKey,
    value = NwcSpendWindow,
    db_prefix = DbKeyPrefix::NwcSpendWindow,
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

#[cfg(test)]
mod tests {
    use std::{
        collections::BTreeMap,
        str::FromStr,
        time::{Duration, UNIX_EPOCH},
    };

    use fedimint_core::{
        config::FederationId,
        db::{mem_impl::MemDatabase, Database, IDatabaseTransactionOpsCoreTyped as _},
        encoding::{Decodable, Encodable},
        module::registry::ModuleDecoderRegistry,
        util::SafeUrl,
    };
    use futures_util::StreamExt as _;

    use super::{
        BtcPrices, BtcPricesKey, Contact, ContactKey, DbKeyPrefix, FederationMetaKey,
        LightningAddressConfig, LightningAddressKey, NwcLimits, NwcLimitsKey, NwcSpendWindow,
        NwcSpendWindowKey, Timestamp, WalletV2PendingDepositFederationPrefix,
        WalletV2PendingDepositKey,
    };
    use crate::multimint::{FederationMeta, FederationSelector, Guardian};

    fn federation_id(byte: u8) -> FederationId {
        FederationId::from_str(&format!("{byte:02x}").repeat(32)).expect("valid federation id")
    }

    /// The blanket `Encodable for SystemTime` that fedimint removed in
    /// `b975ac4d` encoded `self.duration_since(UNIX_EPOCH)`, i.e. exactly a
    /// `Duration`. Wallets in the field have timestamps on disk in that form, so
    /// [`Timestamp`] must keep producing the identical bytes — if this ever
    /// diverges, every stored price cache, relay entry, backup time and NWC
    /// spend window becomes unreadable.
    #[test]
    fn timestamp_encodes_exactly_like_the_removed_system_time_codec() {
        for duration in [
            Duration::ZERO,
            Duration::from_secs(1),
            Duration::new(1_764_000_000, 123_456_789),
            Duration::new(u32::MAX as u64, 999_999_999),
        ] {
            assert_eq!(
                Timestamp(UNIX_EPOCH + duration).consensus_encode_to_vec(),
                duration.consensus_encode_to_vec(),
                "Timestamp must serialize as the bare duration since the epoch",
            );
        }
    }

    #[test]
    fn timestamp_round_trips() {
        let time = Timestamp(UNIX_EPOCH + Duration::new(1_764_000_000, 123_456_789));
        let bytes = time.consensus_encode_to_vec();
        let decoded =
            Timestamp::consensus_decode_whole(&bytes, &ModuleDecoderRegistry::default()).unwrap();
        assert_eq!(decoded, time);
    }

    const DB_KEY_PREFIX_COUNT: usize = 25;

    /// Every [`DbKeyPrefix`] variant, in declaration order. Kept complete by the
    /// exhaustive match in `db_key_prefix_bytes_are_unique_and_pinned`.
    const ALL_DB_KEY_PREFIXES: [DbKeyPrefix; DB_KEY_PREFIX_COUNT] = [
        DbKeyPrefix::FederationConfig,
        DbKeyPrefix::ClientDatabase,
        DbKeyPrefix::SeedPhraseAck,
        DbKeyPrefix::Nwc,
        DbKeyPrefix::FederationMeta,
        DbKeyPrefix::BtcPrice,
        DbKeyPrefix::NostrRelays,
        DbKeyPrefix::LightningAddress,
        DbKeyPrefix::Display,
        DbKeyPrefix::FederationBackup,
        DbKeyPrefix::FederationOrder,
        DbKeyPrefix::FiatCurrency,
        DbKeyPrefix::BtcPrices,
        DbKeyPrefix::Contact,
        DbKeyPrefix::ContactSyncConfig,
        DbKeyPrefix::SchemaVersion,
        DbKeyPrefix::PinCodeHash,
        DbKeyPrefix::RequirePinForSpending,
        DbKeyPrefix::ShowMsats,
        DbKeyPrefix::WalletV2PendingDeposit,
        DbKeyPrefix::NwcV2,
        DbKeyPrefix::PinCredential,
        DbKeyPrefix::PinAttempts,
        DbKeyPrefix::NwcLimits,
        DbKeyPrefix::NwcSpendWindow,
    ];

    /// Every record in the wallet lives in one flat keyspace, and the leading
    /// prefix byte is the only thing separating them.
    ///
    /// Two variants written with the *same* literal is the one case the compiler
    /// already rejects (E0081). What it does not catch is a variant declared
    /// without a discriminant: it silently takes `previous + 1`, which can
    /// renumber a record type that already has data on disk. Dropping the `=
    /// 0x10` from `ContactSyncConfig` moves it to `0x0E` and every stored sync
    /// config is orphaned, with nothing failing to build — the same silent
    /// storage drift the [`Timestamp`] newtype above exists to prevent. So this
    /// pins each variant's byte rather than only checking they differ.
    #[test]
    fn db_key_prefix_bytes_are_unique_and_pinned() {
        // Exhaustive by construction: adding a variant to `DbKeyPrefix` stops
        // this file compiling until the variant is listed here, and what it must
        // supply is its slot in `ALL_DB_KEY_PREFIXES`, so it cannot be
        // acknowledged here and then quietly left out of the checks below.
        fn slot_and_byte(prefix: &DbKeyPrefix) -> (usize, u8) {
            match prefix {
                DbKeyPrefix::FederationConfig => (0, 0x00),
                DbKeyPrefix::ClientDatabase => (1, 0x01),
                DbKeyPrefix::SeedPhraseAck => (2, 0x02),
                DbKeyPrefix::Nwc => (3, 0x03),
                DbKeyPrefix::FederationMeta => (4, 0x04),
                DbKeyPrefix::BtcPrice => (5, 0x05),
                DbKeyPrefix::NostrRelays => (6, 0x06),
                DbKeyPrefix::LightningAddress => (7, 0x07),
                DbKeyPrefix::Display => (8, 0x08),
                DbKeyPrefix::FederationBackup => (9, 0x09),
                DbKeyPrefix::FederationOrder => (10, 0x0A),
                DbKeyPrefix::FiatCurrency => (11, 0x0B),
                DbKeyPrefix::BtcPrices => (12, 0x0C),
                DbKeyPrefix::Contact => (13, 0x0D),
                DbKeyPrefix::ContactSyncConfig => (14, 0x10),
                DbKeyPrefix::SchemaVersion => (15, 0x11),
                DbKeyPrefix::PinCodeHash => (16, 0x12),
                DbKeyPrefix::RequirePinForSpending => (17, 0x13),
                DbKeyPrefix::ShowMsats => (18, 0x14),
                DbKeyPrefix::WalletV2PendingDeposit => (19, 0x15),
                DbKeyPrefix::NwcV2 => (20, 0x16),
                DbKeyPrefix::PinCredential => (21, 0x17),
                DbKeyPrefix::PinAttempts => (22, 0x18),
                DbKeyPrefix::NwcLimits => (23, 0x19),
                DbKeyPrefix::NwcSpendWindow => (24, 0x1A),
            }
        }

        let mut filled = [false; DB_KEY_PREFIX_COUNT];
        let mut by_byte: BTreeMap<u8, DbKeyPrefix> = BTreeMap::new();

        for prefix in ALL_DB_KEY_PREFIXES {
            let byte = prefix.clone() as u8;
            let (slot, expected_byte) = slot_and_byte(&prefix);

            assert_eq!(
                byte, expected_byte,
                "{prefix:?} changed prefix byte; every record already stored under \
                 {expected_byte:#04x} would be orphaned"
            );
            assert!(
                slot < DB_KEY_PREFIX_COUNT,
                "{prefix:?} claims slot {slot}, past the end of ALL_DB_KEY_PREFIXES"
            );
            assert!(
                !filled[slot],
                "{prefix:?} claims slot {slot}, which another variant already holds"
            );
            filled[slot] = true;

            if let Some(other) = by_byte.insert(byte, prefix.clone()) {
                panic!("{prefix:?} and {other:?} both use prefix byte {byte:#04x}");
            }
        }

        assert!(
            filled.iter().all(|filled| *filled),
            "a DbKeyPrefix variant has a slot but is missing from ALL_DB_KEY_PREFIXES"
        );
    }

    /// [`WalletV2PendingDepositKey`] encodes `federation_id` before `address`
    /// precisely so that [`WalletV2PendingDepositFederationPrefix`] is a real key
    /// prefix. That invariant lives entirely in the field order of a derive:
    /// swapping the two fields still compiles, and the deposit list for a
    /// federation would silently come back empty — losing the app's only record
    /// of which addresses it has handed out, since walletv2 creates no client
    /// operation to rebuild them from.
    #[tokio::test]
    async fn walletv2_pending_deposits_are_scannable_by_federation() {
        let db: Database = MemDatabase::new().into();
        let scanned = federation_id(0x11);
        let other = federation_id(0x22);

        let mut dbtx = db.begin_transaction().await;
        // Both states the record can be in: funded, and still awaiting coins.
        dbtx.insert_entry(
            &WalletV2PendingDepositKey {
                federation_id: scanned,
                address: "bcrt1qfunded".to_string(),
            },
            &Some(50_000),
        )
        .await;
        dbtx.insert_entry(
            &WalletV2PendingDepositKey {
                federation_id: scanned,
                address: "bcrt1qunfunded".to_string(),
            },
            &None,
        )
        .await;
        dbtx.insert_entry(
            &WalletV2PendingDepositKey {
                federation_id: other,
                address: "bcrt1qelsewhere".to_string(),
            },
            &Some(1),
        )
        .await;
        dbtx.commit_tx().await;

        let mut dbtx = db.begin_transaction_nc().await;
        let found = dbtx
            .find_by_prefix(&WalletV2PendingDepositFederationPrefix {
                federation_id: scanned,
            })
            .await
            .collect::<BTreeMap<_, _>>()
            .await;

        assert_eq!(
            found,
            BTreeMap::from([
                (
                    WalletV2PendingDepositKey {
                        federation_id: scanned,
                        address: "bcrt1qfunded".to_string(),
                    },
                    Some(50_000),
                ),
                (
                    WalletV2PendingDepositKey {
                        federation_id: scanned,
                        address: "bcrt1qunfunded".to_string(),
                    },
                    None,
                ),
            ]),
            "the scan must return exactly this federation's addresses"
        );

        // The other federation is reachable too, so an empty result above would
        // be a real failure rather than the prefix matching nothing at all.
        let found = dbtx
            .find_by_prefix(&WalletV2PendingDepositFederationPrefix {
                federation_id: other,
            })
            .await
            .collect::<Vec<_>>()
            .await;
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].0.address, "bcrt1qelsewhere");
    }

    /// Federation metadata is cached across restarts and re-rendered from disk,
    /// so a drift in its encoding shows up as a wallet whose federations lose
    /// their names, guardians and welcome screens. `Option` fields are exercised
    /// in both states because an absent value is what most encodings get wrong.
    #[tokio::test]
    async fn federation_meta_round_trips() {
        let db: Database = MemDatabase::new().into();
        let populated_id = federation_id(0x33);
        let sparse_id = federation_id(0x44);

        let populated = FederationMeta {
            picture: Some("https://example.com/fed.png".to_string()),
            welcome: Some("welcome to the federation".to_string()),
            guardians: vec![
                Guardian {
                    peer_id: 0,
                    name: "guardian-zero".to_string(),
                    version: Some("0.9.0".to_string()),
                },
                Guardian {
                    peer_id: 3,
                    name: "guardian-three".to_string(),
                    version: None,
                },
            ],
            selector: FederationSelector {
                federation_name: "Test Federation".to_string(),
                federation_id: populated_id,
                network: Some("signet".to_string()),
            },
            last_updated: 1_764_000_000_789,
            recurringd_api: Some("https://recurringd.example.com".to_string()),
            lnaddress_api: Some("https://lnaddress.example.com".to_string()),
        };
        let sparse = FederationMeta {
            picture: None,
            welcome: None,
            guardians: Vec::new(),
            selector: FederationSelector {
                federation_name: "Sparse Federation".to_string(),
                federation_id: sparse_id,
                network: None,
            },
            last_updated: 0,
            recurringd_api: None,
            lnaddress_api: None,
        };

        let mut dbtx = db.begin_transaction().await;
        dbtx.insert_entry(
            &FederationMetaKey {
                federation_id: populated_id,
            },
            &populated,
        )
        .await;
        dbtx.insert_entry(
            &FederationMetaKey {
                federation_id: sparse_id,
            },
            &sparse,
        )
        .await;
        dbtx.commit_tx().await;

        // `FederationMeta` has no `PartialEq`, so compare field by field rather
        // than deriving one just for the test.
        let mut dbtx = db.begin_transaction_nc().await;
        for expected in [populated, sparse] {
            let loaded = dbtx
                .get_value(&FederationMetaKey {
                    federation_id: expected.selector.federation_id,
                })
                .await
                .expect("meta was stored");
            assert_eq!(loaded.picture, expected.picture);
            assert_eq!(loaded.welcome, expected.welcome);
            assert_eq!(loaded.guardians, expected.guardians);
            assert_eq!(loaded.selector, expected.selector);
            assert_eq!(loaded.last_updated, expected.last_updated);
            assert_eq!(loaded.recurringd_api, expected.recurringd_api);
            assert_eq!(loaded.lnaddress_api, expected.lnaddress_api);
        }
    }

    /// The address book is stored only here — contacts are not recoverable from
    /// the seed phrase — so an encoding change loses them outright. `npub` is
    /// both the key and a value field, which the round trip also covers.
    #[tokio::test]
    async fn contacts_round_trip() {
        let db: Database = MemDatabase::new().into();

        let populated = Contact {
            npub: "npub1populated".to_string(),
            name: Some("satoshi".to_string()),
            display_name: Some("Satoshi Nakamoto".to_string()),
            picture: Some("https://example.com/avatar.png".to_string()),
            lud16: Some("satoshi@example.com".to_string()),
            nip05: Some("_@example.com".to_string()),
            nip05_verified: true,
            about: Some("likes timestamps".to_string()),
            created_at: 1_700_000_000_123,
            last_paid_at: Some(1_764_000_000_456),
        };
        let sparse = Contact {
            npub: "npub1sparse".to_string(),
            name: None,
            display_name: None,
            picture: None,
            lud16: None,
            nip05: None,
            nip05_verified: false,
            about: None,
            created_at: 1_700_000_000_999,
            last_paid_at: None,
        };

        let mut dbtx = db.begin_transaction().await;
        for contact in [&populated, &sparse] {
            dbtx.insert_entry(
                &ContactKey {
                    npub: contact.npub.clone(),
                },
                contact,
            )
            .await;
        }
        dbtx.commit_tx().await;

        let mut dbtx = db.begin_transaction_nc().await;
        for expected in [populated, sparse] {
            let loaded = dbtx
                .get_value(&ContactKey {
                    npub: expected.npub.clone(),
                })
                .await
                .expect("contact was stored");
            assert_eq!(loaded.npub, expected.npub);
            assert_eq!(loaded.name, expected.name);
            assert_eq!(loaded.display_name, expected.display_name);
            assert_eq!(loaded.picture, expected.picture);
            assert_eq!(loaded.lud16, expected.lud16);
            assert_eq!(loaded.nip05, expected.nip05);
            assert_eq!(loaded.nip05_verified, expected.nip05_verified);
            assert_eq!(loaded.about, expected.about);
            assert_eq!(loaded.created_at, expected.created_at);
            assert_eq!(loaded.last_paid_at, expected.last_paid_at);
        }
    }

    /// The spend limits and the running tally are deliberately separate records,
    /// as their doc comments explain: editing a limit must not disturb the tally,
    /// and resetting the tally must not rewrite the user's settings. A prefix
    /// collision between them would break both directions at once — and since a
    /// misread limit is a limit that no longer bounds a paired app, this is the
    /// one round trip here with money on the other end of it.
    #[tokio::test]
    async fn nwc_limits_and_spend_window_are_independent() {
        let db: Database = MemDatabase::new().into();

        let limits = NwcLimits {
            max_payment_msats: 21_000_000,
            daily_budget_msats: 100_000_000,
        };
        let window = NwcSpendWindow {
            started_at: Timestamp(UNIX_EPOCH + Duration::new(1_764_000_000, 123_456_789)),
            spent_msats: 42_000,
        };

        let mut dbtx = db.begin_transaction().await;
        dbtx.insert_entry(&NwcLimitsKey, &limits).await;
        dbtx.insert_entry(&NwcSpendWindowKey, &window).await;
        dbtx.commit_tx().await;

        let mut dbtx = db.begin_transaction_nc().await;
        let loaded_limits = dbtx.get_value(&NwcLimitsKey).await.expect("limits stored");
        assert_eq!(loaded_limits.max_payment_msats, limits.max_payment_msats);
        assert_eq!(loaded_limits.daily_budget_msats, limits.daily_budget_msats);
        let loaded_window = dbtx
            .get_value(&NwcSpendWindowKey)
            .await
            .expect("window stored");
        assert_eq!(loaded_window.started_at, window.started_at);
        assert_eq!(loaded_window.spent_msats, window.spent_msats);
        drop(dbtx);

        // Rolling the window over must leave the limits exactly as the user set
        // them.
        let mut dbtx = db.begin_transaction().await;
        dbtx.insert_entry(
            &NwcSpendWindowKey,
            &NwcSpendWindow {
                started_at: Timestamp(UNIX_EPOCH + Duration::from_secs(1_764_086_400)),
                spent_msats: 0,
            },
        )
        .await;
        dbtx.commit_tx().await;

        let mut dbtx = db.begin_transaction_nc().await;
        let loaded_limits = dbtx.get_value(&NwcLimitsKey).await.expect("limits stored");
        assert_eq!(loaded_limits.max_payment_msats, limits.max_payment_msats);
        assert_eq!(loaded_limits.daily_budget_msats, limits.daily_budget_msats);
        assert_eq!(
            dbtx.get_value(&NwcSpendWindowKey)
                .await
                .expect("window stored")
                .spent_msats,
            0
        );
    }

    /// The Lightning Address record holds the only copy of the authentication
    /// token the wallet needs to keep claiming its address; if this stops
    /// decoding, the user's address is not re-registrable from the seed and is
    /// simply gone. The two [`SafeUrl`] fields are the interesting part, since
    /// they encode through a wrapper rather than as plain strings.
    #[tokio::test]
    async fn lightning_address_config_round_trips() {
        let db: Database = MemDatabase::new().into();
        let id = federation_id(0x55);

        let config = LightningAddressConfig {
            username: "satoshi".to_string(),
            domain: "example.com".to_string(),
            recurringd_api: SafeUrl::parse("https://recurringd.example.com/api")
                .expect("valid url"),
            ln_address_api: SafeUrl::parse("https://lnaddress.example.com/v1").expect("valid url"),
            lnurl: "LNURL1DP68GURN8GHJ7CTSDYH8GETNW3HKZ".to_string(),
            authentication_token: "token-9f3c".to_string(),
        };

        let mut dbtx = db.begin_transaction().await;
        dbtx.insert_entry(&LightningAddressKey { federation_id: id }, &config)
            .await;
        dbtx.commit_tx().await;

        let mut dbtx = db.begin_transaction_nc().await;
        let loaded = dbtx
            .get_value(&LightningAddressKey { federation_id: id })
            .await
            .expect("config was stored");
        assert_eq!(loaded.username, config.username);
        assert_eq!(loaded.domain, config.domain);
        assert_eq!(loaded.recurringd_api, config.recurringd_api);
        assert_eq!(loaded.ln_address_api, config.ln_address_api);
        assert_eq!(loaded.lnurl, config.lnurl);
        assert_eq!(loaded.authentication_token, config.authentication_token);
    }

    /// Seven same-typed fields in a fixed order, which is exactly the shape that
    /// survives a reordering without complaint: swap `eur` and `gbp` and every
    /// cached price silently reads back as the wrong currency. Distinct values
    /// per field are the whole point of this test.
    #[tokio::test]
    async fn btc_prices_round_trip() {
        let db: Database = MemDatabase::new().into();

        let prices = BtcPrices {
            usd: 100_001,
            eur: 100_002,
            gbp: 100_003,
            cad: 100_004,
            chf: 100_005,
            aud: 100_006,
            jpy: 100_007,
            last_updated: Timestamp(UNIX_EPOCH + Duration::new(1_764_000_000, 123_456_789)),
        };

        let mut dbtx = db.begin_transaction().await;
        dbtx.insert_entry(&BtcPricesKey, &prices).await;
        dbtx.commit_tx().await;

        let mut dbtx = db.begin_transaction_nc().await;
        let loaded = dbtx.get_value(&BtcPricesKey).await.expect("prices stored");
        assert_eq!(loaded.usd, prices.usd);
        assert_eq!(loaded.eur, prices.eur);
        assert_eq!(loaded.gbp, prices.gbp);
        assert_eq!(loaded.cad, prices.cad);
        assert_eq!(loaded.chf, prices.chf);
        assert_eq!(loaded.aud, prices.aud);
        assert_eq!(loaded.jpy, prices.jpy);
        assert_eq!(loaded.last_updated, prices.last_updated);
    }
}
