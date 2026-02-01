use nostr_sdk::ToBech32;
use std::{
    collections::{BTreeMap, HashSet},
    str::FromStr,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crate::{
    anyhow, await_send, balance,
    db::{
        Contact, ContactCursor, ContactKey, ContactKeyPrefix, ContactPayment,
        ContactPaymentByNpubPrefix, ContactPaymentKey, ContactSyncConfig, ContactSyncConfigKey,
        ContactsImportedKey, NostrRelaysKey, NostrRelaysKeyPrefix, NostrWalletConnectConfig,
        NostrWalletConnectKey, NostrWalletConnectKeyPrefix,
    },
    error_to_flutter, federations, get_event_bus, info_to_flutter,
    multimint::{ContactSyncEventKind, FederationSelector, LightningSendOutcome, MultimintEvent},
    payment_preview, send,
};
use anyhow::bail;
use bitcoin::Network;
use fedimint_bip39::{Bip39RootSecretStrategy, Mnemonic};
use fedimint_client::{secret::RootSecretStrategy, Client};
use fedimint_core::{
    config::FederationId,
    db::{Database, IDatabaseTransactionOpsCoreTyped},
    encoding::Encodable,
    invite_code::InviteCode,
    task::TaskGroup,
    util::{retry, FmtCompact, SafeUrl},
};
use fedimint_derive_secret::ChildId;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::{
    sync::{oneshot, RwLock},
    time::Instant,
};

pub const DEFAULT_RELAYS: &[&str] = &[
    "wss://nostr.bitcoiner.social",
    "wss://relay.nostr.band",
    "wss://relay.damus.io",
    "wss://nostr.zebedee.cloud",
    "wss://relay.plebstr.com",
    "wss://relayer.fiatjaf.com",
    "wss://nostr-01.bolt.observer",
    "wss://nostr-relay.wlvs.space",
    "wss://relay.nostr.info",
    "wss://nostr-pub.wellorder.net",
    "wss://nostr1.tunnelsats.com",
];

pub const NWC_SUPPORTED_METHODS: &[&str] = &["get_info", "get_balance", "pay_invoice"];

#[derive(Debug, Deserialize)]
#[serde(tag = "method", content = "params")]
pub enum WalletConnectRequest {
    #[serde(rename = "pay_invoice")]
    PayInvoice { invoice: String },

    #[serde(rename = "get_balance")]
    GetBalance {},

    #[serde(rename = "get_info")]
    GetInfo {},
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "result_type", content = "result")]
pub enum WalletConnectResponse {
    #[serde(rename = "get_info")]
    GetInfo {
        network: String,
        methods: Vec<String>,
    },

    #[serde(rename = "get_balance")]
    GetBalance { balance: u64 },

    #[serde(rename = "pay_invoice")]
    PayInvoice { preimage: String },
}

#[derive(Clone)]
pub(crate) struct NostrClient {
    nostr_client: nostr_sdk::Client,
    public_federations: Arc<RwLock<Vec<PublicFederation>>>,
    task_group: TaskGroup,
    db: Database,
    keys: nostr_sdk::Keys,
    nwc_listeners: Arc<RwLock<BTreeMap<FederationId, oneshot::Sender<()>>>>,
}

impl NostrClient {
    pub async fn new(
        db: Database,
        recover_relays: Vec<String>,
        is_desktop: bool,
    ) -> anyhow::Result<NostrClient> {
        let start = Instant::now();
        // We need to derive a Nostr key from the Fedimint secret.
        // Currently we are using 1/0 as the derivation path, as it does not clash with anything used internally in
        // Fedimint.
        let entropy = Client::load_decodable_client_secret::<Vec<u8>>(&db).await?;
        let mnemonic = Mnemonic::from_entropy(&entropy)?;
        let global_root_secret = Bip39RootSecretStrategy::<12>::to_root_secret(&mnemonic);
        let nostr_root_secret = global_root_secret.child_key(ChildId(1));
        let nostr_key_secret = nostr_root_secret.child_key(ChildId(0));
        let keypair = nostr_key_secret.to_secp_key(fedimint_core::secp256k1::SECP256K1);
        let keys = nostr_sdk::Keys::new(keypair.secret_key().into());

        let client = nostr_sdk::Client::builder().signer(keys.clone()).build();

        let mut nostr_client = NostrClient {
            nostr_client: client,
            public_federations: Arc::new(RwLock::new(vec![])),
            task_group: TaskGroup::new(),
            db: db.clone(),
            keys,
            nwc_listeners: Arc::new(RwLock::new(BTreeMap::new())),
        };

        let mut background_nostr = nostr_client.clone();
        nostr_client
            .task_group
            .spawn_cancellable("update nostr feds", async move {
                info_to_flutter("Initializing Nostr relays...").await;
                background_nostr.add_relays_from_db(recover_relays).await;

                info_to_flutter("Updating federations from nostr in the background...").await;
                background_nostr.update_federations_from_nostr().await;
            });

        // On desktop, we need to spawn the background listener for NWC
        if is_desktop {
            let mut dbtx = db.begin_transaction_nc().await;
            let federation_configs = dbtx
                .find_by_prefix(&NostrWalletConnectKeyPrefix)
                .await
                .collect::<Vec<_>>()
                .await;
            for (key, nwc_config) in federation_configs {
                nostr_client
                    .spawn_listen_for_nwc(&key.federation_id, nwc_config)
                    .await;
            }
        }

        info_to_flutter(format!("Initialized Nostr client in {:?}", start.elapsed())).await;
        Ok(nostr_client)
    }

    async fn add_relays_from_db(&self, mut recover_relays: Vec<String>) {
        info_to_flutter(format!("Recovery relays: {:?}", recover_relays)).await;
        let mut relays = Self::get_or_insert_default_relays(self.db.clone()).await;
        recover_relays.append(&mut relays);

        for relay in recover_relays {
            match self.nostr_client.add_relay(relay.as_str()).await {
                Ok(added) => {
                    if added {
                        info_to_flutter(format!("Successfully added relay: {relay}")).await;
                    }
                }
                Err(err) => {
                    error_to_flutter(format!(
                        "Could not add relay {}: {}",
                        relay,
                        err.fmt_compact()
                    ))
                    .await;
                }
            }
        }
    }

    pub async fn insert_relay(&self, relay_uri: String) -> anyhow::Result<()> {
        let added = self.nostr_client.add_relay(relay_uri.clone()).await?;
        if !added {
            bail!("Relay already added");
        }

        let Ok(relay) = self.nostr_client.relay(relay_uri.clone()).await else {
            bail!("Could not get relay");
        };

        relay.connect();
        relay.wait_for_connection(Duration::from_secs(15)).await;

        let status = relay.status();
        match status {
            nostr_sdk::RelayStatus::Connected => {
                info_to_flutter(format!("Connected to relay {}", relay_uri.clone())).await;

                let mut dbtx = self.db.begin_transaction().await;
                dbtx.insert_entry(&NostrRelaysKey { uri: relay_uri }, &SystemTime::now())
                    .await;
                dbtx.commit_tx().await;

                Ok(())
            }
            status => Err(anyhow!("Could not connect to relay: {status:?}")),
        }
    }

