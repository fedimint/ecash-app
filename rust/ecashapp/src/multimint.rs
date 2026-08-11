use std::{
    collections::{BTreeMap, BTreeSet},
    fmt::{self, Display},
    str::FromStr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, UNIX_EPOCH},
};

use anyhow::bail;
use anyhow::Context;
use bitcoin::key::rand::thread_rng;
use fedimint_api_client::api::{DynGlobalApi, DynModuleApi, FederationApiExt, FederationError};
use fedimint_bip39::{Bip39RootSecretStrategy, Language, Mnemonic};
use fedimint_client::{
    db::ChronologicalOperationLogKey,
    module::{
        module::{recovery::RecoveryProgress, ClientModule as _},
        oplog::OperationLogEntry,
    },
    module_init::ClientModuleInitRegistry,
    secret::RootSecretStrategy,
    transaction::FeeQuote,
    Client, ClientHandleArc, OperationId,
};
use fedimint_connectors::{Connectivity, ConnectorRegistry, PeerStatus as FedimintPeerStatus};
use fedimint_core::{
    admin_client::ServerStatusLegacy,
    base32::{decode_prefixed, encode_prefixed, FEDIMINT_PREFIX},
    config::{FederationId, META_FEDERATION_NAME_KEY},
    db::{mem_impl::MemDatabase, Database, IDatabaseTransactionOpsCoreTyped},
    encoding::{Decodable, Encodable},
    endpoint_constants::CONSENSUS_ORD_LATENCY_ENDPOINT,
    envs::BitcoinRpcConfig,
    invite_code::InviteCode,
    module::{ApiAuth, ApiRequestErased},
    task::TaskGroup,
    util::SafeUrl,
    Amount, NumPeers,
};
use fedimint_eventlog::Event;
use fedimint_ln_client::{
    InternalPayState, LightningClientInit, LightningClientModule, LightningOperationMetaPay,
    LightningOperationMetaVariant, LnPayState, LnReceiveState,
};
use fedimint_lnv2_client::{
    events::ReceivePaymentEvent, FinalReceiveOperationState, LightningOperationMeta,
    ReceiveOperationState, SendOperationState,
};
use fedimint_lnv2_common::{
    contracts::fee_from_expiration,
    endpoint_constants::{ADD_GATEWAY_ENDPOINT, REMOVE_GATEWAY_ENDPOINT},
    gateway_api::PaymentFee,
    Bolt11InvoiceDescription,
};
use fedimint_meta_client::common::endpoint::{
    GetConsensusRequest, GetSubmissionResponse, GetSubmissionsRequest, SubmitRequest,
    GET_CONSENSUS_ENDPOINT, GET_SUBMISSIONS_ENDPOINT, SUBMIT_ENDPOINT,
};
use fedimint_meta_client::common::{MetaConsensusValue, MetaValue};
use fedimint_meta_client::{common::DEFAULT_META_KEY, MetaClientInit, MetaClientModule};
use fedimint_mint_client::{
    api::MintFederationApi, MintClientInit, MintClientModule, MintOperationMeta,
    MintOperationMetaVariant, OOBNotes, ReissueExternalNotesState, SpendOOBState,
};
use fedimint_mintv2_client::{
    ECash, FinalReceiveOperationState as MintV2FinalReceiveOperationState,
    MintClientInit as MintV2Init, MintClientModule as MintV2Module,
    MintOperationMeta as MintV2OperationMeta,
};
use fedimint_wallet_client::client_db::TweakIdx;
use fedimint_wallet_client::TxOutputSummary;
use fedimint_wallet_client::WithdrawState;
use fedimint_wallet_client::{
    DepositStateV2, PegOutFees, WalletClientInit, WalletClientModule, WalletOperationMeta,
    WalletOperationMetaVariant,
};
use fedimint_wallet_common::endpoint_constants::{
    BITCOIN_RPC_CONFIG_ENDPOINT, BLOCK_COUNT_ENDPOINT, BLOCK_COUNT_LOCAL_ENDPOINT,
};
use fedimint_walletv2_client::{
    FinalReceiveOperationState as WalletV2FinalReceiveOperationState,
    FinalSendOperationState as WalletV2FinalSendOperationState, WalletClientInit as WalletV2Init,
    WalletClientModule as WalletV2Module, WalletOperationMeta as WalletV2OperationMeta,
};
use fedimint_walletv2_common::endpoint_constants::{
    CONSENSUS_BLOCK_COUNT_ENDPOINT, CONSENSUS_FEERATE_ENDPOINT,
};
use futures_util::{stream, Stream, StreamExt};
use lightning_invoice::{Bolt11Invoice, Description};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::{from_value, json};
use tokio::{sync::mpsc::unbounded_channel, time::Instant};
use tokio::{sync::RwLock, time::timeout};

use crate::get_event_bus;
use crate::{
    anyhow,
    app_error::{classify_anyhow, EcashAppError, EcashAppResult},
    db::{
        BitcoinDisplay, BitcoinDisplayKey, BtcPrice, BtcPriceKey, BtcPrices, BtcPricesKey,
        Connector, ContactSyncConfigKey, FederationBackupKey, FederationMetaKey,
        FederationMetaKeyPrefix, FiatCurrency, FiatCurrencyKey, LightningAddressConfig,
        LightningAddressKey, LightningAddressKeyPrefix, SchemaVersionKey,
    },
    error_to_flutter, get_nostr_client, info_to_flutter, payment_error_to_flutter,
    wallet::WalletHandler,
    FederationConfig, FederationConfigKey, FederationConfigKeyPrefix, SeedPhraseAckKey,
};

const DEFAULT_EXPIRY_TIME_SECS: u32 = 86400;
const CACHE_UPDATE_INTERVAL_SECS: u64 = 30;
const PRICE_CACHE_UPDATE_INTERVAL_SECS: u64 = 60 * 5;
const FEDERATION_BACKUP_CACHE_UPDATE_INTERVAL_SECS: u64 = 60 * 60 * 24;
const CONTACT_SYNC_INTERVAL_SECS: u64 = 90;
const VERSION_CHECK_INTERVAL_SECS: u64 = 60 * 60 * 6;
/// Longest any single stage of the cache task may run before it is abandoned.
///
/// The stages run in sequence within one loop iteration, so a stage that never
/// returns stops every stage behind it from running again — including the
/// federation ecash backup, which would leave the user transacting against a
/// backup that silently stopped updating. Bounding each stage costs at most one
/// skipped cycle of that stage instead.
const CACHE_TASK_STAGE_TIMEOUT_SECS: u64 = 60;
/// Timeout for the BTC price HTTP request itself.
const PRICE_FETCH_TIMEOUT_SECS: u64 = 10;
/// A gateway routing fee at or above this takes 100% of the payment, which
/// makes the fee inversion in [`gross_invoice_for_contract`] unsolvable.
const MAX_GATEWAY_PPM: u64 = 1_000_000;
/// Backstop on the fee-inversion correction walks. The closed form lands within
/// a step or two, so anything beyond this means the gateway's fee curve is not
/// what the algebra assumes.
const MAX_FEE_WALK_STEPS: u32 = 1_000;
const GITHUB_LATEST_RELEASE_URL: &str =
    "https://api.github.com/repos/fedimint/ecash-app/releases/latest";
/// fedimintd rejects a wrong (or unconfigured) admin password with JSON-RPC
/// code 401 / "Invalid authorization". The client surfaces that as an opaque
/// server error inside [`FederationError`], so matching the message is the
/// only way to tell a bad password apart from an unreachable guardian.
fn is_invalid_guardian_auth(err: &FederationError) -> bool {
    err.to_string().contains("Invalid authorization")
}

fn is_newer_version(current: &str, latest: &str) -> bool {
    match (
        semver::Version::parse(current),
        semver::Version::parse(latest),
    ) {
        (Ok(c), Ok(l)) => l > c,
        _ => false,
    }
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug, Encodable, Decodable)]
pub struct FederationSelector {
    pub federation_name: String,
    pub federation_id: FederationId,
    pub network: Option<String>,
}

impl Display for FederationSelector {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.federation_name)
    }
}

#[derive(Clone, PartialEq, Serialize, Debug)]
pub struct WithdrawFeesResponse {
    /// On-chain Bitcoin miner fee, in sats.
    pub fee_amount: u64,
    pub fee_rate_sats_per_vb: f64,
    pub tx_size_vbytes: u32,
    /// On-federation fee (wallet peg-out output fee + mint funding/change fees +
    /// dust), in msats, quoted via the wallet module's `send_fee_quote`.
    pub federation_fee_msats: u64,
    pub fees: WithdrawFees,
}

/// Fee information round-tripped from the fee quote back into the withdraw call,
/// so the user pays exactly the quoted fee. The variant also selects which
/// wallet module performs the on-chain send.
#[derive(Clone, PartialEq, Serialize, Debug)]
pub enum WithdrawFees {
    /// walletv1 peg-out fees (feerate + tx weight computed for the specific tx).
    V1(PegOutFees),
    /// walletv2 flat send fee, in sats.
    V2 { fee_sats: u64 },
}

pub struct ReissueFees {
    pub total_msats: u64,
    pub input_msats: u64,
    pub output_msats: u64,
    pub dust_msats: u64,
}

/// Quote for an ecash send. `amount_msats` is the *actual* amount the send will
/// spend on the ecash: the requested amount rounded up to a representable
/// denomination, which both mint modules do before producing notes, so it can
/// exceed what the user typed. `fee_msats` is the federation fee charged on top.
/// The total debited from the wallet is `amount_msats + fee_msats`.
pub struct EcashSendFees {
    pub amount_msats: u64,
    pub fee_msats: u64,
}

/// Result of pricing a Lightning receive. `invoice_msats` is the invoice's face
/// value (what the payer pays). The fee is broken out into its two sources:
/// `federation_fee_msats` (on-federation: lightning input fee plus mint output
/// fees plus dust) and `gateway_fee_msats` (the gateway's off-chain routing fee,
/// always 0 for LNv1). The receiver is credited
/// `invoice_msats - federation_fee_msats - gateway_fee_msats`. Both are quoted at
/// `invoice_msats`, not the requested amount, so they match what is really
/// deducted.
pub struct ReceiveAmount {
    pub invoice_msats: u64,
    pub federation_fee_msats: u64,
    pub gateway_fee_msats: u64,
}

/// Fee parameters for an on-chain deposit (peg-in). We can't quote an exact
/// charge up front because the deposit amount is unknown, and for walletv2 the
/// federation fee scales with the amount, so we surface the parameters instead.
#[derive(Clone, PartialEq, Serialize, Debug)]
pub struct PeginFeeQuote {
    /// Constant federation fee charged on the deposit, in msats.
    /// walletv1: `peg_in_abs`; walletv2: `fee_consensus.base`.
    pub base_fee_msats: u64,
    /// Relative federation fee in parts-per-million (walletv2 only; 0 for walletv1).
    pub parts_per_million: u64,
    /// Dynamic on-chain claim/sweep fee in sats (walletv2 only; `None` for
    /// walletv1 or when no consensus feerate is currently available).
    pub onchain_claim_fee_sats: Option<u64>,
}

/// Ecash produced by a send, in whichever encoding the federation's mint module
/// uses: walletv1 `OOBNotes` or mintv2 `ECash` (base32). [`OOBNotesWrapper`]
/// hides the difference behind `amount_msats()`/`to_string()`.
pub(crate) enum WrappedEcash {
    V1(OOBNotes),
    V2(ECash),
}

pub struct OOBNotesWrapper(pub(crate) WrappedEcash);

