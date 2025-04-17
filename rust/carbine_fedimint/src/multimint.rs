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
use flutter_rust_bridge::frb;
use futures_util::StreamExt;
use lightning_invoice::Bolt11Invoice;
use serde::Serialize;

use crate::db::{FederationConfig, FederationConfigKey, FederationConfigKeyPrefix};

#[derive(Clone, Eq, PartialEq, Serialize)]
struct FederationSelector {
    federation_name: String,
    federation_id: FederationId,
}

impl Display for FederationSelector {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.federation_name)
    }
}

#[frb]
pub struct Multimint {
    db: Database,
    mnemonic: Mnemonic,
    modules: ClientModuleInitRegistry,
    clients: BTreeMap<FederationId, ClientHandleArc>,
}

#[frb]
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
    #[frb]
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

    #[frb]
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

    #[frb]
    pub async fn balance(&self, federation_id: &FederationId) -> Amount {
        let client = self
            .clients
            .get(federation_id)
            .expect("No federation exists");
        client.get_balance().await
    }

    #[frb]
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

    #[frb]
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

    #[frb]
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

    #[frb]
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