    pub async fn remove_relay(&self, relay_uri: String) -> anyhow::Result<()> {
        self.nostr_client.remove_relay(relay_uri.clone()).await?;
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.remove_entry(&NostrRelaysKey { uri: relay_uri }).await;
        dbtx.commit_tx().await;

        Ok(())
    }

    async fn get_or_insert_default_relays(db: Database) -> Vec<String> {
        let mut dbtx = db.begin_transaction().await;
        let relays = dbtx
            .find_by_prefix(&NostrRelaysKeyPrefix)
            .await
            .map(|(k, _)| k.uri)
            .collect::<Vec<_>>()
            .await;
        if !relays.is_empty() {
            return relays;
        }

        for relay in DEFAULT_RELAYS {
            dbtx.insert_new_entry(
                &NostrRelaysKey {
                    uri: relay.to_string(),
                },
                &SystemTime::now(),
            )
            .await;
        }
        dbtx.commit_tx().await;
        DEFAULT_RELAYS.iter().map(|s| s.to_string()).collect()
    }

    async fn broadcast_nwc_info(nostr_client: &nostr_sdk::Client, federation_id: &FederationId) {
        let supported_methods = NWC_SUPPORTED_METHODS.join(" ");
        let event_builder =
            nostr_sdk::EventBuilder::new(nostr_sdk::Kind::WalletConnectInfo, supported_methods);
        match nostr_client.send_event_builder(event_builder).await {
            Ok(event_id) => {
                let hexid = event_id.to_hex();
                let success = event_id.success;
                let failed = event_id.failed;
                info_to_flutter(format!("FederationId: {federation_id} Successfully broadcasted WalletConnectInfo: {hexid} Success: {success:?} Failed: {failed:?}")).await;
            }
            Err(e) => {
                info_to_flutter(format!("Error sending WalletConnectInfo event: {e:?}")).await;
            }
        }
    }

    async fn spawn_listen_for_nwc(
        &mut self,
        federation_id: &FederationId,
        nwc_config: NostrWalletConnectConfig,
    ) {
        let mut listeners = self.nwc_listeners.write().await;
        if let Some(listener) = listeners.remove(federation_id) {
            info_to_flutter("Sending shutdown signal to previous listening thread").await;
            let _ = listener.send(());
        }
        let (sender, mut receiver) = oneshot::channel::<()>();
        listeners.insert(*federation_id, sender);
        let federation_id = *federation_id;
        self.task_group.spawn_cancellable("desktop nostr wallet connected", async move {
            tokio::select! {
                _ = &mut receiver => {
                    info_to_flutter(format!("Received shutdown signal for {federation_id}")).await;
                }
                _ = Self::listen_for_nwc(&federation_id, nwc_config) => {
                    info_to_flutter(format!("Stopped listening for NWC for {federation_id}")).await;
                }
            }
        });
    }

    /// Blocking NWC listener - runs until the relay connection is closed or an error occurs.
    /// This function is intended to be called directly from the foreground task.
    pub async fn listen_for_nwc(
        federation_id: &FederationId,
        nwc_config: NostrWalletConnectConfig,
    ) {
        let secret_key = nostr_sdk::SecretKey::from_slice(&nwc_config.secret_key)
            .expect("Could not create secret key");
        let keys =
            nostr_sdk::Keys::new_with_ctx(fedimint_core::secp256k1::SECP256K1, secret_key.clone());
        let nostr_client = nostr_sdk::Client::builder().signer(keys.clone()).build();

        let relay = nwc_config.relay.clone();
        if let Err(e) = nostr_client.add_relay(relay.clone()).await {
            info_to_flutter(format!(
                "Could not add NWC relay to NWC client {} {e:?}",
                nwc_config.relay
            ))
            .await;
            return;
        }

        let Ok(relay) = nostr_client.relay(relay).await else {
            info_to_flutter("Could not get relay").await;
            return;
        };

        let status = relay.status();
        info_to_flutter(format!("Relay connection status: {status:?}")).await;
        relay.connect();
        info_to_flutter("Waiting for connection to relay...").await;
        relay
            .wait_for_connection(Duration::from_secs(u64::MAX))
            .await;
        info_to_flutter("Connected to relay!").await;

        let filter = nostr_sdk::Filter::new().kind(nostr_sdk::Kind::WalletConnectRequest);
        let Ok(subscription_id) = nostr_client.subscribe(filter, None).await else {
            info_to_flutter("Error subscribing to WalletConnectRequest").await;
            return;
        };

        Self::broadcast_nwc_info(&nostr_client, federation_id).await;

        let mut notifications = nostr_client.notifications();
        info_to_flutter(format!(
            "FederationId: {federation_id} Listening for NWC Requests..."
        ))
        .await;

        // Main event loop - runs until the notification stream is closed
        // (which happens when the foreground service is stopped)
        while let Ok(notification) = notifications.recv().await {
            let nostr_sdk::RelayPoolNotification::Event { event, .. } = notification else {
                continue;
            };

            if event.kind == nostr_sdk::Kind::WalletConnectRequest {
                let sender_pubkey = event.pubkey;
                let Ok(decrypted) =
                    nostr_sdk::nips::nip04::decrypt(&secret_key, &sender_pubkey, &event.content)
                else {
                    continue;
                };

                let Ok(request) = serde_json::from_str::<WalletConnectRequest>(&decrypted) else {
                    info_to_flutter("Error deserializing WalletConnectRequest").await;
                    continue;
                };

                info_to_flutter(format!("WalletConnectRequest: {request:?}")).await;
                if let Err(err) = Self::handle_request(
                    federation_id,
                    &nostr_client,
                    &keys,
                    request,
                    sender_pubkey,
                    event.id,
                )
                .await
                {
                    info_to_flutter(format!("Error handling WalletConnectRequest: {err:?}")).await;
                }
            } else {
                info_to_flutter(format!(
                    "Event was not a WalletConnectRequest, continuing... {}",
                    event.kind
                ))
                .await;
            }
        }

        info_to_flutter(format!("Notification stream closed for {federation_id}")).await;

        nostr_client.unsubscribe(&subscription_id).await;

        info_to_flutter(format!("FederationId: {federation_id} NWC Done listening")).await;
    }