impl OOBNotesWrapper {
    #[flutter_rust_bridge::frb(sync)]
    pub fn amount_msats(&self) -> u64 {
        match &self.0 {
            WrappedEcash::V1(notes) => notes.total_amount().msats,
            WrappedEcash::V2(ecash) => ecash.amount().msats,
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn to_string(&self) -> String {
        match &self.0 {
            WrappedEcash::V1(notes) => notes.to_string(),
            WrappedEcash::V2(ecash) => encode_prefixed(FEDIMINT_PREFIX, ecash),
        }
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_oob_notes(notes: &str) -> Option<OOBNotesWrapper> {
    // mintv2 ecash first: its decoder is permissive (a v1 string can decode to
    // an `ECash` with `mint() == None`), so only accept it when it carries a
    // federation id, otherwise fall back to walletv1 OOB notes.
    if let Ok(ecash) = decode_prefixed::<ECash>(FEDIMINT_PREFIX, notes) {
        if ecash.mint().is_some() {
            return Some(OOBNotesWrapper(WrappedEcash::V2(ecash)));
        }
    }
    OOBNotes::from_str(notes)
        .ok()
        .map(|notes| OOBNotesWrapper(WrappedEcash::V1(notes)))
}

/// Returns true if `ecash` is mintv2 `ECash` (rather than walletv1 `OOBNotes`).
/// Used by the UI to gate features that only exist for walletv1, e.g. the
/// claim-status check, which mintv2 has no endpoint for yet.
#[flutter_rust_bridge::frb(sync)]
pub fn is_mintv2_ecash(ecash: &str) -> bool {
    // The decoder is permissive, so a valid v2 ecash is one that carries a
    // federation id; v1 strings either fail to decode or have `mint() == None`.
    decode_prefixed::<ECash>(FEDIMINT_PREFIX, ecash)
        .map(|e| e.mint().is_some())
        .unwrap_or(false)
}

#[allow(clippy::type_complexity)]
#[derive(Clone)]
pub struct Multimint {
    db: Database,
    mnemonic: Mnemonic,
    modules: ClientModuleInitRegistry,
    clients: Arc<RwLock<BTreeMap<FederationId, ClientHandleArc>>>,
    task_group: TaskGroup,
    recovery_progress: Arc<RwLock<BTreeMap<FederationId, BTreeMap<u16, RecoveryProgress>>>>,
    internal_ecash_spends: Arc<RwLock<BTreeSet<OperationId>>>,
    recurringd_invoices: Arc<RwLock<BTreeSet<OperationId>>>,
    update_notified: Arc<AtomicBool>,
    wallet_handler: WalletHandler,
}

#[derive(Debug, Serialize, Encodable, Decodable, Clone)]
pub struct FederationMeta {
    pub picture: Option<String>,
    pub welcome: Option<String>,
    pub guardians: Vec<Guardian>,
    pub selector: FederationSelector,
    pub last_updated: u64,
    pub recurringd_api: Option<String>,
    pub lnaddress_api: Option<String>,
}

#[derive(Debug, Serialize, Clone, Eq, PartialEq, Encodable, Decodable)]
pub struct Guardian {
    pub peer_id: u16,
    pub name: String,
    pub version: Option<String>,
}

#[derive(Debug, Serialize, Clone, Copy)]
pub enum PeerConnectivity {
    Direct,
    Relay,
    Mixed,
    Tor,
    Unknown,
}

impl From<Connectivity> for PeerConnectivity {
    fn from(c: Connectivity) -> Self {
        match c {
            Connectivity::Direct => PeerConnectivity::Direct,
            Connectivity::Relay => PeerConnectivity::Relay,
            Connectivity::Mixed => PeerConnectivity::Mixed,
            Connectivity::Tor => PeerConnectivity::Tor,
            Connectivity::Unknown => PeerConnectivity::Unknown,
        }
    }
}

#[derive(Debug, Serialize, Clone)]
pub struct PeerStatus {
    pub peer_id: u16,
    pub name: String,
    pub online: bool,
    pub connectivity: PeerConnectivity,
    pub url: String,
    /// Guardian's reported `fedimintd` version. Travels with the peer status so
    /// the UI reflects guardian upgrades in real time (a guardian upgrade
    /// restarts fedimintd, which surfaces as a reconnect on the status stream).
    pub version: Option<String>,
}

#[derive(Debug, Serialize, Clone)]
pub struct GuardianModuleSummary {
    pub module_instance_id: u16,
    pub kind: String,
    /// Positive means assets, negative means liabilities (e.g. the mint
    /// module's outstanding e-cash).
    pub net_assets_msats: i64,
}

#[derive(Debug, Serialize, Clone)]
pub struct GuardianAuditSummary {
    pub net_assets_msats: i64,
    pub module_summaries: Vec<GuardianModuleSummary>,
}

#[derive(Debug, Serialize, Clone)]
pub struct GuardianBackupStatistics {
    pub num_backups: u64,
    pub total_size_bytes: u64,
    pub refreshed_1d: u64,
    pub refreshed_1w: u64,
    pub refreshed_1m: u64,
    pub refreshed_3m: u64,
}

#[derive(Debug, Serialize, Clone)]
pub struct GuardianHealth {
    pub consensus_running: bool,
    /// Raw server status, shown when consensus is not running (e.g. during
    /// setup or an upgrade).
    pub server_status: String,
    pub session_count: Option<u64>,
    pub peers_online: u64,
    pub peers_total: u64,
    pub consensus_ord_latency_ms: Option<u64>,
    pub scheduled_shutdown_session: Option<u64>,
}

#[derive(Debug, Serialize, Clone)]
pub struct GuardianBitcoinStatus {
    /// Backend kind and credential-stripped URL; None when the authenticated
    /// `bitcoin_rpc_config` endpoint is unavailable on this guardian.
    pub kind: Option<String>,
    pub url: Option<String>,
    pub consensus_block_count: u64,
    /// This guardian's own bitcoin node height; comparing it against the
    /// consensus count reveals a node that has fallen behind. Wallet v1 only.
    pub local_block_count: Option<u64>,
    /// Consensus fee rate in sats per kvB. Wallet v2 only.
    pub consensus_feerate_sats_per_kvb: Option<u64>,
}

#[derive(Debug, Serialize, Clone)]
pub struct GuardianStatusSummary {
    pub health: GuardianHealth,
    /// None when the federation has no wallet module.
    pub bitcoin: Option<GuardianBitcoinStatus>,
    /// Whether the federation runs the lnv2 module, i.e. whether gateway
    /// management is available.
    pub has_lnv2: bool,
    /// Whether the federation runs the meta module, i.e. whether federation
    /// settings can be viewed and proposed.
    pub has_meta: bool,
}

/// A pending meta submission, grouped across every guardian that submitted
/// this exact value.
#[derive(Debug, Serialize, Clone)]
pub struct GuardianMetaProposal {
    pub peer_ids: Vec<u16>,
    /// The raw submitted bytes, hex encoded. Accepting a proposal must
    /// resubmit these exact bytes: consensus only forms over byte-identical
    /// values, so re-serializing the parsed document could silently never
    /// converge.
    pub value_hex: String,
    /// The submission parsed as JSON, or None when a guardian submitted
    /// something that is not valid JSON.
    pub value_json: Option<String>,
    /// Whether the guardian we are logged into is backing this value.
    pub is_ours: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct GuardianMetaState {
    /// The current agreed meta document as JSON, absent until a first
    /// consensus forms.
    pub consensus_json: Option<String>,
    pub revision: Option<u64>,
    pub proposals: Vec<GuardianMetaProposal>,
    /// How many guardians must submit an identical value for it to become the
    /// new consensus.
    pub threshold: u16,
    pub total_guardians: u16,
}

#[derive(Debug, Serialize, Clone)]
pub struct Transaction {
    pub kind: TransactionKind,
    pub amount: u64,
    pub timestamp: u64,
    pub operation_id: Vec<u8>,
}

#[derive(Debug, Serialize, Clone)]
pub enum TransactionKind {
    LightningReceive {
        /// On-federation fee (lightning input fee + mint output fees + dust), as
        /// quoted at the invoice amount when the invoice was created.
        federation_fees: u64,
        /// Gateway off-chain routing fee; always 0 for LNv1.
        gateway_fees: u64,
        /// The invoice's face value (what the payer pays). `invoice_amount -
        /// federation_fees - gateway_fees` is what was credited; the
        /// transaction's `amount` is the requested amount shown in the history
        /// list.
        invoice_amount: u64,
        gateway: String,
        payee_pubkey: String,
        payment_hash: String,
    },
    LightningSend {
        /// On-federation fee: lightning output fee + mint funding/change fees +
        /// dust, quoted at send time via `send_fee_quote`.
        federation_fees: u64,
        /// Gateway off-chain routing fee.
        gateway_fees: u64,
        gateway: String,
        /// The BOLT11 invoice that was paid.
        invoice: String,
        payment_hash: String,
        preimage: String,
        ln_address: Option<String>,
    },
    LightningRecurring {
        /// The Lightning Address (`username@domain`) registered for this
        /// federation that received the payment, looked up from
        /// `LightningAddressKey` (one address per federation). `None` if no
        /// address is currently registered for the federation.
        ln_address: Option<String>,
        /// On-federation fee actually charged when the incoming contract was
        /// claimed (mint input/output fees), derived from the operation's
        /// input/output difference via `get_operation_fees`. `None` for receives
        /// that predate fee tracking.
        federation_fees: Option<u64>,
        /// Gateway off-chain routing fee. The LNURL invoice is minted by
        /// recurringd and never seen by this client, so for LNv2 the fee is
        /// recovered from the fee-encoded contract expiration
        /// (`fee_from_expiration`). `Some(0)` for LNv1 (no gateway layer);
        /// `None` when unrecoverable (LNv2 contracts created before fee-encoding
        /// existed). The gross invoice the payer paid is `amount +
        /// federation_fees + gateway_fees`.
        gateway_fees: Option<u64>,
    },
    OnchainReceive {
        address: String,
        txid: String,
        /// Federation fee actually charged on the claimed deposit, in msats.
        /// `None` for deposits made before the fee-tracking feature existed.
        federation_fee_msats: Option<u64>,
        /// Dynamic on-chain claim/sweep fee actually paid when the deposit was
        /// claimed, in msats. This is the real fee (queried at claim time),
        /// not the estimate shown at address-generation time. walletv2 only;
        /// `None` for walletv1 (which has no separate claim fee) and for
        /// deposits predating fee tracking.
        onchain_claim_fee_msats: Option<u64>,
    },
    OnchainSend {
        address: String,
        txid: String,
        fee_rate_sats_per_vb: Option<f64>,
        tx_size_vb: Option<u32>,
        /// On-chain Bitcoin miner fee, in sats.
        fee_sats: Option<u64>,
        total_sats: Option<u64>,
        /// On-federation fee (wallet output fee + mint funding/change fees +
        /// dust), in msats, quoted at send time via `send_fee_quote`.
        federation_fee_msats: Option<u64>,
    },
    EcashReceive {
        oob_notes: String,
        input_fees: Option<u64>,
        output_fees: Option<u64>,
        dust: Option<u64>,
    },
    EcashSend {
        oob_notes: String,
        fees: u64,
    },
}

#[derive(Debug, Serialize, Clone, Eq, PartialEq)]
pub struct Utxo {
    pub txid: String,
    pub index: u32,
    pub amount: u64,
}

impl From<TxOutputSummary> for Utxo {
    fn from(value: TxOutputSummary) -> Self {
        Self {
            txid: value.outpoint.txid.to_string(),
            index: value.outpoint.vout,
            amount: value.amount.to_sat() * 1000,
        }
    }
}

pub enum MultimintCreation {
    New,
    LoadExisting,
    NewFromMnemonic { words: Vec<String> },
}

#[derive(Debug, Eq, PartialEq)]
pub enum ClientType {
    New,
    Temporary,
    Recovery,
}

impl fmt::Display for ClientType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ClientType::New => write!(f, "New"),
            ClientType::Temporary => write!(f, "Temporary"),
            ClientType::Recovery => write!(f, "Recovery"),
        }
    }
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct MempoolEvent {
    pub amount: u64,
    pub outpoint: String,
    /// The on-chain transaction id. `outpoint` is a correlation key that, for
    /// walletv2, is actually the receive address rather than `txid:vout`
    /// (see `track_pegin_confirmation`), so this field is the only reliable
    /// source of the txid for display purposes.
    pub txid: Option<String>,
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct AwaitingConfsEvent {
    pub amount: u64,
    pub outpoint: String,
    pub block_height: u64,
    pub needed: u64,
    pub txid: Option<String>,
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct ConfirmedEvent {
    pub amount: u64,
    pub outpoint: String,
    pub txid: Option<String>,
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct ClaimedEvent {
    pub amount: u64,
    pub outpoint: String,
    pub txid: Option<String>,
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub enum DepositEventKind {
    Mempool(MempoolEvent),
    AwaitingConfs(AwaitingConfsEvent),
    Confirmed(ConfirmedEvent),
    Claimed(ClaimedEvent),
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct InvoicePaidEvent {
    pub amount_msats: u64,
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub enum LightningEventKind {
    InvoicePaid(InvoicePaidEvent),
    PaymentSent,
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub enum LogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub enum ContactSyncEventKind {
    Started,
    Progress {
        synced: usize,
    },
    Completed {
        added: usize,
        updated: usize,
        removed: usize,
    },
    Error(String),
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub enum RelayStatusKind {
    Connecting,
    Connected,
    Failed,
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub enum NostrRecoveryPhase {
    ConnectingToRelays,
    FetchingBackup,
    DecryptingInvites,
    RejoiningFederations(u32),
    /// The relays returned nothing to restore.
    ///
    /// Distinct from `RejoiningFederations(0)` so the UI cannot render "found
    /// nothing" the same way it renders "restored everything". The nostr backup
    /// is best effort — relays prune, and the seed phrase is the real backup —
    /// so an empty result is an ordinary outcome the user has to be told about,
    /// because rejoining then needs invite codes they must supply themselves.
    NoBackupFound,
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub enum MultimintEvent {
    Deposit((FederationId, DepositEventKind)),
    Lightning((FederationId, LightningEventKind)),
    Log(LogLevel, String),
    RecoveryDone(String),
    RecoveryProgress(String, u16, u32, u32),
    Ecash((FederationId, u64)),
    NostrRecovery(String, u16, Option<FederationSelector>),
    NostrRelayStatus(String, RelayStatusKind),
    NostrRecoveryPhase(NostrRecoveryPhase),
    ContactSync(ContactSyncEventKind),
    UpdateAvailable(String),
    /// A federation's cached meta changed (name, picture, welcome message or
    /// guardians), so screens holding it should reload. Carries the federation
    /// id as a string: a bare opaque type as an enum payload makes the bridge
    /// generate the whole enum as opaque, breaking every other variant.
    MetaUpdated(String),
    /// Structured payment-flow error. The Dart layer auto-surfaces these as
    /// localized error toasts (see `lib/app.dart` and `lib/error_helper.dart`).
    PaymentError((FederationId, EcashAppError)),
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub enum LightningSendOutcome {
    Success(String),
    /// Carries the typed reason for the failure so the Dart layer can render
    /// a localized message on the Failure screen.
    Failure(EcashAppError),
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct FedimintGateway {
    pub endpoint: String,
    pub base_routing_fee: u64,
    pub ppm_routing_fee: u64,
    pub base_transaction_fee: u64,
    pub ppm_transaction_fee: u64,
    pub lightning_alias: Option<String>,
    pub lightning_node: Option<String>,
    pub is_lnv2: bool,
    pub is_vettted: bool,
    /// LNv1 only: short_channel_id used in route hints to identify the federation.
    /// Used to detect "loopback" invoices issued by the same federation, which
    /// incur zero gateway routing fees.
    pub federation_index: Option<u64>,
    /// LNv2 only: gateway's minimum send fee, applied on loopback payments
    /// (where the invoice's payee is the gateway's own Lightning node).
    pub min_base_routing_fee: Option<u64>,
    pub min_ppm_routing_fee: Option<u64>,
}

#[derive(Clone, Serialize, Debug)]
pub struct GatewayPaymentPreview {
    pub gateway: FedimintGateway,
    pub amount_with_fees: u64,
    /// Gateway off-chain routing fee (baked into the outgoing contract).
    pub gateway_fee: u64,
    /// On-federation fee: lightning output fee + mint funding/change fees +
    /// dust, quoted via the lightning module's `send_fee_quote`.
    pub federation_fee: u64,
}

#[derive(Clone, Serialize, Debug)]
pub struct PaymentPreviewWithGateways {
    pub amount_msats: u64,
    pub payment_hash: String,
    pub network: String,
    pub invoice: String,
    pub gateway_previews: Vec<GatewayPaymentPreview>,
    pub selected_index: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LNAddressRegisterRequest {
    pub domain: String,
    pub username: String,
    pub lnurl: String,
    pub recipient_pk: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub enum LNAddressStatus {
    Registered { lnurl: String },
    Available,
    CurrentConfig,
    UnsupportedFederation,
    Invalid,
}

#[derive(Debug, Clone, Serialize)]
pub struct LNAddressRemoveRequest {
    pub domain: String,
    pub username: String,
    pub authentication_token: String,
}

#[derive(Serialize, Deserialize)]
pub(crate) struct OnChainWithdrawalMeta {
    pub(crate) fee_rate_sats_per_vb: f64,
    pub(crate) tx_size_vb: u32,
    pub(crate) fee_sats: u64,
    /// On-federation fee (msats) quoted at send time; 0 when only the bitcoin
    /// fee is being summarized.
    #[serde(default)]
    pub(crate) federation_fee_msats: u64,
}

impl OnChainWithdrawalMeta {
    /// Summarizes the bitcoin (miner) fee from `PegOutFees`. The federation fee
    /// is layered on separately when the meta is stored (see
    /// `WalletHandler::withdraw_to_address`); here it defaults to 0.
    pub(crate) fn from_peg_out_fees(fees: &PegOutFees) -> Self {
        Self {
            fee_rate_sats_per_vb: fees.fee_rate.sats_per_kvb as f64 / 1000.0,
            // ceil(weight / 4) using only u32
            tx_size_vb: fees.total_weight.div_ceil(4) as u32,
            fee_sats: fees.amount().to_sat(),
            federation_fee_msats: 0,
        }
    }
}

impl Multimint {
    pub async fn new(db: Database, creation_type: MultimintCreation) -> anyhow::Result<Self> {
        let start = Instant::now();
        let mnemonic = match creation_type {
            MultimintCreation::New => {
                let mnemonic = Bip39RootSecretStrategy::<12>::random(&mut thread_rng());
                Client::store_encodable_client_secret(&db, mnemonic.to_entropy()).await?;
                info_to_flutter("Created new multimint wallet").await;
                mnemonic
            }
            MultimintCreation::LoadExisting => {
                let entropy = Client::load_decodable_client_secret::<Vec<u8>>(&db)
                    .await
                    .expect("Could not load existing secret");
                let mnemonic = Mnemonic::from_entropy(&entropy)?;
                info_to_flutter("Loaded existing multimint wallet").await;
                mnemonic
            }
            MultimintCreation::NewFromMnemonic { words } => {
                let all_words = words.join(" ");
                let mnemonic =
                    Mnemonic::parse_in_normalized(Language::English, all_words.as_str())?;
                Client::store_encodable_client_secret(&db, mnemonic.to_entropy()).await?;
                info_to_flutter("Created new multimint wallet from mnemonic").await;
                mnemonic
            }
        };

        let mut modules = ClientModuleInitRegistry::new();
        modules.attach(LightningClientInit::default());
        modules.attach(MintClientInit);
        modules.attach(MintV2Init);
        modules.attach(WalletClientInit::default());
        modules.attach(WalletV2Init);
        modules.attach(fedimint_lnv2_client::LightningClientInit::default());
        modules.attach(MetaClientInit);

        let clients = Arc::new(RwLock::new(BTreeMap::new()));

        let (pegin_address_monitor_tx, pegin_address_monitor_rx) =
            unbounded_channel::<(FederationId, TweakIdx)>();

        let task_group = TaskGroup::new();
        let wallet_handler =
            WalletHandler::new(pegin_address_monitor_tx, db.clone(), task_group.clone());

        let mut multimint = Self {
            db,
            mnemonic,
            modules,
            clients: clients.clone(),
            task_group,
            recovery_progress: Arc::new(RwLock::new(BTreeMap::new())),
            internal_ecash_spends: Arc::new(RwLock::new(BTreeSet::new())),
            recurringd_invoices: Arc::new(RwLock::new(BTreeSet::new())),
            update_notified: Arc::new(AtomicBool::new(false)),
            wallet_handler: wallet_handler.clone(),
        };

        multimint.load_clients().await?;
        wallet_handler
            .spawn_pegin_address_watcher(pegin_address_monitor_rx, multimint.clients.clone());
        wallet_handler.monitor_all_pending_deposits(multimint.clients.clone());
        multimint.run_migrations().await;
        multimint.spawn_cache_task();
        multimint.spawn_recurring_invoice_listener();
        multimint.spawn_backfill_recipient_pk();

        info_to_flutter(format!("Initialized Multimint in {:?}", start.elapsed())).await;
        Ok(multimint)
    }

    async fn run_migrations(&self) {
        let mut dbtx = self.db.begin_transaction().await;
        let current_version = dbtx.get_value(&SchemaVersionKey).await.unwrap_or(0);

        if current_version < 1 {
            // Migration v1: Guardian struct gained peer_id field.
            // Purge cached FederationMeta entries so they get rebuilt with the new format.
            dbtx.remove_by_prefix(&FederationMetaKeyPrefix).await;
            info_to_flutter("Purged FederationMeta cache for schema migration v1").await;
        }

        let target_version: u64 = 1;
        if current_version < target_version {
            dbtx.insert_entry(&SchemaVersionKey, &target_version).await;
            dbtx.commit_tx().await;
            info_to_flutter(format!(
                "Database migrated from v{current_version} to v{target_version}"
            ))
            .await;
        }
    }

    async fn load_clients(&mut self) -> anyhow::Result<()> {
        info_to_flutter("Loading all clients...").await;
        let mut dbtx = self.db.begin_transaction_nc().await;
        let configs = dbtx
            .find_by_prefix(&FederationConfigKeyPrefix)
            .await
            .collect::<BTreeMap<FederationConfigKey, FederationConfig>>()
            .await;
        for (id, _) in configs {
            let client_db = self.get_client_database(&id.id);
            let connectors = ConnectorRegistry::build_from_client_defaults()
                .bind()
                .await?;
            let mut client_builder = Client::builder().await?;
            client_builder.with_module_inits(self.modules.clone());
            let global_root_secret = Bip39RootSecretStrategy::<12>::to_root_secret(&self.mnemonic);
            let client = client_builder
                .open(
                    connectors,
                    client_db,
                    fedimint_client::RootSecret::StandardDoubleDerive(global_root_secret),
                )
                .await
                .map(Arc::new)?;

            self.clients.write().await.insert(id.id, client.clone());

            self.spawn_lnv2_event_listener(client.clone(), id.id);
            self.wallet_handler
                .spawn_v2_deposit_event_listener(client.clone(), id.id);
            self.finish_active_subscriptions(client.clone(), id.id)
                .await;
            if client.has_pending_recoveries() {
                self.spawn_recovery_progress(client.clone());
            }

            self.lnv1_update_gateway_cache(&client).await;
        }

        Ok(())
    }

    async fn finish_active_subscriptions(
        &self,
        client: ClientHandleArc,
        federation_id: FederationId,
    ) {
        let self_copy = self.clone();
        self.task_group
            .spawn_cancellable("finish active subscriptions", async move {
                let active_operations = client.get_active_operations().await;
                let operation_log = client.operation_log();
                for op_id in active_operations {
                    let entry = operation_log.get_operation(op_id).await;
                    if let Some(entry) = entry {
                        // Only drive operation to completion if there is no outcome yet
                        if entry.outcome::<serde_json::Value>().is_none() {
                            match entry.operation_module_kind() {
                                // Spawn only the monitor matching the operation's
                                // direction (like the wallet arms below). Driving
                                // a send monitor on a receive op (or vice versa)
                                // resolves to a "no final state" outcome, which
                                // surfaces a spurious error toast to the user.
                                "lnv2" => {
                                    if matches!(
                                        entry.meta::<LightningOperationMeta>(),
                                        LightningOperationMeta::Send(_)
                                    ) {
                                        self_copy.spawn_await_send(federation_id, op_id);
                                    } else {
                                        self_copy.spawn_await_receive(federation_id, op_id);
                                    }
                                }
                                "ln" => {
                                    if matches!(
                                        entry
                                            .meta::<fedimint_ln_client::LightningOperationMeta>()
                                            .variant,
                                        LightningOperationMetaVariant::Pay(_)
                                    ) {
                                        self_copy.spawn_await_send(federation_id, op_id);
                                    } else {
                                        self_copy.spawn_await_receive(federation_id, op_id);
                                    }
                                }
                                "mint" => {
                                    if matches!(
                                        entry.meta::<MintOperationMeta>().variant,
                                        MintOperationMetaVariant::SpendOOB { .. }
                                    ) {
                                        self_copy.spawn_await_ecash_send(federation_id, op_id);
                                    } else {
                                        self_copy.spawn_await_ecash_reissue(federation_id, op_id);
                                    }
                                }
                                // Deposits/receives are re-driven by the pegin
                                // monitor (v1) and the deposit event listener
                                // (v2); in-flight on-chain sends (peg-outs) have
                                // no other driver, so consume those to completion
                                // here. (We gate on the op type because awaiting a
                                // send state on a receive op would never resolve.)
                                "wallet" => {
                                    if let WalletOperationMetaVariant::Withdraw { .. } =
                                        entry.meta::<WalletOperationMeta>().variant
                                    {
                                        self_copy.spawn_await_withdraw(federation_id, op_id);
                                    }
                                }
                                "walletv2" => {
                                    if let WalletV2OperationMeta::Send(_) =
                                        entry.meta::<WalletV2OperationMeta>()
                                    {
                                        self_copy.spawn_await_withdraw(federation_id, op_id);
                                    }
                                }
                                module => {
                                    info_to_flutter(format!(
                                        "Active operation needs to be driven to completion: {module}"
                                    ))
                                    .await;
                                }
                            }
                        }
                    }
                }
            });
    }

    fn spawn_lnv2_event_listener(&self, client: ClientHandleArc, federation_id: FederationId) {
        let event_bus = get_event_bus();
        let mut log_event_added_rx = client.log_event_added_rx();
        self.task_group
            .spawn_cancellable("lnv2 event listener", async move {
                info_to_flutter(format!(
                    "Spawning LNv2 event listener for federation {federation_id}"
                ))
                .await;

                // Start cursor at the end of the existing log so we only process new events
                let existing = client.get_event_log(None, u64::MAX).await;
                let mut position = existing
                    .last()
                    .map(|e| e.id().saturating_add(1))
                    .unwrap_or(fedimint_eventlog::EventLogId::LOG_START);

                loop {
                    // Block until new events are added to the persistent log
                    if log_event_added_rx.changed().await.is_err() {
                        info_to_flutter(format!(
                            "LNv2 event listener channel closed for {federation_id}"
                        ))
                        .await;
                        break;
                    }

                    // Read all new events from our cursor position
                    let batch = client.get_event_log(Some(position), 100).await;

                    for event in &batch {
                        // The "payment-receive" event kind is shared with mintv2,
                        // so filter on the lnv2 module before decoding/awaiting.
                        if event.module_kind() != Some(&fedimint_lnv2_common::KIND)
                            || event.kind != ReceivePaymentEvent::KIND
                        {
                            position = event.id().saturating_add(1);
                            continue;
                        }

                        if let Some(receive_event) =
                            event.to_event::<ReceivePaymentEvent>()
                        {
                            // fedimint reports `amount` as the gross invoice and
                            // `fee` as the gateway's cut, with `amount = contract +
                            // fee` by construction (lnv2 PR #8741). `amount - fee`
                            // is therefore always the incoming-contract amount
                            // credited, with no need to second-guess the value:
                            // it cancels back to the contract amount even when a
                            // recurring daemon older than #8741 leaves a real
                            // timestamp in the fee-encoded expiration field (which
                            // otherwise inflates fedimint's `fee`/`amount` toward
                            // u64::MAX), and for pre-#8741 events where `fee`
                            // defaults to zero.
                            let amount_msats = receive_event
                                .amount
                                .msats
                                .saturating_sub(receive_event.fee.msats);
                            let operation_id = receive_event.operation_id;
                            info_to_flutter(format!(
                                "LNv2 receive event: {amount_msats} msats, op={operation_id:?} for {federation_id}"
                            ))
                            .await;

                            // Wait for the claim to finalize before notifying
                            if let Ok(lnv2) = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>() {
                                match lnv2.await_final_receive_operation_state(operation_id).await {
                                    Ok(FinalReceiveOperationState::Claimed) => {
                                        info_to_flutter(format!(
                                            "LNv2 receive claimed: {amount_msats} msats for {federation_id}"
                                        ))
                                        .await;
                                        let lightning_event =
                                            LightningEventKind::InvoicePaid(InvoicePaidEvent {
                                                amount_msats,
                                            });
                                        let multimint_event =
                                            MultimintEvent::Lightning((federation_id, lightning_event));
                                        event_bus.publish(multimint_event).await;
                                    }
                                    Ok(state) => {
                                        // A non-claimed receive (e.g. expired invoice) is
                                        // normal user behavior, so we only log it rather than
                                        // surfacing a toast.
                                        info_to_flutter(format!(
                                            "LNv2 receive ended in non-claimed state: {state:?} for {federation_id}"
                                        ))
                                        .await;
                                    }
                                    Err(e) => {
                                        error_to_flutter(format!(
                                            "LNv2 receive await error: {e:?} for {federation_id}"
                                        ))
                                        .await;
                                    }
                                }
                            }
                        }
                        position = event.id().saturating_add(1);
                    }
                }
            });
    }

    pub async fn contains_client(&self, federation_id: &FederationId) -> bool {
        self.clients.read().await.contains_key(federation_id)
    }

    /// Pre-warm guardian connections for every joined federation.
    ///
    /// On Android, sockets to guardians often drop while the app is
    /// backgrounded and don't reconnect on their own. Calling this on app
    /// resume kicks off one connection attempt per peer per federation;
    /// already-live connections are no-ops and failures back off internally.
    pub async fn refresh_connections(&self) {
        let clients = self.clients.read().await;
        for client in clients.values() {
            client.federation_reconnect();
        }
    }

    pub async fn has_seed_phrase_ack(&self) -> bool {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&SeedPhraseAckKey).await.is_some()
    }

    pub async fn ack_seed_phrase(&self) {
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(&SeedPhraseAckKey, &()).await;
        dbtx.commit_tx().await;
    }

    async fn get_or_build_temp_client(
        &self,
        invite_code: InviteCode,
    ) -> anyhow::Result<(ClientHandleArc, FederationId)> {
        // Sometimes we want to get the federation meta before we've joined (i.e to show a preview).
        // In this case, we create a temprorary client and retrieve all the data
        let federation_id = invite_code.federation_id();
        let maybe_client = self.clients.read().await.get(&federation_id).cloned();
        let client = if let Some(client) = maybe_client {
            if !client.has_pending_recoveries() {
                client
            } else {
                self.build_client(&federation_id, &invite_code, ClientType::Temporary)
                    .await?
            }
        } else {
            self.build_client(&federation_id, &invite_code, ClientType::Temporary)
                .await?
        };

        Ok((client, federation_id))
    }

    /// Run one stage of the cache task under [`CACHE_TASK_STAGE_TIMEOUT_SECS`],
    /// returning `None` if it ran out of time.
    ///
    /// The point is liveness of the *loop*, not of the stage: several stages
    /// call out to the network (guardians, mempool.space, nostr relays) and a
    /// black-holed TCP connection produces a future that simply never resolves.
    async fn run_cache_stage<T, F>(name: &str, fut: F) -> Option<T>
    where
        F: std::future::Future<Output = T>,
    {
        match timeout(Duration::from_secs(CACHE_TASK_STAGE_TIMEOUT_SECS), fut).await {
            Ok(value) => Some(value),
            Err(_) => {
                error_to_flutter(format!(
                    "Cache task stage '{name}' timed out after \
                     {CACHE_TASK_STAGE_TIMEOUT_SECS}s; skipping it this cycle"
                ))
                .await;
                None
            }
        }
    }

    fn spawn_cache_task(&self) {
        let self_copy = self.clone();
        self.task_group
            .spawn_cancellable("cache update", async move {
                // Every 5 seconds this thread will wake up to check if the cached federation meta or the cached bitcoin price
                // needs updating
                let mut interval = tokio::time::interval(Duration::from_secs(5));
                interval.tick().await;
                let mut last_version_check: Option<std::time::SystemTime> = None;
                loop {
                    let now = std::time::SystemTime::now();

                    if !self_copy.update_notified.load(Ordering::Relaxed) {
                        let version_due = match last_version_check {
                            Some(t) => now
                                .duration_since(t)
                                .map(|d| d.as_secs() >= VERSION_CHECK_INTERVAL_SECS)
                                .unwrap_or(true),
                            None => true,
                        };
                        if version_due {
                            last_version_check = Some(now);
                            Self::run_cache_stage("version check", self_copy.check_for_update())
                                .await;
                        }
                    }
                    let threshold = now
                        .checked_sub(Duration::from_secs(CACHE_UPDATE_INTERVAL_SECS))
                        .expect("Cannot be negative");

                    // First check if the federation meta needs updating
                    let mut dbtx = self_copy.db.begin_transaction_nc().await;
                    let configs = dbtx
                        .find_by_prefix(&FederationConfigKeyPrefix)
                        .await
                        .collect::<Vec<_>>()
                        .await;
                    for (key, _) in configs.iter() {
                        let federation_id = key.id;

                        let cached_meta =
                            dbtx.get_value(&FederationMetaKey { federation_id }).await;
                        if let Some(cached_meta) = cached_meta {
                            let last_updated =
                                UNIX_EPOCH + Duration::from_millis(cached_meta.last_updated);
                            // Skip over caching this federation's meta if we cached it recently
                            if last_updated >= threshold {
                                continue;
                            }
                        }

                        let client = self_copy.clients.read().await.get(&federation_id).cloned();
                        let Some(client) = client else { continue };

                        if !client.has_pending_recoveries() {
                            // Bounded per federation: one unreachable guardian
                            // must not consume the whole cycle.
                            Self::run_cache_stage(
                                "federation meta",
                                self_copy.cache_federation_meta(client.clone(), now),
                            )
                            .await;
                        }
                    }

                    // Next check if the bitcoin price needs updating. Only update the price if it has not been cached yet, or if
                    // it is out of date
                    let threshold = now
                        .checked_sub(Duration::from_secs(PRICE_CACHE_UPDATE_INTERVAL_SECS))
                        .expect("Cannot be negative");
                    let cached_price = dbtx.get_value(&BtcPriceKey).await;
                    let price_due = match cached_price {
                        Some(cached_price) => cached_price.last_updated < threshold,
                        None => true,
                    };
                    if price_due {
                        // This is the stage that used to starve the backup
                        // below it: an unresponsive mempool.space held a
                        // no-timeout request open forever.
                        Self::run_cache_stage("btc price", self_copy.cache_btc_price(now)).await;
                    }

                    // Next check if we need to backup our ecash to the federation
                    let threshold = now
                        .checked_sub(Duration::from_secs(
                            FEDERATION_BACKUP_CACHE_UPDATE_INTERVAL_SECS,
                        ))
                        .expect("Cannot be negative");
                    for (key, _) in configs {
                        let federation_id = key.id;
                        let backup_time =
                            dbtx.get_value(&FederationBackupKey { federation_id }).await;
                        let backup_due = match backup_time {
                            Some(backup) => backup < threshold,
                            None => true,
                        };
                        if backup_due {
                            Self::run_cache_stage(
                                "federation backup",
                                self_copy.backup(&federation_id, now),
                            )
                            .await;
                        }
                    }

                    // Check if contact sync is due
                    let contact_sync_threshold = now
                        .checked_sub(Duration::from_secs(CONTACT_SYNC_INTERVAL_SECS))
                        .expect("Cannot be negative");
                    if let Some(sync_config) = dbtx.get_value(&ContactSyncConfigKey).await {
                        if sync_config.sync_enabled {
                            let should_sync = match sync_config.last_sync_at {
                                Some(last_sync) => {
                                    let last_sync_time =
                                        UNIX_EPOCH + Duration::from_millis(last_sync);
                                    last_sync_time < contact_sync_threshold
                                }
                                None => true,
                            };

                            if should_sync {
                                let nostr_client = get_nostr_client();
                                // Clone the NostrClient and drop the RwLock guard immediately
                                // to avoid holding the NOSTR read lock during slow network
                                // operations in sync_contacts(). Holding the read lock would
                                // block any pending write lock, which in turn blocks new
                                // readers (like get_nwc_connection_info) due to Tokio's
                                // write-preferring RwLock.
                                let nostr = nostr_client.read().await.clone();
                                Self::run_cache_stage("contact sync", nostr.sync_contacts()).await;
                            }
                        }
                    }

                    interval.tick().await;
                }
            });
    }

    async fn check_for_update(&self) {
        let client = match crate::net::http_client_builder()
            .user_agent(concat!("ecash-app/", env!("CARGO_PKG_VERSION")))
            .timeout(Duration::from_secs(10))
            .build()
        {
            Ok(c) => c,
            Err(_) => return,
        };

        let response = match client.get(GITHUB_LATEST_RELEASE_URL).send().await {
            Ok(r) => r,
            Err(_) => return,
        };
        if !response.status().is_success() {
            return;
        }
        let json: serde_json::Value = match response.json().await {
            Ok(v) => v,
            Err(_) => return,
        };
        let Some(tag_name) = json.get("tag_name").and_then(|v| v.as_str()) else {
            return;
        };
        let latest = tag_name.trim_start_matches('v').to_string();
        let current = env!("CARGO_PKG_VERSION");
        if is_newer_version(current, &latest) {
            self.update_notified.store(true, Ordering::Relaxed);
            get_event_bus()
                .publish(MultimintEvent::UpdateAvailable(latest))
                .await;
        }
    }

    async fn backup(&self, federation_id: &FederationId, now: std::time::SystemTime) {
        // Clone the client out and drop the clients lock BEFORE the network
        // backup upload. Holding `clients.read()` across `backup_to_federation()`
        // (a guardian round-trip that retries against offline peers) would block
        // `join_federation`'s `clients.write()`, and tokio's write-preferring
        // RwLock would then stall every other reader too.
        let client = self.clients.read().await.get(federation_id).cloned();
        let Some(client) = client else { return };

        if client.has_pending_recoveries() {
            return;
        }

        let mut dbtx = self.db.begin_transaction().await;
        let metadata: BTreeMap<String, String> = BTreeMap::new();
        #[allow(deprecated)]
        let backup_result = client
            .backup_to_federation(fedimint_client::backup::Metadata::from_json_serialized(
                metadata,
            ))
            .await;
        match backup_result {
            Ok(()) => {
                dbtx.insert_entry(
                    &FederationBackupKey {
                        federation_id: *federation_id,
                    },
                    &now,
                )
                .await;
                dbtx.commit_tx().await;
                info_to_flutter(format!("Successfully backed up {federation_id}")).await;
            }
            Err(e) => {
                error_to_flutter(format!("Could not create backup for {federation_id}: {e}")).await;
            }
        }
    }

    async fn cache_btc_price(&self, now: std::time::SystemTime) {
        let url = "https://mempool.space/api/v1/prices";
        // `reqwest::get` applies no timeout at all, so a black-holed connection
        // leaves this future pending forever.
        let client = match crate::net::http_client_builder()
            .timeout(Duration::from_secs(PRICE_FETCH_TIMEOUT_SECS))
            .build()
        {
            Ok(client) => client,
            Err(e) => {
                error_to_flutter(format!("Could not build BTC price HTTP client: {e}")).await;
                return;
            }
        };
        let Ok(response) = client.get(url).send().await else {
            error_to_flutter("BTC Price GET returned error").await;
            return;
        };

        if response.status().is_success() {
            let json: Result<serde_json::Value, reqwest::Error> = response.json().await;
            if let Ok(json) = json {
                // Extract all currency prices
                let usd = json.get("USD").and_then(|v| v.as_u64());
                let eur = json.get("EUR").and_then(|v| v.as_u64());
                let gbp = json.get("GBP").and_then(|v| v.as_u64());
                let cad = json.get("CAD").and_then(|v| v.as_u64());
                let chf = json.get("CHF").and_then(|v| v.as_u64());
                let aud = json.get("AUD").and_then(|v| v.as_u64());
                let jpy = json.get("JPY").and_then(|v| v.as_u64());

                if let (
                    Some(usd),
                    Some(eur),
                    Some(gbp),
                    Some(cad),
                    Some(chf),
                    Some(aud),
                    Some(jpy),
                ) = (usd, eur, gbp, cad, chf, aud, jpy)
                {
                    let mut dbtx = self.db.begin_transaction().await;

                    // Store multi-currency prices
                    dbtx.insert_entry(
                        &BtcPricesKey,
                        &BtcPrices {
                            usd,
                            eur,
                            gbp,
                            cad,
                            chf,
                            aud,
                            jpy,
                            last_updated: now,
                        },
                    )
                    .await;

                    // Also store USD price in old format for backward compatibility
                    dbtx.insert_entry(
                        &BtcPriceKey,
                        &BtcPrice {
                            price: usd,
                            last_updated: now,
                        },
                    )
                    .await;

                    dbtx.commit_tx().await;
                    info_to_flutter(format!(
                        "Updated BTC Prices: USD={}, EUR={}, GBP={}, CAD={}, CHF={}, AUD={}, JPY={}",
                        usd, eur, gbp, cad, chf, aud, jpy
                    ))
                    .await;
                } else {
                    error_to_flutter("Failed to parse all currency prices from API response").await;
                }
            }
        } else {
            error_to_flutter(format!(
                "Failed to load price data, status: {}",
                response.status()
            ))
            .await;
        }
    }

    pub async fn get_cached_federation_meta(
        &self,
        invite: Option<String>,
        federation_id: Option<FederationId>,
    ) -> anyhow::Result<FederationMeta> {
        let (client, federation_id) = match federation_id {
            Some(federation_id) => {
                let clients = self.clients.read().await;
                let client = clients
                    .get(&federation_id)
                    .ok_or(anyhow!("No federation exists"))?
                    .clone();
                (client, federation_id)
            }
            None => {
                let invite =
                    invite.ok_or(anyhow!("Federation ID and Invite cannot both be None"))?;
                let invite_code = InviteCode::from_str(&invite)?;
                // Building a temporary client downloads the config from the
                // federation's guardians. If they're unreachable this otherwise
                // hangs forever, leaving the preview spinner stuck. Bound it so
                // the caller gets a real error instead.
                timeout(
                    Duration::from_secs(15),
                    self.get_or_build_temp_client(invite_code),
                )
                .await
                .map_err(|_| anyhow!("Timed out downloading federation config from guardians"))??
            }
        };

        let mut dbtx = self.db.begin_transaction().await;
        if let Some(cached_meta) = dbtx.get_value(&FederationMetaKey { federation_id }).await {
            return Ok(cached_meta);
        }

        // Federation either has not been cached yet, or is a new federation
        Ok(self
            .cache_federation_meta(client, std::time::SystemTime::now())
            .await)
    }

    /// Refetch and re-cache a federation's meta immediately, bypassing both the
    /// cached value and the periodic refresh task. Used after a guardian action
    /// changes meta consensus, so the app reflects it without waiting out the
    /// cache interval.
    pub async fn refresh_federation_meta(
        &self,
        federation_id: &FederationId,
    ) -> anyhow::Result<FederationMeta> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("Federation does not exist"))?
            .clone();
        Ok(self
            .cache_federation_meta(client, std::time::SystemTime::now())
            .await)
    }

    fn get_url(key: &str, meta: &serde_json::Value) -> Option<String> {
        let value = meta.get(key)?;
        let url_str = value.as_str()?;
        Some(SafeUrl::parse(url_str).ok()?.to_string())
    }

    /// Resolves the Bitcoin network for a federation from whichever wallet
    /// module it has. walletv1 and walletv2 both expose `get_network()`, but a
    /// federation only has one of them, so we try both. Returns `None` for a
    /// federation with no wallet module at all.
    fn wallet_network(client: &ClientHandleArc) -> Option<String> {
        if let Ok(wallet) = client.get_first_module::<WalletV2Module>() {
            return Some(wallet.get_network().to_string());
        }
        if let Ok(wallet) = client.get_first_module::<fedimint_wallet_client::WalletClientModule>()
        {
            return Some(wallet.get_network().to_string());
        }
        None
    }

    async fn cache_federation_meta(
        &self,
        client: ClientHandleArc,
        now: std::time::SystemTime,
    ) -> FederationMeta {
        let federation_id = client.federation_id();

        let config = client.config().await;
        let network = Self::wallet_network(&client);

        let cached_meta: Option<FederationMeta> = {
            let mut dbtx = self.db.begin_transaction_nc().await;
            dbtx.get_value(&FederationMetaKey { federation_id }).await
        };

        // Load cached guardian versions so we can preserve them when a guardian is offline
        let cached_versions: BTreeMap<u16, Option<String>> = cached_meta
            .as_ref()
            .map(|m| {
                m.guardians
                    .iter()
                    .map(|g| (g.peer_id, g.version.clone()))
                    .collect()
            })
            .unwrap_or_default();

        let peers = &config.global.api_endpoints;
        let mut guardians = Vec::new();
        for (peer_id, endpoint) in peers {
            let pid = peer_id.to_usize() as u16;
            let fetched_version = client.api().fedimintd_version(*peer_id).await.ok();
            let version = match &fetched_version {
                Some(v) => {
                    let cached = cached_versions.get(&pid).and_then(|c| c.as_ref());
                    if cached == Some(v) {
                        // Version unchanged, keep cached
                        cached.cloned()
                    } else {
                        // New or changed version
                        fetched_version
                    }
                }
                // API returned None (guardian offline), preserve cached version
                None => cached_versions.get(&pid).cloned().flatten(),
            };
            guardians.push(Guardian {
                peer_id: pid,
                name: endpoint.name.clone(),
                version,
            });
        }

        // Fetch the federation's meta-module consensus value (when the module
        // exists and a value has been set). Guardians can change fields like the
        // federation name here, so we prefer it over the static config below.
        let meta_json = match client.get_first_module::<fedimint_meta_client::MetaClientModule>() {
            Ok(meta) => match meta.get_consensus_value(DEFAULT_META_KEY).await {
                Ok(Some(value)) => value.value.to_json().ok(),
                _ => None,
            },
            Err(_) => None,
        };

        // Prefer the federation name set in the meta module so guardian-driven
        // name changes are reflected, falling back to the name baked into the
        // config when the meta module is absent or has no name set.
        let federation_name = meta_json
            .as_ref()
            .and_then(|meta| meta.get(META_FEDERATION_NAME_KEY))
            .and_then(serde_json::Value::as_str)
            .filter(|name| !name.is_empty())
            .map(ToString::to_string)
            .unwrap_or_else(|| config.global.federation_name().unwrap_or("").to_string());

        let selector = FederationSelector {
            federation_name: federation_name.clone(),
            federation_id,
            network,
        };

        let last_updated = now
            .duration_since(UNIX_EPOCH)
            .expect("Cannot be before epoch")
            .as_millis() as u64;

        let federation_meta = match meta_json {
            Some(meta) => {
                let welcome = meta
                    .get("welcome_message")
                    .and_then(serde_json::Value::as_str)
                    .map(ToString::to_string);
                let picture = Self::get_url("fedi:federation_icon_url", &meta);
                let recurringd_api = Self::get_url("recurringd_api", &meta);
                let lnaddress_api = Self::get_url("lnaddress_api", &meta);

                FederationMeta {
                    picture,
                    welcome,
                    guardians,
                    selector,
                    last_updated,
                    recurringd_api,
                    lnaddress_api,
                }
            }
            None => FederationMeta {
                picture: None,
                welcome: None,
                guardians,
                selector,
                last_updated,
                recurringd_api: None,
                lnaddress_api: None,
            },
        };

        let mut dbtx = self.db.begin_transaction().await;
        // Keep the persisted config name in sync so the federation list (which
        // reads FederationConfig) reflects guardian-driven name changes too.
        if let Some(mut fed_config) = dbtx
            .get_value(&FederationConfigKey { id: federation_id })
            .await
        {
            if fed_config.federation_name != federation_name {
                fed_config.federation_name = federation_name;
                dbtx.insert_entry(&FederationConfigKey { id: federation_id }, &fed_config)
                    .await;
            }
        }
        dbtx.insert_entry(&FederationMetaKey { federation_id }, &federation_meta)
            .await;
        dbtx.commit_tx().await;
        info_to_flutter(format!(
            "Updated meta for {}",
            federation_meta.selector.federation_name
        ))
        .await;

        // Notify the UI only when something it renders actually changed. This
        // runs on a timer, and `last_updated` differs on every pass, so
        // comparing whole values would republish constantly.
        let changed = match &cached_meta {
            Some(old) => {
                old.picture != federation_meta.picture
                    || old.welcome != federation_meta.welcome
                    || old.selector.federation_name != federation_meta.selector.federation_name
                    || old.guardians != federation_meta.guardians
            }
            None => true,
        };
        if changed {
            get_event_bus()
                .publish(MultimintEvent::MetaUpdated(federation_id.to_string()))
                .await;
        }

        federation_meta
    }

    pub async fn subscribe_peer_status(
        &self,
        invite: Option<String>,
        federation_id: Option<FederationId>,
    ) -> anyhow::Result<impl Stream<Item = Vec<PeerStatus>>> {
        let client = match &invite {
            Some(invite) => {
                let invite_code = InviteCode::from_str(invite)?;
                self.get_or_build_temp_client(invite_code).await?.0
            }
            None => {
                let federation_id =
                    federation_id.expect("Invite code and federation ID cannot both be None");
                let clients = self.clients.read().await;
                clients
                    .get(&federation_id)
                    .ok_or(anyhow!("No federation exists"))?
                    .clone()
            }
        };

        // Get the peer names and URLs from the federation config
        let config = client.config().await;
        let peers: BTreeMap<u16, (String, String)> = config
            .global
            .api_endpoints
            .iter()
            .map(|(peer_id, endpoint)| {
                (
                    peer_id.to_usize() as u16,
                    (endpoint.name.clone(), endpoint.url.to_string()),
                )
            })
            .collect();

        // If the invite code is available, that means we have not joined the federation yet. We cannot use the `connection_stream_status`
        // because the client will go out of scope and end the stream. So instead, we just lookup the federation's online status by querying
        // the fedimintd version.
        if invite.is_some() {
            let peer_statuses =
                futures_util::future::join_all(peers.iter().map(|(peer_id, (name, url))| {
                    let client = client.clone();
                    async move {
                        let fetched_version =
                            client.api().fedimintd_version((*peer_id).into()).await.ok();
                        PeerStatus {
                            peer_id: *peer_id,
                            name: name.clone(),
                            online: fetched_version.is_some(),
                            // The preview path calls fedimintd_version directly rather than
                            // going through the pooled connection, so the hop is always direct.
                            connectivity: PeerConnectivity::Direct,
                            url: url.clone(),
                            version: fetched_version,
                        }
                    }
                }))
                .await;

            return Ok(stream::once(async { peer_statuses }).boxed());
        }

        // Get the connection status stream from the client
        let status_stream = client.api().connection_status_stream();

        // Guardian versions are refreshed out-of-band by the periodic meta cache
        // task (`spawn_cache_task` -> `cache_federation_meta`) and persisted under
        // `FederationMetaKey`. We read them from that cache rather than fetching
        // inline, so this stream stays a cheap, purely-local mapping of
        // connectivity -> status: the sidebar's online indicator updates the
        // instant fedimint reports a peer up/down, with no per-guardian network
        // round-trips gating the emission.
        let db = self.db.clone();
        let federation_id = client.federation_id();
        let peers = Arc::new(peers);
        let mapped_stream = status_stream.then(move |status_map| {
            let db = db.clone();
            let peers = peers.clone();
            async move {
                // A single local read returns every guardian's last-known version.
                let cached_versions: BTreeMap<u16, Option<String>> = {
                    let mut dbtx = db.begin_transaction_nc().await;
                    dbtx.get_value(&FederationMetaKey { federation_id })
                        .await
                        .map(|meta| {
                            meta.guardians
                                .into_iter()
                                .map(|g| (g.peer_id, g.version))
                                .collect()
                        })
                        .unwrap_or_default()
                };

                peers
                    .iter()
                    .map(|(peer_id, (name, url))| {
                        let (online, connectivity) = match status_map.get(&(*peer_id).into()) {
                            Some(FedimintPeerStatus::Connected(c)) => (true, (*c).into()),
                            Some(FedimintPeerStatus::Disconnected) | None => {
                                (false, PeerConnectivity::Unknown)
                            }
                        };
                        PeerStatus {
                            peer_id: *peer_id,
                            name: name.clone(),
                            online,
                            connectivity,
                            url: url.clone(),
                            version: cached_versions.get(peer_id).cloned().flatten(),
                        }
                    })
                    .collect::<Vec<_>>()
            }
        });

        Ok(mapped_stream.boxed())
    }

    pub fn get_mnemonic(&self) -> Vec<String> {
        self.mnemonic
            .words()
            .map(std::string::ToString::to_string)
            .collect::<Vec<_>>()
    }

    pub async fn join_federation(
        &mut self,
        invite: String,
        recover: bool,
    ) -> anyhow::Result<FederationSelector> {
        let invite_code = InviteCode::from_str(&invite)?;
        let federation_id = invite_code.federation_id();

        let client = if recover {
            self.build_client(&federation_id, &invite_code, ClientType::Recovery)
                .await?
        } else {
            self.build_client(&federation_id, &invite_code, ClientType::New)
                .await?
        };

        let client_config = client.config().await;
        let federation_name = client_config
            .global
            .federation_name()
            .expect("No federation name")
            .to_owned();

        let network = Self::wallet_network(&client);

        let federation_config = FederationConfig {
            connector: Connector::default(),
            federation_name: federation_name.clone(),
            network: network.clone(),
            client_config: client_config.clone(),
        };

        self.clients
            .write()
            .await
            .insert(federation_id, client.clone());

        self.wallet_handler
            .spawn_v2_deposit_event_listener(client.clone(), federation_id);
        self.spawn_lnv2_event_listener(client, federation_id);

        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(
            &FederationConfigKey { id: federation_id },
            &federation_config,
        )
        .await;
        dbtx.commit_tx().await;

        Ok(FederationSelector {
            federation_name,
            federation_id,
            network,
        })
    }

    pub async fn leave_federation(&mut self, federation_id: &FederationId) {
        // Config first, client second. `federations()` walks the persisted
        // configs and looks each one up in the client map, so removing the
        // client first opened a window — the two removals are separated by
        // several awaits — where a config existed with no client behind it.
        // Dropping the config first means the federation is simply absent from
        // that walk, never half-present.
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.remove_entry(&FederationConfigKey { id: *federation_id })
            .await;
        dbtx.commit_tx().await;
        self.clients.write().await.remove(federation_id);
    }

    async fn build_client(
        &self,
        federation_id: &FederationId,
        invite_code: &InviteCode,
        client_type: ClientType,
    ) -> anyhow::Result<ClientHandleArc> {
        info_to_flutter(format!("Building new client. type: {client_type}")).await;
        let connectors = ConnectorRegistry::build_from_client_defaults()
            .bind()
            .await?;
        let client_db = match client_type {
            ClientType::Temporary => MemDatabase::new().into(),
            _ => self.get_client_database(federation_id),
        };

        let global_root_secret = Bip39RootSecretStrategy::<12>::to_root_secret(&self.mnemonic);
        let mut client_builder = Client::builder().await?;
        client_builder.with_module_inits(self.modules.clone());

        let client = match client_type {
            ClientType::Recovery => {
                let client_preview = client_builder
                    .preview(connectors.clone(), invite_code)
                    .await?;
                #[allow(deprecated)]
                let backup = client_preview
                    .download_backup_from_federation(
                        fedimint_client::RootSecret::StandardDoubleDerive(
                            global_root_secret.clone(),
                        ),
                    )
                    .await?;
                if backup.is_some() {
                    info_to_flutter("Starting recovery with backup from federation").await;
                } else {
                    info_to_flutter(
                        "Starting recovery without a backup! This could take some time...",
                    )
                    .await;
                }
                let client = client_preview
                    .recover(
                        client_db,
                        fedimint_client::RootSecret::StandardDoubleDerive(global_root_secret),
                        backup,
                    )
                    .await
                    .map(Arc::new)?;
                self.spawn_recovery_progress(client.clone());
                client
            }
            client_type => {
                let client = if Client::is_initialized(&client_db).await {
                    info_to_flutter("Client is already initialized, opening using secret...").await;
                    client_builder
                        .open(
                            connectors.clone(),
                            client_db,
                            fedimint_client::RootSecret::StandardDoubleDerive(global_root_secret),
                        )
                        .await
                } else {
                    info_to_flutter("Client is not initialized, downloading invite code...").await;
                    let preview = match timeout(
                        Duration::from_secs(60),
                        client_builder.preview(connectors.clone(), invite_code),
                    )
                    .await
                    {
                        Ok(preview) => preview,
                        Err(error) => {
                            return Err(anyhow!("Timed out getting federation preview: {error}"))
                        }
                    };
                    preview?
                        .join(
                            client_db,
                            fedimint_client::RootSecret::StandardDoubleDerive(global_root_secret),
                        )
                        .await
                }
                .map(Arc::new)?;

                if client_type == ClientType::New {
                    self.lnv1_update_gateway_cache(&client).await;
                }

                client
            }
        };

        Ok(client)
    }

    fn spawn_recovery_progress(&self, client: ClientHandleArc) {
        let mut self_copy = self.clone();
        let recovering_client = client.clone();
        self.task_group
            .spawn_cancellable("wait for recovery", async move {
                if let Err(e) = self_copy.wait_for_recovery(recovering_client).await {
                    error_to_flutter(format!("Error waiting for recovery: {e:?}")).await;
                }
            });

        let progress_copy = self.clone();
        self.task_group
            .spawn_cancellable("recovery progress", async move {
                progress_copy
                    .init_recovery_progress_cache(client.federation_id())
                    .await;

                let mut stream = client.subscribe_to_recovery_progress();
                while let Some((module_id, progress)) = stream.next().await {
                    progress_copy
                        .update_recovery_progress_cache(
                            &client.federation_id(),
                            module_id,
                            progress,
                        )
                        .await;
                }

                progress_copy
                    .remove_recovery_progress_cache(&client.federation_id())
                    .await;
            });
    }

    async fn init_recovery_progress_cache(&self, federation_id: FederationId) {
        let mut progress = self.recovery_progress.write().await;
        progress.insert(federation_id, BTreeMap::new());
    }

    async fn remove_recovery_progress_cache(&self, federation_id: &FederationId) {
        let mut progress = self.recovery_progress.write().await;
        progress.remove(federation_id);
    }

    async fn update_recovery_progress_cache(
        &self,
        federation_id: &FederationId,
        module_id: u16,
        module_progress: RecoveryProgress,
    ) {
        let mut progress = self.recovery_progress.write().await;
        if let Some(module_progress_cache) = progress.get_mut(federation_id) {
            module_progress_cache.insert(module_id, module_progress);
        }
        get_event_bus()
            .publish(MultimintEvent::RecoveryProgress(
                federation_id.to_string(),
                module_id,
                module_progress.complete,
                module_progress.total,
            ))
            .await;
    }

    pub async fn get_recovery_progress(
        &self,
        federation_id: &FederationId,
        module_id: u16,
    ) -> RecoveryProgress {
        let progress = self.recovery_progress.read().await;
        let module_progress = progress.get(federation_id);
        if let Some(module_progress) = module_progress {
            if let Some(progress) = module_progress.get(&module_id) {
                return *progress;
            }
        }

        RecoveryProgress {
            complete: 0,
            total: 0,
        }
    }

    async fn wait_for_recovery(
        &mut self,
        recovering_client: ClientHandleArc,
    ) -> anyhow::Result<()> {
        let federation_id = recovering_client.federation_id();
        info_to_flutter("Waiting for all recoveries...").await;
        recovering_client.wait_for_all_recoveries().await?;

        // Try all federation invite codes in case some peers are down
        let config = recovering_client.config().await;
        let peers = config.global.api_endpoints.keys().collect::<Vec<_>>();
        let mut joined = false;
        for peer in peers {
            if let Some(invite_code) = recovering_client.invite_code(*peer).await {
                self.join_federation(invite_code.to_string(), false).await?;
                joined = true;
                break;
            }
        }

        if !joined {
            bail!("Could not re-join federation after recovering");
        }

        let new_client = self
            .clients
            .read()
            .await
            .get(&federation_id)
            .expect("Client should be available")
            .clone();
        info_to_flutter("Waiting for all active state machines...").await;
        new_client.wait_for_all_active_state_machines().await?;

        // Attempt to recover Lightning Address before publishing RecoveryDone,
        // so the UI can display the recovered address when it handles the event.
        let ln_address_api = "https://ecash.love";
        let recurringd_api = "https://recurring.ecash.love";
        if let Err(e) = self
            .recover_ln_address(&federation_id, ln_address_api, recurringd_api)
            .await
        {
            error_to_flutter(format!("Lightning Address recovery failed: {e}")).await;
        }

        get_event_bus()
            .publish(MultimintEvent::RecoveryDone(federation_id.to_string()))
            .await;

        Ok(())
    }

    fn get_client_database(&self, federation_id: &FederationId) -> Database {
        let mut prefix = vec![crate::db::DbKeyPrefix::ClientDatabase as u8];
        prefix.append(&mut federation_id.consensus_encode_to_vec());
        self.db.with_prefix(prefix)
    }

    pub async fn federations(&self) -> Vec<(FederationSelector, bool)> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        let mut federations: Vec<(FederationSelector, bool)> = dbtx
            .find_by_prefix(&FederationConfigKeyPrefix)
            .await
            .filter_map(|(id, config)| {
                let clients_clone = self.clients.clone();
                async move {
                    // Belt and braces alongside the removal order in
                    // `leave_federation`: a config with no client is skipped
                    // rather than panicking the whole listing.
                    let client = clients_clone.read().await.get(&id.id).cloned()?;
                    let selector = FederationSelector {
                        federation_name: config.federation_name,
                        federation_id: id.id,
                        network: config.network,
                    };
                    Some((selector, client.has_pending_recoveries()))
                }
            })
            .collect::<Vec<_>>()
            .await;

        // Apply saved order if it exists
        if let Some(saved_order) = self.get_federation_order().await {
            // Create a map of federation_id to (selector, recovery_status)
            let mut fed_map: BTreeMap<FederationId, (FederationSelector, bool)> = federations
                .into_iter()
                .map(|(selector, status)| (selector.federation_id, (selector, status)))
                .collect();

            // Build ordered list based on saved order, then append any new federations
            let mut ordered_feds = Vec::new();
            for fed_id in saved_order {
                if let Some(fed) = fed_map.remove(&fed_id) {
                    ordered_feds.push(fed);
                }
            }
            // Append any federations not in the saved order (newly added)
            for (_, fed) in fed_map {
                ordered_feds.push(fed);
            }
            federations = ordered_feds;
        }

        federations
    }

    /// The Bitcoin network this federation operates on, as recorded in its
    /// persisted config. `None` when the federation has no wallet module, or
    /// when the stored string isn't a network we recognize — callers should
    /// treat that as "unknown" and skip network-dependent checks rather than
    /// guessing.
    ///
    /// Not exposed over the bridge: `bitcoin::Network` has no FRB
    /// representation, and Dart already gets the network as a string on
    /// [`FederationSelector`].
    #[flutter_rust_bridge::frb(ignore)]
    pub async fn federation_network(
        &self,
        federation_id: &FederationId,
    ) -> Option<bitcoin::Network> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        let config = dbtx
            .get_value(&FederationConfigKey { id: *federation_id })
            .await?;
        bitcoin::Network::from_str(&config.network?).ok()
    }

    /// Fallible on purpose. The UI polls this, and both failure modes are
    /// ordinary rather than exceptional: the federation can be left while a
    /// screen still holds its id, and the balance query itself can fail
    /// transiently while a module is still coming up during recovery.
    ///
    /// Returning zero for either would be worse than an error — a wallet
    /// showing a confident zero is alarming and wrong.
    pub async fn balance(&self, federation_id: &FederationId) -> anyhow::Result<u64> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .cloned()
            .ok_or(anyhow!("No federation exists"))?;
        Ok(client.get_balance_for_btc().await?.msats)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn receive(
        &self,
        federation_id: &FederationId,
        amount_msats_with_fees: u64,
        amount_msats_without_fees: u64,
        federation_fee_msats: u64,
        gateway_fee_msats: u64,
        gateway: SafeUrl,
        is_lnv2: bool,
    ) -> anyhow::Result<(Bolt11Invoice, OperationId)> {
        let amount_with_fees = Amount::from_msats(amount_msats_with_fees);
        let amount_without_fees = Amount::from_msats(amount_msats_without_fees);
        let federation_fee = Amount::from_msats(federation_fee_msats);
        let gateway_fee = Amount::from_msats(gateway_fee_msats);
        info_to_flutter(format!("Amount with fees: {amount_with_fees:?}")).await;
        info_to_flutter(format!("Amount without fees: {amount_without_fees:?}")).await;
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .cloned()
            .ok_or(anyhow!("No federation exists"))?;

        if is_lnv2 {
            if let Ok((invoice, operation_id)) = Self::receive_lnv2(
                &client,
                amount_with_fees,
                amount_without_fees,
                federation_fee,
                gateway_fee,
                gateway.clone(),
            )
            .await
            {
                info_to_flutter("Using LNv2 for the actual invoice").await;
                self.spawn_await_receive(*federation_id, operation_id);
                return Ok((invoice, operation_id));
            }
        }

        info_to_flutter("Using LNv1 for the actual invoice").await;
        let (invoice, operation_id) = Self::receive_lnv1(
            &client,
            amount_with_fees,
            amount_without_fees,
            federation_fee,
            gateway_fee,
            gateway,
        )
        .await?;

        // Spawn new task that awaits the payment in case the user clicks away
        self.spawn_await_receive(*federation_id, operation_id);

        Ok((invoice, operation_id))
    }

    fn spawn_await_receive(&self, federation_id: FederationId, operation_id: OperationId) {
        let self_copy = self.clone();
        self.task_group
            .spawn_cancellable("await receive", async move {
                // Check if this is an LNv1 operation. LNv2 receive notifications
                // are handled by the event listener, so we only publish to the
                // EventBus for LNv1 receives.
                let is_lnv1 = {
                    // Federation left while this watcher was running. Nothing
                    // left to report to, so end the task instead of panicking it.
                    let Some(client) = self_copy.clients.read().await.get(&federation_id).cloned()
                    else {
                        return;
                    };
                    client
                        .operation_log()
                        .get_operation(operation_id)
                        .await
                        .map(|entry| entry.operation_module_kind() == "ln")
                        .unwrap_or(false)
                };

                match self_copy.await_receive(&federation_id, operation_id).await {
                    Ok((final_state, amount_msats)) => {
                        info_to_flutter(format!("Receive completed: {final_state:?}")).await;
                        if final_state == FinalReceiveOperationState::Claimed && is_lnv1 {
                            let lightning_event =
                                LightningEventKind::InvoicePaid(InvoicePaidEvent { amount_msats });
                            let multimint_event =
                                MultimintEvent::Lightning((federation_id, lightning_event));
                            get_event_bus().publish(multimint_event).await;
                        }
                    }
                    Err(e) => {
                        info_to_flutter(format!("Could not await receive {operation_id:?} {e:?}"))
                            .await;
                    }
                }
            });
    }

    async fn receive_lnv2(
        client: &ClientHandleArc,
        amount_with_fees: Amount,
        amount_without_fees: Amount,
        federation_fee: Amount,
        gateway_fee: Amount,
        gateway: SafeUrl,
    ) -> anyhow::Result<(Bolt11Invoice, OperationId)> {
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let custom_meta = json!({
            "amount": amount_without_fees,
            "amount_with_fees": amount_with_fees,
            "federation_fees": federation_fee,
            "gateway_fees": gateway_fee,
            "gateway_url": gateway,
        });
        let (invoice, operation_id) = lnv2
            .receive(
                amount_with_fees,
                DEFAULT_EXPIRY_TIME_SECS,
                Bolt11InvoiceDescription::Direct(String::new()),
                Some(gateway),
                custom_meta,
            )
            .await?;
        Ok((invoice, operation_id))
    }

    async fn receive_lnv1(
        client: &ClientHandleArc,
        amount_with_fees: Amount,
        amount_without_fees: Amount,
        federation_fee: Amount,
        gateway_fee: Amount,
        gateway_url: SafeUrl,
    ) -> anyhow::Result<(Bolt11Invoice, OperationId)> {
        let lnv1 = client.get_first_module::<LightningClientModule>()?;
        let custom_meta = json!({
            "amount": amount_without_fees,
            "amount_with_fees": amount_with_fees,
            "federation_fees": federation_fee,
            "gateway_fees": gateway_fee,
            "gateway_url": gateway_url,
        });
        let gateways = lnv1.list_gateways().await;
        let gateway = gateways
            .iter()
            .find(|g| g.info.api == gateway_url)
            .ok_or(anyhow!("Could not find gateway"))?
            .info
            .clone();
        let desc = Description::new(String::new())?;
        let (operation_id, invoice, _) = lnv1
            .create_bolt11_invoice(
                amount_with_fees,
                lightning_invoice::Bolt11InvoiceDescription::Direct(desc),
                Some(DEFAULT_EXPIRY_TIME_SECS as u64),
                custom_meta,
                Some(gateway),
            )
            .await?;
        Ok((invoice, operation_id))
    }

    /// Computes the invoice amount and fee breakdown for a receive.
    ///
    /// When `include_fees` is true the fees are added on top of `amount`, so the
    /// sender covers them and exactly `amount` is credited to the receiver. When
    /// it is false the invoice equals `amount` exactly — the sender pays only what
    /// was requested and the receiver absorbs the fees, netting `amount` minus the
    /// fees. In both cases the returned `invoice_msats` is the invoice face value
    /// and the receiver nets `invoice_msats - federation_fee_msats -
    /// gateway_fee_msats`.
    pub async fn compute_receive_amount_with_fees(
        &self,
        federation_id: &FederationId,
        gateway_url: SafeUrl,
        is_lnv2: bool,
        amount: Amount,
        include_fees: bool,
    ) -> anyhow::Result<ReceiveAmount> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("No federation exists"))?
            .clone();
        let requested = amount.msats;

        // LNv2 has two fee layers. The gateway's off-chain routing fee is taken on
        // the invoice amount, and the gateway forwards the remainder into the
        // on-federation incoming contract. Claiming that contract is a federation
        // transaction whose fee — the lightning input fee, the mint output fees,
        // and any sub-denomination dust — is quoted by a dry-run via
        // `receive_fee_quote`.
        if is_lnv2 {
            let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
            let routing_info = lnv2
                .routing_info(&gateway_url)
                .await?
                .ok_or(anyhow!("Gateway has no routing info"))?;
            // Both branches below consume this gateway-supplied fee. Reject a
            // 100%-or-more fee up front so neither has to cope with it: the
            // `include_fees` path cannot invert it, and the exact-invoice path
            // would otherwise quote a receive that credits the user nothing.
            validate_receive_fee(&routing_info.receive_fee)?;

            if include_fees {
                // Invert both layers so the sender covers everything and exactly
                // `requested` is credited.
                //
                // Federation layer: smallest contract amount that, after the
                // on-federation receive fee, credits at least `requested`.
                // `federation_fee_msats` is that fee quoted at the solved contract
                // amount, so the receiver nets `requested` from the federation.
                let (contract, federation_fee_msats) =
                    solve_gross_for_net(requested, |gross| lnv2.receive_fee_quote(gross)).await?;

                // Gateway layer: invert the off-chain routing fee so the gateway
                // funds the contract with at least `contract` msats. The gateway's
                // cut is the difference between the invoice and the contract it funds.
                let invoice_msats =
                    gross_invoice_for_contract(contract, &routing_info.receive_fee)?;
                return Ok(ReceiveAmount {
                    invoice_msats,
                    federation_fee_msats,
                    gateway_fee_msats: invoice_msats.saturating_sub(contract),
                });
            }

            // Exact invoice: the face value is `requested`. The gateway takes its
            // off-chain routing fee from the invoice and forwards the remainder
            // into the contract; claiming that contract costs the federation fee
            // quoted at the contract amount. Both fees come out of `requested`.
            let contract = routing_info.receive_fee.subtract_from(requested).msats;
            let gateway_fee_msats = requested.saturating_sub(contract);
            let federation_fee_msats = lnv2
                .receive_fee_quote(Amount::from_msats(contract))
                .await?
                .total()
                .get_bitcoin()
                .msats;
            return Ok(ReceiveAmount {
                invoice_msats: requested,
                federation_fee_msats,
                gateway_fee_msats,
            });
        }

        // LNv1 has no gateway or lightning routing fee, but claiming the incoming
        // contract still mints ecash, so the mint output fees (quoted the same way)
        // must be covered. There is no gateway layer.
        let ln = client.get_first_module::<LightningClientModule>()?;
        if include_fees {
            // The invoice equals the solved gross amount and the only fee is the
            // federation fee quoted at it, so the receiver nets `requested`.
            let (invoice_msats, federation_fee_msats) =
                solve_gross_for_net(requested, |gross| ln.receive_fee_quote(gross)).await?;
            return Ok(ReceiveAmount {
                invoice_msats,
                federation_fee_msats,
                gateway_fee_msats: 0,
            });
        }

        // Exact invoice: the face value is `requested` and the federation fee for
        // claiming the contract — quoted at that amount — is absorbed by the receiver.
        let federation_fee_msats = ln
            .receive_fee_quote(Amount::from_msats(requested))
            .await?
            .total()
            .get_bitcoin()
            .msats;
        Ok(ReceiveAmount {
            invoice_msats: requested,
            federation_fee_msats,
            gateway_fee_msats: 0,
        })
    }

    /// Computes the send fee breakdown for an `amount` paid through a gateway
    /// whose off-chain routing fee is `send_fee`. Returns `(gateway_fee,
    /// federation_fee, amount_with_fees)` in msats.
    ///
    /// `gateway_fee` is the routing fee the gateway bakes into the outgoing
    /// contract; `federation_fee` is the on-federation transaction fee (lightning
    /// output fee + mint fees on the funding notes and change + dust), quoted via
    /// the lightning module's `send_fee_quote` against the current note
    /// inventory. `amount_with_fees` is the total the sender pays.
    async fn compute_send_fees(
        client: &ClientHandleArc,
        amount: Amount,
        send_fee: PaymentFee,
        is_lnv2: bool,
    ) -> (u64, u64, u64) {
        let contract_amount = send_fee.add_to(amount.msats);
        let gateway_fee = contract_amount.msats.saturating_sub(amount.msats);
        let federation_fee = Self::send_federation_fee(client, is_lnv2, contract_amount).await;
        let amount_with_fees = contract_amount.msats.saturating_add(federation_fee);
        (gateway_fee, federation_fee, amount_with_fees)
    }

    /// Quotes the on-federation fee for funding an outgoing contract worth
    /// `contract_amount`. The quote is display-only (fedimint funds the real send
    /// itself), so a failure degrades to 0 rather than blocking the payment.
    async fn send_federation_fee(
        client: &ClientHandleArc,
        is_lnv2: bool,
        contract_amount: Amount,
    ) -> u64 {
        if is_lnv2 {
            if let Ok(lnv2) =
                client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()
            {
                if let Ok(quote) = lnv2.send_fee_quote(contract_amount).await {
                    return quote.total().get_bitcoin().msats;
                }
            }
        }
        if let Ok(ln) = client.get_first_module::<LightningClientModule>() {
            if let Ok(quote) = ln.send_fee_quote(contract_amount).await {
                return quote.total().get_bitcoin().msats;
            }
        }
        0
    }

    pub async fn compute_all_gateway_previews(
        &self,
        federation_id: &FederationId,
        amount: Amount,
        bolt11: &Bolt11Invoice,
    ) -> anyhow::Result<Vec<GatewayPaymentPreview>> {
        let gateways = self
            .list_gateways(None, Some(*federation_id), Duration::from_secs(5))
            .await?;

        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("No federation exists"))?
            .clone();

        let last_route_hint_hop = bolt11
            .route_hints()
            .first()
            .and_then(|rh| rh.0.last())
            .map(|hop| (hop.src_node_id.to_string(), hop.short_channel_id));
        let payee_pubkey = bolt11.get_payee_pub_key().to_string();

        // The federation fee is quoted per gateway (the contract amount, and thus
        // the mint funding fee, depends on the gateway's routing fee), so this is
        // an async loop rather than a map.
        let mut previews: Vec<GatewayPaymentPreview> = Vec::with_capacity(gateways.len());
        for gw in gateways {
            let send_fee = if gw.is_lnv2 {
                let is_loopback = gw.lightning_node.as_deref() == Some(payee_pubkey.as_str());
                let (send_base, send_ppm) = if is_loopback {
                    (
                        gw.min_base_routing_fee.unwrap_or(gw.base_routing_fee),
                        gw.min_ppm_routing_fee.unwrap_or(gw.ppm_routing_fee),
                    )
                } else {
                    (gw.base_routing_fee, gw.ppm_routing_fee)
                };
                PaymentFee {
                    base: Amount::from_msats(send_base),
                    parts_per_million: send_ppm,
                }
            } else {
                let routes_back = match (last_route_hint_hop.as_ref(), gw.federation_index) {
                    (Some((src, scid)), Some(fi)) => {
                        gw.lightning_node.as_deref() == Some(src.as_str()) && *scid == fi
                    }
                    _ => false,
                };
                let (send_base, send_ppm) = if routes_back {
                    (0, 0)
                } else {
                    (gw.base_routing_fee, gw.ppm_routing_fee)
                };
                PaymentFee {
                    base: Amount::from_msats(send_base),
                    parts_per_million: send_ppm,
                }
            };

            let (gateway_fee, federation_fee, amount_with_fees) =
                Self::compute_send_fees(&client, amount, send_fee, gw.is_lnv2).await;
            previews.push(GatewayPaymentPreview {
                gateway: gw,
                amount_with_fees,
                gateway_fee,
                federation_fee,
            });
        }

        // Sort: LNv2 first, then if its vetted, then by lowest fees
        previews.sort_by(|a, b| {
            b.gateway
                .is_lnv2
                .cmp(&a.gateway.is_lnv2)
                .then(b.gateway.is_vettted.cmp(&a.gateway.is_vettted))
                .then(a.amount_with_fees.cmp(&b.amount_with_fees))
        });

        Ok(previews)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn send(
        &self,
        federation_id: &FederationId,
        invoice: String,
        gateway: SafeUrl,
        is_lnv2: bool,
        amount_with_fees: u64,
        federation_fee_msats: u64,
        gateway_fee_msats: u64,
        ln_address: Option<String>,
    ) -> EcashAppResult<OperationId> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or_else(|| EcashAppError::other("federation does not exist"))?
            .clone();
        let invoice = Bolt11Invoice::from_str(&invoice)
            .map_err(|e| EcashAppError::InvalidInvoice(e.to_string()))?;
        if invoice.is_expired() {
            return Err(EcashAppError::ExpiredInvoice);
        }
        let custom_meta = json!({
            "amount_with_fees": amount_with_fees,
            "federation_fees": federation_fee_msats,
            "gateway_fees": gateway_fee_msats,
            "gateway_url": gateway,
            "ln_address": ln_address,
        });

        if is_lnv2 {
            info_to_flutter("Attempting to pay using LNv2...").await;
            if let Ok(lnv2_operation_id) = Self::pay_lnv2(
                &client,
                invoice.clone(),
                gateway.clone(),
                custom_meta.clone(),
            )
            .await
            {
                info_to_flutter("Successfully initated LNv2 payment").await;
                self.spawn_await_send(*federation_id, lnv2_operation_id);
                return Ok(lnv2_operation_id);
            }
        }

        info_to_flutter("Attempting to pay using LNv1...").await;
        let operation_id = Self::pay_lnv1(&client, invoice, gateway, custom_meta).await?;
        info_to_flutter("Successfully initiated LNv1 payment").await;
        self.spawn_await_send(*federation_id, operation_id);
        Ok(operation_id)
    }

    async fn pay_lnv2(
        client: &ClientHandleArc,
        invoice: Bolt11Invoice,
        gateway: SafeUrl,
        custom_meta: serde_json::Value,
    ) -> EcashAppResult<OperationId> {
        let lnv2 = client
            .get_first_module::<fedimint_lnv2_client::LightningClientModule>()
            .map_err(|e| EcashAppError::other(format!("LNv2 module unavailable: {e:#}")))?;
        let operation_id = lnv2
            .send(invoice, Some(gateway), custom_meta)
            .await
            .map_err(EcashAppError::from_display)?;
        Ok(operation_id)
    }

    async fn pay_lnv1(
        client: &ClientHandleArc,
        invoice: Bolt11Invoice,
        gateway_url: SafeUrl,
        custom_meta: serde_json::Value,
    ) -> EcashAppResult<OperationId> {
        let lnv1 = client
            .get_first_module::<LightningClientModule>()
            .map_err(|e| EcashAppError::other(format!("LNv1 module unavailable: {e:#}")))?;
        let gateways = lnv1.list_gateways().await;
        let gateway = gateways
            .iter()
            .find(|g| g.info.api == gateway_url)
            .ok_or(EcashAppError::GatewayOffline)?
            .info
            .clone();
        let outgoing_lightning_payment = lnv1
            .pay_bolt11_invoice(Some(gateway), invoice, custom_meta)
            .await
            .map_err(EcashAppError::from_display)?;
        Ok(outgoing_lightning_payment.payment_type.operation_id())
    }

    fn spawn_await_send(&self, federation_id: FederationId, operation_id: OperationId) {
        let self_copy = self.clone();
        self.task_group.spawn_cancellable("await send", async move {
            let final_state = self_copy.await_send(&federation_id, operation_id).await;
            match final_state {
                // The preimage is deliberately not bound: it is the
                // cryptographic proof of this payment and used to be written to
                // the log. It remains available in the transaction details.
                LightningSendOutcome::Success(_) => {
                    let multimint_event =
                        MultimintEvent::Lightning((federation_id, LightningEventKind::PaymentSent));
                    get_event_bus().publish(multimint_event).await;
                    info_to_flutter("Successfully sent payment").await;
                }
                LightningSendOutcome::Failure(err) => {
                    payment_error_to_flutter(federation_id, err).await;
                }
            }
        });
    }

    /// Drives an on-chain send (peg-out) operation to completion. Used on
    /// startup to finish a withdraw that was in flight when the app last closed;
    /// works for both walletv1 and walletv2 (see [`Self::await_withdraw`]).
    fn spawn_await_withdraw(&self, federation_id: FederationId, operation_id: OperationId) {
        let self_copy = self.clone();
        self.task_group
            .spawn_cancellable("await withdraw", async move {
                match self_copy.await_withdraw(&federation_id, operation_id).await {
                    Ok(txid) => {
                        info_to_flutter(format!("On-chain send completed: {txid}")).await;
                    }
                    Err(e) => {
                        // await_withdraw already surfaces genuine failures via a
                        // toast; this only records the outcome (or a no-op error from
                        // driving an operation that isn't a send).
                        info_to_flutter(format!("await_withdraw({operation_id:?}) ended: {e}"))
                            .await;
                    }
                }
            });
    }

    pub async fn await_send(
        &self,
        federation_id: &FederationId,
        operation_id: OperationId,
    ) -> LightningSendOutcome {
        // Left mid-payment: report a failure to whoever is awaiting rather than
        // panicking their task. The payment's real outcome is settled by the
        // federation regardless of whether this client is still around to watch.
        let Some(client) = self.clients.read().await.get(federation_id).cloned() else {
            return LightningSendOutcome::Failure(EcashAppError::other(
                "Federation was left while the payment was in flight",
            ));
        };

        let send_state = match Self::await_send_lnv2(&client, operation_id).await {
            Ok(lnv2_final_state) => lnv2_final_state,
            Err(_) => Self::await_send_lnv1(&client, operation_id).await,
        };
        send_state
    }

    async fn await_send_lnv2(
        client: &ClientHandleArc,
        operation_id: OperationId,
    ) -> anyhow::Result<LightningSendOutcome> {
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let mut updates = lnv2
            .subscribe_send_operation_state_updates(operation_id)
            .await?
            .into_stream();
        let mut final_state =
            LightningSendOutcome::Failure(EcashAppError::other("LNv2 send: no final state"));
        while let Some(update) = updates.next().await {
            match update {
                SendOperationState::Success(preimage) => {
                    final_state = LightningSendOutcome::Success(preimage.consensus_encode_to_hex());
                }
                SendOperationState::Refunded => {
                    final_state = LightningSendOutcome::Failure(EcashAppError::PaymentRefunded(
                        "LNv2".to_string(),
                    ));
                }
                SendOperationState::Failure => {
                    final_state = LightningSendOutcome::Failure(EcashAppError::other(
                        "LNv2 payment unrecoverable failure",
                    ));
                }
                _ => {}
            }
        }
        Ok(final_state)
    }

    async fn await_send_lnv1(
        client: &ClientHandleArc,
        operation_id: OperationId,
    ) -> LightningSendOutcome {
        let lnv1 = client
            .get_first_module::<LightningClientModule>()
            .expect("LNv1 module not available");
        // First check if its an internal payment
        let mut final_state = None;
        if let Ok(updates) = lnv1.subscribe_internal_pay(operation_id).await {
            let mut stream = updates.into_stream();
            while let Some(update) = stream.next().await {
                match update {
                    InternalPayState::Preimage(preimage) => {
                        final_state = Some(LightningSendOutcome::Success(
                            preimage.0.consensus_encode_to_hex(),
                        ));
                    }
                    InternalPayState::RefundSuccess {
                        out_points: _,
                        error,
                    } => {
                        final_state = Some(LightningSendOutcome::Failure(
                            EcashAppError::PaymentRefunded(format!("{error:?}")),
                        ));
                    }
                    InternalPayState::FundingFailed { error } => {
                        final_state = Some(LightningSendOutcome::Failure(EcashAppError::other(
                            format!("LNv1 internal payment funding failed: {error}"),
                        )));
                    }
                    InternalPayState::RefundError {
                        error_message,
                        error,
                    } => {
                        final_state = Some(LightningSendOutcome::Failure(EcashAppError::other(
                            format!("LNv1 internal refund error: {error_message} ({error:?})"),
                        )));
                    }
                    InternalPayState::UnexpectedError(error) => {
                        final_state = Some(LightningSendOutcome::Failure(EcashAppError::other(
                            format!("LNv1 internal payment unexpected error: {error}"),
                        )));
                    }
                    _ => {}
                }
            }
        }

        if let Some(internal_final_state) = final_state {
            return internal_final_state;
        }

        // If internal fails, check if its an external payment
        if let Ok(updates) = lnv1.subscribe_ln_pay(operation_id).await {
            let mut stream = updates.into_stream();
            while let Some(update) = stream.next().await {
                match update {
                    LnPayState::Success { preimage } => {
                        final_state = Some(LightningSendOutcome::Success(preimage));
                    }
                    LnPayState::Refunded { gateway_error } => {
                        final_state = Some(LightningSendOutcome::Failure(
                            EcashAppError::PaymentRefunded(format!("{gateway_error:?}")),
                        ));
                    }
                    LnPayState::UnexpectedError { error_message } => {
                        final_state = Some(LightningSendOutcome::Failure(classify_anyhow(
                            &anyhow!("{error_message}"),
                        )));
                    }
                    _ => {}
                }
            }
        }

        if let Some(external_final_state) = final_state {
            return external_final_state;
        }

        LightningSendOutcome::Failure(EcashAppError::other("LNv1 send: no final state"))
    }

    pub async fn await_receive(
        &self,
        federation_id: &FederationId,
        operation_id: OperationId,
    ) -> anyhow::Result<(FinalReceiveOperationState, u64)> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .cloned()
            .ok_or(anyhow!("No federation exists"))?;
        let (receive_state, amount) = match Self::await_receive_lnv2(&client, operation_id).await {
            Ok(lnv2_final_state) => lnv2_final_state,
            Err(_) => Self::await_receive_lnv1(&client, operation_id).await?,
        };

        Ok((receive_state, amount))
    }

    async fn await_receive_lnv2(
        client: &ClientHandleArc,
        operation_id: OperationId,
    ) -> anyhow::Result<(FinalReceiveOperationState, u64)> {
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let mut updates = lnv2
            .subscribe_receive_operation_state_updates(operation_id)
            .await?
            .into_stream();
        let mut final_state = FinalReceiveOperationState::Failure;
        while let Some(update) = updates.next().await {
            match update {
                ReceiveOperationState::Claimed => {
                    final_state = FinalReceiveOperationState::Claimed;
                }
                ReceiveOperationState::Expired => {
                    final_state = FinalReceiveOperationState::Expired;
                }
                ReceiveOperationState::Failure => {
                    final_state = FinalReceiveOperationState::Failure;
                }
                _ => {}
            }
        }

        let operation = client.operation_log().get_operation(operation_id).await;
        let amount = Self::get_lnv2_amount_from_meta(operation);
        Ok((final_state, amount))
    }

    fn get_lnv2_amount_from_meta(op_log_val: Option<OperationLogEntry>) -> u64 {
        let Some(op_log_val) = op_log_val else {
            return 0;
        };
        let meta = op_log_val.meta::<LightningOperationMeta>();
        match meta {
            // Runs inside the spawned `await_receive` task, which re-drives old
            // operations after an upgrade — so `amount` may predate this build.
            // Fall back to the same zero this function returns for an unknown
            // operation instead of panicking a background task.
            LightningOperationMeta::Receive(receive) => {
                read_meta_msats(&receive.custom_meta, "amount").unwrap_or(0)
            }
            LightningOperationMeta::Send(send) => send.contract.amount.msats,
            LightningOperationMeta::LnurlReceive(receive) => {
                receive.contract.commitment.amount.msats
            }
        }
    }

    async fn await_receive_lnv1(
        client: &ClientHandleArc,
        operation_id: OperationId,
    ) -> anyhow::Result<(FinalReceiveOperationState, u64)> {
        let lnv1 = client.get_first_module::<LightningClientModule>()?;
        let mut updates = lnv1.subscribe_ln_receive(operation_id).await?.into_stream();
        let mut final_state = FinalReceiveOperationState::Failure;
        while let Some(update) = updates.next().await {
            if let LnReceiveState::Claimed = update {
                final_state = FinalReceiveOperationState::Claimed;
            }
        }

        let operation = client.operation_log().get_operation(operation_id).await;
        let amount = Self::get_lnv1_amount_from_meta(operation);
        Ok((final_state, amount))
    }

    async fn spawn_await_recurringd_receive(
        &self,
        client: ClientHandleArc,
        operation_id: OperationId,
        federation_id: FederationId,
    ) {
        self.task_group
            .spawn_cancellable("recurringd invoice", async move {
                info_to_flutter(format!(
                    "Checking invoice with operation id: {operation_id:?}"
                ))
                .await;
                if let Ok(lnv1) = client.get_first_module::<LightningClientModule>() {
                    if let Ok(updates) = lnv1.subscribe_ln_recurring_receive(operation_id).await {
                        let mut stream = updates.into_stream();
                        let mut final_state = FinalReceiveOperationState::Failure;
                        let operation = client
                            .operation_log()
                            .get_operation(operation_id)
                            .await
                            .expect("operation must exist");
                        while let Some(update) = stream.next().await {
                            if update == LnReceiveState::Claimed {
                                final_state = FinalReceiveOperationState::Claimed;
                                if let LightningOperationMetaVariant::RecurringPaymentReceive(
                                    meta,
                                ) = operation
                                    .meta::<fedimint_ln_client::LightningOperationMeta>()
                                    .variant
                                {
                                    // The payment landed either way; report zero
                                    // rather than panicking this spawned task if
                                    // the invoice carried no amount.
                                    let amount_msats =
                                        meta.invoice.amount_milli_satoshis().unwrap_or(0);
                                    let lightning_event =
                                        LightningEventKind::InvoicePaid(InvoicePaidEvent {
                                            amount_msats,
                                        });
                                    info_to_flutter(format!(
                                        "Recurringd receive completed: {final_state:?}"
                                    ))
                                    .await;
                                    let multimint_event =
                                        MultimintEvent::Lightning((federation_id, lightning_event));
                                    get_event_bus().publish(multimint_event).await;
                                }
                            }
                        }
                        info_to_flutter(format!(
                            "Final state of recurringd receive: {final_state:?}"
                        ))
                        .await;
                    }
                }
            });

        let mut recurringd_invoices = self.recurringd_invoices.write().await;
        recurringd_invoices.insert(operation_id);
    }

    fn get_lnv1_amount_from_meta(op_log_val: Option<OperationLogEntry>) -> u64 {
        let Some(op_log_val) = op_log_val else {
            return 0;
        };

        let meta = op_log_val.meta::<fedimint_ln_client::LightningOperationMeta>();
        // An amountless invoice carries no amount to report, so it falls back to
        // the same zero this function already returns for an unknown operation.
        // Panicking here would take down every caller for one odd entry.
        match meta.variant {
            LightningOperationMetaVariant::Pay(send) => {
                send.invoice.amount_milli_satoshis().unwrap_or(0)
            }
            LightningOperationMetaVariant::Receive { invoice, .. } => {
                invoice.amount_milli_satoshis().unwrap_or(0)
            }
            LightningOperationMetaVariant::RecurringPaymentReceive(recurring) => {
                recurring.invoice.amount_milli_satoshis().unwrap_or(0)
            }
            // Claim is covered by send
            _ => 0,
        }
    }

    async fn lnv1_update_gateway_cache(&self, client: &ClientHandleArc) {
        let lnv1_client = client.clone();
        self.task_group
            .spawn_cancellable("update gateway cache", async move {
                // LNv2-only federations have no LNv1 (`ln`) module, so there is
                // no LNv1 gateway cache to maintain — skip instead of panicking.
                let Ok(lnv1) = lnv1_client.get_first_module::<LightningClientModule>() else {
                    info_to_flutter(
                        "Skipping LNv1 gateway cache update; federation has no LNv1 module",
                    )
                    .await;
                    return;
                };
                match lnv1.update_gateway_cache().await {
                    Ok(_) => info_to_flutter("Updated gateway cache").await,
                    Err(e) => info_to_flutter(format!("Could not update gateway cache {e}")).await,
                }

                lnv1.update_gateway_cache_continuously(|gateway| async { gateway })
                    .await
            });
    }

    /// Report an operation the history renderer cannot read and move on.
    ///
    /// The `custom_meta` keys these rows depend on have changed across app
    /// versions, so an operation written by an older build, restored into a
    /// recovered wallet, or left behind by an interrupted write can be missing
    /// any of them. Skipping costs one row; the `.expect()`s this replaces took
    /// down the entire history screen for that federation, permanently.
    async fn skip_unrenderable(operation_id: OperationId, reason: &str) {
        error_to_flutter(format!(
            "Skipping unreadable transaction {operation_id:?}: {reason}"
        ))
        .await;
    }

    pub async fn transactions(
        &self,
        federation_id: &FederationId,
        timestamp: Option<u64>,
        operation_id: Option<Vec<u8>>,
        modules: Vec<String>,
    ) -> Vec<Transaction> {
        // A federation that is gone has no history to render. Callers poll this
        // from screens that can outlive the client by a frame or two.
        let Some(client) = self.clients.read().await.get(federation_id).cloned() else {
            return Vec::new();
        };

        // There is one Lightning Address per federation, so any recurring/LNURL
        // receive on this federation was received via it. Looked up once here
        // and reused for every recurring receive built below.
        let ln_address = self
            .get_ln_address_config(federation_id)
            .await
            .map(|config| format!("{}@{}", config.username, config.domain));

        let mut collected = Vec::new();
        let mut next_key = timestamp.map(|timestamp| ChronologicalOperationLogKey {
            creation_time: UNIX_EPOCH + Duration::from_millis(timestamp),
            operation_id: OperationId(
                operation_id
                    .expect("Invalid operation")
                    .try_into()
                    .expect("Invalid operation"),
            ),
        });

        while collected.len() < 10 {
            let page = client
                .operation_log()
                .paginate_operations_rev(50, next_key)
                .await;

            if page.is_empty() {
                break;
            }

            for (key, op_log_val) in &page {
                if collected.len() >= 10 {
                    break;
                }

                if !modules.contains(&op_log_val.operation_module_kind().to_string()) {
                    continue;
                }

                let timestamp = key
                    .creation_time
                    .duration_since(UNIX_EPOCH)
                    .expect("Cannot be before unix epoch")
                    .as_millis() as u64;

                let tx = match op_log_val.operation_module_kind() {
                    "lnv2" => {
                        let meta = op_log_val.meta::<LightningOperationMeta>();
                        match meta {
                            LightningOperationMeta::Receive(receive) => {
                                let outcome = op_log_val.outcome::<ReceiveOperationState>();
                                let fedimint_lnv2_common::LightningInvoice::Bolt11(bolt11) =
                                    receive.invoice;
                                if let Some(ReceiveOperationState::Claimed) = outcome {
                                    let Some(amount) =
                                        read_meta_msats(&receive.custom_meta, "amount")
                                    else {
                                        Self::skip_unrenderable(
                                            key.operation_id,
                                            "lnv2 receive has no readable 'amount'",
                                        )
                                        .await;
                                        continue;
                                    };
                                    let Some(amount_with_fees) =
                                        read_meta_msats(&receive.custom_meta, "amount_with_fees")
                                    else {
                                        Self::skip_unrenderable(
                                            key.operation_id,
                                            "lnv2 receive has no readable 'amount_with_fees'",
                                        )
                                        .await;
                                        continue;
                                    };
                                    // Per-source fees stored at invoice creation.
                                    // Fall back through the earlier combined `fees`
                                    // key, then the invoice-minus-requested
                                    // estimate, for transactions that predate them.
                                    let federation_fees =
                                        read_meta_msats(&receive.custom_meta, "federation_fees")
                                            .or_else(|| {
                                                read_meta_msats(&receive.custom_meta, "fees")
                                            })
                                            .unwrap_or(amount_with_fees - amount);
                                    let gateway_fees =
                                        read_meta_msats(&receive.custom_meta, "gateway_fees")
                                            .unwrap_or(0);
                                    Some(Transaction {
                                        kind: TransactionKind::LightningReceive {
                                            federation_fees,
                                            gateway_fees,
                                            invoice_amount: amount_with_fees,
                                            gateway: receive.gateway.to_string(),
                                            payee_pubkey: bolt11.get_payee_pub_key().to_string(),
                                            payment_hash: bolt11.payment_hash().to_string(),
                                        },
                                        amount,
                                        timestamp,
                                        operation_id: key.operation_id.0.to_vec(),
                                    })
                                } else {
                                    None
                                }
                            }
                            LightningOperationMeta::Send(send) => {
                                let outcome = op_log_val.outcome::<SendOperationState>();
                                let fedimint_lnv2_common::LightningInvoice::Bolt11(bolt11) =
                                    send.invoice;
                                match outcome {
                                    Some(SendOperationState::Success(preimage)) => {
                                        let Some(amount_with_fees) =
                                            read_meta_u64(&send.custom_meta, "amount_with_fees")
                                        else {
                                            Self::skip_unrenderable(
                                                key.operation_id,
                                                "lnv2 send has no readable 'amount_with_fees'",
                                            )
                                            .await;
                                            continue;
                                        };

                                        let ln_address = send
                                            .custom_meta
                                            .get("ln_address")
                                            .and_then(|v| from_value::<String>(v.clone()).ok());

                                        // Per-source fees stored at send time; older
                                        // transactions predate them, so fall back to
                                        // attributing the whole fee to the gateway.
                                        let combined =
                                            amount_with_fees - send.contract.amount.msats;
                                        let federation_fees =
                                            read_meta_u64(&send.custom_meta, "federation_fees")
                                                .unwrap_or(0);
                                        let gateway_fees =
                                            read_meta_u64(&send.custom_meta, "gateway_fees")
                                                .unwrap_or(combined);

                                        Some(Transaction {
                                            kind: TransactionKind::LightningSend {
                                                federation_fees,
                                                gateway_fees,
                                                gateway: send.gateway.to_string(),
                                                invoice: bolt11.to_string(),
                                                payment_hash: bolt11.payment_hash().to_string(),
                                                preimage: preimage.consensus_encode_to_hex(),
                                                ln_address,
                                            },
                                            amount: send.contract.amount.msats,
                                            timestamp,
                                            operation_id: key.operation_id.0.to_vec(),
                                        })
                                    }
                                    _ => None,
                                }
                            }
                            LightningOperationMeta::LnurlReceive(receive) => {
                                let outcome = op_log_val.outcome::<ReceiveOperationState>();
                                match outcome {
                                    Some(ReceiveOperationState::Claimed) => {
                                        // The federation fee for claiming the incoming
                                        // contract is the operation's input/output
                                        // difference; `None` predates fee tracking. The
                                        // gateway's cut was taken before the contract, so
                                        // it isn't part of this.
                                        let federation_fees = client
                                            .get_operation_fees(key.operation_id)
                                            .await
                                            .ok()
                                            .flatten()
                                            .map(|fees| fees.get_bitcoin().msats);
                                        // LNURL incoming contracts fee-encode the gateway's
                                        // routing fee into the expiration field as
                                        // `u64::MAX - fee` (the client never sees the
                                        // invoice). Contracts created before that encoding
                                        // existed hold a real unix timestamp, which would
                                        // decode to an absurd fee, so only decode values
                                        // far too large to be a timestamp.
                                        let expiration_or_fee =
                                            receive.contract.commitment.expiration_or_fee;
                                        let gateway_fees = (expiration_or_fee > u64::MAX / 2)
                                            .then(|| fee_from_expiration(expiration_or_fee));
                                        // Headline is the net amount credited: the
                                        // contract the gateway funded, minus the
                                        // federation claim fee.
                                        let amount = receive
                                            .contract
                                            .commitment
                                            .amount
                                            .msats
                                            .saturating_sub(federation_fees.unwrap_or(0));
                                        Some(Transaction {
                                            kind: TransactionKind::LightningRecurring {
                                                ln_address: ln_address.clone(),
                                                federation_fees,
                                                gateway_fees,
                                            },
                                            amount,
                                            timestamp,
                                            operation_id: key.operation_id.0.to_vec(),
                                        })
                                    }
                                    _ => None,
                                }
                            }
                        }
                    }
                    "ln" => {
                        let meta = op_log_val.meta::<fedimint_ln_client::LightningOperationMeta>();
                        match meta.variant {
                            LightningOperationMetaVariant::Pay(send) => Self::get_lnv1_send_tx(
                                send,
                                op_log_val,
                                timestamp,
                                key.operation_id,
                                meta.extra_meta,
                            ),
                            LightningOperationMetaVariant::Receive { invoice, .. } => {
                                Self::get_lnv1_receive_tx(
                                    &invoice,
                                    op_log_val,
                                    timestamp,
                                    key.operation_id,
                                    meta.extra_meta,
                                )
                            }
                            LightningOperationMetaVariant::RecurringPaymentReceive(recurring) => {
                                let receive_outcome = op_log_val.outcome::<LnReceiveState>();
                                match receive_outcome {
                                    Some(LnReceiveState::Claimed) => {
                                        let Some(invoice_msat) =
                                            recurring.invoice.amount_milli_satoshis()
                                        else {
                                            Self::skip_unrenderable(
                                                key.operation_id,
                                                "recurring receive invoice has no amount",
                                            )
                                            .await;
                                            continue;
                                        };
                                        // The federation fee for claiming the contract is
                                        // the operation's input/output difference; `None`
                                        // predates fee tracking. LNv1 has no gateway fee,
                                        // so this is the entire receive cost.
                                        let federation_fees = client
                                            .get_operation_fees(key.operation_id)
                                            .await
                                            .ok()
                                            .flatten()
                                            .map(|fees| fees.get_bitcoin().msats);
                                        // Headline is the net credited: invoice face value
                                        // minus the federation claim fee.
                                        let amount = invoice_msat
                                            .saturating_sub(federation_fees.unwrap_or(0));
                                        Some(Transaction {
                                            kind: TransactionKind::LightningRecurring {
                                                ln_address: ln_address.clone(),
                                                federation_fees,
                                                // LNv1 has no gateway/routing fee layer.
                                                gateway_fees: Some(0),
                                            },
                                            amount,
                                            timestamp,
                                            operation_id: key.operation_id.0.to_vec(),
                                        })
                                    }
                                    _ => None,
                                }
                            }
                            _ => None,
                        }
                    }
                    "mint" => {
                        let meta = op_log_val.meta::<MintOperationMeta>();
                        match meta.variant {
                            MintOperationMetaVariant::SpendOOB { oob_notes, .. } => {
                                let internal_spends = self.internal_ecash_spends.read().await;
                                if internal_spends.contains(&key.operation_id) {
                                    continue;
                                }
                                // The send fee was stashed in extra_meta at send
                                // time (see `send_ecash`); older transactions
                                // predate it, so default to 0.
                                let fees = meta
                                    .extra_meta
                                    .get("fee_msats")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(0);
                                Some(Transaction {
                                    kind: TransactionKind::EcashSend {
                                        oob_notes: oob_notes.to_string(),
                                        fees,
                                    },
                                    amount: oob_notes.total_amount().msats,
                                    timestamp,
                                    operation_id: key.operation_id.0.to_vec(),
                                })
                            }
                            MintOperationMetaVariant::Reissuance { .. } => {
                                let extra_meta = meta.extra_meta.clone();
                                if let Ok(operation_id) =
                                    serde_json::from_value::<OperationId>(extra_meta)
                                {
                                    let mut internal_spends =
                                        self.internal_ecash_spends.write().await;
                                    internal_spends.insert(operation_id);
                                    continue;
                                }

                                let outcome = op_log_val.outcome::<ReissueExternalNotesState>();
                                if let Some(ReissueExternalNotesState::Done) = outcome {
                                    let Some(amount) =
                                        read_meta_msats(&meta.extra_meta, "total_amount")
                                    else {
                                        Self::skip_unrenderable(
                                            key.operation_id,
                                            "ecash receive has no readable 'total_amount'",
                                        )
                                        .await;
                                        continue;
                                    };
                                    let Some(ecash) = read_meta_string(&meta.extra_meta, "ecash")
                                    else {
                                        Self::skip_unrenderable(
                                            key.operation_id,
                                            "ecash receive has no readable 'ecash'",
                                        )
                                        .await;
                                        continue;
                                    };
                                    // Fee breakdown is optional: absent for
                                    // reissues predating fee tracking, and a
                                    // non-numeric value is treated the same as
                                    // absent rather than panicking.
                                    let input_fees =
                                        meta.extra_meta.get("input_fee").and_then(|f| f.as_u64());
                                    let output_fees =
                                        meta.extra_meta.get("output_fee").and_then(|f| f.as_u64());
                                    let dust = meta.extra_meta.get("dust").and_then(|f| f.as_u64());
                                    Some(Transaction {
                                        kind: TransactionKind::EcashReceive {
                                            oob_notes: ecash,
                                            input_fees,
                                            output_fees,
                                            dust,
                                        },
                                        amount,
                                        timestamp,
                                        operation_id: key.operation_id.0.to_vec(),
                                    })
                                } else {
                                    None
                                }
                            }
                        }
                    }
                    "mintv2" => {
                        match op_log_val.meta::<MintV2OperationMeta>() {
                            MintV2OperationMeta::Receive {
                                ecash, custom_meta, ..
                            } => {
                                let outcome =
                                    op_log_val.outcome::<MintV2FinalReceiveOperationState>();
                                if let Some(MintV2FinalReceiveOperationState::Success) = outcome {
                                    // The fee breakdown and amount were stashed in
                                    // custom_meta at receive time (see
                                    // reissue_ecash); fall back to decoding the
                                    // ecash string for the amount.
                                    let amount = custom_meta
                                        .get("total_amount")
                                        .and_then(|v| v.as_u64())
                                        .or_else(|| {
                                            decode_prefixed::<ECash>(FEDIMINT_PREFIX, &ecash)
                                                .ok()
                                                .map(|e| e.amount().msats)
                                        })
                                        .unwrap_or(0);
                                    let input_fees =
                                        custom_meta.get("input_fee").and_then(|v| v.as_u64());
                                    let output_fees =
                                        custom_meta.get("output_fee").and_then(|v| v.as_u64());
                                    let dust = custom_meta.get("dust").and_then(|v| v.as_u64());
                                    Some(Transaction {
                                        kind: TransactionKind::EcashReceive {
                                            oob_notes: ecash,
                                            input_fees,
                                            output_fees,
                                            dust,
                                        },
                                        amount,
                                        timestamp,
                                        operation_id: key.operation_id.0.to_vec(),
                                    })
                                } else {
                                    None
                                }
                            }
                            MintV2OperationMeta::Send {
                                ecash, custom_meta, ..
                            } => {
                                // The amount isn't stored in the meta; recover it
                                // from the ecash string.
                                let amount = decode_prefixed::<ECash>(FEDIMINT_PREFIX, &ecash)
                                    .map(|e| e.amount().msats)
                                    .unwrap_or(0);
                                // The send fee — incurred by the internal reissue
                                // that mints the right denominations (the
                                // filtered-out op below) — was stashed in
                                // custom_meta at send time (see `send_ecash`).
                                // Older transactions predate it, so default to 0.
                                let fees = custom_meta
                                    .get("fee_msats")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(0);
                                Some(Transaction {
                                    kind: TransactionKind::EcashSend {
                                        oob_notes: ecash,
                                        fees,
                                    },
                                    amount,
                                    timestamp,
                                    operation_id: key.operation_id.0.to_vec(),
                                })
                            }
                            // Internal reissues (minting the right denominations
                            // so a send can be made) are not user-facing.
                            MintV2OperationMeta::Reissue { .. } => None,
                        }
                    }
                    "wallet" => {
                        let meta = op_log_val.meta::<WalletOperationMeta>();
                        match meta.variant {
                            WalletOperationMetaVariant::Deposit { address, .. } => {
                                let outcome = op_log_val.outcome::<DepositStateV2>();
                                if let Some(DepositStateV2::Claimed {
                                    btc_deposited,
                                    btc_out_point,
                                }) = outcome
                                {
                                    let amount = Amount::from_sats(btc_deposited.to_sat()).msats;
                                    let address = address.assume_checked().to_string();
                                    let txid = btc_out_point.txid.to_string();

                                    // The actual federation fee is the difference
                                    // between the transaction inputs and outputs;
                                    // `None` for deposits predating fee tracking.
                                    let federation_fee_msats = client
                                        .get_operation_fees(key.operation_id)
                                        .await
                                        .ok()
                                        .flatten()
                                        .map(|fees| fees.get_bitcoin().msats);

                                    Some(Transaction {
                                        kind: TransactionKind::OnchainReceive {
                                            address,
                                            txid,
                                            federation_fee_msats,
                                            // walletv1 has no separate on-chain
                                            // claim fee; the federation fee is the
                                            // whole receive fee.
                                            onchain_claim_fee_msats: None,
                                        },
                                        amount,
                                        timestamp,
                                        operation_id: key.operation_id.0.to_vec(),
                                    })
                                } else {
                                    None
                                }
                            }
                            WalletOperationMetaVariant::Withdraw {
                                amount, address, ..
                            } => {
                                let outcome = op_log_val.outcome::<WithdrawState>();
                                if let Some(WithdrawState::Succeeded(txid)) = outcome {
                                    let address = address.assume_checked().to_string();

                                    let meta = op_log_val.meta::<WalletOperationMeta>();
                                    // meta was introduced after users began testing pre-releases of the
                                    // app and won't exist for recovered clients, so these need to be optional
                                    let meta = serde_json::from_value::<OnChainWithdrawalMeta>(
                                        meta.extra_meta,
                                    )
                                    .ok();

                                    Some(Transaction {
                                        kind: TransactionKind::OnchainSend {
                                            address,
                                            txid: txid.to_string(),
                                            fee_rate_sats_per_vb: meta
                                                .as_ref()
                                                .map(|m| m.fee_rate_sats_per_vb),
                                            tx_size_vb: meta.as_ref().map(|m| m.tx_size_vb),
                                            fee_sats: meta.as_ref().map(|m| m.fee_sats),
                                            total_sats: meta
                                                .as_ref()
                                                .map(|m| m.fee_sats + amount.to_sat()),
                                            federation_fee_msats: meta
                                                .as_ref()
                                                .map(|m| m.federation_fee_msats),
                                        },
                                        amount: Amount::from_sats(amount.to_sat()).msats,
                                        timestamp,
                                        operation_id: key.operation_id.0.to_vec(),
                                    })
                                } else {
                                    None
                                }
                            }
                            WalletOperationMetaVariant::RbfWithdraw { .. } => {
                                // RbfWithdrawal isn't supported
                                None
                            }
                        }
                    }
                    "walletv2" => {
                        let meta = op_log_val.meta::<WalletV2OperationMeta>();
                        match meta {
                            WalletV2OperationMeta::Receive(receive) => {
                                // The operation's outcome is persisted once the
                                // claim finalizes (driven by the deposit event
                                // listener), so only successful deposits surface.
                                let outcome =
                                    op_log_val.outcome::<WalletV2FinalReceiveOperationState>();
                                if let Some(WalletV2FinalReceiveOperationState::Success) = outcome {
                                    let amount = Amount::from_sats(receive.value.to_sat()).msats;
                                    let address = receive
                                        .address
                                        .map(|a| a.assume_checked().to_string())
                                        .unwrap_or_default();
                                    let txid = receive
                                        .outpoint
                                        .map(|o| o.txid.to_string())
                                        .unwrap_or_default();

                                    // The actual federation fee is the difference
                                    // between the transaction inputs and outputs;
                                    // `None` for deposits predating fee tracking.
                                    let federation_fee_msats = client
                                        .get_operation_fees(key.operation_id)
                                        .await
                                        .ok()
                                        .flatten()
                                        .map(|fees| fees.get_bitcoin().msats);

                                    // The on-chain claim/sweep fee is deducted from
                                    // the deposit before it enters the fedimint tx,
                                    // so it isn't part of `get_operation_fees`. The
                                    // actual fee paid at claim time is recorded in
                                    // the receive meta.
                                    let onchain_claim_fee_msats =
                                        Some(Amount::from_sats(receive.fee.to_sat()).msats);

                                    Some(Transaction {
                                        kind: TransactionKind::OnchainReceive {
                                            address,
                                            txid,
                                            federation_fee_msats,
                                            onchain_claim_fee_msats,
                                        },
                                        amount,
                                        timestamp,
                                        operation_id: key.operation_id.0.to_vec(),
                                    })
                                } else {
                                    None
                                }
                            }
                            WalletV2OperationMeta::Send(send) => {
                                let outcome =
                                    op_log_val.outcome::<WalletV2FinalSendOperationState>();
                                if let Some(WalletV2FinalSendOperationState::Success(txid)) =
                                    outcome
                                {
                                    let amount = Amount::from_sats(send.value.to_sat()).msats;
                                    let address = send.address.assume_checked().to_string();
                                    let fee_sats = send.fee.to_sat();

                                    // walletv2 SendMeta stores only the flat fee, but the
                                    // tx is always 1-in/1-out, so we recover the feerate and
                                    // size from the per-federation config.
                                    let tx_size_vb =
                                        WalletHandler::walletv2_send_tx_vbytes(&client).await.ok();
                                    let fee_rate_sats_per_vb = tx_size_vb.and_then(|vb| {
                                        (vb > 0).then(|| fee_sats as f64 / f64::from(vb))
                                    });
                                    // Federation fee stored in custom_meta at send
                                    // time (older sends predate it).
                                    let federation_fee_msats =
                                        read_meta_u64(&send.custom_meta, "federation_fees");

                                    Some(Transaction {
                                        kind: TransactionKind::OnchainSend {
                                            address,
                                            txid: txid.to_string(),
                                            fee_rate_sats_per_vb,
                                            tx_size_vb,
                                            fee_sats: Some(fee_sats),
                                            total_sats: Some(send.value.to_sat() + fee_sats),
                                            federation_fee_msats,
                                        },
                                        amount,
                                        timestamp,
                                        operation_id: key.operation_id.0.to_vec(),
                                    })
                                } else {
                                    None
                                }
                            }
                        }
                    }
                    _ => None,
                };

                if let Some(tx) = tx {
                    collected.push(tx);
                }
            }

            // Update the pagination key to the last item in this page
            next_key = page.last().map(|(key, _)| *key);
        }

        collected
    }

    /// LNv1 has two different operation send types: external (over the Lightning network) and internal (ecash swap)
    /// In order to check if the "send" was successful or not, we need to check both outcomes.
    fn get_lnv1_send_tx(
        meta: LightningOperationMetaPay,
        ln_outcome: &OperationLogEntry,
        timestamp: u64,
        operation_id: OperationId,
        custom_meta: serde_json::Value,
    ) -> Option<Transaction> {
        // These keys have changed across app versions, so an operation written by
        // an older build — or a recovered wallet, or an interrupted write — can be
        // missing any of them. Returning `None` drops just this row from the
        // history; the panic it replaces took the whole screen down permanently.
        let amount = meta.invoice.amount_milli_satoshis()?;
        let amount_with_fees = read_meta_u64(&custom_meta, "amount_with_fees")?;
        let gateway = read_meta_url(&custom_meta, "gateway_url")?;

        let ln_address = read_meta_string(&custom_meta, "ln_address");

        // Per-source fees stored at send time; older transactions predate them,
        // so fall back to attributing the whole fee to the gateway.
        let combined = amount_with_fees.saturating_sub(amount);
        let federation_fees = read_meta_u64(&custom_meta, "federation_fees").unwrap_or(0);
        let gateway_fees = read_meta_u64(&custom_meta, "gateway_fees").unwrap_or(combined);

        let operation_id = operation_id.0.to_vec();

        // First check if the send was an internal payment
        if meta.is_internal_payment {
            let internal_outcome = ln_outcome.outcome::<InternalPayState>();
            match internal_outcome {
                Some(InternalPayState::Preimage(preimage)) => Some(Transaction {
                    kind: TransactionKind::LightningSend {
                        federation_fees,
                        gateway_fees,
                        gateway,
                        invoice: meta.invoice.to_string(),
                        payment_hash: meta.invoice.payment_hash().to_string(),
                        preimage: preimage.0.consensus_encode_to_hex(),
                        ln_address,
                    },
                    amount,
                    timestamp,
                    operation_id,
                }),
                _ => None,
            }
        } else {
            let external_outcome = ln_outcome.outcome::<LnPayState>();
            match external_outcome {
                Some(LnPayState::Success { preimage }) => Some(Transaction {
                    kind: TransactionKind::LightningSend {
                        federation_fees,
                        gateway_fees,
                        gateway,
                        invoice: meta.invoice.to_string(),
                        payment_hash: meta.invoice.payment_hash().to_string(),
                        preimage,
                        ln_address,
                    },
                    amount,
                    timestamp,
                    operation_id,
                }),
                _ => None,
            }
        }
    }

    /// Checks the outcome of an LNv1 receive operation and constructs the appropriate `Transaction`
    /// for the transaction log.
    fn get_lnv1_receive_tx(
        invoice: &Bolt11Invoice,
        ln_outcome: &OperationLogEntry,
        timestamp: u64,
        operation_id: OperationId,
        custom_meta: serde_json::Value,
    ) -> Option<Transaction> {
        let receive_outcome = ln_outcome.outcome::<LnReceiveState>();
        // As in `get_lnv1_send_tx`: skip a row whose meta this build cannot read
        // rather than panicking the whole history query.
        let amount = read_meta_msats(&custom_meta, "amount")?;
        let amount_with_fees = read_meta_msats(&custom_meta, "amount_with_fees")?;
        let gateway = read_meta_url(&custom_meta, "gateway_url")?;
        // Per-source fees stored at invoice creation. Fall back through the
        // earlier combined `fees` key, then the invoice-minus-requested estimate,
        // for transactions that predate them.
        let federation_fees = read_meta_msats(&custom_meta, "federation_fees")
            .or_else(|| read_meta_msats(&custom_meta, "fees"))
            .unwrap_or(amount_with_fees - amount);
        let gateway_fees = read_meta_msats(&custom_meta, "gateway_fees").unwrap_or(0);
        match receive_outcome {
            Some(LnReceiveState::Claimed) => Some(Transaction {
                kind: TransactionKind::LightningReceive {
                    federation_fees,
                    gateway_fees,
                    invoice_amount: amount_with_fees,
                    gateway,
                    payee_pubkey: invoice.get_payee_pub_key().to_string(),
                    payment_hash: invoice.payment_hash().to_string(),
                },
                amount,
                timestamp,
                operation_id: operation_id.0.to_vec(),
            }),
            _ => None,
        }
    }

    pub async fn send_ecash(
        &self,
        federation_id: &FederationId,
        amount_msats: u64,
        fee_msats: u64,
    ) -> EcashAppResult<OOBNotesWrapper> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or_else(|| EcashAppError::other("federation does not exist"))?
            .clone();
        // The send fee (the federation reissue fee, quoted on the review screen)
        // isn't recoverable from the operation log afterwards — the reissue that
        // pays it is a separate, filtered-out operation. So we stash it in the
        // send operation's meta here and read it back when reconstructing the
        // transaction (see `transactions`), mirroring how lightning/onchain
        // persist their fees in custom_meta.
        let send_meta = json!({ "fee_msats": fee_msats });
        // mintv2: `send` produces the `ECash`, performing any internal reissue
        // (to mint the right denominations) inline before returning. There's no
        // SpendOOB/refund state to await as in walletv1, so the returned
        // operation id is unused. `include_invite = true` embeds the federation
        // invite code in the ecash so a recipient that has not joined the
        // federation can do so directly from the received ecash.
        if let Ok(mintv2) = client.get_first_module::<MintV2Module>() {
            let (_operation_id, ecash) = mintv2
                .send(Amount::from_msats(amount_msats), send_meta, true)
                .await
                .map_err(EcashAppError::from_display)?;
            return Ok(OOBNotesWrapper(WrappedEcash::V2(ecash)));
        }

        let notes = client
            .get_first_module::<MintClientModule>()
            .map_err(|e| EcashAppError::other(format!("mint module unavailable: {e:#}")))?
            .send_oob_notes(Amount::from_msats(amount_msats), send_meta)
            .await
            .map_err(EcashAppError::from_display)?;
        Ok(OOBNotesWrapper(WrappedEcash::V1(notes)))
    }

    fn spawn_await_ecash_send(&self, federation_id: FederationId, operation_id: OperationId) {
        let self_copy = self.clone();
        self.task_group
            .spawn_cancellable("await ecash send", async move {
                match self_copy
                    .await_ecash_send(&federation_id, operation_id)
                    .await
                {
                    Ok(final_state) => {
                        info_to_flutter(format!("Ecash send completed: {final_state:?}")).await;
                        match final_state {
                            // Recipient reissued — spend is successful.
                            SpendOOBState::Success => {}
                            // User canceled and got the money back — also fine.
                            SpendOOBState::UserCanceledSuccess => {}
                            // Transient / never the final state in practice.
                            SpendOOBState::Created | SpendOOBState::UserCanceledProcessing => {}
                            // User tried to cancel but the notes were already spent by the
                            // recipient — the spend still succeeded, so this isn't an error.
                            SpendOOBState::UserCanceledFailure => {}
                            // Auto-cancel succeeded — recipient never reissued.
                            SpendOOBState::Refunded => {
                                payment_error_to_flutter(
                                    federation_id,
                                    EcashAppError::PaymentRefunded(
                                        "recipient did not redeem ecash".to_string(),
                                    ),
                                )
                                .await;
                            }
                        }
                    }
                    Err(e) => {
                        payment_error_to_flutter(federation_id, e).await;
                    }
                }
            });
    }

    pub async fn await_ecash_send(
        &self,
        federation_id: &FederationId,
        operation_id: OperationId,
    ) -> EcashAppResult<SpendOOBState> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or_else(|| EcashAppError::other("federation does not exist"))?
            .clone();
        let mint = client
            .get_first_module::<MintClientModule>()
            .map_err(|e| EcashAppError::other(format!("mint module unavailable: {e:#}")))?;
        let mut updates = mint
            .subscribe_spend_notes(operation_id)
            .await
            .map_err(EcashAppError::from_display)?
            .into_stream();
        let mut final_state = SpendOOBState::UserCanceledFailure;
        while let Some(update) = updates.next().await {
            final_state = update;
        }
        Ok(final_state)
    }

    pub async fn parse_ecash(
        &self,
        federation_id: &FederationId,
        notes: &OOBNotes,
    ) -> anyhow::Result<u64> {
        let given_federation_id_prefix = notes.federation_id_prefix();
        if federation_id.to_prefix() != given_federation_id_prefix {
            return Err(anyhow!("Trying to claim ecash into incorrect federation"));
        }
        let total_amount = notes.total_amount();
        Ok(total_amount.msats)
    }

    /// Quotes a [`Self::send_ecash`] of `amount_msats` without spending
    /// anything, returning both the *actual* amount the send will spend and the
    /// federation fee on top.
    ///
    /// Both mint modules round the requested amount up to a representable
    /// denomination before producing notes (mintv1 to the smallest economical
    /// denomination via `FeeConsensus::round_up`, mintv2 to a multiple of the
    /// smallest client denomination), so the actual amount can exceed what the
    /// user typed. We mirror that rounding here so the review screen shows the
    /// amount that will really be spent, then quote the fee at that amount.
    ///
    /// The fee comes from the same `send_fee_quote` both modules expose: zero
    /// when the wallet already holds exact-change notes (the send just hands
    /// them out), otherwise the cost of the self-reissue the send performs. The
    /// quote is point-in-time over the current note inventory and display-only.
    pub async fn calculate_ecash_send_fees(
        &self,
        federation_id: &FederationId,
        amount_msats: u64,
    ) -> anyhow::Result<EcashSendFees> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("No federation exists"))?
            .clone();

        let requested = Amount::from_msats(amount_msats);

        if let Ok(mintv2) = client.get_first_module::<MintV2Module>() {
            let min_denomination = fedimint_mintv2_common::config::client_denominations()
                .next()
                .ok_or(anyhow!("mintv2 has no client denominations"))?
                .amount();
            let actual =
                Amount::from_msats(requested.msats.next_multiple_of(min_denomination.msats));
            let quote = mintv2.send_fee_quote(actual).await?;
            return Ok(EcashSendFees {
                amount_msats: actual.msats,
                fee_msats: quote.total().get_bitcoin().msats,
            });
        }

        let mint = client.get_first_module::<MintClientModule>()?;
        let module_configs = client.config().await.modules;
        let mint_config = module_configs
            .get(&mint.id)
            .ok_or(anyhow!("Could not get mint config"))?
            .cast::<fedimint_mint_common::config::MintClientConfig>()?;
        let actual = mint_config.fee_consensus.round_up(requested);
        let quote = mint.send_fee_quote(actual).await?;
        Ok(EcashSendFees {
            amount_msats: actual.msats,
            fee_msats: quote.total().get_bitcoin().msats,
        })
    }

    pub async fn calculate_ecash_reissue_fees(
        &self,
        federation_id: &FederationId,
        ecash: String,
    ) -> anyhow::Result<ReissueFees> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("No federation exists"))?
            .clone();

        // Both mint modules quote the exact fee by dry-running their real change
        // generation against the wallet's current note inventory (which includes
        // consolidation/rebalancing), rather than estimating the note
        // representation. They return the same module-agnostic
        // `fedimint_client::transaction::FeeQuote`, so the breakdown maps onto
        // `ReissueFees` the same way regardless of which mint module quoted it.
        let quote: FeeQuote = if let Ok(mintv2) = client.get_first_module::<MintV2Module>() {
            let ecash_obj = decode_prefixed::<ECash>(FEDIMINT_PREFIX, &ecash)?;
            mintv2.receive_fee_quote(&ecash_obj).await?
        } else {
            let mint = client.get_first_module::<MintClientModule>()?;
            let notes = OOBNotes::from_str(&ecash)?;
            mint.reissue_fee_quote(&notes).await?
        };

        Ok(ReissueFees {
            total_msats: quote.total().get_bitcoin().msats,
            input_msats: quote.input.get_bitcoin().msats,
            output_msats: quote.output.get_bitcoin().msats,
            dust_msats: quote.dust.get_bitcoin().msats,
        })
    }

    pub async fn check_ecash_spent(
        &self,
        federation_id: &FederationId,
        ecash: String,
    ) -> anyhow::Result<bool> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("No federation exists"))?
            .clone();

        // mintv2 exposes no note-level spent query; its idempotent `receive`
        // surfaces already-spent notes as a `Rejected` final state instead, so
        // we report "not spent" here and let the receive handle it.
        if client.get_first_module::<MintV2Module>().is_ok() {
            return Ok(false);
        }

        let mint = client.get_first_module::<MintClientModule>()?;
        let oob_notes = OOBNotes::from_str(&ecash)?;
        // We assume that if any note has been spent, all of the notes have been spent
        for (amount, notes) in oob_notes.notes().iter() {
            info_to_flutter(format!("Checking if notes in tier {:?} are spent", amount)).await;
            for note in notes {
                let nonce = note.nonce();
                if mint.api.check_note_spent(nonce).await? {
                    return Ok(true);
                }
            }
        }

        Ok(false)
    }

