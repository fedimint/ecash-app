mod db;
mod frb_generated;
use fedimint_client::oplog::OperationLog;
use fedimint_core::config::ClientConfig;
use fedimint_core::db::mem_impl::MemDatabase;
use fedimint_core::hex;
use fedimint_core::secp256k1::rand::seq::SliceRandom;
use fedimint_core::task::TaskGroup;
use fedimint_meta_client::common::DEFAULT_META_KEY;
use fedimint_meta_client::MetaClientInit;
/* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use flutter_rust_bridge::frb;
use tokio::sync::{OnceCell, RwLock};

use std::time::UNIX_EPOCH;
use std::{collections::BTreeMap, fmt::Display, str::FromStr, sync::Arc, time::Duration};

use anyhow::{anyhow, bail};
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
use fedimint_ln_client::{
    InternalPayState, LightningClientInit, LightningClientModule, LightningOperationMetaVariant,
    LnPayState, LnReceiveState,
};
use fedimint_lnv2_client::{
    FinalReceiveOperationState, FinalSendOperationState, LightningOperationMeta,
    ReceiveOperationState, SendOperationState,
};
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
    let amount = invoice
        .amount_milli_satoshis()
        .expect("No amount specified");
    let payment_hash = invoice.payment_hash().consensus_encode_to_hex();
    let network = invoice.network().to_string();
    Ok(PaymentPreview {
        amount,
        payment_hash,
        network,
        invoice: bolt11,
    })
}

#[frb]
pub async fn get_federation_meta(
    invite_code: String,
) -> anyhow::Result<(FederationMeta, FederationSelector)> {
    let multimint = get_multimint().await;
    let mm = multimint.read().await;
    mm.get_federation_meta(invite_code).await
}

#[frb]
pub async fn transactions(federation_id: &FederationId, modules: Vec<String>) -> Vec<Transaction> {
    let multimint = get_multimint().await;
    let mm = multimint.read().await;
    mm.transactions(federation_id, modules).await
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
        match picture {
            Some(picture) => {
                match picture.as_str() {
                    Some(pic_url) => {
                        // Verify that the picture is a URL
                        let safe_url = SafeUrl::parse(pic_url).ok()?;
                        return Some(safe_url.to_string());
                    }
                    None => {}
                }
            }
            None => {}
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

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct FederationSelector {
    pub federation_name: String,
    pub federation_id: FederationId,
    pub network: String,
    pub num_peers: usize,
    pub invite_code: String,
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

#[derive(Debug, Serialize)]
pub struct FederationMeta {
    picture: Option<String>,
    welcome: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Transaction {
    received: bool,
    amount: u64,
    module: String,
    timestamp: u64,
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
        modules.attach(MetaClientInit);

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
                .build_client(&id.id, &config.invite_code, config.connector, false)
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
                        match PublicFederation::parse_network(&event.tags) {
                            Ok(network) if network == Network::Regtest => {
                                // Skip over regtest advertisements
                                return None;
                            }
                            _ => {}
                        }

                        PublicFederation::try_from(event.clone()).ok()
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

    async fn get_federation_meta(
        &self,
        invite: String,
    ) -> anyhow::Result<(FederationMeta, FederationSelector)> {
        // Sometimes we want to get the federation meta before we've joined (i.e to show a preview).
        // In this case, we create a temprorary client and retrieve all the data
        let invite_code = InviteCode::from_str(&invite)?;
        let federation_id = invite_code.federation_id();
        let client = if let Some(client) = self.clients.get(&federation_id) {
            client
        } else {
            &self
                .build_client(&federation_id, &invite_code, Connector::Tcp, true)
                .await?
        };

        let config = client.config().await;
        let wallet = client.get_first_module::<fedimint_wallet_client::WalletClientModule>()?;
        let network = wallet.get_network().to_string();
        let selector = FederationSelector {
            federation_name: config.global.federation_name().unwrap_or("").to_string(),
            federation_id,
            network,
            num_peers: config.global.api_endpoints.len(),
            invite_code: invite_code.to_string(),
        };

        let meta = client.get_first_module::<fedimint_meta_client::MetaClientModule>()?;
        let consensus = meta.get_consensus_value(DEFAULT_META_KEY).await?;
        match consensus {
            Some(value) => {
                let val = serde_json::to_value(value).expect("cant fail");
                let val = val
                    .get("value")
                    .ok_or(anyhow!("value not present"))?
                    .as_str()
                    .ok_or(anyhow!("value was not a string"))?;
                let str = hex::decode(val)?;
                let json = String::from_utf8(str)?;
                let meta: serde_json::Value = serde_json::from_str(&json)?;
                let welcome = if let Some(welcome) = meta.get("welcome_message") {
                    welcome.as_str().map(|s| s.to_string())
                } else {
                    None
                };
                let picture = if let Some(picture) = meta.get("fedi:federation_icon_url") {
                    let url_str = picture
                        .as_str()
                        .ok_or(anyhow!("icon url is not a string"))?;
                    // Verify that it is a url
                    Some(SafeUrl::parse(url_str)?.to_string())
                } else {
                    None
                };

                return Ok((FederationMeta { picture, welcome }, selector));
            }
            None => {}
        }

        Ok((
            FederationMeta {
                picture: None,
                welcome: None,
            },
            selector,
        ))
    }

    // TODO: Implement recovery
    pub async fn join_federation(&mut self, invite: String) -> anyhow::Result<FederationSelector> {
        let invite_code = InviteCode::from_str(&invite)?;
        let federation_id = invite_code.federation_id();
        if self.has_federation(&federation_id).await {
            bail!("Already joined federation")
        }

        let client = self
            .build_client(&federation_id, &invite_code, Connector::Tcp, false)
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
            client_config: client_config.clone(),
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
            num_peers: client_config.global.api_endpoints.len(),
            invite_code: invite,
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
        is_temporary: bool,
    ) -> anyhow::Result<ClientHandleArc> {
        let client_db = if is_temporary {
            MemDatabase::new().into()
        } else {
            self.get_client_database(&federation_id)
        };
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
                num_peers: config.client_config.global.api_endpoints.len(),
                invite_code: config.invite_code.to_string(),
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

    async fn receive_lnv2(
        client: &ClientHandleArc,
        amount: Amount,
    ) -> anyhow::Result<(String, OperationId)> {
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

    async fn receive_lnv1(
        client: &ClientHandleArc,
        amount: Amount,
    ) -> anyhow::Result<(String, OperationId)> {
        let lnv1 = client.get_first_module::<LightningClientModule>()?;
        let gateway = Self::lnv1_select_gateway(client).await;
        let desc = Description::new(String::new())?;
        let (operation_id, invoice, _) = lnv1
            .create_bolt11_invoice(
                amount,
                lightning_invoice::Bolt11InvoiceDescription::Direct(&desc),
                Some(DEFAULT_EXPIRY_TIME_SECS as u64),
                (),
                gateway,
            )
            .await?;
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

    async fn pay_lnv2(
        client: &ClientHandleArc,
        invoice: Bolt11Invoice,
    ) -> anyhow::Result<OperationId> {
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let operation_id = lnv2.send(invoice, None, ().into()).await?;
        Ok(operation_id)
    }

    async fn pay_lnv1(
        client: &ClientHandleArc,
        invoice: Bolt11Invoice,
    ) -> anyhow::Result<OperationId> {
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

        let send_state = match Self::await_send_lnv2(client, operation_id).await {
            Ok(lnv2_final_state) => lnv2_final_state,
            Err(_) => Self::await_send_lnv1(client, operation_id).await?,
        };
        OperationLog::set_operation_outcome(client.db(), operation_id, &send_state).await?;
        Ok(send_state)
    }

    async fn await_send_lnv2(
        client: &ClientHandleArc,
        operation_id: OperationId,
    ) -> anyhow::Result<FinalSendOperationState> {
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let final_state = lnv2.await_final_send_operation_state(operation_id).await?;
        Ok(final_state)
    }

    async fn await_send_lnv1(
        client: &ClientHandleArc,
        operation_id: OperationId,
    ) -> anyhow::Result<FinalSendOperationState> {
        let lnv1 = client.get_first_module::<LightningClientModule>()?;
        // First check if its an internal payment
        if let Ok(updates) = lnv1.subscribe_internal_pay(operation_id).await {
            let mut stream = updates.into_stream();
            while let Some(update) = stream.next().await {
                match update {
                    InternalPayState::Preimage(_) => return Ok(FinalSendOperationState::Success),
                    InternalPayState::RefundSuccess {
                        out_points: _,
                        error: _,
                    } => return Ok(FinalSendOperationState::Refunded),
                    InternalPayState::FundingFailed { error: _ }
                    | InternalPayState::RefundError {
                        error_message: _,
                        error: _,
                    }
                    | InternalPayState::UnexpectedError(_) => {
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
                    LnPayState::Success { preimage: _ } => {
                        return Ok(FinalSendOperationState::Success)
                    }
                    LnPayState::Refunded { gateway_error: _ } => {
                        return Ok(FinalSendOperationState::Refunded)
                    }
                    LnPayState::UnexpectedError { error_message: _ } => {
                        return Ok(FinalSendOperationState::Failure)
                    }
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
        let receive_state = match Self::await_receive_lnv2(client, operation_id).await {
            Ok(lnv2_final_state) => lnv2_final_state,
            Err(_) => Self::await_receive_lnv1(client, operation_id).await?,
        };
        OperationLog::set_operation_outcome(client.db(), operation_id, &receive_state).await?;
        Ok(receive_state)
    }

    async fn await_receive_lnv2(
        client: &ClientHandleArc,
        operation_id: OperationId,
    ) -> anyhow::Result<FinalReceiveOperationState> {
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let final_state = lnv2
            .await_final_receive_operation_state(operation_id)
            .await?;
        Ok(final_state)
    }

    async fn await_receive_lnv1(
        client: &ClientHandleArc,
        operation_id: OperationId,
    ) -> anyhow::Result<FinalReceiveOperationState> {
        let lnv1 = client.get_first_module::<LightningClientModule>()?;
        let mut updates = lnv1.subscribe_ln_receive(operation_id).await?.into_stream();
        while let Some(update) = updates.next().await {
            match update {
                LnReceiveState::Claimed => {
                    return Ok(FinalReceiveOperationState::Claimed);
                }
                LnReceiveState::Canceled { reason: _ } => {
                    return Ok(FinalReceiveOperationState::Failure);
                }
                _ => {}
            }
        }

        Ok(FinalReceiveOperationState::Failure)
    }

    async fn lnv1_update_gateway_cache(&self, client: &ClientHandleArc) -> anyhow::Result<()> {
        let lnv1_client = client.clone();
        self.task_group
            .spawn_cancellable("update gateway cache", async move {
                let lnv1 = lnv1_client
                    .get_first_module::<LightningClientModule>()
                    .expect("LNv1 should be present");
                match lnv1.update_gateway_cache().await {
                    Ok(_) => println!("Updated gateway cache"),
                    Err(e) => println!("Could not update gateway cache {e}"),
                }

                lnv1.update_gateway_cache_continuously(|gateway| async { gateway })
                    .await
            });
        Ok(())
    }

    async fn lnv1_select_gateway(
        client: &ClientHandleArc,
    ) -> Option<fedimint_ln_common::LightningGateway> {
        let lnv1 = client.get_first_module::<LightningClientModule>().ok()?;
        let gateways = lnv1.list_gateways().await;

        if gateways.len() == 0 {
            return None;
        }

        if let Some(vetted) = gateways.iter().find(|gateway| gateway.vetted) {
            return Some(vetted.info.clone());
        }

        gateways
            .choose(&mut thread_rng())
            .map(|gateway| gateway.info.clone())
    }

    // TODO: Paginate this
    async fn transactions(
        &self,
        federation_id: &FederationId,
        modules: Vec<String>,
    ) -> Vec<Transaction> {
        let client = self
            .clients
            .get(federation_id)
            .expect("No federation exists");

        let page = client
            .operation_log()
            .paginate_operations_rev(10, None)
            .await;
        let transactions = page
            .iter()
            .filter_map(|(key, op_log_val)| {
                if !modules.contains(&op_log_val.operation_module_kind().to_string()) {
                    return None;
                }

                let ts = key.creation_time;
                let timestamp = ts
                    .duration_since(UNIX_EPOCH)
                    .expect("Cannot be before unix epoch")
                    .as_millis() as u64;

                match op_log_val.operation_module_kind() {
                    "lnv2" => {
                        let meta = op_log_val.meta::<LightningOperationMeta>();
                        match meta {
                            LightningOperationMeta::Receive(receive) => {
                                // TODO: Maybe include as pending
                                if op_log_val.outcome::<ReceiveOperationState>().is_none() {
                                    return None;
                                }

                                Some(Transaction {
                                    received: true,
                                    amount: receive.contract.commitment.amount.msats,
                                    module: "lnv2".to_string(),
                                    timestamp,
                                })
                            }
                            LightningOperationMeta::Send(send) => {
                                // TODO: Maybe include as pending
                                if op_log_val.outcome::<SendOperationState>().is_none() {
                                    return None;
                                }
                                Some(Transaction {
                                    received: false,
                                    amount: send.contract.amount.msats,
                                    module: "lnv2".to_string(),
                                    timestamp,
                                })
                            }
                        }
                    }
                    "ln" => {
                        let meta = op_log_val.meta::<fedimint_ln_client::LightningOperationMeta>();
                        match meta.variant {
                            LightningOperationMetaVariant::Pay(send) => {
                                // TODO: Maybe include as pending
                                if op_log_val.outcome::<SendOperationState>().is_none() {
                                    return None;
                                }
                                Some(Transaction {
                                    received: false,
                                    amount: send
                                        .invoice
                                        .amount_milli_satoshis()
                                        .expect("Cannot pay amountless invoice"),
                                    module: "ln".to_string(),
                                    timestamp,
                                })
                            }
                            LightningOperationMetaVariant::Receive {
                                out_point: _,
                                invoice,
                                gateway_id: _,
                            } => {
                                // TODO: Maybe include as pending
                                if op_log_val.outcome::<ReceiveOperationState>().is_none() {
                                    return None;
                                }

                                Some(Transaction {
                                    received: true,
                                    amount: invoice
                                        .amount_milli_satoshis()
                                        .expect("Cannot receive amountless invoice"),
                                    module: "ln".to_string(),
                                    timestamp,
                                })
                            }
                            LightningOperationMetaVariant::RecurringPaymentReceive(recurring) => {
                                // TODO: Maybe include as pending
                                if op_log_val.outcome::<ReceiveOperationState>().is_none() {
                                    return None;
                                }
                                Some(Transaction {
                                    received: true,
                                    amount: recurring
                                        .invoice
                                        .amount_milli_satoshis()
                                        .expect("Cannot receive amountless invoice"),
                                    module: "ln".to_string(),
                                    timestamp,
                                })
                            }
                            _ => None,
                        }
                    }
                    _ => None,
                }
            })
            .collect::<Vec<_>>();

        transactions
    }
}