    async fn broadcast_response(
        response: WalletConnectResponse,
        nostr_client: &nostr_sdk::Client,
        keys: &nostr_sdk::Keys,
        sender_pubkey: &nostr_sdk::PublicKey,
        request_event_id: nostr_sdk::EventId,
    ) -> anyhow::Result<()> {
        let content = serde_json::to_string(&response)?;
        let encrypted_content =
            nostr_sdk::nips::nip04::encrypt(keys.secret_key(), sender_pubkey, content.clone())?;

        let event_builder =
            nostr_sdk::EventBuilder::new(nostr_sdk::Kind::WalletConnectResponse, encrypted_content)
                .tag(nostr_sdk::Tag::public_key(keys.public_key))
                .tag(nostr_sdk::Tag::event(request_event_id));

        retry(
            "broadcast wallet response",
            fedimint_core::util::backoff_util::background_backoff(),
            || async {
                match nostr_client.send_event_builder(event_builder.clone()).await {
                    Ok(event_id) => {
                        info_to_flutter(format!("Broadcasted WalletConnectResponse: {event_id:?}"))
                            .await;
                        if event_id.failed.is_empty() && !event_id.success.is_empty() {
                            return Ok(());
                        }
                    }
                    Err(e) => {
                        info_to_flutter(format!(
                            "Error broadcasting WalletConnect response: {e:?}"
                        ))
                        .await;
                    }
                }

                Err(anyhow!("Error broadcasting WalletConnect response"))
            },
        )
        .await?;
        Ok(())
    }

    async fn handle_request(
        federation_id: &FederationId,
        nostr_client: &nostr_sdk::Client,
        keys: &nostr_sdk::Keys,
        request: WalletConnectRequest,
        sender_pubkey: nostr_sdk::PublicKey,
        request_event_id: nostr_sdk::EventId,
    ) -> anyhow::Result<()> {
        match request {
            WalletConnectRequest::GetInfo {} => {
                let all_federations = federations().await;
                let federation_selector = all_federations
                    .iter()
                    .find(|fed| fed.0.federation_id == *federation_id);
                if let Some((selector, _)) = federation_selector {
                    let network = selector.network.clone().expect("Network is not set");
                    let supported_methods = NWC_SUPPORTED_METHODS
                        .iter()
                        .map(|s| s.to_string())
                        .collect::<Vec<_>>();
                    let response = WalletConnectResponse::GetInfo {
                        network,
                        methods: supported_methods,
                    };
                    Self::broadcast_response(
                        response,
                        nostr_client,
                        keys,
                        &sender_pubkey,
                        request_event_id,
                    )
                    .await?;
                }
            }
            WalletConnectRequest::GetBalance {} => {
                let balance = balance(federation_id).await;
                let response = WalletConnectResponse::GetBalance { balance };
                Self::broadcast_response(
                    response,
                    nostr_client,
                    keys,
                    &sender_pubkey,
                    request_event_id,
                )
                .await?;
            }
            WalletConnectRequest::PayInvoice { invoice } => {
                let payment_preview = payment_preview(federation_id, invoice.clone()).await?;
                info_to_flutter(format!(
                    "Processing NWC PayInvoice. PaymentPreview Gateway: {} IsLNv2: {}",
                    payment_preview.gateway, payment_preview.is_lnv2
                ))
                .await;
                let operation_id = send(
                    federation_id,
                    invoice,
                    payment_preview.gateway,
                    payment_preview.is_lnv2,
                    payment_preview.amount_with_fees,
                    None,
                )
                .await?;
                let final_state = await_send(federation_id, operation_id).await;
                match final_state {
                    LightningSendOutcome::Success(preimage) => {
                        let response = WalletConnectResponse::PayInvoice { preimage };
                        Self::broadcast_response(
                            response,
                            nostr_client,
                            keys,
                            &sender_pubkey,
                            request_event_id,
                        )
                        .await?;
                    }
                    LightningSendOutcome::Failure => {
                        info_to_flutter("NWC Payment Failure".to_string()).await;
                    }
                }
            }
        }

        Ok(())
    }

    pub async fn get_public_federations(&mut self, force_update: bool) -> Vec<PublicFederation> {
        let update = {
            let public_federations = self.public_federations.read().await;
            public_federations.is_empty() || force_update
        };

        if update {
            self.update_federations_from_nostr().await;
        }

        self.public_federations.read().await.clone()
    }

    async fn update_federations_from_nostr(&mut self) {
        self.nostr_client.connect().await;

        let filter = nostr_sdk::Filter::new().kind(nostr_sdk::Kind::from(38173));
        match self
            .nostr_client
            .fetch_events(filter, Duration::from_secs(3))
            .await
        {
            Ok(events) => {
                let all_events = events.to_vec();
                let events = all_events
                    .iter()
                    .filter_map(|event| {
                        if let Ok(Network::Regtest) = PublicFederation::parse_network(&event.tags) {
                            // Skip over regtest advertisements
                            return None;
                        }

                        PublicFederation::try_from(event.clone()).ok()
                    })
                    .collect::<Vec<_>>();

                let mut public_federations = self.public_federations.write().await;
                *public_federations = events;
            }
            Err(e) => {
                error_to_flutter(format!("Failed to fetch events from nostr: {e}")).await;
            }
        }
    }

    pub async fn get_backup_invite_codes(&self) -> Vec<String> {
        let pubkey = self.keys.public_key;
        info_to_flutter(format!("Getting backup invite codes for {}", pubkey)).await;
        self.nostr_client.connect().await;

        let filter = nostr_sdk::Filter::new()
            .author(pubkey)
            .kind(nostr_sdk::Kind::from(30000))
            .custom_tag(
                nostr_sdk::SingleLetterTag {
                    character: nostr_sdk::Alphabet::D,
                    uppercase: false,
                },
                "fedimint-backup",
            );
        let mut invite_codes: Vec<String> = Vec::new();
        match self
            .nostr_client
            .fetch_events(filter, Duration::from_secs(60))
            .await
        {
            Ok(events) => {
                let all_events = events.to_vec();
                for event in all_events {
                    if let Ok(decrypted) = nostr_sdk::nips::nip04::decrypt(
                        self.keys.secret_key(),
                        &pubkey,
                        event.content,
                    ) {
                        let codes = decrypted.split(",");
                        for code in codes {
                            if InviteCode::from_str(code).is_ok() {
                                invite_codes.push(code.to_string());
                            }
                        }
                    }
                }
            }
            Err(e) => {
                error_to_flutter(format!(
                    "Failed to fetch replaceable events from nostr: {e}"
                ))
                .await;
            }
        }

        invite_codes
    }

