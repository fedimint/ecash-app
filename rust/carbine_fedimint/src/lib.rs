mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
mod db;
use flutter_rust_bridge::frb;
use tokio::sync::{OnceCell, RwLock};

use std::{collections::BTreeMap, fmt::Display, str::FromStr, sync::Arc};

use anyhow::bail;
use fedimint_api_client::api::net::Connector;
use fedimint_bip39::{Bip39RootSecretStrategy, Mnemonic};
use fedimint_client::{
    module_init::ClientModuleInitRegistry, secret::RootSecretStrategy, Client, ClientHandleArc,
    OperationId,
};
use fedimint_core::{
    config::FederationId,
    db::{Database, IDatabaseTransactionOpsCoreTyped},
    encoding::Encodable,
    invite_code::InviteCode,
    secp256k1::rand::thread_rng,
    Amount,
};
use fedimint_derive_secret::{ChildId, DerivableSecret};
use fedimint_ln_client::LightningClientInit;
use fedimint_lnv2_client::{FinalReceiveOperationState, FinalSendOperationState};
use fedimint_lnv2_common::Bolt11InvoiceDescription;
use fedimint_mint_client::MintClientInit;
use fedimint_rocksdb::RocksDb;
use fedimint_wallet_client::WalletClientInit;
use futures_util::StreamExt;
use lightning_invoice::Bolt11Invoice;
use serde::Serialize;

use crate::db::{FederationConfig, FederationConfigKey, FederationConfigKeyPrefix};

static MULTIMINT: OnceCell<Arc<RwLock<Multimint>>> = OnceCell::const_new();

async fn init_global() -> Arc<RwLock<Multimint>> {
    Arc::new(RwLock::new(Multimint::new().await.expect("Could not create multimint")))
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
pub async fn balance(federation_id: &FederationId) -> Amount {
    let multimint = get_multimint().await;
    let mm = multimint.read().await;
    mm.balance(federation_id).await
}

#[frb]
pub async fn receive(
    federation_id: &FederationId,
    amount: Amount,
) -> anyhow::Result<(String, OperationId)> {
    let multimint = get_multimint().await;
    let mm = multimint.read().await;
    mm.receive(federation_id, amount).await
}

#[frb]
pub async fn send(
    federation_id: &FederationId,
    invoice: String,
) -> anyhow::Result<OperationId> {
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


#[derive(Clone, Eq, PartialEq, Serialize)]
pub struct FederationSelector {
    pub federation_name: String,
    pub federation_id: FederationId,
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
        let federation_config = FederationConfig {
            invite_code,
            connector: Connector::default(),
            federation_name: federation_name.clone(),
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

        if Client::is_initialized(client_builder.db_no_decoders()).await {
            client_builder.open(secret).await
        } else {
            let client_config = connector.download_from_invite_code(&invite_code).await?;
            client_builder
                .join(secret, client_config.clone(), invite_code.api_secret())
                .await
        }
        .map(Arc::new)
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
            })
            .collect::<Vec<_>>()
            .await
    }

    pub async fn balance(&self, federation_id: &FederationId) -> Amount {
        let client = self
            .clients
            .get(federation_id)
            .expect("No federation exists");
        client.get_balance().await
    }

    pub async fn receive(
        &self,
        federation_id: &FederationId,
        amount: Amount,
    ) -> anyhow::Result<(String, OperationId)> {
        let client = self
            .clients
            .get(federation_id)
            .expect("No federation exists");
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        const DEFAULT_EXPIRY_TIME_SECS: u32 = 86400;
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

    pub async fn send(
        &self,
        federation_id: &FederationId,
        invoice: String,
    ) -> anyhow::Result<OperationId> {
        let client = self
            .clients
            .get(federation_id)
            .expect("No federation exists");
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let invoice = Bolt11Invoice::from_str(&invoice)?;
        let operation_id = lnv2.send(invoice, None, ().into()).await?;
        Ok(operation_id)
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
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let final_state = lnv2.await_final_send_operation_state(operation_id).await?;

        Ok(final_state)
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
        let lnv2 = client.get_first_module::<fedimint_lnv2_client::LightningClientModule>()?;
        let final_state = lnv2
            .await_final_receive_operation_state(operation_id)
            .await?;
        Ok(final_state)
    }
}