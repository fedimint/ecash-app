mod db;
mod frb_generated; use fedimint_core::secp256k1::rand::seq::SliceRandom;
use fedimint_core::task::TaskGroup;
/* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use flutter_rust_bridge::frb;
use tokio::sync::{OnceCell, RwLock};

use std::{collections::BTreeMap, fmt::Display, str::FromStr, sync::Arc, time::Duration};

use anyhow::bail;
use fedimint_api_client::api::net::Connector;
use fedimint_bip39::{Bip39RootSecretStrategy, Mnemonic};
use fedimint_client::{
    module_init::ClientModuleInitRegistry, secret::RootSecretStrategy, Client, ClientHandleArc,
    OperationId,
};
use fedimint_core::util::FmtCompact;
use fedimint_core::{
    bitcoin::Network,
    config::FederationId,
    db::{Database, IDatabaseTransactionOpsCoreTyped},
    encoding::Encodable,
    invite_code::InviteCode,
    secp256k1::rand::thread_rng,
    util::SafeUrl,
    Amount,
};
use fedimint_derive_secret::{ChildId, DerivableSecret};
use fedimint_ln_client::{InternalPayState, LightningClientInit, LightningClientModule, LnPayState, LnReceiveState};
use fedimint_lnv2_client::{FinalReceiveOperationState, FinalSendOperationState};
use fedimint_lnv2_common::Bolt11InvoiceDescription;
use fedimint_mint_client::MintClientInit;
use fedimint_rocksdb::RocksDb;
use fedimint_wallet_client::WalletClientInit;
use futures_util::StreamExt;
use lightning_invoice::{Bolt11Invoice, Description};
use serde::Serialize;

use crate::db::{FederationConfig, FederationConfigKey, FederationConfigKeyPrefix};

pub const DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.nostr.band",
    "wss://nostr-pub.wellorder.net",
    "wss://relay.plebstr.com",
    "wss://relayer.fiatjaf.com",
    "wss://nostr-01.bolt.observer",
    "wss://nostr.bitcoiner.social",
    "wss://relay.nostr.info",
    "wss://relay.damus.io",
];

const DEFAULT_EXPIRY_TIME_SECS: u32 = 86400;

static MULTIMINT: OnceCell<Arc<RwLock<Multimint>>> = OnceCell::const_new();

async fn init_global() -> Arc<RwLock<Multimint>> {
    Arc::new(RwLock::new(
        Multimint::new().await.expect("Could not create multimint"),
    ))
}

async fn get_multimint() -> Arc<RwLock<Multimint>> {
    MULTIMINT.get_or_init(init_global).await.clone()
}

#[frb]
pub async fn join_federation(invite_code: String) -> anyhow::Result<FederationSelector> {
    let multimint = get_multimint().await;
    let mut mm = multimint.write().await;
    mm.join_federation(invite_code).await
}

#[frb]
pub async fn federations() -> Vec<FederationSelector> {
    let multimint = get_multimint().await;
    let mm = multimint.read().await;
    mm.federations().await
}

#[frb]
pub async fn balance(federation_id: &FederationId) -> u64 {
    let multimint = get_multimint().await;
    let mm = multimint.read().await;
    mm.balance(federation_id).await
}

#[frb]
pub async fn receive(
    federation_id: &FederationId,
    amount_msats: u64,
) -> anyhow::Result<(String, OperationId)> {
    let multimint = get_multimint().await;
    let mm = multimint.read().await;
    mm.receive(federation_id, amount_msats).await
}

#[frb]
pub async fn send(federation_id: &FederationId, invoice: String) -> anyhow::Result<OperationId> {
    let multimint = get_multimint().await;
    let mm = multimint.read().await;
    mm.send(federation_id, invoice).await
}

#[frb]
pub async fn await_send(
    federation_id: &FederationId,
    operation_id: OperationId,
) -> anyhow::Result<FinalSendOperationState> {
    let multimint = get_multimint().await;
    let mm = multimint.read().await;
    mm.await_send(federation_id, operation_id).await
}

#[frb]
pub async fn await_receive(
    federation_id: &FederationId,
    operation_id: OperationId,
) -> anyhow::Result<FinalReceiveOperationState> {
    let multimint = get_multimint().await;
    let mm = multimint.read().await;
    mm.await_receive(federation_id, operation_id).await
}

#[frb]
pub async fn list_federations_from_nostr(force_update: bool) -> Vec<PublicFederation> {
    let multimint = get_multimint().await;
    let mut mm = multimint.write().await;
    if mm.public_federations.is_empty() || force_update {
        mm.update_federations_from_nostr().await;
    }
    mm.public_federations
        .clone()
        .into_iter()
        .filter(|pub_fed| !mm.clients.contains_key(&pub_fed.federation_id))
        .collect()
}

#[frb]
pub async fn parse_invoice(bolt11: String) -> anyhow::Result<PaymentPreview> {
    let invoice = Bolt11Invoice::from_str(&bolt11)?;
    let amount = invoice.amount_milli_satoshis().expect("No amount specified");
    let payment_hash = invoice.payment_hash().consensus_encode_to_hex();
    let network = invoice.network().to_string();
    Ok(PaymentPreview { amount, payment_hash, network, invoice: bolt11 })
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct PaymentPreview {
    amount: u64,
    payment_hash: String,
    network: String,
    invoice: String,
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

#[derive(Clone, Eq, PartialEq, Serialize)]
pub struct FederationSelector {
    pub federation_name: String,
    pub federation_id: FederationId,
    pub network: String,
}

impl Display for FederationSelector {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.federation_name)
    }
}

pub struct Multimint {
    db: Database,
    mnemonic: Mnemonic,
    modules: ClientModuleInitRegistry,
    clients: BTreeMap<FederationId, ClientHandleArc>,
    nostr_client: nostr_sdk::Client,
    public_federations: Vec<PublicFederation>,
    task_group: TaskGroup,
}

impl Multimint {
    pub async fn new() -> anyhow::Result<Self> {
        // TODO: Need android-safe path here
        let db: Database = RocksDb::open("client.db").await?.into();

        let mnemonic =
            if let Ok(entropy) = Client::load_decodable_client_secret::<Vec<u8>>(&db).await {
                Mnemonic::from_entropy(&entropy)?
            } else {
                let mnemonic = Bip39RootSecretStrategy::<12>::random(&mut thread_rng());

                Client::store_encodable_client_secret(&db, mnemonic.to_entropy()).await?;
                mnemonic
            };

        let mut modules = ClientModuleInitRegistry::new();
        modules.attach(LightningClientInit::default());
        modules.attach(MintClientInit);
        modules.attach(WalletClientInit::default());
        modules.attach(fedimint_lnv2_client::LightningClientInit::default());

        let mut multimint = Self {
            db,
            mnemonic,
            modules,
            clients: BTreeMap::new(),
            nostr_client: Multimint::create_nostr_client().await,
            public_federations: vec![],
            task_group: TaskGroup::new(),
        };
        multimint.load_clients().await?;
        Ok(multimint)
    }

    async fn load_clients(&mut self) -> anyhow::Result<()> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        let configs = dbtx
            .find_by_prefix(&FederationConfigKeyPrefix)
            .await
            .collect::<BTreeMap<FederationConfigKey, FederationConfig>>()
            .await;
        for (id, config) in configs {
            let client = self
                .build_client(&id.id, &config.invite_code, config.connector)
                .await?;
            self.clients.insert(id.id, client);
        }

        Ok(())
    }

    async fn create_nostr_client() -> nostr_sdk::Client {
        let keys = nostr_sdk::Keys::generate();
        let client = nostr_sdk::Client::builder().signer(keys).build();
        for relay in DEFAULT_RELAYS {
            Multimint::add_relay(&client, relay).await;
        }
        client
    }

    async fn add_relay(client: &nostr_sdk::Client, relay: &str) {
        if let Err(err) = client.add_relay(relay).await {
            println!("Could not add relay {}: {}", relay, err.fmt_compact());
        }
    }

    pub async fn update_federations_from_nostr(&mut self) {
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
                        // TODO: This is horrible code, it needs to be cleaned up so that it never crashes, only filters events that are not valid
                        let tags = event.tags.clone();
                        let n_tag = tags.find(nostr_sdk::TagKind::SingleLetter(
                            nostr_sdk::SingleLetterTag::lowercase(nostr_sdk::Alphabet::N),
                        ));
                        if n_tag.is_none() {
                            return None;
                        }
                        let network_str = n_tag.unwrap().content();
                        if network_str.is_none() {
                            return None;
                        }
                        let network = if network_str.unwrap() == "mainnet" {
                            Network::Bitcoin
                        } else {
                            Network::from_str(network_str.unwrap())
                                .expect("Network parsing should succeed")
                        };
                        if network == Network::Regtest {
                            println!("Skipping regtest federation...");
                            return None;
                        }

                        let json: Result<serde_json::Value, serde_json::Error> =
                            serde_json::from_str(&event.content);
                        let (federation_name, about, picture) = match json {
                            Ok(json) => {
                                let federation_name = json.get("name");
                                let federation_name = match federation_name {
                                    Some(name) => name
                                        .as_str()
                                        .expect("Could not parse federation name as str")
                                        .to_string(),
                                    None => json
                                        .get("federation_name")
                                        .expect("federation name and name do not exist")
                                        .as_str()
                                        .expect("Could not parse as str")
                                        .to_string(),
                                };
                                let about = json.get("about").map(|val| {
                                    val.as_str().expect("Could not parse as str").to_string()
                                });
                                let picture = json.get("picture").map(|val| {
                                    SafeUrl::parse(val.as_str().expect("Could not parse as str"))
                                        .expect("Could not parse as SafeUrl")
                                        .to_string()
                                });
                                (federation_name, about, picture)
                            }
                            Err(_) => {
                                let federation_name = event.content.to_string();
                                (federation_name, None, None)
                            }
                        };

                        let d_tag = tags.identifier().expect("should be present");
                        let federation_id = FederationId::from_str(d_tag).expect("Should parse");
                        let u_tag = tags.find(nostr_sdk::TagKind::SingleLetter(
                            nostr_sdk::SingleLetterTag::lowercase(nostr_sdk::Alphabet::U),
                        ));
                        let invite_codes = match u_tag {
                            Some(u_tag) => {
                                let invite_code =
                                    u_tag.content().expect("u tag not present").to_string();
                                vec![invite_code]
                            }
                            None => {
                                return None;
                            }
                        };
                        let modules = tags
                            .find(nostr_sdk::TagKind::custom("modules".to_string()))
                            .expect("Modules should be present")
                            .content()
                            .expect("Content should be present")
                            .split(",")
                            .map(|m| m.to_string())
                            .collect::<Vec<_>>();

                        Some(PublicFederation {
                            federation_name: federation_name.to_string(),
                            federation_id,
                            invite_codes,
                            about,
                            picture,
                            modules,
                            network: network.to_string(),
                        })
                    })
                    .collect::<Vec<_>>();

                println!("Public Federations: {events:?}");
                self.public_federations = events;
            }
            Err(e) => {
                println!("Failed to fetch events from nostr: {e}");
            }
        }
    }

    // TODO: Implement recovery
    pub async fn join_federation(
        &mut self,
        invite_code: String,
    ) -> anyhow::Result<FederationSelector> {
        let invite_code = InviteCode::from_str(&invite_code)?;
        let federation_id = invite_code.federation_id();
        if self.has_federation(&federation_id).await {
            bail!("Already joined federation")
        }

        let client = self
            .build_client(&federation_id, &invite_code, Connector::Tcp)
            .await?;

        let client_config = Connector::default()
            .download_from_invite_code(&invite_code)
            .await?;
        let federation_name = client_config
            .global
            .federation_name()
            .expect("No federation name")
            .to_owned();

        let wallet = client.get_first_module::<fedimint_wallet_client::WalletClientModule>()?;
        let network = wallet.get_network().to_string();
        let federation_config = FederationConfig {
            invite_code,
            connector: Connector::default(),
            federation_name: federation_name.clone(),
            network: network.clone(),
        };
        
        self.clients.insert(federation_id, client);

        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_new_entry(
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

    async fn has_federation(&self, federation_id: &FederationId) -> bool {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&FederationConfigKey { id: *federation_id })
            .await
            .is_some()
    }

    async fn build_client(
        &self,
        federation_id: &FederationId,
        invite_code: &InviteCode,
        connector: Connector,
    ) -> anyhow::Result<ClientHandleArc> {
        let client_db = self.get_client_database(&federation_id);
        let secret = Self::derive_federation_secret(&self.mnemonic, &federation_id);

        let mut client_builder = Client::builder(client_db).await?;
        client_builder.with_module_inits(self.modules.clone());
        client_builder.with_primary_module_kind(fedimint_mint_client::KIND);

        let client = if Client::is_initialized(client_builder.db_no_decoders()).await {
            client_builder.open(secret).await
        } else {
            let client_config = connector.download_from_invite_code(&invite_code).await?;
            client_builder
                .join(secret, client_config.clone(), invite_code.api_secret())
                .await
        }
        .map(Arc::new)?;

        self.lnv1_update_gateway_cache(&client).await?;
        Ok(client)
    }

    fn get_client_database(&self, federation_id: &FederationId) -> Database {
        let mut prefix = vec![crate::db::DbKeyPrefix::ClientDatabase as u8];
        prefix.append(&mut federation_id.consensus_encode_to_vec());
        self.db.with_prefix(prefix)
    }

    /// Derives a per-federation secret according to Fedimint's multi-federation
    /// secret derivation policy.
    fn derive_federation_secret(
        mnemonic: &Mnemonic,
        federation_id: &FederationId,
    ) -> DerivableSecret {
        let global_root_secret = Bip39RootSecretStrategy::<12>::to_root_secret(mnemonic);
        let multi_federation_root_secret = global_root_secret.child_key(ChildId(0));
        let federation_root_secret = multi_federation_root_secret.federation_key(federation_id);
        let federation_wallet_root_secret = federation_root_secret.child_key(ChildId(0));
        federation_wallet_root_secret.child_key(ChildId(0))
    }

    pub async fn federations(&self) -> Vec<FederationSelector> {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.find_by_prefix(&FederationConfigKeyPrefix)
            .await
            .map(|(id, config)| FederationSelector {
                federation_name: config.federation_name,
                federation_id: id.id,
                network: config.network,
            })
            .collect::<Vec<_>>()
            .await
    }

    pub async fn balance(&self, federation_id: &FederationId) -> u64 {
        let client = self
            .clients
            .get(federation_id)
            .expect("No federation exists");
        client.get_balance().await.msats
    }

    pub async fn receive(
        &self,
        federation_id: &FederationId,
        amount_msats: u64,
    ) -> anyhow::Result<(String, OperationId)> {
        let amount = Amount::from_msats(amount_msats);
        let client = self
            .clients
            .get(federation_id)
            .expect("No federation exists");

        if let Ok((invoice, operation_id)) = Self::receive_lnv2(client, amount).await {
            return Ok((invoice, operation_id));
        }

        Self::receive_lnv1(client, amount).await
    }

    async fn receive_lnv2(client: &ClientHandleArc, amount: Amount) -> anyhow::Result<(String, OperationId)> {
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let (invoice, operation_id) = lnv2
            .receive(
                amount,
                DEFAULT_EXPIRY_TIME_SECS,
                Bolt11InvoiceDescription::Direct(String::new()),
                None,
                ().into(),
            )
            .await?;
        Ok((invoice.to_string(), operation_id))
    }

    async fn receive_lnv1(client: &ClientHandleArc, amount: Amount) -> anyhow::Result<(String, OperationId)> {
        let lnv1 = client.get_first_module::<LightningClientModule>()?;
        let gateway = Self::lnv1_select_gateway(client).await;
        let desc = Description::new(String::new())?;
        let (operation_id, invoice, _) = lnv1.create_bolt11_invoice(amount, lightning_invoice::Bolt11InvoiceDescription::Direct(&desc), Some(DEFAULT_EXPIRY_TIME_SECS as u64), (), gateway).await?;
        Ok((invoice.to_string(), operation_id))
    }

    pub async fn send(
        &self,
        federation_id: &FederationId,
        invoice: String,
    ) -> anyhow::Result<OperationId> {
        let client = self
            .clients
            .get(federation_id)
            .expect("No federation exists");
        let invoice = Bolt11Invoice::from_str(&invoice)?;

        println!("Attempting to pay using LNv2...");
        if let Ok(lnv2_operation_id) = Self::pay_lnv2(client, invoice.clone()).await {
            println!("Successfully initated LNv2 payment");
            return Ok(lnv2_operation_id);
        }

        println!("Attempting to pay using LNv1...");
        let operation_id = Self::pay_lnv1(client, invoice).await?;
        println!("Successfully initiated LNv1 payment");
        Ok(operation_id)
    }

    async fn pay_lnv2(client: &ClientHandleArc, invoice: Bolt11Invoice) -> anyhow::Result<OperationId> {
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let operation_id = lnv2.send(invoice, None, ().into()).await?;
        Ok(operation_id)
    }

    async fn pay_lnv1(client: &ClientHandleArc, invoice: Bolt11Invoice) -> anyhow::Result<OperationId> {
        let lnv1 = client.get_first_module::<LightningClientModule>()?;
        let gateway = Self::lnv1_select_gateway(client).await;
        let outgoing_lightning_payment = lnv1.pay_bolt11_invoice(gateway, invoice, ()).await?;
        Ok(outgoing_lightning_payment.payment_type.operation_id())
    }

    pub async fn await_send(
        &self,
        federation_id: &FederationId,
        operation_id: OperationId,
    ) -> anyhow::Result<FinalSendOperationState> {
        let client = self
            .clients
            .get(federation_id)
            .expect("No federation exists");
        if let Ok(lnv2_final_state) = Self::await_send_lnv2(client, operation_id).await {
            return Ok(lnv2_final_state);
        }

        let lnv1_final_state = Self::await_send_lnv1(client, operation_id).await?;
        Ok(lnv1_final_state)
    }

    async fn await_send_lnv2(client: &ClientHandleArc, operation_id: OperationId) -> anyhow::Result<FinalSendOperationState> {
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let final_state = lnv2.await_final_send_operation_state(operation_id).await?;
        Ok(final_state)
    }

    async fn await_send_lnv1(client: &ClientHandleArc, operation_id: OperationId) -> anyhow::Result<FinalSendOperationState> {
        let lnv1 = client.get_first_module::<LightningClientModule>()?;
        // First check if its an internal payment
        if let Ok(updates) = lnv1.subscribe_internal_pay(operation_id).await {
            let mut stream = updates.into_stream();
            while let Some(update) = stream.next().await {
                match update {
                    InternalPayState::Preimage(_) => return Ok(FinalSendOperationState::Success),
                    InternalPayState::RefundSuccess { out_points: _, error: _ } => return Ok(FinalSendOperationState::Refunded),
                    InternalPayState::FundingFailed { error: _ } | InternalPayState::RefundError { error_message: _, error: _ } | InternalPayState::UnexpectedError(_) => {
                        return Ok(FinalSendOperationState::Failure);
                    }
                    _ => {}
                }
            }
        }

        // If internal fails, check if its an external payment
        if let Ok(updates) = lnv1.subscribe_ln_pay(operation_id).await {
            let mut stream = updates.into_stream();
            while let Some(update) = stream.next().await {
                match update {
                    LnPayState::Success { preimage: _ } => return Ok(FinalSendOperationState::Success),
                    LnPayState::Refunded { gateway_error: _ } => return Ok(FinalSendOperationState::Refunded),
                    LnPayState::UnexpectedError { error_message: _ } => return Ok(FinalSendOperationState::Failure),
                    _ => {}
                }
            }
        }

        Ok(FinalSendOperationState::Failure)
    }

    pub async fn await_receive(
        &self,
        federation_id: &FederationId,
        operation_id: OperationId,
    ) -> anyhow::Result<FinalReceiveOperationState> {
        let client = self
            .clients
            .get(federation_id)
            .expect("No federation exists");
        if let Ok(lnv2_final_state) = Self::await_receive_lnv2(client, operation_id).await {
            return Ok(lnv2_final_state);
        }

        Self::await_receive_lnv1(client, operation_id).await
    }

    async fn await_receive_lnv2(client: &ClientHandleArc, operation_id: OperationId) -> anyhow::Result<FinalReceiveOperationState> {
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let final_state = lnv2
            .await_final_receive_operation_state(operation_id)
            .await?;
        Ok(final_state)
    }

    async fn await_receive_lnv1(client: &ClientHandleArc, operation_id: OperationId) -> anyhow::Result<FinalReceiveOperationState> {
        let lnv1 = client.get_first_module::<LightningClientModule>()?;
        let mut updates = lnv1.subscribe_ln_receive(operation_id).await?.into_stream();
        while let Some(update) = updates.next().await {
            match update {
                LnReceiveState::Claimed => {
                    return Ok(FinalReceiveOperationState::Claimed);
                }
                LnReceiveState::Canceled{ reason: _ } => {
                    return Ok(FinalReceiveOperationState::Failure);
                }
                _ => {}
            }
        }

        Ok(FinalReceiveOperationState::Failure)
    }

    async fn lnv1_update_gateway_cache(&self, client: &ClientHandleArc) -> anyhow::Result<()> {
        let lnv1_client = client.clone();
        self.task_group.spawn_cancellable("update gateway cache", async move {
            let lnv1 = lnv1_client.get_first_module::<LightningClientModule>().expect("LNv1 should be present");
            match lnv1.update_gateway_cache().await {
                Ok(_) => println!("Updated gateway cache"),
                Err(e) => println!("Could not update gateway cache {e}"),
            }

            lnv1.update_gateway_cache_continuously(|gateway| async { gateway }).await
        });
        Ok(())
    }

    async fn lnv1_select_gateway(client: &ClientHandleArc) -> Option<fedimint_ln_common::LightningGateway> {
        let lnv1 = client.get_first_module::<LightningClientModule>().ok()?;
        let gateways = lnv1.list_gateways().await;

        if gateways.len() == 0 {
            return None;
        }

        if let Some(vetted) = gateways.iter().find(|gateway| gateway.vetted) {
            return Some(vetted.info.clone());
        }

        gateways.choose(&mut thread_rng()).map(|gateway| gateway.info.clone())
    }
}