    pub async fn reissue_ecash(
        &self,
        federation_id: &FederationId,
        ecash: String,
        fees: ReissueFees,
    ) -> EcashAppResult<OperationId> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or_else(|| EcashAppError::other("federation does not exist"))?
            .clone();

        // mintv2 uses a different ecash encoding (base32 `ECash`) and a simpler,
        // idempotent `receive` that reissues the notes in the background.
        if let Ok(mintv2) = client.get_first_module::<MintV2Module>() {
            let ecash_obj = decode_prefixed::<ECash>(FEDIMINT_PREFIX, &ecash)
                .map_err(|e| EcashAppError::InvalidEcash(e.to_string()))?;
            let amount_msats = ecash_obj.amount().msats;
            // Persist the fee breakdown in the operation's custom meta so the
            // transaction log can show it later (mirrors walletv1's extra_meta).
            let custom_meta = json!({
                "total_amount": amount_msats,
                "input_fee": fees.input_msats,
                "output_fee": fees.output_msats,
                "dust": fees.dust_msats,
            });
            let operation_id = mintv2
                .receive(ecash_obj, custom_meta)
                .await
                .map_err(EcashAppError::from_display)?;
            self.spawn_await_mintv2_receive(*federation_id, operation_id, amount_msats);
            return Ok(operation_id);
        }