    pub async fn get_nwc_connection_info(&self) -> Vec<(FederationSelector, NWCConnectionInfo)> {
        let feds = federations().await;
        let mut dbtx = self.db.begin_transaction().await;
        let federation_configs = dbtx
            .find_by_prefix(&NostrWalletConnectKeyPrefix)
            .await
            .collect::<Vec<_>>()
            .await;
        federation_configs
            .iter()
            .map(|(key, config)| {
                let secret_key = nostr_sdk::SecretKey::from_slice(&config.secret_key)
                    .expect("Could not create secret key");
                let keys =
                    nostr_sdk::Keys::new_with_ctx(fedimint_core::secp256k1::SECP256K1, secret_key);
                let public_key = keys.public_key.to_hex();
                let selector = feds
                    .iter()
                    .find(|fed| fed.0.federation_id == key.federation_id)
                    .expect("Federation should exist")
                    .0
                    .clone();
                (
                    selector,
                    NWCConnectionInfo {
                        public_key,
                        relay: config.relay.clone(),
                        secret: config.secret_key.consensus_encode_to_hex(),
                    },
                )
            })
            .collect::<Vec<_>>()
    }

    pub async fn set_nwc_connection_info(
        &mut self,
        federation_id: FederationId,
        relay: String,
        is_desktop: bool,
    ) -> NWCConnectionInfo {
        let mut dbtx = self.db.begin_transaction().await;
        let keys = nostr_sdk::Keys::generate();
        let nwc_config = NostrWalletConnectConfig {
            secret_key: keys
                .secret_key()
                .as_secret_bytes()
                .try_into()
                .expect("Could not serialize secret key"),
            relay: relay.clone(),
        };
        dbtx.insert_entry(&NostrWalletConnectKey { federation_id }, &nwc_config)
            .await;

        dbtx.commit_tx().await;

        let public_key = keys.public_key.to_hex();
        if is_desktop {
            self.spawn_listen_for_nwc(&federation_id, nwc_config).await;
        }
        NWCConnectionInfo {
            public_key,
            relay,
            secret: keys.secret_key().to_secret_hex(),
        }
    }

    pub async fn remove_nwc_connection_info(&self, federation_id: FederationId) {
        // Remove from database
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.remove_entry(&NostrWalletConnectKey { federation_id })
            .await;
        dbtx.commit_tx().await;

        let mut listeners = self.nwc_listeners.write().await;
        if let Some(sender) = listeners.remove(&federation_id) {
            let _ = sender.send(());
        }
    }

    /// Get NWC config for a federation and return it.
    /// This is used by the blocking listen function.
    pub async fn get_nwc_config(
        &self,
        federation_id: FederationId,
    ) -> anyhow::Result<(NostrWalletConnectConfig, NWCConnectionInfo)> {
        let mut dbtx = self.db.begin_transaction().await;

        let existing_config = dbtx
            .get_value(&NostrWalletConnectKey { federation_id })
            .await
            .ok_or(anyhow!("NostrWalletConnectKey does not exist"))?;

        let secret_key = nostr_sdk::SecretKey::from_slice(&existing_config.secret_key)
            .expect("Could not create secret key");
        let keys = nostr_sdk::Keys::new_with_ctx(fedimint_core::secp256k1::SECP256K1, secret_key);
        let public_key = keys.public_key.to_hex();
        let relay = existing_config.relay.clone();
        Ok((
            existing_config,
            NWCConnectionInfo {
                public_key,
                relay,
                secret: keys.secret_key().to_secret_hex(),
            },
        ))
    }

    pub async fn get_relays(&self) -> Vec<(String, bool)> {
        let relays = Self::get_or_insert_default_relays(self.db.clone()).await;
        let mut relays_and_status = Vec::new();
        for uri in relays {
            if let Ok(relay) = self.nostr_client.relay(uri.clone()).await {
                relays_and_status.push((uri, relay.status() == nostr_sdk::RelayStatus::Connected));
            } else {
                relays_and_status.push((uri, false));
            }
        }

        relays_and_status
    }

    pub async fn backup_invite_codes(&self, invite_codes: Vec<String>) -> anyhow::Result<()> {
        self.nostr_client.connect().await;

        let pubkey = self.keys.public_key;
        let serialized_invite_codes = invite_codes.join(",");
        let encrypted_content = nostr_sdk::nips::nip04::encrypt(
            self.keys.secret_key(),
            &pubkey,
            serialized_invite_codes,
        )?;

        let event_builder =
            nostr_sdk::EventBuilder::new(nostr_sdk::Kind::from(30000), encrypted_content)
                .tag(nostr_sdk::Tag::public_key(pubkey))
                .tag(nostr_sdk::Tag::custom(
                    nostr_sdk::TagKind::d(),
                    ["fedimint-backup"],
                ));

        retry(
            "broadcast fedimint backoff",
            fedimint_core::util::backoff_util::background_backoff(),
            || async {
                match self
                    .nostr_client
                    .send_event_builder(event_builder.clone())
                    .await
                {
                    Ok(event_id) => {
                        info_to_flutter(format!("Broadcasted Fedimint Backup: {event_id:?}")).await;
                        return Ok(());
                    }
                    Err(e) => {
                        info_to_flutter(format!("Error broadcasting Fedimint backup: {e:?}")).await;
                    }
                }

                Err(anyhow!("Error broadcasting Fedimint backup"))
            },
        )
        .await?;

        Ok(())
    }

    /// Get the user's public key as an npub string
    pub fn get_user_npub(&self) -> String {
        self.keys
            .public_key
            .to_bech32()
            .expect("Could not encode to bech32")
    }

    /// Fetch the user's follows list (Kind 3 contact list)
    pub async fn get_nostr_follows(&self) -> anyhow::Result<Vec<String>> {
        self.nostr_client.connect().await;

        let pubkey = self.keys.public_key;
        let filter = nostr_sdk::Filter::new()
            .author(pubkey)
            .kind(nostr_sdk::Kind::ContactList)
            .limit(1);

        let events = self
            .nostr_client
            .fetch_events(filter, Duration::from_secs(10))
            .await?;

        let events_vec = events.to_vec();
        if events_vec.is_empty() {
            return Ok(Vec::new());
        }

        // Get the most recent event
        let contact_list = events_vec
            .into_iter()
            .max_by_key(|e| e.created_at)
            .ok_or_else(|| anyhow!("No contact list found"))?;

        // Extract p tags (followed pubkeys)
        let mut follows = Vec::new();
        for tag in contact_list.tags.iter() {
            if let Some(nostr_sdk::TagStandard::PublicKey { public_key, .. }) =
                tag.as_standardized()
            {
                follows.push(public_key.to_bech32().expect("Could not encode to bech32"));
            }
        }

        info_to_flutter(format!("Found {} follows", follows.len())).await;
        Ok(follows)
    }

