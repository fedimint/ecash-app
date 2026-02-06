#![allow(unexpected_cfgs)]

mod db;
mod event_bus;
mod frb_generated;
mod multimint;
mod nostr;
mod words;
use bitcoin::key::rand::rngs::OsRng;
use bitcoin::key::rand::seq::SliceRandom;
use bitcoin::key::rand::Rng;
use bitcoin_payment_instructions::http_resolver::HTTPHrnResolver;
use bitcoin_payment_instructions::{
    PaymentInstructions, PaymentMethod, PossiblyResolvedPaymentMethod,
};
use db::SeedPhraseAckKey;
use event_bus::EventBus;
use fedimint_client::module::module::recovery::RecoveryProgress;
use fedimint_core::config::ClientConfig;
/* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use fedimint_wallet_client::PegOutFees;
use flutter_rust_bridge::frb;
use futures_util::StreamExt;
use multimint::{
    FederationMeta, FederationSelector, LightningSendOutcome, LogLevel, Multimint,
    MultimintCreation, MultimintEvent, PaymentPreview, Transaction, Utxo, WithdrawFeesResponse,
};
use nostr::{NWCConnectionInfo, NostrClient, PublicFederation};
use serde::Serialize;
use tokio::sync::{Mutex, OnceCell, RwLock};

use anyhow::{anyhow, bail, Context};
use fedimint_bip39::Language;
use fedimint_client::OperationId;
use fedimint_core::rustls::install_crypto_provider;
use fedimint_core::{
    config::FederationId, db::Database, encoding::Encodable, invite_code::InviteCode,
    util::SafeUrl, Amount,
};
use fedimint_lnv2_client::FinalReceiveOperationState;
use fedimint_mint_client::{OOBNotes, ReissueExternalNotesState, SpendOOBState};
use fedimint_rocksdb::RocksDb;
use lightning_invoice::Bolt11Invoice;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::{str::FromStr, sync::Arc};

use crate::db::{
    BitcoinDisplay, Contact, ContactCursor, FederationConfig, FederationConfigKey,
    FederationConfigKeyPrefix, FiatCurrency, LightningAddressConfig,
};
use crate::frb_generated::StreamSink;
use crate::multimint::{DepositEventKind, FedimintGateway, LNAddressStatus};
use crate::words::{ADJECTIVES, NOUNS};

static MULTIMINT: OnceCell<Multimint> = OnceCell::const_new();
static DATABASE: OnceCell<Database> = OnceCell::const_new();
static NOSTR: OnceCell<Arc<RwLock<NostrClient>>> = OnceCell::const_new();
static EVENT_BUS: OnceCell<EventBus<MultimintEvent>> = OnceCell::const_new();
static RECOVERY_RELAYS: OnceCell<Mutex<Vec<String>>> = OnceCell::const_new();

fn get_multimint() -> Multimint {
    MULTIMINT.get().expect("Multimint not initialized").clone()
}

async fn get_database(path: String) -> Database {
    DATABASE
        .get_or_init(|| async {
            let db_path = PathBuf::from_str(&path)
                .expect("Could not parse db path")
                .join("client.db");
            RocksDb::build(db_path)
                .open()
                .await
                .expect("Could not open database")
                .into()
        })
        .await
        .clone()
}

pub(crate) fn get_nostr_client() -> Arc<RwLock<NostrClient>> {
    NOSTR.get().expect("NostrClient not initialized").clone()
}

async fn get_recovery_relays() -> &'static Mutex<Vec<String>> {
    RECOVERY_RELAYS
        .get_or_init(|| async { Mutex::new(Vec::new()) })
        .await
}

async fn create_nostr_client(db: Database, is_desktop: bool) {
    let recovery_relays = get_recovery_relays().await.lock().await.clone();
    NOSTR
        .get_or_init(|| async {
            Arc::new(RwLock::new(
                NostrClient::new(db, recovery_relays, is_desktop)
                    .await
                    .expect("Could not create nostr client"),
            ))
        })
        .await;
}

pub fn get_event_bus() -> EventBus<MultimintEvent> {
    EVENT_BUS
        .get()
        .expect("EventBus is not initialized")
        .clone()
}

async fn create_event_bus() {
    EVENT_BUS
        .get_or_init(|| async { EventBus::new(100, 1000) })
        .await;
}

async fn info_to_flutter<T: Into<String>>(message: T) {
    get_event_bus()
        .publish(MultimintEvent::Log(LogLevel::Info, message.into()))
        .await;
}

async fn error_to_flutter<T: Into<String>>(message: T) {
    get_event_bus()
        .publish(MultimintEvent::Log(LogLevel::Error, message.into()))
        .await;
}

#[frb]
pub async fn add_recovery_relay(relay: String) {
    let mut relays = get_recovery_relays().await.lock().await;
    relays.push(relay);
}

#[frb]
pub async fn create_new_multimint(path: String, is_desktop: bool) {
    install_crypto_provider().await;
    create_event_bus().await;
    let db = get_database(path).await;
    MULTIMINT
        .get_or_init(|| async {
            Multimint::new(db.clone(), MultimintCreation::New)
                .await
                .expect("Could not create multimint")
        })
        .await;
    create_nostr_client(db, is_desktop).await;
}

#[frb]
pub async fn load_multimint(path: String, is_desktop: bool) {
    install_crypto_provider().await;
    create_event_bus().await;
    let db = get_database(path).await;
    MULTIMINT
        .get_or_init(|| async {
            Multimint::new(db.clone(), MultimintCreation::LoadExisting)
                .await
                .expect("Could not create multimint")
        })
        .await;
    create_nostr_client(db, is_desktop).await;
}

#[frb]
pub async fn create_multimint_from_words(path: String, words: Vec<String>, is_desktop: bool) {
    install_crypto_provider().await;
    create_event_bus().await;
    let db = get_database(path).await;
    MULTIMINT
        .get_or_init(|| async {
            Multimint::new(db.clone(), MultimintCreation::NewFromMnemonic { words })
                .await
                .expect("Could not create multimint")
        })
        .await;
    create_nostr_client(db, is_desktop).await;
}

#[frb]
pub async fn get_mnemonic() -> Vec<String> {
    let multimint = get_multimint();
    multimint.get_mnemonic()
}

#[frb]
pub async fn join_federation(
    invite_code: String,
    recover: bool,
) -> anyhow::Result<FederationSelector> {
    let mut multimint = get_multimint();
    multimint
        .join_federation(invite_code.clone(), recover)
        .await
}

#[frb]
pub async fn backup_invite_codes() -> anyhow::Result<()> {
    let multimint = get_multimint();
    let invite_codes = multimint.get_all_invite_codes().await;
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    nostr.backup_invite_codes(invite_codes).await
}

#[frb]
pub async fn rejoin_from_backup_invites() {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    let backup_invites = nostr.get_backup_invite_codes().await;
    let mut multimint = get_multimint();
    multimint.rejoin_from_backup_invites(backup_invites).await;
}

#[frb]
pub async fn federations() -> Vec<(FederationSelector, bool)> {
    let multimint = get_multimint();
    multimint.federations().await
}

#[frb]
pub async fn balance(federation_id: &FederationId) -> u64 {
    let multimint = get_multimint();
    multimint.balance(federation_id).await
}

#[frb]
pub async fn receive(
    federation_id: &FederationId,
    amount_msats_with_fees: u64,
    amount_msats_without_fees: u64,
    gateway: String,
    is_lnv2: bool,
) -> anyhow::Result<(String, OperationId, String, String, u64)> {
    let gateway = SafeUrl::parse(&gateway)?;
    let multimint = get_multimint();
    let (invoice, operation_id) = multimint
        .receive(
            federation_id,
            amount_msats_with_fees,
            amount_msats_without_fees,
            gateway,
            is_lnv2,
        )
        .await?;
    let pubkey = invoice.get_payee_pub_key();
    let payment_hash = invoice.payment_hash();
    let expiry = invoice.expiry_time().as_secs();
    Ok((
        invoice.to_string(),
        operation_id,
        pubkey.to_string(),
        payment_hash.to_string(),
        expiry,
    ))
}

#[frb]
pub async fn select_receive_gateway(
    federation_id: &FederationId,
    amount_msats: u64,
) -> anyhow::Result<(String, u64, bool)> {
    let amount = Amount::from_msats(amount_msats);
    let multimint = get_multimint();
    multimint
        .select_receive_gateway(federation_id, amount)
        .await
}

#[frb]
pub async fn get_invoice_from_lnaddress_or_lnurl(
    amount_msats: u64,
    lnaddress_or_lnurl: String,
) -> anyhow::Result<String> {
    let lnurl = match lnurl::lightning_address::LightningAddress::from_str(&lnaddress_or_lnurl) {
        Ok(lightning_address) => lightning_address.lnurl(),
        _ => lnurl::lnurl::LnUrl::from_str(&lnaddress_or_lnurl)?,
    };

    let async_client = lnurl::AsyncClient::from_client(reqwest::Client::new());
    let response = async_client.make_request(&lnurl.url).await?;
    match response {
        lnurl::LnUrlResponse::LnUrlPayResponse(response) => {
            let invoice = async_client
                .get_invoice(&response, amount_msats, None, None)
                .await?;

            let bolt11 = Bolt11Invoice::from_str(invoice.invoice())?;
            Ok(bolt11.to_string())
        }
        other => bail!("Unexpected response from lnurl: {other:?}"),
    }
}

#[frb]
pub async fn send_lnaddress(
    federation_id: &FederationId,
    amount_msats: u64,
    address: String,
) -> anyhow::Result<OperationId> {
    let lnurl = lnurl::lightning_address::LightningAddress::from_str(&address)?.lnurl();
    let async_client = lnurl::AsyncClient::from_client(reqwest::Client::new());
    let response = async_client.make_request(&lnurl.url).await?;
    match response {
        lnurl::LnUrlResponse::LnUrlPayResponse(response) => {
            let invoice = async_client
                .get_invoice(&response, amount_msats, None, None)
                .await?;

            let multimint = get_multimint();
            let bolt11 = Bolt11Invoice::from_str(invoice.invoice())?;
            let (gateway_url, amount_with_fees, is_lnv2) = multimint
                .select_send_gateway(
                    federation_id,
                    Amount::from_msats(amount_msats),
                    bolt11.clone(),
                )
                .await?;
            let gateway = SafeUrl::parse(&gateway_url)?;
            return multimint
                .send(
                    federation_id,
                    bolt11.to_string(),
                    gateway,
                    is_lnv2,
                    amount_with_fees,
                    Some(address),
                )
                .await;
        }
        other => bail!("Unexpected response from lnurl: {other:?}"),
    }
}

#[frb]
pub async fn send(
    federation_id: &FederationId,
    invoice: String,
    gateway: String,
    is_lnv2: bool,
    amount_with_fees: u64,
    ln_address: Option<String>,
) -> anyhow::Result<OperationId> {
    let multimint = get_multimint();
    let gateway = SafeUrl::parse(&gateway)?;
    multimint
        .send(
            federation_id,
            invoice,
            gateway,
            is_lnv2,
            amount_with_fees,
            ln_address,
        )
        .await
}

#[frb]
pub async fn await_send(
    federation_id: &FederationId,
    operation_id: OperationId,
) -> LightningSendOutcome {
    let multimint = get_multimint();
    multimint.await_send(federation_id, operation_id).await
}

#[frb]
pub async fn await_receive(
    federation_id: &FederationId,
    operation_id: OperationId,
) -> anyhow::Result<(FinalReceiveOperationState, u64)> {
    let multimint = get_multimint();
    multimint.await_receive(federation_id, operation_id).await
}

#[frb]
pub async fn list_federations_from_nostr(force_update: bool) -> Vec<PublicFederation> {
    let nostr_client = get_nostr_client();
    let mut nostr = nostr_client.write().await;

    let multimint = get_multimint();

    let public_federations = nostr.get_public_federations(force_update).await;

    let mut joinable_federations = Vec::new();
    for pub_fed in public_federations {
        if !multimint.contains_client(&pub_fed.federation_id).await {
            joinable_federations.push(pub_fed);
        }
    }

    joinable_federations
}

#[frb]
pub async fn payment_preview(
    federation_id: &FederationId,
    bolt11: String,
) -> anyhow::Result<PaymentPreview> {
    let invoice = Bolt11Invoice::from_str(&bolt11)?;
    let amount_msats = invoice
        .amount_milli_satoshis()
        .expect("No amount specified");
    let payment_hash = invoice.payment_hash().consensus_encode_to_hex();
    let network = invoice.network().to_string();

    let multimint = get_multimint();
    let (gateway, amount_with_fees, is_lnv2) = multimint
        .select_send_gateway(federation_id, Amount::from_msats(amount_msats), invoice)
        .await?;

    Ok(PaymentPreview {
        amount_msats,
        payment_hash,
        network,
        invoice: bolt11,
        gateway,
        amount_with_fees,
        is_lnv2,
    })
}

#[frb]
pub async fn get_federation_meta(
    invite_code: Option<String>,
    federation_id: Option<FederationId>,
) -> anyhow::Result<FederationMeta> {
    let multimint = get_multimint();
    multimint
        .get_cached_federation_meta(invite_code, federation_id)
        .await
}

#[frb]
pub async fn transactions(
    federation_id: &FederationId,
    timestamp: Option<u64>,
    operation_id: Option<Vec<u8>>,
    modules: Vec<String>,
) -> Vec<Transaction> {
    let multimint = get_multimint();
    multimint
        .transactions(federation_id, timestamp, operation_id, modules)
        .await
}

#[frb]
pub async fn send_ecash(
    federation_id: &FederationId,
    amount_msats: u64,
) -> anyhow::Result<(OperationId, String, u64)> {
    let multimint = get_multimint();
    multimint.send_ecash(federation_id, amount_msats).await
}

async fn parse_ecash(federation_id: &FederationId, notes: &OOBNotes) -> anyhow::Result<u64> {
    let multimint = get_multimint();
    multimint.parse_ecash(federation_id, notes).await
}

#[frb]
pub async fn reissue_ecash(
    federation_id: &FederationId,
    ecash: String,
) -> anyhow::Result<OperationId> {
    let multimint = get_multimint();
    multimint.reissue_ecash(federation_id, ecash).await
}

#[frb]
pub async fn await_ecash_reissue(
    federation_id: &FederationId,
    operation_id: OperationId,
) -> anyhow::Result<(ReissueExternalNotesState, Option<u64>)> {
    let multimint = get_multimint();
    multimint
        .await_ecash_reissue(federation_id, operation_id)
        .await
}

#[frb]
pub async fn has_seed_phrase_ack() -> bool {
    let multimint = get_multimint();
    multimint.has_seed_phrase_ack().await
}

#[frb]
pub async fn ack_seed_phrase() {
    let multimint = get_multimint();
    multimint.ack_seed_phrase().await
}

#[frb]
pub async fn word_list() -> Vec<String> {
    Language::English
        .word_list()
        .iter()
        .map(|s| s.to_string())
        .collect()
}

#[frb]
pub async fn subscribe_deposits(sink: StreamSink<DepositEventKind>, federation_id: FederationId) {
    let event_bus = get_event_bus();
    let mut stream = event_bus.subscribe();

    while let Some(evt) = stream.next().await {
        if let MultimintEvent::Deposit((evt_fed_id, deposit)) = evt {
            if evt_fed_id == federation_id {
                if sink.add(deposit).is_err() {
                    break;
                }
            }
        }
    }
}

#[frb]
pub async fn allocate_deposit_address(federation_id: FederationId) -> anyhow::Result<String> {
    let multimint = get_multimint();
    multimint.allocate_deposit_address(federation_id).await
}

#[frb]
pub async fn get_pegin_fee(federation_id: FederationId) -> anyhow::Result<u64> {
    let multimint = get_multimint();
    multimint.get_pegin_fee(&federation_id).await
}

#[frb]
pub async fn get_nwc_connection_info() -> Vec<(FederationSelector, NWCConnectionInfo)> {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    nostr.get_nwc_connection_info().await
}

#[frb]
pub async fn set_nwc_connection_info(
    federation_id: FederationId,
    relay: String,
    is_desktop: bool,
) -> NWCConnectionInfo {
    let nostr_client = get_nostr_client();
    let mut nostr = nostr_client.write().await;
    nostr
        .set_nwc_connection_info(federation_id, relay, is_desktop)
        .await
}

#[frb]
pub async fn remove_nwc_connection_info(federation_id: FederationId) {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    nostr.remove_nwc_connection_info(federation_id).await;
}

/// Blocking NWC listener that runs until the connection is closed.
/// This is called directly from the foreground task.
/// Takes a string federation_id for easier passing from Dart foreground task.
#[frb]
pub async fn listen_for_nwc_blocking(federation_id_str: String) -> anyhow::Result<()> {
    info_to_flutter(format!(
        "[NWC] listen_for_nwc_blocking called with federation: {federation_id_str}"
    ))
    .await;
    let federation_id = FederationId::from_str(&federation_id_str)?;

    // Get or create the NWC config, then drop the lock before blocking
    let nwc_config = {
        let nostr_client = get_nostr_client();
        let nostr = nostr_client.read().await;
        let (nwc_config, _connection_info) = nostr.get_nwc_config(federation_id).await?;
        nwc_config
        // Read lock is dropped here when `nostr` goes out of scope
    };

    // Start listening (this blocks until the connection is closed)
    nostr::NostrClient::listen_for_nwc(&federation_id, nwc_config).await;
    Ok(())
}

#[frb]
pub async fn get_relays() -> Vec<(String, bool)> {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    nostr.get_relays().await
}

#[frb]
pub async fn wallet_summary(
    invite: Option<String>,
    federation_id: Option<FederationId>,
) -> anyhow::Result<Vec<Utxo>> {
    let multimint = get_multimint();
    multimint.wallet_summary(invite, federation_id).await
}

#[frb]
pub async fn subscribe_multimint_events(sink: StreamSink<MultimintEvent>) {
    let event_bus = get_event_bus();
    let mut stream = event_bus.subscribe();

    while let Some(mm_event) = stream.next().await {
        if sink.add(mm_event).is_err() {
            break;
        }
    }
}

#[frb]
pub async fn federation_id_to_string(federation_id: FederationId) -> String {
    federation_id.to_string()
}

#[frb]
pub async fn get_btc_price() -> Option<u64> {
    let multimint = get_multimint();
    multimint.get_btc_price().await
}

#[frb]
pub async fn calculate_withdraw_fees(
    federation_id: &FederationId,
    address: String,
    amount_sats: u64,
) -> anyhow::Result<WithdrawFeesResponse> {
    let multimint = get_multimint();
    multimint
        .calculate_withdraw_fees(federation_id, address, amount_sats)
        .await
}

#[frb]
pub async fn withdraw_to_address(
    federation_id: &FederationId,
    address: String,
    amount_sats: u64,
    peg_out_fees: PegOutFees,
) -> anyhow::Result<OperationId> {
    let multimint = get_multimint();
    multimint
        .withdraw_to_address(federation_id, address, amount_sats, peg_out_fees)
        .await
}

#[frb]
pub async fn await_withdraw(
    federation_id: &FederationId,
    operation_id: OperationId,
) -> anyhow::Result<String> {
    let multimint = get_multimint();
    multimint.await_withdraw(federation_id, operation_id).await
}

#[frb]
pub async fn get_max_withdrawable_amount(
    federation_id: &FederationId,
    address: String,
) -> anyhow::Result<u64> {
    let multimint = get_multimint();
    multimint
        .get_max_withdrawable_amount(federation_id, address)
        .await
}

#[frb]
pub async fn get_module_recovery_progress(
    federation_id: &FederationId,
    module_id: u16,
) -> (u32, u32) {
    let multimint = get_multimint();
    let progress = multimint
        .get_recovery_progress(federation_id, module_id)
        .await;
    (progress.complete, progress.total)
}

#[frb]
pub async fn subscribe_recovery_progress(
    sink: StreamSink<(u32, u32)>,
    federation_id: FederationId,
    module_id: u16,
) {
    let event_bus = get_event_bus();
    let mut stream = event_bus.subscribe();

    while let Some(evt) = stream.next().await {
        if let MultimintEvent::RecoveryProgress(evt_fed_id, evt_module_id, complete, total) = evt {
            let event_federation_id =
                FederationId::from_str(&evt_fed_id).expect("Could not parse FederationId");
            if event_federation_id == federation_id && evt_module_id == module_id {
                if sink.add((complete, total)).is_err() {
                    break;
                }
            }
        }
    }
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub enum ParsedText {
    InviteCode(String),
    InviteCodeWithEcash(String, String),
    LightningInvoice(String),
    BitcoinAddress(String, Option<u64>),
    Ecash(u64),
    LightningAddressOrLnurl(String),
    EcashNoFederation,
}

#[frb]
pub async fn parse_scanned_text_for_federation(
    text: String,
    federation: &FederationSelector,
) -> anyhow::Result<(ParsedText, FederationSelector)> {
    let network =
        bitcoin::Network::from_str(&federation.network.clone().ok_or(anyhow!("No network"))?)?;

    let instructions = bitcoin_payment_instructions::PaymentInstructions::parse(
        &text,
        network,
        &HTTPHrnResolver,
        false,
    )
    .await;

    match instructions {
        Ok(instructions) => {
            if let Ok((parsed_text, fed)) =
                handle_parsed_payment_instructions(&federation, &instructions, text.clone()).await
            {
                return Ok((parsed_text, fed));
            }

            return Err(anyhow!("No federation found with sufficient balance"));
        }
        Err(e) => {
            error_to_flutter(format!("Error parsing payment instructions: {e:?}")).await;
        }
    }

    if lnurl::lnurl::LnUrl::from_str(&text).is_ok() {
        return Ok((
            ParsedText::LightningAddressOrLnurl(text),
            federation.clone(),
        ));
    }

    if let Ok(notes) = OOBNotes::from_str(&text) {
        if let Ok(amount) = parse_ecash(&federation.federation_id, &notes).await {
            return Ok((ParsedText::Ecash(amount), federation.clone()));
        }
    }

    Err(anyhow!("Payment method not supported"))
}

#[frb]
pub async fn parsed_scanned_text(
    text: String,
) -> anyhow::Result<(ParsedText, Option<FederationSelector>)> {
    // First try to parse as a federation invite code
    if InviteCode::from_str(&text).is_ok() {
        return Ok((ParsedText::InviteCode(text), None));
    }

    // Next try to parse the text as LN or Bitcoin payment instructions
    // We need to loop over all networks and find the first federation that has a sufficient balance
    let all_federations = federations().await;
    let group_by_network: BTreeMap<bitcoin::Network, Vec<FederationSelector>> = all_federations
        .clone()
        .into_iter()
        .fold(BTreeMap::new(), |mut acc, (selector, _flag)| {
            acc.entry(
                bitcoin::Network::from_str(&selector.network.clone().expect("Invalid network"))
                    .expect("Could not convert network"),
            )
            .or_default()
            .push(selector);
            acc
        });

    for (network, federations) in group_by_network.iter() {
        let instructions = bitcoin_payment_instructions::PaymentInstructions::parse(
            &text,
            *network,
            &HTTPHrnResolver,
            false,
        )
        .await;
        match instructions {
            Ok(instructions) => {
                // Find the first federation that has a sufficient balance
                for fed in federations {
                    if let Ok((parsed_text, fed)) =
                        handle_parsed_payment_instructions(&fed, &instructions, text.clone()).await
                    {
                        return Ok((parsed_text, Some(fed)));
                    }
                }

                return Err(anyhow!("No federation found with sufficient balance"));
            }
            Err(e) => {
                error_to_flutter(format!(
                    "Error when trying to parse payment instructions: {e:?}"
                ))
                .await;
            }
        }
    }

    if lnurl::lnurl::LnUrl::from_str(&text).is_ok() {
        // get a test invoice so we can determine the network
        let invoice = get_invoice_from_lnaddress_or_lnurl(1, text.clone()).await?;
        let bolt11 = Bolt11Invoice::from_str(&invoice)?;
        let network = bolt11.network();
        if let Some(feds) = group_by_network.get(&network) {
            if let Some(fed) = feds.first() {
                return Ok((ParsedText::LightningAddressOrLnurl(text), Some(fed.clone())));
            }
        }
    }

    // Try to find a federation that can parse the ecash
    if let Ok(notes) = OOBNotes::from_str(&text) {
        for (federation, _) in all_federations {
            if let Ok(amount) = parse_ecash(&federation.federation_id, &notes).await {
                return Ok((ParsedText::Ecash(amount), Some(federation)));
            }
        }

        // If none of our joined federation's can parse the ecash, lets prompt the user to join
        if let Some(invite_code) = notes.federation_invite() {
            return Ok((
                ParsedText::InviteCodeWithEcash(invite_code.to_string(), text),
                None,
            ));
        }

        return Ok((ParsedText::EcashNoFederation, None));
    }

    Err(anyhow!("Payment method not supported"))
}

async fn handle_parsed_payment_instructions(
    fed: &FederationSelector,
    instructions: &PaymentInstructions,
    text: String,
) -> anyhow::Result<(ParsedText, FederationSelector)> {
    match &instructions {
        // We currently only support Bitcoin addresses for configurable amounts
        PaymentInstructions::ConfigurableAmount(configurable) => {
            for method in configurable.methods() {
                match method {
                    PossiblyResolvedPaymentMethod::Resolved(resolved) => {
                        if let PaymentMethod::OnChain(address) = resolved {
                            return Ok((
                                ParsedText::BitcoinAddress(address.to_string(), None),
                                fed.clone(),
                            ));
                        }
                    }
                    PossiblyResolvedPaymentMethod::LNURLPay {
                        min_value: _,
                        max_value: _,
                        callback: _,
                    } => {
                        return Ok((ParsedText::LightningAddressOrLnurl(text), fed.clone()));
                    }
                }
            }
        }
        PaymentInstructions::FixedAmount(fixed) => {
            let balance = balance(&fed.federation_id).await;
            // Find a payment method that we support
            let mut found_payment_method = None;
            for method in fixed.methods() {
                match method {
                    PaymentMethod::LightningBolt11(invoice) => {
                        // Verify that the federation's balance is sufficient to pay the invoice
                        if let Some(lightning_amount) = fixed.ln_payment_amount() {
                            if balance >= lightning_amount.milli_sats() {
                                found_payment_method = Some((
                                    ParsedText::LightningInvoice(invoice.to_string()),
                                    fed.clone(),
                                ));
                            }
                        }
                    }
                    PaymentMethod::OnChain(address) => {
                        // Verify that the federation's balance is sufficient to pay the onchain address
                        if let Some(onchain_amount) = fixed.onchain_payment_amount() {
                            if balance >= onchain_amount.milli_sats() {
                                // Prefer using Lightning if its available
                                if found_payment_method.is_none() {
                                    found_payment_method = Some((
                                        ParsedText::BitcoinAddress(
                                            address.to_string(),
                                            Some(onchain_amount.milli_sats()),
                                        ),
                                        fed.clone(),
                                    ));
                                }
                            }
                        }
                    }
                    method => {
                        info_to_flutter(format!("Payment method not supported: {:?}", method))
                            .await;
                    }
                }
            }

            if let Some(payment_method) = found_payment_method {
                return Ok(payment_method);
            }
        }
    }

    Err(anyhow!("Cannot find payment method"))
}

#[frb]
pub async fn insert_relay(relay_uri: String) -> anyhow::Result<()> {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    nostr.insert_relay(relay_uri).await
}

#[frb]
pub async fn remove_relay(relay_uri: String) -> anyhow::Result<()> {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    nostr.remove_relay(relay_uri).await
}

#[frb]
pub async fn get_addresses(federation_id: &FederationId) -> Vec<(String, u64, Option<u64>)> {
    let multimint = get_multimint();
    multimint.get_addresses(federation_id).await
}

#[frb]
pub async fn recheck_address(federation_id: &FederationId, tweak_idx: u64) -> anyhow::Result<()> {
    let multimint = get_multimint();
    multimint.recheck_address(federation_id, tweak_idx).await
}

#[frb]
pub async fn get_note_summary(federation_id: &FederationId) -> anyhow::Result<Vec<(u64, usize)>> {
    let multimint = get_multimint();
    multimint.get_note_summary(federation_id).await
}

#[frb]
pub async fn list_gateways(federation_id: &FederationId) -> anyhow::Result<Vec<FedimintGateway>> {
    let multimint = get_multimint();
    multimint.list_gateways(federation_id).await
}

#[frb]
pub async fn check_ecash_spent(
    federation_id: &FederationId,
    ecash: String,
) -> anyhow::Result<bool> {
    let multimint = get_multimint();
    multimint.check_ecash_spent(federation_id, ecash).await
}

#[frb]
pub async fn list_ln_address_domains(ln_address_api: String) -> anyhow::Result<Vec<String>> {
    let safe_ln_address_api = SafeUrl::parse(&ln_address_api)?.join("domains")?;
    let http_client = reqwest::Client::new();
    let url = safe_ln_address_api.to_unsafe();
    let result = http_client
        .get(url)
        .send()
        .await
        .context("Failed to send domains request")?;

    let domains = result.json::<Vec<String>>().await?;
    Ok(domains)
}

#[frb]
pub async fn get_ln_address_config(federation_id: &FederationId) -> Option<LightningAddressConfig> {
    let multimint = get_multimint();
    multimint.get_ln_address_config(federation_id).await
}

#[frb]
pub async fn check_ln_address_availability(
    username: String,
    domain: String,
    ln_address_api: String,
    recurringd_api: String,
    federation_id: &FederationId,
) -> anyhow::Result<LNAddressStatus> {
    let multimint = get_multimint();
    multimint
        .check_ln_address_availability(
            username,
            domain,
            ln_address_api,
            recurringd_api,
            federation_id,
        )
        .await
}

#[frb]
pub async fn register_ln_address(
    federation_id: &FederationId,
    recurringd_api: String,
    ln_address_api: String,
    username: String,
    domain: String,
) -> anyhow::Result<()> {
    let multimint = get_multimint();
    multimint
        .register_ln_address(
            federation_id,
            recurringd_api,
            ln_address_api,
            username,
            domain,
        )
        .await
}

#[frb]
pub async fn get_invite_code(federation_id: &FederationId, peer: u16) -> anyhow::Result<String> {
    let multimint = get_multimint();
    multimint.get_invite_code(federation_id, peer).await
}

#[frb]
pub async fn get_bitcoin_display() -> BitcoinDisplay {
    let multimint = get_multimint();
    multimint.get_bitcoin_display().await
}

#[frb]
pub async fn set_bitcoin_display(bitcoin_display: BitcoinDisplay) {
    let multimint = get_multimint();
    multimint.set_bitcoin_display(bitcoin_display).await;
}

#[frb]
pub async fn get_fiat_currency() -> FiatCurrency {
    let multimint = get_multimint();
    multimint.get_fiat_currency().await
}

#[frb]
pub async fn set_fiat_currency(fiat_currency: FiatCurrency) {
    let multimint = get_multimint();
    multimint.set_fiat_currency(fiat_currency).await;
}

#[frb]
pub async fn get_all_btc_prices() -> Option<Vec<(FiatCurrency, u64)>> {
    let multimint = get_multimint();
    multimint.get_all_btc_prices().await
}

#[frb]
pub async fn get_federation_order() -> Option<Vec<FederationId>> {
    let multimint = get_multimint();
    multimint.get_federation_order().await
}

#[frb]
pub async fn set_federation_order(order: Vec<FederationId>) {
    let multimint = get_multimint();
    multimint.set_federation_order(order).await;
}

#[frb]
pub async fn claim_random_ln_address(
    federation_id: &FederationId,
    ln_address_api: String,
    recurringd_api: String,
) -> anyhow::Result<(String, String)> {
    let mut rng = OsRng;
    let domains = list_ln_address_domains(ln_address_api.clone()).await?;
    loop {
        let domain = domains
            .choose(&mut rng)
            .ok_or(anyhow!("No domains available"))?;
        let adjective = ADJECTIVES
            .choose(&mut rng)
            .ok_or(anyhow!("No adjectives"))?;
        let noun = NOUNS.choose(&mut rng).ok_or(anyhow!("No nouns"))?;
        let number: u32 = rng.gen_range(1..=99999);

        let username = format!("{adjective}{noun}{number}");
        let availability = check_ln_address_availability(
            username.clone(),
            domain.clone(),
            ln_address_api.clone(),
            recurringd_api.clone(),
            federation_id,
        )
        .await?;

        match availability {
            LNAddressStatus::Available => {
                register_ln_address(
                    federation_id,
                    recurringd_api.clone(),
                    ln_address_api.clone(),
                    username.clone(),
                    domain.clone(),
                )
                .await?;
                return Ok((username, domain.clone()));
            }
            LNAddressStatus::UnsupportedFederation => {
                return Err(anyhow!("Unsupported federation"))
            }
            LNAddressStatus::CurrentConfig => {
                return Ok((username, domain.clone()));
            }
            _ => {
                info_to_flutter(format!(
                    "Could not claim {username}@{domain} Trying again..."
                ))
                .await;
            }
        }
    }
}

#[frb]
pub async fn leave_federation(federation_id: &FederationId) {
    let mut multimint = get_multimint();
    multimint.leave_federation(federation_id).await;
}

// === Contact Address Book Functions ===

/// Verify a NIP-05 identifier and return the associated npub
#[frb]
pub async fn verify_nip05(nip05_id: String) -> anyhow::Result<String> {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    nostr.verify_nip05(&nip05_id).await
}

/// Check if contacts have been imported (first-time flag)
#[frb]
pub async fn has_imported_contacts() -> bool {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    nostr.has_imported_contacts().await
}

/// Starts contact sync
#[frb]
pub async fn sync_contacts(npub: String) {
    let nostr_client = get_nostr_client();
    // Use write lock in case background thread is also syncing
    let nostr = nostr_client.write().await;
    nostr.set_contact_sync_config(npub, true).await;
    nostr.sync_contacts().await;
}

/// Clear all contacts and stop syncing
#[frb]
pub async fn clear_contacts_and_stop_sync() -> usize {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    nostr.clear_contacts_and_stop_sync().await
}

/// Get all contacts, sorted by last_paid_at (recent first)
#[frb]
pub async fn get_all_contacts() -> Vec<Contact> {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;
    nostr.get_all_contacts().await
}

/// Get paginated contacts with cursor-based pagination
#[frb]
pub async fn paginate_contacts(
    cursor_last_paid_at: Option<u64>,
    cursor_created_at: Option<u64>,
    cursor_npub: Option<String>,
    limit: u32,
) -> Vec<Contact> {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;

    let cursor = if let (Some(created_at), Some(npub)) = (cursor_created_at, cursor_npub) {
        Some(ContactCursor {
            last_paid_at: cursor_last_paid_at,
            created_at,
            npub,
        })
    } else {
        None
    };

    nostr.paginate_contacts(cursor, limit as usize).await
}

/// Search contacts with pagination
#[frb]
pub async fn paginate_search_contacts(
    query: String,
    cursor_last_paid_at: Option<u64>,
    cursor_created_at: Option<u64>,
    cursor_npub: Option<String>,
    limit: u32,
) -> Vec<Contact> {
    let nostr_client = get_nostr_client();
    let nostr = nostr_client.read().await;

    let cursor = if let (Some(created_at), Some(npub)) = (cursor_created_at, cursor_npub) {
        Some(ContactCursor {
            last_paid_at: cursor_last_paid_at,
            created_at,
            npub,
        })
    } else {
        None
    };

    nostr
        .paginate_search_contacts(&query, cursor, limit as usize)
        .await
}