        let mint = client
            .get_first_module::<MintClientModule>()
            .map_err(|e| EcashAppError::other(format!("mint module unavailable: {e:#}")))?;
        let notes =
            OOBNotes::from_str(&ecash).map_err(|e| EcashAppError::InvalidEcash(e.to_string()))?;

        // Validate the notes before attempting to reissue
        let total_amount = mint
            .validate_notes(&notes)
            .map_err(EcashAppError::from_display)?;

        let extra_meta = json!({
            "total_amount": total_amount,
            "ecash": ecash,
            "input_fee": fees.input_msats,
            "output_fee": fees.output_msats,
            "dust": fees.dust_msats,
        });
        let operation_id = mint
            .reissue_external_notes(notes, extra_meta)
            .await
            .map_err(EcashAppError::from_display)?;
        self.spawn_await_ecash_reissue(*federation_id, operation_id);
        Ok(operation_id)
    }

    fn spawn_await_ecash_reissue(&self, federation_id: FederationId, operation_id: OperationId) {
        let self_copy = self.clone();
        self.task_group
            .spawn_cancellable("await ecash reissue", async move {
                match self_copy
                    .await_ecash_reissue(&federation_id, operation_id)
                    .await
                {
                    Ok((final_state, amount)) => {
                        info_to_flutter(format!("Ecash reissue completed: {final_state:?}")).await;
                        match final_state {
                            ReissueExternalNotesState::Done => {
                                if let Some(amount) = amount {
                                    let ecash_event =
                                        MultimintEvent::Ecash((federation_id, amount));
                                    get_event_bus().publish(ecash_event).await;
                                }
                            }
                            ReissueExternalNotesState::Failed(msg) => {
                                // A reissue failure is most commonly caused by notes that have
                                // already been spent (e.g. reissuing the same ecash twice),
                                // which is the actionable case for the user. Keep the raw
                                // reason in the log for diagnostics.
                                info_to_flutter(format!("Ecash reissue failed: {msg}")).await;
                                payment_error_to_flutter(
                                    federation_id,
                                    EcashAppError::EcashAlreadySpent,
                                )
                                .await;
                            }
                            _ => {}
                        }
                    }
                    Err(e) => {
                        payment_error_to_flutter(federation_id, EcashAppError::from(e)).await;
                    }
                }
            });
    }

    pub async fn await_ecash_reissue(
        &self,
        federation_id: &FederationId,
        operation_id: OperationId,
    ) -> anyhow::Result<(ReissueExternalNotesState, Option<u64>)> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("No federation exists"))?
            .clone();

        // mintv2 has a simpler Success/Rejected outcome; map it onto the v1
        // reissue state the redeem UI already understands.
        if let Ok(mintv2) = client.get_first_module::<MintV2Module>() {
            let final_state = match mintv2
                .await_final_receive_operation_state(operation_id)
                .await
            {
                Ok(MintV2FinalReceiveOperationState::Success) => ReissueExternalNotesState::Done,
                Ok(MintV2FinalReceiveOperationState::Rejected) => {
                    ReissueExternalNotesState::Failed("ecash already spent".to_string())
                }
                Err(e) => ReissueExternalNotesState::Failed(e.to_string()),
            };
            let amount = if matches!(final_state, ReissueExternalNotesState::Done) {
                Self::get_mintv2_receive_amount(
                    client.operation_log().get_operation(operation_id).await,
                )
            } else {
                None
            };
            return Ok((final_state, amount));
        }

        let mint = client.get_first_module::<MintClientModule>()?;
        let mut updates = mint
            .subscribe_reissue_external_notes(operation_id)
            .await?
            .into_stream();
        let mut final_state = ReissueExternalNotesState::Failed("Unexpected state".to_string());
        while let Some(update) = updates.next().await {
            match update {
                ReissueExternalNotesState::Done => {
                    final_state = ReissueExternalNotesState::Done;
                }
                ReissueExternalNotesState::Failed(e) => {
                    final_state = ReissueExternalNotesState::Failed(e);
                }
                _ => {}
            }
        }

        let operation = client.operation_log().get_operation(operation_id).await;
        let amount = Self::get_ecash_amount_from_meta(operation);

        Ok((final_state, amount))
    }

    fn get_ecash_amount_from_meta(op_log_val: Option<OperationLogEntry>) -> Option<u64> {
        let op_log_val = op_log_val?;
        let meta = op_log_val.meta::<MintOperationMeta>();
        // Internal reissues will have an operation id in the extra meta, these should not generate events
        if serde_json::from_value::<OperationId>(meta.extra_meta).is_ok() {
            return None;
        }

        Some(meta.amount.msats)
    }

    /// Recovers a mintv2 receive amount (msats) from its operation meta — from
    /// the `total_amount` we stash in custom_meta, falling back to decoding the
    /// stored ecash string.
    fn get_mintv2_receive_amount(op_log_val: Option<OperationLogEntry>) -> Option<u64> {
        let op_log_val = op_log_val?;
        match op_log_val.meta::<MintV2OperationMeta>() {
            MintV2OperationMeta::Receive {
                ecash, custom_meta, ..
            } => custom_meta
                .get("total_amount")
                .and_then(|v| v.as_u64())
                .or_else(|| {
                    decode_prefixed::<ECash>(FEDIMINT_PREFIX, &ecash)
                        .ok()
                        .map(|e| e.amount().msats)
                }),
            _ => None,
        }
    }

    /// Drives a mintv2 receive (reissuance) to completion. On success publishes
    /// the ecash balance event; on rejection (already-spent notes) surfaces the
    /// structured error. `amount_msats` is captured from the decoded ecash since
    /// the mintv2 receive meta does not carry the amount directly.
    fn spawn_await_mintv2_receive(
        &self,
        federation_id: FederationId,
        operation_id: OperationId,
        amount_msats: u64,
    ) {
        let self_copy = self.clone();
        self.task_group
            .spawn_cancellable("await mintv2 receive", async move {
                let client = match self_copy.get_client(&federation_id).await {
                    Ok(client) => client,
                    Err(e) => {
                        info_to_flutter(format!("await mintv2 receive: {e}")).await;
                        return;
                    }
                };
                let Ok(mintv2) = client.get_first_module::<MintV2Module>() else {
                    return;
                };
                match mintv2
                    .await_final_receive_operation_state(operation_id)
                    .await
                {
                    Ok(MintV2FinalReceiveOperationState::Success) => {
                        // Reaching `Success` only means the reissue tx was accepted
                        // into consensus; the reissued notes are finalized
                        // asynchronously by the mintv2 output state machines
                        // (blind-signature fetch + note write). Wait for those
                        // outputs before publishing so the balance reflects the
                        // reissue — otherwise the dashboard refreshes before the
                        // notes land and shows a stale value until the next manual
                        // refresh. This mirrors the walletv2 deposit path.
                        if let Some(op) = client.operation_log().get_operation(operation_id).await {
                            if let MintV2OperationMeta::Receive {
                                change_outpoint_range,
                                ..
                            } = op.meta::<MintV2OperationMeta>()
                            {
                                if let Err(e) = client
                                    .await_primary_bitcoin_module_outputs(
                                        operation_id,
                                        change_outpoint_range.into_iter().collect(),
                                    )
                                    .await
                                {
                                    info_to_flutter(format!(
                                        "mintv2 await primary module outputs error: {e:?}"
                                    ))
                                    .await;
                                }
                            }
                        }

                        get_event_bus()
                            .publish(MultimintEvent::Ecash((federation_id, amount_msats)))
                            .await;
                        info_to_flutter(format!("mintv2 receive completed: {amount_msats} msats"))
                            .await;
                    }
                    Ok(MintV2FinalReceiveOperationState::Rejected) => {
                        payment_error_to_flutter(federation_id, EcashAppError::EcashAlreadySpent)
                            .await;
                    }
                    Err(e) => {
                        payment_error_to_flutter(federation_id, EcashAppError::from_display(e))
                            .await;
                    }
                }
            });
    }

    pub async fn calculate_withdraw_fees(
        &self,
        federation_id: &FederationId,
        address: String,
        amount_sats: u64,
    ) -> EcashAppResult<WithdrawFeesResponse> {
        let client = self.get_client(federation_id).await?;
        self.wallet_handler
            .calculate_withdraw_fees(&client, address, amount_sats)
            .await
    }

    pub async fn withdraw_to_address(
        &self,
        federation_id: &FederationId,
        address: String,
        amount_sats: u64,
        fees: WithdrawFees,
        federation_fee_msats: u64,
    ) -> EcashAppResult<OperationId> {
        let client = self.get_client(federation_id).await?;
        self.wallet_handler
            .withdraw_to_address(&client, address, amount_sats, fees, federation_fee_msats)
            .await
    }

    pub async fn await_withdraw(
        &self,
        federation_id: &FederationId,
        operation_id: OperationId,
    ) -> EcashAppResult<String> {
        let client = self.get_client(federation_id).await?;
        self.wallet_handler
            .await_withdraw(*federation_id, &client, operation_id)
            .await
    }

    pub async fn get_max_withdrawable_amount(
        &self,
        federation_id: &FederationId,
        address: String,
    ) -> EcashAppResult<u64> {
        let client = self.get_client(federation_id).await?;
        self.wallet_handler
            .get_max_withdrawable_amount(&client, address)
            .await
    }

    /// Looks up the loaded client for a federation.
    pub(crate) async fn get_client(
        &self,
        federation_id: &FederationId,
    ) -> EcashAppResult<ClientHandleArc> {
        self.clients
            .read()
            .await
            .get(federation_id)
            .ok_or_else(|| EcashAppError::other("federation does not exist"))
            .cloned()
    }

    pub async fn get_pegin_fee_quote(
        &self,
        federation_id: &FederationId,
    ) -> anyhow::Result<PeginFeeQuote> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("No federation exists for peg-in fee query"))?
            .clone();

        // walletv2 charges a fixed base fee plus a relative (ppm) fee, both read
        // from the module config, and additionally a dynamic, feerate-based
        // on-chain claim fee queried from the federation.
        if let Ok(wallet_module) =
            client.get_first_module::<fedimint_walletv2_client::WalletClientModule>()
        {
            let client_module_config = client.config().await.modules;
            let config = client_module_config
                .get(&wallet_module.id)
                .ok_or(anyhow!("Could not get WalletV2 config for peg-in fee"))?
                .cast::<fedimint_walletv2_common::config::WalletClientConfig>()?;

            // Best-effort: the claim fee is unavailable if the federation has no
            // consensus feerate yet, in which case we simply omit it.
            let onchain_claim_fee_sats = wallet_module
                .receive_fee()
                .await
                .ok()
                .map(|fee| fee.to_sat());

            return Ok(PeginFeeQuote {
                base_fee_msats: config.fee_consensus.base.msats,
                parts_per_million: config.fee_consensus.parts_per_million,
                onchain_claim_fee_sats,
            });
        }

        let wallet_module =
            client.get_first_module::<fedimint_wallet_client::WalletClientModule>()?;

        let client_module_config = client.config().await.modules;
        let config = client_module_config
            .get(&wallet_module.id)
            .ok_or(anyhow!("Could not get Wallet config for peg-in fee"))?
            .cast::<fedimint_wallet_common::config::WalletClientConfig>()?;

        // walletv1 charges a single constant peg-in fee; there is no relative
        // component and the on-chain claim is handled by the federation.
        Ok(PeginFeeQuote {
            base_fee_msats: config.fee_consensus.peg_in_abs.msats,
            parts_per_million: 0,
            onchain_claim_fee_sats: None,
        })
    }

    pub async fn wallet_summary(
        &self,
        invite: Option<String>,
        federation_id: Option<FederationId>,
    ) -> anyhow::Result<Vec<Utxo>> {
        let client = match invite {
            Some(invite) => {
                let invite_code = InviteCode::from_str(&invite)?;
                self.get_or_build_temp_client(invite_code).await?.0
            }
            None => {
                let federation_id =
                    federation_id.expect("Invite code and federation ID cannot both be None");
                let clients = self.clients.read().await;
                clients
                    .get(&federation_id)
                    .ok_or(anyhow!("No federation exists"))?
                    .clone()
            }
        };
        // walletv2 holds a single consolidated UTXO at the federation rather
        // than a client-side UTXO set. The last entry of its transaction chain
        // is that current UTXO (a single change output at vout 0).
        if let Ok(wallet_module) = client.get_first_module::<WalletV2Module>() {
            let tx_chain = wallet_module.tx_chain().await?;
            let utxos = tx_chain
                .last()
                .map(|tip| Utxo {
                    txid: tip.txid.to_string(),
                    index: 0,
                    amount: tip.output.to_sat() * 1000,
                })
                .into_iter()
                .collect();
            return Ok(utxos);
        }

        let wallet_module = client.get_first_module::<WalletClientModule>()?;
        let wallet_summary = wallet_module.get_wallet_summary().await?;
        let mut utxos: Vec<Utxo> = wallet_summary
            .spendable_utxos
            .into_iter()
            .map(Utxo::from)
            .collect();
        utxos.sort_by_key(|u| std::cmp::Reverse(u.amount));
        Ok(utxos)
    }

    pub async fn allocate_deposit_address(
        &self,
        federation_id: FederationId,
    ) -> anyhow::Result<(String, Option<u64>)> {
        let client = self
            .clients
            .read()
            .await
            .get(&federation_id)
            .cloned()
            .ok_or(anyhow!("No federation exists"))?;
        self.wallet_handler
            .allocate_deposit_address(federation_id, client)
            .await
    }

    pub async fn get_addresses(
        &self,
        federation_id: &FederationId,
    ) -> Vec<(String, Option<u64>, Option<u64>)> {
        let client = {
            let clients = self.clients.read().await;
            clients.get(federation_id).cloned()
        };
        let Some(client) = client else {
            return Vec::new();
        };
        self.wallet_handler
            .get_addresses(federation_id, &client)
            .await
    }

    pub async fn get_btc_price(&self) -> Option<u64> {
        // Backward compatibility - returns USD price
        let mut dbtx = self.db.begin_transaction_nc().await;
        let prices = dbtx.get_value(&BtcPricesKey).await?;
        Some(prices.usd)
    }

    pub async fn get_all_btc_prices(&self) -> Option<Vec<(FiatCurrency, u64)>> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        let prices = dbtx.get_value(&BtcPricesKey).await?;

        Some(vec![
            (FiatCurrency::Usd, prices.usd),
            (FiatCurrency::Eur, prices.eur),
            (FiatCurrency::Gbp, prices.gbp),
            (FiatCurrency::Cad, prices.cad),
            (FiatCurrency::Chf, prices.chf),
            (FiatCurrency::Aud, prices.aud),
            (FiatCurrency::Jpy, prices.jpy),
        ])
    }

    pub async fn recheck_address(
        &self,
        federation_id: &FederationId,
        tweak_idx: u64,
    ) -> anyhow::Result<()> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .context("No federation exists")?
            .clone();
        let wallet_module =
            client.get_first_module::<fedimint_wallet_client::WalletClientModule>()?;

        wallet_module
            .recheck_pegin_address(TweakIdx(tweak_idx))
            .await?;
        Ok(())
    }

    pub async fn get_note_summary(
        &self,
        federation_id: &FederationId,
    ) -> anyhow::Result<Vec<(u64, usize)>> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .context("No federation exists")?
            .clone();

        if let Ok(mintv2) = client.get_first_module::<MintV2Module>() {
            let counts = mintv2.get_count_by_denomination().await;
            let notes = counts
                .iter()
                .map(|(denom, count)| (denom.amount().msats, *count as usize))
                .collect::<Vec<_>>();
            return Ok(notes);
        }

        let mint = client.get_first_module::<MintClientModule>()?;
        let mut dbtx = mint.client_ctx.module_db().begin_transaction_nc().await;
        let tiered_notes = mint.get_note_counts_by_denomination(&mut dbtx).await;
        let notes = tiered_notes
            .iter()
            .map(|(amount, count)| (amount.msats, count))
            .collect::<Vec<_>>();
        Ok(notes)
    }

    pub(crate) async fn list_gateways(
        &self,
        invite: Option<String>,
        federation_id: Option<FederationId>,
        routing_info_timeout: Duration,
    ) -> anyhow::Result<Vec<FedimintGateway>> {
        let is_temp_client = invite.is_some();
        let client = match invite {
            Some(invite) => {
                let invite_code = InviteCode::from_str(&invite)?;
                self.get_or_build_temp_client(invite_code).await?.0
            }
            None => {
                let federation_id =
                    federation_id.expect("Invite code and federation ID cannot both be None");
                let clients = self.clients.read().await;
                clients
                    .get(&federation_id)
                    .ok_or(anyhow!("No federation exists"))?
                    .clone()
            }
        };
        let mut gateways: Vec<FedimintGateway> = Vec::new();

        if let Ok(lnv1) = client.get_first_module::<LightningClientModule>() {
            // Temp clients (invite-based) don't run the continuous gateway cache
            // update, so populate it on demand. Active clients already have a
            // background task keeping the cache fresh.
            if is_temp_client {
                let _ = lnv1.update_gateway_cache().await;
            }
            for g in lnv1.list_gateways().await {
                let info = g.info;
                gateways.push(FedimintGateway {
                    endpoint: info.api.to_string(),
                    base_routing_fee: info.fees.base_msat as u64,
                    ppm_routing_fee: info.fees.proportional_millionths as u64,
                    base_transaction_fee: 0,
                    ppm_transaction_fee: 0,
                    lightning_alias: Some(info.lightning_alias),
                    lightning_node: Some(info.node_pub_key.to_string()),
                    is_lnv2: false,
                    is_vettted: g.vetted,
                    federation_index: Some(info.federation_index),
                    min_base_routing_fee: None,
                    min_ppm_routing_fee: None,
                });
            }
        }

        if let Ok(lnv2) = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>() {
            if let Ok(lnv2_urls) = lnv2.list_gateways(None).await {
                let routing_infos =
                    futures_util::future::join_all(lnv2_urls.iter().map(|url| async {
                        let routing_info =
                            timeout(routing_info_timeout, lnv2.routing_info(url)).await;
                        (url.clone(), routing_info)
                    }))
                    .await;

                for (url, info) in &routing_infos {
                    if let Ok(Ok(Some(info))) = info {
                        gateways.push(FedimintGateway {
                            endpoint: url.to_string(),
                            base_routing_fee: info.send_fee_default.base.msats,
                            ppm_routing_fee: info.send_fee_default.parts_per_million,
                            base_transaction_fee: info.receive_fee.base.msats,
                            ppm_transaction_fee: info.receive_fee.parts_per_million,
                            lightning_alias: info.lightning_alias.clone(),
                            lightning_node: Some(info.lightning_public_key.to_string()),
                            is_lnv2: true,
                            is_vettted: true, // all LNv2 gateways are vetted
                            federation_index: None,
                            min_base_routing_fee: Some(info.send_fee_minimum.base.msats),
                            min_ppm_routing_fee: Some(info.send_fee_minimum.parts_per_million),
                        });
                    }
                }
            }
        }

        // Sort: LNv2 first, then if its vetted
        gateways.sort_by(|a, b| {
            b.is_lnv2
                .cmp(&a.is_lnv2)
                .then(b.is_vettted.cmp(&a.is_vettted))
        });

        Ok(gateways)
    }

    /// Retreives currently configured Lightning Address
    pub async fn get_ln_address_config(
        &self,
        federation_id: &FederationId,
    ) -> Option<LightningAddressConfig> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&LightningAddressKey {
            federation_id: *federation_id,
        })
        .await
    }

    /// Removes an existing LN Address
    /// Give up a registered address on the LN-address server, and drop the local
    /// record once the server confirms it is gone.
    ///
    /// The local removal belongs here rather than at the caller: the moment the
    /// server confirms the delete, the address genuinely no longer exists, and
    /// the stored config describes something that is not there. Leaving it for a
    /// later overwrite would mean a crash in between leaves the wallet pointing
    /// at a deleted address.
    ///
    /// Takes the config rather than reading it, so the caller controls *when*
    /// the address is given up — see `register_ln_address`, which only releases
    /// the old address after a replacement has been confirmed.
    async fn release_ln_address(
        &self,
        federation_id: &FederationId,
        config: &LightningAddressConfig,
        ln_address_api: &str,
    ) -> anyhow::Result<()> {
        let safe_ln_address_api = SafeUrl::parse(ln_address_api)?;
        let remove_request = LNAddressRemoveRequest {
            username: config.username.clone(),
            domain: config.domain.clone(),
            authentication_token: config.authentication_token.clone(),
        };

        let http_client = crate::net::http_client();
        let remove_endpoint = safe_ln_address_api.join("lnaddress/remove")?;
        let result = http_client
            .delete(remove_endpoint.to_unsafe())
            .json(&remove_request)
            .send()
            .await
            .context("Failed to send remove request")?;

        if !result.status().is_success() {
            let status = result.status();
            let body = result.text().await.unwrap_or_default();
            bail!("Failed to remove LN address: {} - {}", status, body);
        }

        // Confirmed gone on the server, so the local record goes now. This used
        // to be a `remove_entry` on a transaction that was never committed, so
        // the local removal silently never happened.
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.remove_entry(&LightningAddressKey {
            federation_id: *federation_id,
        })
        .await;
        dbtx.commit_tx().await;

        Ok(())
    }

    /// Register LNURL/LN Address
    pub async fn register_ln_address(
        &self,
        federation_id: &FederationId,
        recurringd_api: String,
        ln_address_api: String,
        username: String,
        domain: String,
    ) -> anyhow::Result<()> {
        // Give up the current address before claiming a new one. The local
        // record is dropped by `release_ln_address` at the point the server
        // confirms the delete, so the two stay in step rather than relying on a
        // later overwrite.
        let existing_config = {
            let mut dbtx = self.db.begin_transaction_nc().await;
            dbtx.get_value(&LightningAddressKey {
                federation_id: *federation_id,
            })
            .await
        };
        if let Some(config) = existing_config {
            self.release_ln_address(federation_id, &config, &ln_address_api)
                .await?;
        }

        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .context("No federation exists")?
            .clone();
        let lnv2_gateways = self.lnv2_gateways(federation_id).await;

        let safe_recurringd_api = SafeUrl::parse(&recurringd_api)?;
        let lnv1_recurringd_api = SafeUrl::parse("https://lnurl.ecash.love")?;

        let (payment_code, recipient_pk) = match lnv2_gateways {
            // LNv2 is available, use that to generate an LNURL
            Ok(gws) if !gws.is_empty() => {
                let lnv2 =
                    client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
                let safe_recurringd_api = SafeUrl::parse(&recurringd_api)?;
                let payment_code = lnv2.generate_lnurl(safe_recurringd_api, None).await?;
                info_to_flutter(format!("Registered LNv2 LNURL {:?}", payment_code)).await;
                let pk = Self::extract_recipient_pk_from_lnv2_lnurl(&payment_code)?;
                (payment_code, Some(pk))
            }
            // Only LNv1 is available, use that to generate an LNURL
            _ => {
                let lnv1 = client.get_first_module::<LightningClientModule>()?;

                // Verify at least one LNv1 gateway is registered
                let lnv1_gateways = lnv1.list_gateways().await;
                if lnv1_gateways.is_empty() {
                    bail!("No LNv1 gateways");
                }

                let meta = serde_json::to_string(&json!([["text/plain", "Fedimint LNURL Pay"]]))
                    .expect("serialization can't fail");

                let lnurl = lnv1
                    .register_recurring_payment_code(
                        fedimint_ln_client::recurring::RecurringPaymentProtocol::LNURL,
                        lnv1_recurringd_api,
                        meta.as_str(),
                    )
                    .await?;
                info_to_flutter(format!("Registered LNv1 LNURL {:?}", lnurl)).await;
                let pk = lnurl.root_keypair.public_key().to_string();
                (lnurl.code, Some(pk))
            }
        };

        let safe_ln_address_api = SafeUrl::parse(&ln_address_api)?;
        let register_request = LNAddressRegisterRequest {
            username: username.clone(),
            domain: domain.clone(),
            lnurl: payment_code.clone(),
            recipient_pk: recipient_pk.clone(),
        };

        let http_client = crate::net::http_client();
        let register_endpoint = safe_ln_address_api.join("lnaddress/register")?;
        let result = http_client
            .post(register_endpoint.to_unsafe())
            .json(&register_request)
            .send()
            .await
            .context("Failed to send register request")?;

        if !result.status().is_success() {
            let status = result.status();
            let body = result.text().await.unwrap_or_default();
            bail!("Failed to register LN address: {} - {}", status, body);
        }

        let registration_result = result.json::<serde_json::Value>().await?;
        // Server-controlled JSON, so a non-string here is a badly behaved or
        // hostile server rather than a bug on our side — an error, not a panic.
        let authentication_token = registration_result
            .get("authentication_token")
            .and_then(|token| token.as_str())
            .ok_or(anyhow!(
                "Registration response has no usable authentication token"
            ))?;
        // Never the raw response: it carries `authentication_token`, which is
        // the bearer credential for this lightning address. Log access would
        // otherwise be enough to hijack the address.
        info_to_flutter("Registered lightning address").await;

        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(
            &LightningAddressKey {
                federation_id: *federation_id,
            },
            &LightningAddressConfig {
                username,
                domain,
                recurringd_api: safe_recurringd_api,
                ln_address_api: safe_ln_address_api,
                lnurl: payment_code.clone(),
                authentication_token: authentication_token.to_string(),
            },
        )
        .await;
        dbtx.commit_tx().await;

        info_to_flutter(format!(
            "Successfully registered LN Address. LNURL: {}",
            payment_code
        ))
        .await;

        Ok(())
    }

    /// Extract the recipient public key from an LNv2 LNURL string.
    /// The LNURL encodes a URL containing a base32 payload with the LnurlRequest struct.
    fn extract_recipient_pk_from_lnv2_lnurl(lnurl_str: &str) -> anyhow::Result<String> {
        use fedimint_core::base32::{decode_prefixed, FEDIMINT_PREFIX};
        use fedimint_lnv2_common::lnurl::LnurlRequest;

        let lnurl = lnurl::lnurl::LnUrl::decode(lnurl_str.to_string())
            .map_err(|e| anyhow::anyhow!("Failed to decode LNURL: {:?}", e))?;
        let url = &lnurl.url;

        // Extract the base32 payload after "/pay/"
        let payload = url
            .split("/pay/")
            .nth(1)
            .ok_or_else(|| anyhow::anyhow!("LNURL does not contain /pay/ path"))?;

        let request: LnurlRequest = decode_prefixed(FEDIMINT_PREFIX, payload)?;
        Ok(request.recipient_pk.to_string())
    }

    /// Attempt to recover a Lightning Address after wallet recovery.
    /// Uses the deterministic recipient_pk to reverse-lookup on the lnaddr server.
    pub async fn recover_ln_address(
        &self,
        federation_id: &FederationId,
        ln_address_api: &str,
        recurringd_api: &str,
    ) -> anyhow::Result<()> {
        // Check if config already exists for this federation
        let mut dbtx = self.db.begin_transaction_nc().await;
        let existing = dbtx
            .get_value(&LightningAddressKey {
                federation_id: *federation_id,
            })
            .await;
        if existing.is_some() {
            info_to_flutter("Lightning Address config already exists, skipping recovery").await;
            return Ok(());
        }

        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .context("No federation exists")?
            .clone();

        let safe_ln_address_api = SafeUrl::parse(ln_address_api)?;
        let http_client = crate::net::http_client();

        // Try LNv2 first: generate LNURL with a dummy gateway to extract recipient_pk
        let mut recovered_pk: Option<String> = None;
        let mut is_lnv2 = false;

        if let Ok(lnv2) = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>() {
            let safe_recurringd_api = SafeUrl::parse(recurringd_api)?;
            // Use a dummy gateway to generate LNURL just for pk extraction
            let dummy_gateway = SafeUrl::parse("https://dummy.gateway")?;
            if let Ok(lnurl) = lnv2
                .generate_lnurl(safe_recurringd_api, Some(dummy_gateway))
                .await
            {
                if let Ok(pk) = Self::extract_recipient_pk_from_lnv2_lnurl(&lnurl) {
                    recovered_pk = Some(pk);
                    is_lnv2 = true;
                }
            }
        }

        // Fallback to LNv1: re-register with recurringd to get the keypair
        if recovered_pk.is_none() {
            if let Ok(lnv1) = client.get_first_module::<LightningClientModule>() {
                let lnv1_recurringd_api = SafeUrl::parse("https://lnurl.ecash.love")?;
                let meta = serde_json::to_string(&json!([["text/plain", "Fedimint LNURL Pay"]]))
                    .expect("serialization can't fail");
                if let Ok(entry) = lnv1
                    .register_recurring_payment_code(
                        fedimint_ln_client::recurring::RecurringPaymentProtocol::LNURL,
                        lnv1_recurringd_api,
                        meta.as_str(),
                    )
                    .await
                {
                    recovered_pk = Some(entry.root_keypair.public_key().to_string());
                }
            }
        }

        let recipient_pk = match recovered_pk {
            Some(pk) => pk,
            None => {
                info_to_flutter("Could not derive recipient_pk for Lightning Address recovery")
                    .await;
                return Ok(());
            }
        };

        info_to_flutter(format!(
            "Attempting Lightning Address recovery with recipient_pk: {}",
            recipient_pk
        ))
        .await;

        // Reverse lookup on lnaddr server
        let lookup_url = safe_ln_address_api.join("lnaddress/reverse-lookup")?;
        let lookup_result = http_client
            .get(lookup_url.to_unsafe())
            .query(&[("recipient_pk", &recipient_pk)])
            .send()
            .await
            .context("Failed to send reverse lookup request")?;

        if !lookup_result.status().is_success() {
            info_to_flutter("No Lightning Address found for this wallet on the server").await;
            return Ok(());
        }

        let lookup_response = lookup_result.json::<serde_json::Value>().await?;
        let username = lookup_response
            .get("username")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing username in reverse lookup response"))?
            .to_string();
        let domain = lookup_response
            .get("domain")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing domain in reverse lookup response"))?
            .to_string();
        let old_lnurl = lookup_response
            .get("lnurl")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        info_to_flutter(format!("Found Lightning Address: {}@{}", username, domain)).await;

        // Reclaim: get challenge, sign it, get new auth token
        let challenge_url = safe_ln_address_api.join("lnaddress/challenge")?;
        let challenge_result = http_client
            .get(challenge_url.to_unsafe())
            .query(&[("recipient_pk", &recipient_pk)])
            .send()
            .await
            .context("Failed to get challenge")?;

        if !challenge_result.status().is_success() {
            bail!("Failed to get challenge from lnaddr server");
        }

        let challenge_response = challenge_result.json::<serde_json::Value>().await?;
        let challenge = challenge_response
            .get("challenge")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing challenge in response"))?
            .to_string();

        // Sign the challenge with the appropriate private key.
        // Derive the signing key from the mnemonic using the same derivation path
        // that the Fedimint SDK uses internally for module secrets.
        // StandardDoubleDerive path: global → child(0) → federation_key(fed_id) → child(0) → child(0)
        // Then builder applies: → federation_key(fed_id)
        // Then module secret: → derive_module_secret(instance_id)
        use fedimint_client::module::secret::{
            get_default_client_secret, DeriveableSecretClientExt as _,
        };
        let global_root_secret = Bip39RootSecretStrategy::<12>::to_root_secret(&self.mnemonic);
        let pre_root_secret = get_default_client_secret(&global_root_secret, federation_id);
        let fed_root_secret = pre_root_secret.federation_key(federation_id);

        let signature = if is_lnv2 {
            // LNv2 module's lnurl_keypair = module_root_secret.child_key(ChildId(1))
            let lnv2_kind = fedimint_lnv2_client::LightningClientModule::kind();
            let lnv2_instance_id = client
                .get_first_instance(&lnv2_kind)
                .context("No LNv2 module instance")?;
            let module_secret = fed_root_secret.derive_module_secret(lnv2_instance_id);
            let lnurl_keypair: bitcoin::secp256k1::Keypair = module_secret
                .child_key(fedimint_derive_secret::ChildId(1))
                .to_secp_key(&bitcoin::secp256k1::Secp256k1::new());
            Self::sign_challenge(&challenge, &lnurl_keypair)?
        } else {
            // LNv1: recurring_payment_code_secret = module_root_secret.child_key(ChildId(2))
            // Then payment code keypair = recurring_secret.child_key(ChildId(0))
            let lnv1_kind = LightningClientModule::kind();
            let lnv1_instance_id = client
                .get_first_instance(&lnv1_kind)
                .context("No LNv1 module instance")?;
            let module_secret = fed_root_secret.derive_module_secret(lnv1_instance_id);
            let recurring_secret = module_secret.child_key(fedimint_derive_secret::ChildId(
                fedimint_ln_client::LightningChildKeys::RecurringPaymentCodeSecret as u64,
            ));
            let payment_keypair: bitcoin::secp256k1::Keypair = recurring_secret
                .child_key(fedimint_derive_secret::ChildId(0))
                .to_secp_key(&bitcoin::secp256k1::Secp256k1::new());
            Self::sign_challenge(&challenge, &payment_keypair)?
        };

        // Send reclaim request
        let reclaim_url = safe_ln_address_api.join("lnaddress/reclaim")?;
        let reclaim_body = json!({
            "recipient_pk": recipient_pk,
            "challenge": challenge,
            "signature": signature,
        });
        let reclaim_result = http_client
            .post(reclaim_url.to_unsafe())
            .json(&reclaim_body)
            .send()
            .await
            .context("Failed to send reclaim request")?;

        if !reclaim_result.status().is_success() {
            let status = reclaim_result.status();
            let body = reclaim_result.text().await.unwrap_or_default();
            bail!("Failed to reclaim Lightning Address: {} - {}", status, body);
        }

        let reclaim_response = reclaim_result.json::<serde_json::Value>().await?;
        let authentication_token = reclaim_response
            .get("authentication_token")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing authentication_token in reclaim response"))?
            .to_string();

        // For LNv2: check if gateways changed and update LNURL on the server
        let safe_recurringd_api = SafeUrl::parse(recurringd_api)?;
        let mut final_auth_token = authentication_token;
        let final_lnurl = if is_lnv2 {
            let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
            match lnv2.generate_lnurl(safe_recurringd_api.clone(), None).await {
                Ok(new_lnurl) if new_lnurl != old_lnurl && !old_lnurl.is_empty() => {
                    info_to_flutter("Gateways changed, updating LNURL on Lightning Address server")
                        .await;
                    // Remove old registration and re-register with new LNURL
                    let remove_body = json!({
                        "domain": domain,
                        "username": username,
                        "authentication_token": final_auth_token,
                    });
                    let remove_url = safe_ln_address_api.join("lnaddress/remove")?;
                    let _ = http_client
                        .delete(remove_url.to_unsafe())
                        .json(&remove_body)
                        .send()
                        .await;

                    let register_request = LNAddressRegisterRequest {
                        username: username.clone(),
                        domain: domain.clone(),
                        lnurl: new_lnurl.clone(),
                        recipient_pk: Some(recipient_pk.clone()),
                    };
                    let register_url = safe_ln_address_api.join("lnaddress/register")?;
                    let reg_result = http_client
                        .post(register_url.to_unsafe())
                        .json(&register_request)
                        .send()
                        .await
                        .context("Failed to re-register with updated LNURL")?;

                    if reg_result.status().is_success() {
                        let reg_response = reg_result.json::<serde_json::Value>().await?;
                        if let Some(new_token) = reg_response
                            .get("authentication_token")
                            .and_then(|v| v.as_str())
                        {
                            final_auth_token = new_token.to_string();
                        }
                    }
                    new_lnurl
                }
                Ok(new_lnurl) => new_lnurl,
                Err(_) => old_lnurl,
            }
        } else {
            old_lnurl
        };

        // Store the recovered config in the app database
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(
            &LightningAddressKey {
                federation_id: *federation_id,
            },
            &LightningAddressConfig {
                username: username.clone(),
                domain: domain.clone(),
                recurringd_api: safe_recurringd_api,
                ln_address_api: safe_ln_address_api,
                lnurl: final_lnurl,
                authentication_token: final_auth_token,
            },
        )
        .await;
        dbtx.commit_tx().await;

        info_to_flutter(format!(
            "Successfully recovered Lightning Address: {}@{}",
            username, domain
        ))
        .await;

        Ok(())
    }

    /// Sign a challenge hex string with the given keypair using ECDSA.
    /// Returns the compact signature as a hex string.
    fn sign_challenge(
        challenge_hex: &str,
        keypair: &bitcoin::secp256k1::Keypair,
    ) -> anyhow::Result<String> {
        use bitcoin::hashes::{sha256::Hash as Sha256Hash, Hash as _};
        let challenge_bytes = hex::decode(challenge_hex).context("Invalid challenge hex")?;
        let hash = Sha256Hash::hash(&challenge_bytes);
        let msg = bitcoin::secp256k1::Message::from_digest(hash.to_byte_array());
        let secp = bitcoin::secp256k1::Secp256k1::new();
        let sig = secp.sign_ecdsa(&msg, &keypair.secret_key());
        Ok(hex::encode(sig.serialize_compact()))
    }

    async fn lnv2_gateways(&self, federation_id: &FederationId) -> anyhow::Result<Vec<SafeUrl>> {
        // Clone out and drop the clients lock before the gateway network call.
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("No federation exists"))?
            .clone();
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let lnv2_gateways = lnv2.list_gateways(None).await?;
        Ok(lnv2_gateways)
    }

    // Check LN Address status (registered or not)
    pub async fn check_ln_address_availability(
        &self,
        username: String,
        domain: String,
        ln_address_api: String,
        _recurringd_api: String, // hard coded to LNv1 LNURL server
        federation_id: &FederationId,
    ) -> anyhow::Result<LNAddressStatus> {
        // First check if the current config is equivalent
        if let Some(current_config) = self.get_ln_address_config(federation_id).await {
            if username == current_config.username && domain == current_config.domain {
                return Ok(LNAddressStatus::CurrentConfig);
            }
        }

        // Check that the selected federation is supported by recurringd
        let lnv2_gateways = self.lnv2_gateways(federation_id).await;
        match lnv2_gateways {
            // Verify that if LNv2 is available and has a gateway, there is nothing to check
            Ok(gws) if !gws.is_empty() => {}
            _ => {
                // Use the LNv1 recurringd endpoint for federation support check,
                // matching the hardcoded URL used in register_ln_address for LNv1.
                let lnv1_recurringd = "https://lnurl.ecash.love".to_string();
                let supported_federations =
                    self.get_recurringd_federations(lnv1_recurringd).await?;
                if !supported_federations.contains(federation_id) {
                    return Ok(LNAddressStatus::UnsupportedFederation);
                }
            }
        }

        // Validate that the given username and domain are a valid Lightning Address
        let username_re = regex::Regex::new(r"^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$")?;
        let domain_re = regex::Regex::new(r"^[a-z0-9.-]+\.[a-z]{2,}$")?;

        if !username_re.is_match(&username) {
            return Ok(LNAddressStatus::Invalid);
        }

        if !domain_re.is_match(&domain) {
            return Ok(LNAddressStatus::Invalid);
        }

        let safe_url = SafeUrl::parse(&ln_address_api)?;
        let endpoint = safe_url.join(&format!("lnaddress/{}/{}", domain, username))?;
        let http_client = crate::net::http_client();
        let result = http_client
            .get(endpoint.to_unsafe())
            .send()
            .await
            .context("Failed to send GET request")?;

        match result.status() {
            StatusCode::OK => {
                let json = result.json::<serde_json::Value>().await?;
                let payment_code = json
                    .get("url")
                    .ok_or(anyhow!("url not in response"))?
                    .as_str()
                    .ok_or(anyhow!("response not a string"))?;
                Ok(LNAddressStatus::Registered {
                    lnurl: payment_code.to_string(),
                })
            }
            StatusCode::NOT_FOUND => Ok(LNAddressStatus::Available),
            _ => {
                error_to_flutter(format!(
                    "Error getting ln address availability: {:?}",
                    result
                ))
                .await;
                Err(anyhow!("Error getting ln address availability"))
            }
        }
    }

    /// Returns a vector of `FederationId`s that recurringd supports
    async fn get_recurringd_federations(
        &self,
        recurringd_api: String,
    ) -> anyhow::Result<Vec<FederationId>> {
        let endpoint = SafeUrl::parse(&recurringd_api)?.join("lnv1/federations")?;

        let http_client = crate::net::http_client();
        let result = http_client
            .get(endpoint.to_unsafe())
            .send()
            .await
            .context("Failed to send domains request")?;

        let feds = result.json::<Vec<FederationId>>().await?;
        Ok(feds)
    }

    fn spawn_recurring_invoice_listener(&self) {
        let self_copy = self.clone();
        self.task_group
            .spawn_cancellable("recurringd listener", async move {
                info_to_flutter("Spawning recurringd invoice listener").await;
                let mut interval = tokio::time::interval(Duration::from_secs(20));
                interval.tick().await;
                loop {
                    let mut dbtx = self_copy.db.begin_transaction_nc().await;
                    let lightning_configs = dbtx
                        .find_by_prefix(&LightningAddressKeyPrefix)
                        .await
                        .collect::<Vec<_>>()
                        .await;
                    for (key, config) in lightning_configs {
                        let federation_id = key.federation_id;
                        if let Some(client) = self_copy.clients.read().await.get(&federation_id) {
                            // This poller only drives the LNv1 recurringd flow.
                            // LNv2-only federations have no `ln` module (their
                            // LNURL receives are detected via the LNv2 contract
                            // stream), so skip them instead of panicking.
                            let Ok(lnv1) = client.get_first_module::<LightningClientModule>()
                            else {
                                continue;
                            };
                            let payment_codes = lnv1.list_recurring_payment_codes().await;
                            if let Some((index, _)) = payment_codes
                                .into_iter()
                                .find(|(_, entry)| entry.code == config.lnurl)
                            {
                                if let Some(invoices) =
                                    lnv1.list_recurring_payment_code_invoices(index).await
                                {
                                    for (_, operation_id) in invoices {
                                        let operation = client
                                            .operation_log()
                                            .get_operation(operation_id)
                                            .await
                                            .expect("operation must exist");
                                        if operation.outcome::<serde_json::Value>().is_none()
                                            && !self_copy
                                                .recurringd_invoices
                                                .read()
                                                .await
                                                .contains(&operation_id)
                                        {
                                            self_copy
                                                .spawn_await_recurringd_receive(
                                                    client.clone(),
                                                    operation_id,
                                                    federation_id,
                                                )
                                                .await;
                                        }
                                    }
                                }
                            }
                        }
                    }

                    interval.tick().await;
                }
            });
    }

    /// Spawn a one-shot task to backfill `recipient_pk` for existing Lightning
    /// Address registrations that were created before this feature was added.
    fn spawn_backfill_recipient_pk(&self) {
        let self_copy = self.clone();
        self.task_group
            .spawn_cancellable("backfill recipient_pk", async move {
                // Small delay to let things settle after startup
                tokio::time::sleep(Duration::from_secs(10)).await;

                let mut dbtx = self_copy.db.begin_transaction_nc().await;
                let lightning_configs = dbtx
                    .find_by_prefix(&LightningAddressKeyPrefix)
                    .await
                    .collect::<Vec<_>>()
                    .await;

                for (key, config) in lightning_configs {
                    let federation_id = key.federation_id;
                    let Some(client) = self_copy.clients.read().await.get(&federation_id).cloned()
                    else {
                        continue;
                    };

                    // Try to extract recipient_pk for this federation
                    let recipient_pk = if let Ok(lnv2) =
                        client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()
                    {
                        // Try generating LNURL to extract pk
                        let dummy_gateway = SafeUrl::parse("https://dummy.gateway").unwrap();
                        if let Ok(lnurl) = lnv2
                            .generate_lnurl(config.recurringd_api.clone(), Some(dummy_gateway))
                            .await
                        {
                            Self::extract_recipient_pk_from_lnv2_lnurl(&lnurl).ok()
                        } else {
                            None
                        }
                    } else if let Ok(lnv1) = client.get_first_module::<LightningClientModule>() {
                        // Check if there are existing payment codes
                        let codes = lnv1.list_recurring_payment_codes().await;
                        codes
                            .values()
                            .find(|entry| entry.code == config.lnurl)
                            .map(|entry| entry.root_keypair.public_key().to_string())
                    } else {
                        None
                    };

                    if let Some(pk) = recipient_pk {
                        let http_client = crate::net::http_client();
                        let update_url = match config.ln_address_api.join("lnaddress/update-pk") {
                            Ok(url) => url,
                            Err(_) => continue,
                        };
                        let body = serde_json::json!({
                            "domain": config.domain,
                            "username": config.username,
                            "authentication_token": config.authentication_token,
                            "recipient_pk": pk,
                        });
                        match http_client
                            .patch(update_url.to_unsafe())
                            .json(&body)
                            .send()
                            .await
                        {
                            Ok(resp) if resp.status().is_success() => {
                                info_to_flutter(format!(
                                    "Backfilled recipient_pk for {}@{}",
                                    config.username, config.domain
                                ))
                                .await;
                            }
                            _ => {
                                // Silently ignore errors - might already be backfilled
                            }
                        }
                    }
                }
            });
    }

    pub async fn get_all_invite_codes(&self) -> Vec<String> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        let configs = dbtx
            .find_by_prefix(&FederationConfigKeyPrefix)
            .await
            .collect::<Vec<_>>()
            .await;
        // Snapshot the clients (cheap Arc clones) and drop the lock before the
        // per-peer network calls below, so we don't hold `clients.read()` across
        // `invite_code().await` and block joins.
        let clients: BTreeMap<FederationId, ClientHandleArc> = {
            let guard = self.clients.read().await;
            guard.iter().map(|(k, v)| (*k, v.clone())).collect()
        };
        let mut all_invite_codes = Vec::new();
        for (key, config) in configs {
            if let Some(client) = clients.get(&key.id) {
                let peers = config
                    .client_config
                    .global
                    .api_endpoints
                    .keys()
                    .collect::<Vec<_>>();
                for peer in peers {
                    let invite_code = client
                        .invite_code(*peer)
                        .await
                        .expect("Invalid peer")
                        .to_string();
                    all_invite_codes.push(invite_code);
                }
            }
        }

        all_invite_codes
    }

    pub async fn rejoin_from_backup_invites(&mut self, backup_invite_codes: Vec<String>) {
        let mut already_joined_feds = BTreeSet::new();

        info_to_flutter(format!(
            "Starting to re-join federations from Nostr. Number of invite codes: {}",
            backup_invite_codes.len()
        ))
        .await;

        if backup_invite_codes.is_empty() {
            get_event_bus()
                .publish(MultimintEvent::NostrRecoveryPhase(
                    NostrRecoveryPhase::NoBackupFound,
                ))
                .await;
            return;
        }

        get_event_bus()
            .publish(MultimintEvent::NostrRecoveryPhase(
                NostrRecoveryPhase::RejoiningFederations(backup_invite_codes.len() as u32),
            ))
            .await;
        for invite in backup_invite_codes {
            if let Ok(invite_code) = InviteCode::from_str(&invite) {
                let fed_id = invite_code.federation_id();

                if !already_joined_feds.contains(&fed_id) {
                    get_event_bus()
                        .publish(MultimintEvent::NostrRecovery(
                            invite_code.federation_id().to_string(),
                            invite_code.peer().into(),
                            None,
                        ))
                        .await;

                    info_to_flutter(format!(
                        "Rejoining: {} peer: {}",
                        invite_code.federation_id(),
                        invite_code.peer()
                    ))
                    .await;
                    match timeout(
                        Duration::from_secs(30),
                        self.join_federation(invite.clone(), true),
                    )
                    .await
                    {
                        Ok(Ok(selector)) => {
                            already_joined_feds.insert(fed_id);
                            info_to_flutter(format!(
                                "Successfully rejoined {} after recovery",
                                fed_id
                            ))
                            .await;

                            get_event_bus()
                                .publish(MultimintEvent::NostrRecovery(
                                    invite_code.federation_id().to_string(),
                                    invite_code.peer().into(),
                                    Some(selector),
                                ))
                                .await;
                        }
                        Ok(Err(e)) => {
                            error_to_flutter(format!(
                                "Rejoining federation {} with invite code {} failed: {}",
                                fed_id, invite, e
                            ))
                            .await;
                        }
                        Err(_) => {
                            error_to_flutter(format!(
                                "Rejoining federation {} with invite code {} timed out",
                                fed_id, invite
                            ))
                            .await;
                        }
                    }
                }
            }
        }

        get_event_bus().clear_history().await;
    }

    pub async fn get_invite_code(
        &self,
        federation_id: &FederationId,
        peer: u16,
    ) -> anyhow::Result<String> {
        // Clone out and drop the clients lock before the invite_code network call.
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("Federation does not exist"))?
            .clone();
        Ok(client
            .invite_code(peer.into())
            .await
            .ok_or(anyhow!("Peer does not exist"))?
            .to_string())
    }

    /// Build an admin API handle scoped to a single guardian. Authenticated
    /// (admin) endpoints read or mutate that guardian's local state, so unlike
    /// regular client requests they always target one peer's URL.
    async fn guardian_admin_api(
        &self,
        federation_id: &FederationId,
        peer: u16,
    ) -> anyhow::Result<DynGlobalApi> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("Federation does not exist"))?
            .clone();
        let invite = client
            .invite_code(peer.into())
            .await
            .ok_or(anyhow!("Peer does not exist"))?;
        let connectors = ConnectorRegistry::build_from_client_defaults()
            .bind()
            .await?;
        DynGlobalApi::new_admin(
            connectors,
            peer.into(),
            invite.url(),
            invite.api_secret().as_deref(),
        )
    }

    /// Verify guardian admin credentials against the `auth` endpoint, which
    /// succeeds only with the correct password. Returns `Ok(false)` on a
    /// rejected password (also the guardian's response when it has no admin
    /// password configured at all) and `Err` when the guardian is unreachable.
    pub async fn guardian_login(
        &self,
        federation_id: &FederationId,
        peer: u16,
        password: String,
    ) -> anyhow::Result<bool> {
        let api = self.guardian_admin_api(federation_id, peer).await?;
        match api.auth(ApiAuth::new(password)).await {
            Ok(()) => Ok(true),
            Err(err) if is_invalid_guardian_auth(&err) => Ok(false),
            Err(err) => Err(err.into()),
        }
    }

    pub async fn guardian_audit(
        &self,
        federation_id: &FederationId,
        peer: u16,
        password: String,
    ) -> anyhow::Result<GuardianAuditSummary> {
        let api = self.guardian_admin_api(federation_id, peer).await?;
        let summary = api.audit(ApiAuth::new(password)).await?;
        Ok(GuardianAuditSummary {
            net_assets_msats: summary.net_assets,
            module_summaries: summary
                .module_summaries
                .into_iter()
                .map(|(module_instance_id, module)| GuardianModuleSummary {
                    module_instance_id,
                    kind: module.kind,
                    net_assets_msats: module.net_assets,
                })
                .collect(),
        })
    }

    pub async fn guardian_backup_statistics(
        &self,
        federation_id: &FederationId,
        peer: u16,
        password: String,
    ) -> anyhow::Result<GuardianBackupStatistics> {
        let api = self.guardian_admin_api(federation_id, peer).await?;
        let stats = api.backup_statistics(ApiAuth::new(password)).await?;
        Ok(GuardianBackupStatistics {
            num_backups: stats.num_backups as u64,
            total_size_bytes: stats.total_size as u64,
            refreshed_1d: stats.refreshed_1d as u64,
            refreshed_1w: stats.refreshed_1w as u64,
            refreshed_1m: stats.refreshed_1m as u64,
            refreshed_3m: stats.refreshed_3m as u64,
        })
    }

    pub async fn guardian_status(
        &self,
        federation_id: &FederationId,
        peer: u16,
        password: String,
    ) -> anyhow::Result<GuardianStatusSummary> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("Federation does not exist"))?
            .clone();
        let api = self.guardian_admin_api(federation_id, peer).await?;

        let status = api.status().await?;
        let latency: Option<Duration> = api
            .request_admin_no_auth(CONSENSUS_ORD_LATENCY_ENDPOINT, ApiRequestErased::default())
            .await
            .unwrap_or_default();

        let federation = status.federation.as_ref();
        let health = GuardianHealth {
            consensus_running: status.server == ServerStatusLegacy::ConsensusRunning,
            server_status: format!("{:?}", status.server),
            session_count: federation.map(|f| f.session_count),
            peers_online: federation.map(|f| f.peers_online).unwrap_or_default(),
            peers_total: federation
                .map(|f| f.status_by_peer.len() as u64)
                .unwrap_or_default(),
            consensus_ord_latency_ms: latency.map(|latency| latency.as_millis() as u64),
            scheduled_shutdown_session: federation.and_then(|f| f.scheduled_shutdown),
        };

        let bitcoin = Self::guardian_bitcoin_status(&client, &api, password).await;
        let has_lnv2 = client
            .get_first_module::<fedimint_lnv2_client::LightningClientModule>()
            .is_ok();
        let has_meta = client.get_first_module::<MetaClientModule>().is_ok();

        Ok(GuardianStatusSummary {
            health,
            bitcoin,
            has_lnv2,
            has_meta,
        })
    }

    async fn guardian_bitcoin_status(
        client: &ClientHandleArc,
        admin_api: &DynGlobalApi,
        password: String,
    ) -> Option<GuardianBitcoinStatus> {
        if let Ok(wallet) = client.get_first_module::<WalletClientModule>() {
            let module_api = admin_api.with_module(wallet.id);

            let consensus_block_count: u32 = module_api
                .request_admin_no_auth(BLOCK_COUNT_ENDPOINT, ApiRequestErased::default())
                .await
                .ok()?;
            let local_block_count: Option<u32> = module_api
                .request_admin_no_auth(BLOCK_COUNT_LOCAL_ENDPOINT, ApiRequestErased::default())
                .await
                .unwrap_or_default();
            // Requires guardian auth and a recent fedimintd; the block counts
            // above are still useful without it.
            let rpc_config: Option<BitcoinRpcConfig> = module_api
                .request_admin(
                    BITCOIN_RPC_CONFIG_ENDPOINT,
                    ApiRequestErased::default(),
                    ApiAuth::new(password),
                )
                .await
                .ok();

            return Some(GuardianBitcoinStatus {
                kind: rpc_config.as_ref().map(|config| config.kind.clone()),
                url: rpc_config.map(|config| config.url.to_string()),
                consensus_block_count: consensus_block_count.into(),
                local_block_count: local_block_count.map(Into::into),
                consensus_feerate_sats_per_kvb: None,
            });
        }

        // Wallet v2 exposes no local block count or backend config, so the
        // card degrades to consensus height plus fee rate.
        let wallet_id = client.get_first_module::<WalletV2Module>().ok()?.id;
        let module_api = admin_api.with_module(wallet_id);

        let consensus_block_count: u64 = module_api
            .request_admin_no_auth(CONSENSUS_BLOCK_COUNT_ENDPOINT, ApiRequestErased::default())
            .await
            .ok()?;
        let consensus_feerate: Option<u64> = module_api
            .request_admin_no_auth(CONSENSUS_FEERATE_ENDPOINT, ApiRequestErased::default())
            .await
            .unwrap_or_default();

        Some(GuardianBitcoinStatus {
            kind: None,
            url: None,
            consensus_block_count,
            local_block_count: None,
            consensus_feerate_sats_per_kvb: consensus_feerate,
        })
    }

    /// The lnv2 gateway whitelist is per-guardian state, so listing queries
    /// the given peer directly instead of the client's default strategy.
    pub async fn guardian_list_gateways(
        &self,
        federation_id: &FederationId,
        peer: u16,
    ) -> anyhow::Result<Vec<String>> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("Federation does not exist"))?
            .clone();
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let gateways = lnv2
            .list_gateways(Some(peer.into()))
            .await
            .map_err(|err| anyhow!("Could not list gateways: {err:?}"))?;
        Ok(gateways.into_iter().map(|url| url.to_string()).collect())
    }

    async fn guardian_lnv2_module_api(
        &self,
        federation_id: &FederationId,
        peer: u16,
    ) -> anyhow::Result<DynModuleApi> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("Federation does not exist"))?
            .clone();
        let lnv2_id = client
            .get_first_module::<fedimint_lnv2_client::LightningClientModule>()?
            .id;
        let api = self.guardian_admin_api(federation_id, peer).await?;
        Ok(api.with_module(lnv2_id))
    }

    /// Returns false when the gateway was already whitelisted.
    pub async fn guardian_add_gateway(
        &self,
        federation_id: &FederationId,
        peer: u16,
        password: String,
        gateway_url: String,
    ) -> anyhow::Result<bool> {
        let gateway = SafeUrl::parse(gateway_url.trim())?;
        let module_api = self.guardian_lnv2_module_api(federation_id, peer).await?;
        Ok(module_api
            .request_admin(
                ADD_GATEWAY_ENDPOINT,
                ApiRequestErased::new(gateway),
                ApiAuth::new(password),
            )
            .await?)
    }

    async fn guardian_meta_module_api(
        &self,
        federation_id: &FederationId,
        peer: u16,
    ) -> anyhow::Result<(DynModuleApi, u16)> {
        let client = self
            .clients
            .read()
            .await
            .get(federation_id)
            .ok_or(anyhow!("Federation does not exist"))?
            .clone();
        let meta_id = client.get_first_module::<MetaClientModule>()?.id;
        let total_guardians = client.config().await.global.api_endpoints.len() as u16;
        let api = self.guardian_admin_api(federation_id, peer).await?;
        Ok((api.with_module(meta_id), total_guardians))
    }

    async fn guardian_meta_consensus(
        module_api: &DynModuleApi,
    ) -> anyhow::Result<Option<MetaConsensusValue>> {
        Ok(module_api
            .request_admin_no_auth(
                GET_CONSENSUS_ENDPOINT,
                ApiRequestErased::new(GetConsensusRequest(DEFAULT_META_KEY)),
            )
            .await?)
    }

    pub async fn guardian_meta_state(
        &self,
        federation_id: &FederationId,
        peer: u16,
        password: String,
    ) -> anyhow::Result<GuardianMetaState> {
        let (module_api, total_guardians) =
            self.guardian_meta_module_api(federation_id, peer).await?;

        let consensus = Self::guardian_meta_consensus(&module_api).await?;
        let submissions: GetSubmissionResponse = module_api
            .request_admin(
                GET_SUBMISSIONS_ENDPOINT,
                ApiRequestErased::new(GetSubmissionsRequest(DEFAULT_META_KEY)),
                ApiAuth::new(password),
            )
            .await?;

        // Guardians backing byte-identical values are voting together, so group
        // them into a single proposal the UI can show one vote tally for.
        let mut by_value: BTreeMap<Vec<u8>, Vec<u16>> = BTreeMap::new();
        for (peer_id, value) in submissions {
            by_value
                .entry(value.as_slice().to_vec())
                .or_default()
                .push(peer_id.to_usize() as u16);
        }

        let proposals = by_value
            .into_iter()
            .map(|(value, peer_ids)| {
                let is_ours = peer_ids.contains(&peer);
                let value_json = serde_json::from_slice::<serde_json::Value>(&value)
                    .ok()
                    .and_then(|json| serde_json::to_string(&json).ok());
                GuardianMetaProposal {
                    peer_ids,
                    value_hex: hex::encode(&value),
                    value_json,
                    is_ours,
                }
            })
            .collect();

        Ok(GuardianMetaState {
            consensus_json: consensus
                .as_ref()
                .and_then(|c| c.value.to_json().ok())
                .and_then(|json| serde_json::to_string(&json).ok()),
            revision: consensus.as_ref().map(|c| c.revision),
            proposals,
            threshold: NumPeers::from(total_guardians as usize).threshold() as u16,
            total_guardians,
        })
    }

    async fn guardian_meta_submit(
        module_api: &DynModuleApi,
        password: String,
        value: MetaValue,
    ) -> anyhow::Result<()> {
        // The endpoint returns unit; naming the type keeps the generic return
        // from falling back to the never type.
        let () = module_api
            .request_admin(
                SUBMIT_ENDPOINT,
                ApiRequestErased::new(SubmitRequest {
                    key: DEFAULT_META_KEY,
                    value,
                }),
                ApiAuth::new(password),
            )
            .await?;
        Ok(())
    }

    /// Back an existing proposal by resubmitting its exact bytes.
    pub async fn guardian_meta_accept(
        &self,
        federation_id: &FederationId,
        peer: u16,
        password: String,
        value_hex: String,
    ) -> anyhow::Result<()> {
        let (module_api, _) = self.guardian_meta_module_api(federation_id, peer).await?;
        let value = MetaValue::from(hex::decode(value_hex)?.as_slice());
        Self::guardian_meta_submit(&module_api, password, value).await
    }

    /// Withdraw this guardian's vote by submitting the current consensus
    /// value, which is how the meta module expresses "no change".
    pub async fn guardian_meta_withdraw(
        &self,
        federation_id: &FederationId,
        peer: u16,
        password: String,
    ) -> anyhow::Result<()> {
        let (module_api, _) = self.guardian_meta_module_api(federation_id, peer).await?;
        let consensus = Self::guardian_meta_consensus(&module_api)
            .await?
            .ok_or(anyhow!("Federation has no meta consensus value yet"))?;
        Self::guardian_meta_submit(&module_api, password, consensus.value).await
    }

    /// Propose a single field change. The meta module stores one JSON document
    /// per key, so this reads the current consensus document, applies the edit
    /// and submits the whole document back. Passing `None` removes the field.
    pub async fn guardian_meta_propose_field(
        &self,
        federation_id: &FederationId,
        peer: u16,
        password: String,
        field: String,
        value: Option<String>,
    ) -> anyhow::Result<()> {
        let (module_api, _) = self.guardian_meta_module_api(federation_id, peer).await?;

        let mut document = match Self::guardian_meta_consensus(&module_api).await? {
            Some(consensus) => consensus.value.to_json().unwrap_or_else(|_| json!({})),
            None => json!({}),
        };
        let object = document
            .as_object_mut()
            .ok_or(anyhow!("Meta consensus value is not a JSON object"))?;

        match value {
            Some(value) => {
                object.insert(field, serde_json::Value::String(value));
            }
            None => {
                object.remove(&field);
            }
        }

        let encoded = serde_json::to_vec(&document)?;
        Self::guardian_meta_submit(&module_api, password, MetaValue::from(encoded.as_slice())).await
    }

    /// Returns false when the gateway was not whitelisted to begin with.
    pub async fn guardian_remove_gateway(
        &self,
        federation_id: &FederationId,
        peer: u16,
        password: String,
        gateway_url: String,
    ) -> anyhow::Result<bool> {
        let gateway = SafeUrl::parse(gateway_url.trim())?;
        let module_api = self.guardian_lnv2_module_api(federation_id, peer).await?;
        Ok(module_api
            .request_admin(
                REMOVE_GATEWAY_ENDPOINT,
                ApiRequestErased::new(gateway),
                ApiAuth::new(password),
            )
            .await?)
    }

    pub async fn get_bitcoin_display(&self) -> BitcoinDisplay {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&BitcoinDisplayKey)
            .await
            .unwrap_or(BitcoinDisplay::Bip177)
    }

    pub async fn set_bitcoin_display(&self, bitcoin_display: BitcoinDisplay) {
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(&BitcoinDisplayKey, &bitcoin_display)
            .await;
        dbtx.commit_tx().await;
    }

    pub async fn get_fiat_currency(&self) -> FiatCurrency {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&FiatCurrencyKey)
            .await
            .unwrap_or(FiatCurrency::Usd)
    }

    pub async fn set_fiat_currency(&self, fiat_currency: FiatCurrency) {
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(&FiatCurrencyKey, &fiat_currency).await;
        dbtx.commit_tx().await;
    }

    pub async fn get_show_msats(&self) -> bool {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&crate::db::ShowMsatsKey).await.is_some()
    }

    pub async fn set_show_msats(&self, show_msats: bool) {
        let mut dbtx = self.db.begin_transaction().await;
        if show_msats {
            dbtx.insert_entry(&crate::db::ShowMsatsKey, &()).await;
        } else {
            dbtx.remove_entry(&crate::db::ShowMsatsKey).await;
        }
        dbtx.commit_tx().await;
    }

    pub async fn get_federation_order(&self) -> Option<Vec<FederationId>> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&crate::db::FederationOrderKey)
            .await
            .map(|order| order.order)
    }

    pub async fn set_federation_order(&self, order: Vec<FederationId>) {
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(
            &crate::db::FederationOrderKey,
            &crate::db::FederationOrder { order },
        )
        .await;
        dbtx.commit_tx().await;
    }
}