    /// Fetch follows list for any pubkey (Kind 3 contact list)
    pub async fn get_follows_for_pubkey(&self, npub: String) -> anyhow::Result<Vec<String>> {
        self.nostr_client.connect().await;

        let pubkey = nostr_sdk::PublicKey::parse(&npub)?;
        let filter = nostr_sdk::Filter::new()
            .author(pubkey)
            .kind(nostr_sdk::Kind::ContactList)
            .limit(1);

        let events = self
            .nostr_client
            .fetch_events(filter, Duration::from_secs(10))
            .await?;

        let events_vec = events.to_vec();
        if events_vec.is_empty() {
            return Ok(Vec::new());
        }

        // Get the most recent event
        let contact_list = events_vec
            .into_iter()
            .max_by_key(|e| e.created_at)
            .ok_or_else(|| anyhow!("No contact list found"))?;

        // Extract p tags (followed pubkeys)
        let mut follows = Vec::new();
        for tag in contact_list.tags.iter() {
            if let Some(nostr_sdk::TagStandard::PublicKey { public_key, .. }) =
                tag.as_standardized()
            {
                follows.push(public_key.to_bech32().expect("Could not encode to bech32"));
            }
        }

        info_to_flutter(format!("Found {} follows for {}", follows.len(), npub)).await;
        Ok(follows)
    }

    /// Fetch Nostr profiles (Kind 0) for a list of npubs
    pub async fn fetch_nostr_profiles(
        &self,
        npubs: Vec<String>,
    ) -> anyhow::Result<Vec<NostrProfile>> {
        if npubs.is_empty() {
            return Ok(Vec::new());
        }

        self.nostr_client.connect().await;

        // Convert npubs to public keys
        let pubkeys: Vec<nostr_sdk::PublicKey> = npubs
            .iter()
            .filter_map(|npub| nostr_sdk::PublicKey::parse(npub).ok())
            .collect();

        if pubkeys.is_empty() {
            return Ok(Vec::new());
        }

        // Chunk requests to avoid timeouts with large batches
        const CHUNK_SIZE: usize = 100;
        let mut all_profiles: BTreeMap<nostr_sdk::PublicKey, nostr_sdk::Event> = BTreeMap::new();

        for chunk in pubkeys.chunks(CHUNK_SIZE) {
            let filter = nostr_sdk::Filter::new()
                .authors(chunk.to_vec())
                .kind(nostr_sdk::Kind::Metadata);

            let events = self
                .nostr_client
                .fetch_events(filter, Duration::from_secs(15))
                .await?;

            // Group by author and take the most recent profile for each
            for event in events.to_vec() {
                all_profiles
                    .entry(event.pubkey)
                    .and_modify(|existing| {
                        if event.created_at > existing.created_at {
                            *existing = event.clone();
                        }
                    })
                    .or_insert(event);
            }
        }

        let profiles: Vec<NostrProfile> = all_profiles
            .into_values()
            .filter_map(|event| NostrProfile::try_from(event).ok())
            .collect();

        info_to_flutter(format!("Fetched {} profiles", profiles.len())).await;
        Ok(profiles)
    }

    /// Fetch a single profile by npub
    pub async fn fetch_nostr_profile(&self, npub: String) -> anyhow::Result<NostrProfile> {
        let profiles = self.fetch_nostr_profiles(vec![npub.clone()]).await?;
        profiles
            .into_iter()
            .next()
            .ok_or_else(|| anyhow!("Profile not found for {}", npub))
    }

    /// Resolve and verify a NIP-05 identifier, returning the npub if valid
    pub async fn verify_nip05(&self, nip05_id: &str) -> anyhow::Result<String> {
        // Parse the NIP-05 identifier (user@domain.com or _@domain.com)
        let parts: Vec<&str> = nip05_id.split('@').collect();
        if parts.len() != 2 {
            bail!("Invalid NIP-05 identifier format");
        }

        let name = parts[0];
        let domain = parts[1];

        // Build the URL for the well-known file
        let url = format!("https://{}/.well-known/nostr.json?name={}", domain, name);

        // Make the HTTP request
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()?;

        let response = client.get(&url).send().await?;

        if !response.status().is_success() {
            bail!("NIP-05 verification failed: HTTP {}", response.status());
        }

        let json: serde_json::Value = response.json().await?;

        // Extract the public key from the response
        let pubkey_hex = json
            .get("names")
            .and_then(|names| names.get(name))
            .and_then(|pk| pk.as_str())
            .ok_or_else(|| anyhow!("Name not found in NIP-05 response"))?;

        // Convert hex public key to npub
        let pubkey = nostr_sdk::PublicKey::from_hex(pubkey_hex)?;
        Ok(pubkey.to_bech32().expect("Could not encode to bech32"))
    }

    /// Check if a contact's NIP-05 is still valid
    pub async fn verify_contact_nip05(&self, npub: &str, nip05: &str) -> bool {
        match self.verify_nip05(nip05).await {
            Ok(verified_npub) => verified_npub == npub,
            Err(_) => false,
        }
    }

    // === Contact Database Operations ===

