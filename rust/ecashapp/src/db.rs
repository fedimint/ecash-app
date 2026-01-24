use std::time::SystemTime;

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
    ContactPayment = 0x0E,
    ContactsImported = 0x0F,
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
pub(crate) struct FederationMetaKey {
    pub(crate) federation_id: FederationId,
}

impl_db_record!(
    key = FederationMetaKey,
    value = FederationMeta,
    db_prefix = DbKeyPrefix::FederationMeta,
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
    pub created_at: u64,         // Unix timestamp in milliseconds
    pub last_paid_at: Option<u64>, // Unix timestamp in milliseconds
}

impl_db_record!(
    key = ContactKey,
    value = Contact,
    db_prefix = DbKeyPrefix::Contact,
);

impl_db_lookup!(
    key = ContactKey,
    query_prefix = ContactKeyPrefix,
);

// ContactPayment - stores payment history per contact
#[derive(Debug, Clone, Encodable, Decodable, Eq, PartialEq, Hash, Ord, PartialOrd)]
pub struct ContactPaymentKey {
    pub npub: String,
    pub timestamp: u64, // Unix timestamp in milliseconds
}

#[derive(Debug, Encodable, Decodable)]
pub struct ContactPaymentKeyPrefix;

#[derive(Debug, Encodable, Decodable)]
pub struct ContactPaymentByNpubPrefix {
    pub npub: String,
}

#[derive(Debug, Clone, Encodable, Decodable, Serialize, Deserialize)]
pub struct ContactPayment {
    pub amount_msats: u64,
    pub federation_id: FederationId,
    pub operation_id: Vec<u8>,
    pub note: Option<String>,
}

impl_db_record!(
    key = ContactPaymentKey,
    value = ContactPayment,
    db_prefix = DbKeyPrefix::ContactPayment,
);

impl_db_lookup!(
    key = ContactPaymentKey,
    query_prefix = ContactPaymentKeyPrefix,
);

impl_db_lookup!(
    key = ContactPaymentKey,
    query_prefix = ContactPaymentByNpubPrefix,
);

// ContactsImported - flag indicating first-time import prompt has been shown
#[derive(Debug, Encodable, Decodable)]
pub struct ContactsImportedKey;

impl_db_record!(
    key = ContactsImportedKey,
    value = (),
    db_prefix = DbKeyPrefix::ContactsImported,
);