/// Using the given federation (transaction) and gateway fees, compute the value `X` such that `X - total_fee == requested_amount`.
/// This is non-trivial because the federation and gateway fees both contain a ppm fee, making each fee calculation dependent on each other.
/// Smallest gross amount to submit as a lightning receive so that, after the
/// on-federation receive fee, at least `requested` msats are credited.
///
/// `quote` is a module's `receive_fee_quote` (lnv1 or lnv2): a point-in-time
/// dry-run returning the federation-transaction fee (lightning input fee + mint
/// output fees + dust) for receiving `gross` msats, computed against the current
/// note inventory. Because that fee depends on `gross` (more value can require
/// more change notes), this iterates to a fixed point. The fee is monotonic
/// non-decreasing in `gross`, so the sequence increases until it stabilizes; the
/// `next <= gross` break guarantees `gross - fee(gross) >= requested`.
/// Reads a key from a lightning receive's `custom_meta` as msats, treating the
/// stored value as a serialized [`Amount`]. Returns `None` if the key is absent
/// or unparseable (e.g. transactions created before the key existed).
fn read_meta_msats(custom_meta: &serde_json::Value, key: &str) -> Option<u64> {
    custom_meta
        .get(key)
        .and_then(|v| from_value::<Amount>(v.clone()).ok())
        .map(|a| a.msats)
}