    /// Check if contacts have been imported (first-time flag)
    pub async fn has_imported_contacts(&self) -> bool {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&ContactsImportedKey).await.is_some()
    }

    /// Mark contacts as having been imported
    pub async fn set_contacts_imported(&self) {
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(&ContactsImportedKey, &()).await;
        dbtx.commit_tx().await;
    }

    /// Get contact sync configuration
    pub async fn get_contact_sync_config(&self) -> Option<ContactSyncConfig> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&ContactSyncConfigKey).await
    }

    /// Set up contact sync with an npub
    pub async fn set_contact_sync_config(&self, npub: String, enabled: bool) {
        let config = ContactSyncConfig {
            npub,
            last_sync_at: None,
            sync_enabled: enabled,
        };
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(&ContactSyncConfigKey, &config).await;
        dbtx.commit_tx().await;
    }

    /// Clear all contacts and stop syncing
    pub async fn clear_contacts_and_stop_sync(&self) -> usize {
        let mut dbtx = self.db.begin_transaction().await;

        // Get all contacts to count them
        let contacts: Vec<_> = dbtx.find_by_prefix(&ContactKeyPrefix).await.collect().await;
        let count = contacts.len();

        // Remove all contacts
        for (key, _) in contacts {
            dbtx.remove_entry(&key).await;
        }

        // Remove sync config (this stops syncing)
        dbtx.remove_entry(&ContactSyncConfigKey).await;

        // Remove the imported flag so the sync dialog will show again
        dbtx.remove_entry(&ContactsImportedKey).await;

        dbtx.commit_tx().await;

        info_to_flutter(format!("Cleared {} contacts and stopped syncing", count)).await;
        count
    }

    /// Sync contacts from Nostr follows
    /// Fetches follows from the configured npub, filters to those with lightning addresses,
    /// and updates the contact database
    pub async fn sync_contacts(&self) -> anyhow::Result<(usize, usize, usize)> {
        let config = self
            .get_contact_sync_config()
            .await
            .ok_or_else(|| anyhow!("Contact sync not configured"))?;

        if !config.sync_enabled {
            return Ok((0, 0, 0));
        }

        // Publish sync started event
        get_event_bus()
            .publish(MultimintEvent::ContactSync(ContactSyncEventKind::Started))
            .await;

        // Fetch follows for the configured npub
        let follows = match self.get_follows_for_pubkey(config.npub.clone()).await {
            Ok(f) => f,
            Err(e) => {
                let error_msg = format!("Failed to fetch follows: {}", e);
                get_event_bus()
                    .publish(MultimintEvent::ContactSync(ContactSyncEventKind::Error(
                        error_msg,
                    )))
                    .await;
                return Err(e);
            }
        };

        if follows.is_empty() {
            // Update last sync time even if no follows
            let updated_config = ContactSyncConfig {
                npub: config.npub,
                last_sync_at: Some(Self::now_millis()),
                sync_enabled: true,
            };
            let mut dbtx = self.db.begin_transaction().await;
            dbtx.insert_entry(&ContactSyncConfigKey, &updated_config)
                .await;
            dbtx.commit_tx().await;

            get_event_bus()
                .publish(MultimintEvent::ContactSync(
                    ContactSyncEventKind::Completed {
                        added: 0,
                        updated: 0,
                        removed: 0,
                    },
                ))
                .await;
            return Ok((0, 0, 0));
        }

        // Fetch profiles for follows
        let profiles = match self.fetch_nostr_profiles(follows).await {
            Ok(p) => p,
            Err(e) => {
                let error_msg = format!("Failed to fetch profiles: {}", e);
                get_event_bus()
                    .publish(MultimintEvent::ContactSync(ContactSyncEventKind::Error(
                        error_msg,
                    )))
                    .await;
                return Err(e);
            }
        };

        // Filter to only profiles with lightning addresses
        let profiles_with_ln: Vec<NostrProfile> = profiles
            .into_iter()
            .filter(|p| p.lud16.as_ref().is_some_and(|l| !l.is_empty()))
            .collect();

        // Get current contacts
        let current_contacts = self.get_all_contacts().await;
        let current_npubs: HashSet<String> =
            current_contacts.iter().map(|c| c.npub.clone()).collect();
        let new_npubs: HashSet<String> = profiles_with_ln.iter().map(|p| p.npub.clone()).collect();

        // Determine adds, updates, removes
        let to_add: Vec<&NostrProfile> = profiles_with_ln
            .iter()
            .filter(|p| !current_npubs.contains(&p.npub))
            .collect();
        let to_remove: Vec<&Contact> = current_contacts
            .iter()
            .filter(|c| !new_npubs.contains(&c.npub))
            .collect();
        let to_update: Vec<&NostrProfile> = profiles_with_ln
            .iter()
            .filter(|p| current_npubs.contains(&p.npub))
            .collect();

        let now = Self::now_millis();
        let mut dbtx = self.db.begin_transaction().await;

        // Remove contacts that are no longer follows (payment history preserved in separate table)
        for contact in &to_remove {
            dbtx.remove_entry(&ContactKey {
                npub: contact.npub.clone(),
            })
            .await;
        }

        // Add new contacts
        for profile in &to_add {
            let contact = Contact {
                npub: profile.npub.clone(),
                name: profile.name.clone(),
                display_name: profile.display_name.clone(),
                picture: profile.picture.clone(),
                lud16: profile.lud16.clone(),
                nip05: profile.nip05.clone(),
                nip05_verified: false,
                about: profile.about.clone(),
                created_at: now,
                last_paid_at: None,
            };
            dbtx.insert_entry(
                &ContactKey {
                    npub: profile.npub.clone(),
                },
                &contact,
            )
            .await;
        }

        // Update existing contacts (preserve last_paid_at and created_at)
        for profile in &to_update {
            if let Some(existing) = current_contacts.iter().find(|c| c.npub == profile.npub) {
                let contact = Contact {
                    npub: profile.npub.clone(),
                    name: profile.name.clone(),
                    display_name: profile.display_name.clone(),
                    picture: profile.picture.clone(),
                    lud16: profile.lud16.clone(),
                    nip05: profile.nip05.clone(),
                    nip05_verified: existing.nip05_verified,
                    about: profile.about.clone(),
                    created_at: existing.created_at,
                    last_paid_at: existing.last_paid_at,
                };
                dbtx.insert_entry(
                    &ContactKey {
                        npub: profile.npub.clone(),
                    },
                    &contact,
                )
                .await;
            }
        }

        // Update sync timestamp
        let updated_config = ContactSyncConfig {
            npub: config.npub,
            last_sync_at: Some(now),
            sync_enabled: true,
        };
        dbtx.insert_entry(&ContactSyncConfigKey, &updated_config)
            .await;

        dbtx.commit_tx().await;

        let result = (to_add.len(), to_update.len(), to_remove.len());

        info_to_flutter(format!(
            "Contact sync: +{} added, ~{} updated, -{} removed",
            result.0, result.1, result.2
        ))
        .await;

        // Publish sync completed event
        get_event_bus()
            .publish(MultimintEvent::ContactSync(
                ContactSyncEventKind::Completed {
                    added: result.0,
                    updated: result.1,
                    removed: result.2,
                },
            ))
            .await;

        Ok(result)
    }

    /// Helper to get current time as milliseconds since Unix epoch
    fn now_millis() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    /// Import contacts from Nostr profiles into the database
    pub async fn import_contacts(&self, profiles: Vec<NostrProfile>) -> anyhow::Result<usize> {
        let mut dbtx = self.db.begin_transaction().await;
        let mut imported_count = 0;
        let now = Self::now_millis();

        for profile in profiles {
            let contact = Contact {
                npub: profile.npub.clone(),
                name: profile.name,
                display_name: profile.display_name,
                picture: profile.picture,
                lud16: profile.lud16,
                nip05: profile.nip05.clone(),
                nip05_verified: false, // Will be verified separately
                about: profile.about,
                created_at: now,
                last_paid_at: None,
            };

            dbtx.insert_entry(
                &ContactKey {
                    npub: profile.npub.clone(),
                },
                &contact,
            )
            .await;
            imported_count += 1;
        }

        dbtx.commit_tx().await;
        info_to_flutter(format!("Imported {} contacts", imported_count)).await;
        Ok(imported_count)
    }

    /// Get all contacts, sorted by last_paid_at (most recent first), then by created_at
    pub async fn get_all_contacts(&self) -> Vec<Contact> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        let mut contacts: Vec<Contact> = dbtx
            .find_by_prefix(&ContactKeyPrefix)
            .await
            .map(|(_, contact)| contact)
            .collect()
            .await;

        // Sort by last_paid_at descending (recent first), then created_at descending
        contacts.sort_by(|a, b| match (&b.last_paid_at, &a.last_paid_at) {
            (Some(b_time), Some(a_time)) => b_time.cmp(a_time),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => b.created_at.cmp(&a.created_at),
        });

        contacts
    }

    /// Get paginated contacts with cursor-based pagination
    pub async fn paginate_contacts(
        &self,
        cursor: Option<ContactCursor>,
        limit: usize,
    ) -> Vec<Contact> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        let mut contacts: Vec<Contact> = dbtx
            .find_by_prefix(&ContactKeyPrefix)
            .await
            .map(|(_, contact)| contact)
            .collect()
            .await;

        // Sort by last_paid_at descending (recent first), then created_at descending
        contacts.sort_by(|a, b| match (&b.last_paid_at, &a.last_paid_at) {
            (Some(b_time), Some(a_time)) => b_time.cmp(a_time),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => b.created_at.cmp(&a.created_at),
        });

        // Apply cursor filtering
        let mut result = Vec::new();
        let mut skip_until_cursor = cursor.is_some();

        for contact in contacts {
            if skip_until_cursor {
                if let Some(ref cur) = cursor {
                    // Check if this is the cursor contact
                    if contact.npub == cur.npub {
                        skip_until_cursor = false;
                    }
                }
                continue;
            }

            result.push(contact);
            if result.len() >= limit {
                break;
            }
        }

        result
    }

    /// Get a single contact by npub
    pub async fn get_contact(&self, npub: &str) -> Option<Contact> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&ContactKey {
            npub: npub.to_string(),
        })
        .await
    }

    /// Refresh a contact's profile from Nostr
    pub async fn refresh_contact_profile(&self, npub: &str) -> anyhow::Result<Contact> {
        let existing = self
            .get_contact(npub)
            .await
            .ok_or_else(|| anyhow!("Contact not found"))?;

        let profile = self.fetch_nostr_profile(npub.to_string()).await?;

        let updated_contact = Contact {
            npub: profile.npub.clone(),
            name: profile.name,
            display_name: profile.display_name,
            picture: profile.picture,
            lud16: profile.lud16,
            nip05: profile.nip05,
            nip05_verified: existing.nip05_verified, // Preserve verification status
            about: profile.about,
            created_at: existing.created_at, // Preserve original creation time
            last_paid_at: existing.last_paid_at, // Preserve payment history
        };

        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(
            &ContactKey {
                npub: npub.to_string(),
            },
            &updated_contact,
        )
        .await;
        dbtx.commit_tx().await;

        Ok(updated_contact)
    }

    /// Update a contact's NIP-05 verification status
    pub async fn update_contact_nip05_verification(
        &self,
        npub: &str,
        verified: bool,
    ) -> anyhow::Result<()> {
        let mut contact = self
            .get_contact(npub)
            .await
            .ok_or_else(|| anyhow!("Contact not found"))?;

        contact.nip05_verified = verified;

        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(
            &ContactKey {
                npub: npub.to_string(),
            },
            &contact,
        )
        .await;
        dbtx.commit_tx().await;

        Ok(())
    }

    /// Record a payment to a contact
    pub async fn record_contact_payment(
        &self,
        npub: &str,
        amount_msats: u64,
        federation_id: FederationId,
        operation_id: Vec<u8>,
        note: Option<String>,
    ) -> anyhow::Result<()> {
        let now = Self::now_millis();

        // Update the contact's last_paid_at
        if let Some(mut contact) = self.get_contact(npub).await {
            contact.last_paid_at = Some(now);

            let mut dbtx = self.db.begin_transaction().await;
            dbtx.insert_entry(
                &ContactKey {
                    npub: npub.to_string(),
                },
                &contact,
            )
            .await;

            // Record the payment
            let payment = ContactPayment {
                amount_msats,
                federation_id,
                operation_id,
                note,
            };

            dbtx.insert_entry(
                &ContactPaymentKey {
                    npub: npub.to_string(),
                    timestamp: now,
                },
                &payment,
            )
            .await;

            dbtx.commit_tx().await;
        }

        Ok(())
    }

    /// Get payment history for a contact
    pub async fn get_contact_payments(
        &self,
        npub: &str,
        limit: usize,
    ) -> Vec<(u64, ContactPayment)> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        let mut payments: Vec<(u64, ContactPayment)> = dbtx
            .find_by_prefix(&ContactPaymentByNpubPrefix {
                npub: npub.to_string(),
            })
            .await
            .map(|(key, payment)| (key.timestamp, payment))
            .collect()
            .await;

        // Sort by timestamp descending (most recent first)
        payments.sort_by(|a, b| b.0.cmp(&a.0));

        // Limit results
        payments.truncate(limit);

        payments
    }

    /// Search contacts by name, display_name, nip05, or npub
    pub async fn search_contacts(&self, query: &str) -> Vec<Contact> {
        let query_lower = query.to_lowercase();
        let all_contacts = self.get_all_contacts().await;

        all_contacts
            .into_iter()
            .filter(|contact| {
                contact.npub.to_lowercase().contains(&query_lower)
                    || contact
                        .name
                        .as_ref()
                        .map(|n| n.to_lowercase().contains(&query_lower))
                        .unwrap_or(false)
                    || contact
                        .display_name
                        .as_ref()
                        .map(|n| n.to_lowercase().contains(&query_lower))
                        .unwrap_or(false)
                    || contact
                        .nip05
                        .as_ref()
                        .map(|n| n.to_lowercase().contains(&query_lower))
                        .unwrap_or(false)
                    || contact
                        .lud16
                        .as_ref()
                        .map(|l| l.to_lowercase().contains(&query_lower))
                        .unwrap_or(false)
            })
            .collect()
    }

    /// Search contacts with pagination
    pub async fn paginate_search_contacts(
        &self,
        query: &str,
        cursor: Option<ContactCursor>,
        limit: usize,
    ) -> Vec<Contact> {
        let query_lower = query.to_lowercase();
        let all_contacts = self.get_all_contacts().await;

        // Filter contacts based on query
        let mut filtered: Vec<Contact> = all_contacts
            .into_iter()
            .filter(|contact| {
                contact.npub.to_lowercase().contains(&query_lower)
                    || contact
                        .name
                        .as_ref()
                        .map(|n| n.to_lowercase().contains(&query_lower))
                        .unwrap_or(false)
                    || contact
                        .display_name
                        .as_ref()
                        .map(|d| d.to_lowercase().contains(&query_lower))
                        .unwrap_or(false)
                    || contact
                        .nip05
                        .as_ref()
                        .map(|n| n.to_lowercase().contains(&query_lower))
                        .unwrap_or(false)
                    || contact
                        .lud16
                        .as_ref()
                        .map(|l| l.to_lowercase().contains(&query_lower))
                        .unwrap_or(false)
            })
            .collect();

        // Sort by last_paid_at descending, then created_at descending (same as get_all_contacts)
        filtered.sort_by(|a, b| match (&b.last_paid_at, &a.last_paid_at) {
            (Some(b_time), Some(a_time)) => b_time.cmp(a_time),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => b.created_at.cmp(&a.created_at),
        });

        // Apply cursor filtering
        let mut result = Vec::new();
        let mut skip_until_cursor = cursor.is_some();

        for contact in filtered {
            if skip_until_cursor {
                if let Some(ref cur) = cursor {
                    if contact.npub == cur.npub {
                        skip_until_cursor = false;
                    }
                }
                continue;
            }

            result.push(contact);
            if result.len() >= limit {
                break;
            }
        }

        result
    }
}