/// Reads a key from a lightning send's `custom_meta` as a raw msats `u64`.
/// Returns `None` if the key is absent (e.g. transactions created before it).
fn read_meta_u64(custom_meta: &serde_json::Value, key: &str) -> Option<u64> {
    custom_meta
        .get(key)
        .and_then(|v| from_value::<u64>(v.clone()).ok())
}

/// Reads a key from an operation's stored meta as a gateway URL.
fn read_meta_url(custom_meta: &serde_json::Value, key: &str) -> Option<String> {
    custom_meta
        .get(key)
        .and_then(|v| from_value::<SafeUrl>(v.clone()).ok())
        .map(|url| url.to_string())
}

/// Reads a key from an operation's stored meta as a `String`.
fn read_meta_string(custom_meta: &serde_json::Value, key: &str) -> Option<String> {
    custom_meta
        .get(key)
        .and_then(|v| from_value::<String>(v.clone()).ok())
}

/// Returns `(gross, fee)` where `fee` is the quote taken at the returned `gross`
/// — i.e. the fee the federation actually charges for that amount, not the fee
/// at `requested`. The two differ when the (step-valued) fee moves between
/// iterations; `fee` is the realized one, so callers can display it truthfully.
async fn solve_gross_for_net<F, Fut>(requested: u64, quote: F) -> anyhow::Result<(u64, u64)>
where
    F: Fn(Amount) -> Fut,
    Fut: std::future::Future<Output = anyhow::Result<FeeQuote>>,
{
    let mut gross = requested;
    let mut fee = 0;
    // 64 is a safety cap; convergence is normally reached in one or two steps
    // since the fee is tiny relative to the amount.
    for _ in 0..64 {
        fee = quote(Amount::from_msats(gross))
            .await?
            .total()
            .get_bitcoin()
            .msats;
        let next = requested.saturating_add(fee);
        if next <= gross {
            // `fee` is the quote at the current (returned) `gross`.
            break;
        }
        gross = next;
    }
    Ok((gross, fee))
}

/// Smallest invoice amount whose value, after the gateway's off-chain receive
/// fee is deducted, funds the on-federation contract with at least `contract`
/// msats. This inverts [`PaymentFee::subtract_from`], correcting the closed-form
/// estimate for integer-division rounding.
fn gross_invoice_for_contract(contract: u64, receive_fee: &PaymentFee) -> anyhow::Result<u64> {
    validate_receive_fee(receive_fee)?;

    let ppm = receive_fee.parts_per_million as f64;
    let base = receive_fee.base.msats;
    // invoice - (base + ppm * invoice / 1e6) = contract
    //   => invoice = (contract + base) / (1 - ppm / 1e6)
    let numerator = contract
        .checked_add(base)
        .ok_or_else(|| anyhow!("Gateway base fee of {base} msat overflows the contract amount"))?;
    let estimate = (numerator as f64 / (1.0 - ppm / 1_000_000.0)).ceil();
    // A ppm close to 100% drives the estimate past `u64`. `as u64` saturates
    // silently rather than wrapping, which would leave the walk below starting
    // at `u64::MAX` and overflowing on its first increment.
    if !estimate.is_finite() || estimate >= u64::MAX as f64 {
        bail!(
            "Gateway receive fee ({ppm} ppm, {base} msat base) makes the required \
             invoice amount too large to represent"
        );
    }
    let mut invoice = (estimate as u64).max(contract);

    // Walk up until the post-fee contract reaches `contract`, then back down to
    // the smallest invoice that still satisfies it.
    //
    // The closed form above is exact for this fee curve apart from
    // integer-division rounding, so both walks converge in a step or two. The
    // caps are a backstop: `receive_fee` comes straight from the gateway, and a
    // fee that does not behave the way the algebra assumes must not be able to
    // spin a tokio worker — there is no `.await` in either loop.
    let mut steps = 0u32;
    while receive_fee.subtract_from(invoice).msats < contract {
        invoice = invoice
            .checked_add(1)
            .ok_or_else(|| anyhow!("Gateway receive fee could not be inverted"))?;
        steps += 1;
        if steps > MAX_FEE_WALK_STEPS {
            bail!("Gateway receive fee did not converge to a payable invoice amount");
        }
    }
    steps = 0;
    while invoice > contract && receive_fee.subtract_from(invoice - 1).msats >= contract {
        invoice -= 1;
        steps += 1;
        if steps > MAX_FEE_WALK_STEPS {
            break;
        }
    }
    Ok(invoice)
}