#[derive(Debug, Clone)]
pub struct NWCConnectionInfo {
    pub public_key: String,
    pub relay: String,
    pub secret: String,
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct PublicFederation {
    pub federation_name: String,
    pub federation_id: FederationId,
    pub invite_codes: Vec<String>,
    pub about: Option<String>,
    pub picture: Option<String>,
    pub modules: Vec<String>,
    pub network: String,
}

impl TryFrom<nostr_sdk::Event> for PublicFederation {
    type Error = anyhow::Error;

    fn try_from(event: nostr_sdk::Event) -> Result<Self, Self::Error> {
        let tags = event.tags;
        let network = Self::parse_network(&tags)?;
        let (federation_name, about, picture) = Self::parse_content(event.content)?;
        let federation_id = Self::parse_federation_id(&tags)?;
        let invite_codes = Self::parse_invite_codes(&tags)?;
        let modules = Self::parse_modules(&tags)?;
        Ok(PublicFederation {
            federation_name,
            federation_id,
            invite_codes,
            about,
            picture,
            modules,
            network: network.to_string(),
        })
    }
}

impl PublicFederation {
    fn parse_network(tags: &nostr_sdk::Tags) -> anyhow::Result<Network> {
        let n_tag = tags
            .find(nostr_sdk::TagKind::SingleLetter(
                nostr_sdk::SingleLetterTag::lowercase(nostr_sdk::Alphabet::N),
            ))
            .ok_or(anyhow::anyhow!("n_tag not present"))?;
        let network = n_tag
            .content()
            .ok_or(anyhow::anyhow!("n_tag has no content"))?;
        match network {
            "mainnet" => Ok(Network::Bitcoin),
            network_str => {
                let network = Network::from_str(network_str)?;
                Ok(network)
            }
        }
    }

    fn parse_content(content: String) -> anyhow::Result<(String, Option<String>, Option<String>)> {
        let json: Result<serde_json::Value, serde_json::Error> = serde_json::from_str(&content);
        match json {
            Ok(json) => {
                let federation_name = Self::parse_federation_name(&json)?;
                let about = json
                    .get("about")
                    .map(|val| val.as_str().expect("about is not a string").to_string());

                let picture = Self::parse_picture(&json);
                Ok((federation_name, about, picture))
            }
            Err(_) => {
                // Just interpret the entire content as the federation name
                Ok((content, None, None))
            }
        }
    }

    fn parse_federation_name(json: &serde_json::Value) -> anyhow::Result<String> {
        // First try to parse using the "name" key
        let federation_name = json.get("name");
        match federation_name {
            Some(name) => Ok(name
                .as_str()
                .ok_or(anyhow!("name is not a string"))?
                .to_string()),
            None => {
                // Try to parse using "federation_name" key
                let federation_name = json
                    .get("federation_name")
                    .ok_or(anyhow!("Could not get federation name"))?;
                Ok(federation_name
                    .as_str()
                    .ok_or(anyhow!("federation name is not a string"))?
                    .to_string())
            }
        }
    }

    fn parse_picture(json: &serde_json::Value) -> Option<String> {
        let picture = json.get("picture");
        if let Some(picture) = picture {
            if let Some(pic_url) = picture.as_str() {
                // Verify that the picture is a URL
                let safe_url = SafeUrl::parse(pic_url).ok()?;
                return Some(safe_url.to_string());
            }
        }

        None
    }

    fn parse_federation_id(tags: &nostr_sdk::Tags) -> anyhow::Result<FederationId> {
        let d_tag = tags.identifier().ok_or(anyhow!("d_tag is not present"))?;
        let federation_id = FederationId::from_str(d_tag)?;
        Ok(federation_id)
    }

    fn parse_invite_codes(tags: &nostr_sdk::Tags) -> anyhow::Result<Vec<String>> {
        let u_tag = tags
            .find(nostr_sdk::TagKind::SingleLetter(
                nostr_sdk::SingleLetterTag::lowercase(nostr_sdk::Alphabet::U),
            ))
            .ok_or(anyhow!("u_tag does not exist"))?;
        let invite = u_tag
            .content()
            .ok_or(anyhow!("No content for u_tag"))?
            .to_string();
        Ok(vec![invite])
    }

    fn parse_modules(tags: &nostr_sdk::Tags) -> anyhow::Result<Vec<String>> {
        let modules = tags
            .find(nostr_sdk::TagKind::custom("modules".to_string()))
            .ok_or(anyhow!("No modules tag"))?
            .content()
            .ok_or(anyhow!("modules should have content"))?
            .split(",")
            .map(|m| m.to_string())
            .collect::<Vec<_>>();
        Ok(modules)
    }
}

/// Nostr profile data parsed from Kind 0 events
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NostrProfile {
    pub npub: String,
    pub name: Option<String>,
    pub display_name: Option<String>,
    pub picture: Option<String>,
    pub lud16: Option<String>,
    pub nip05: Option<String>,
    pub about: Option<String>,
}

impl TryFrom<nostr_sdk::Event> for NostrProfile {
    type Error = anyhow::Error;

    fn try_from(event: nostr_sdk::Event) -> Result<Self, Self::Error> {
        if event.kind != nostr_sdk::Kind::Metadata {
            bail!("Event is not a metadata event");
        }

        let npub = event
            .pubkey
            .to_bech32()
            .expect("Could not encode to bech32");
        let json: serde_json::Value = serde_json::from_str(&event.content)?;

        Ok(NostrProfile {
            npub,
            name: json.get("name").and_then(|v| v.as_str()).map(String::from),
            display_name: json
                .get("display_name")
                .and_then(|v| v.as_str())
                .map(String::from),
            picture: json
                .get("picture")
                .and_then(|v| v.as_str())
                .map(String::from),
            lud16: json.get("lud16").and_then(|v| v.as_str()).map(String::from),
            nip05: json.get("nip05").and_then(|v| v.as_str()).map(String::from),
            about: json.get("about").and_then(|v| v.as_str()).map(String::from),
        })
    }
}