/// Reject a gateway whose receive fee would swallow the entire payment.
///
/// [`PaymentFee::subtract_from`] saturates at zero, so at 1,000,000 ppm or more
/// the post-fee amount is always zero: no invoice can fund a non-zero contract.
/// The closed-form inversion is undefined there too — the divisor is exactly
/// zero at 100% and negative above it.
fn validate_receive_fee(receive_fee: &PaymentFee) -> anyhow::Result<()> {
    if receive_fee.parts_per_million >= MAX_GATEWAY_PPM {
        bail!(
            "Gateway receive fee of {} ppm would take the entire payment",
            receive_fee.parts_per_million
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use fedimint_lnv2_common::gateway_api::PaymentFee;

    use crate::multimint::{gross_invoice_for_contract, MAX_GATEWAY_PPM};

    fn payment_fee(base_msats: u64, ppm: u64) -> PaymentFee {
        PaymentFee {
            base: fedimint_core::Amount::from_msats(base_msats),
            parts_per_million: ppm,
        }
    }

    #[test]
    fn verify_gross_invoice_for_contract() {
        let fee = payment_fee(1_000, 5_000);

        // The invoice must fund the contract with at least its amount, ...
        let contract = 1_000_000;
        let invoice = gross_invoice_for_contract(contract, &fee).expect("solvable fee");
        assert!(fee.subtract_from(invoice).msats >= contract);
        // ... and be the smallest such invoice (one msat less falls short).
        assert!(fee.subtract_from(invoice - 1).msats < contract);

        // A zero-fee gateway (e.g. loopback) leaves the contract unchanged.
        let zero = payment_fee(0, 0);
        assert_eq!(
            gross_invoice_for_contract(contract, &zero).expect("solvable fee"),
            contract
        );
    }

    /// The H2 case. `subtract_from` saturates at zero, so at exactly 100% no
    /// invoice can ever satisfy the walk — it used to spin forever with no
    /// `.await`, pinning a tokio worker. The closed form is a divide by zero
    /// here too, and `f64::INFINITY as u64` saturates rather than wrapping, so
    /// the walk would have started at `u64::MAX`.
    #[test]
    fn gross_invoice_rejects_fee_at_one_hundred_percent() {
        let err = gross_invoice_for_contract(1_000_000, &payment_fee(0, MAX_GATEWAY_PPM))
            .expect_err("100% fee is not invertible");
        assert!(err.to_string().contains("entire payment"), "got: {err}");
    }

    #[test]
    fn gross_invoice_rejects_fee_above_one_hundred_percent() {
        let err = gross_invoice_for_contract(1_000_000, &payment_fee(0, MAX_GATEWAY_PPM + 1))
            .expect_err("over-100% fee is not invertible");
        assert!(err.to_string().contains("entire payment"), "got: {err}");
    }

    /// Just below the ceiling must still work — the guard bounds the hostile
    /// case without rejecting an expensive but legitimate gateway.
    #[test]
    fn gross_invoice_accepts_fee_just_below_the_ceiling() {
        let steep = payment_fee(0, MAX_GATEWAY_PPM - 1);
        let contract = 1_000;
        let invoice = gross_invoice_for_contract(contract, &steep).expect("solvable fee");
        assert!(steep.subtract_from(invoice).msats >= contract);
    }

    /// A gateway can also push the required invoice past `u64` with a large
    /// base fee rather than a large ppm.
    #[test]
    fn gross_invoice_rejects_unrepresentable_amount() {
        let err = gross_invoice_for_contract(u64::MAX, &payment_fee(u64::MAX, 0))
            .expect_err("overflowing base fee has no solution");
        assert!(
            err.to_string().contains("overflows") || err.to_string().contains("too large"),
            "got: {err}"
        );
    }
}
