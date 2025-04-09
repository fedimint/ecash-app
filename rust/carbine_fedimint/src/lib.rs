mod db;
mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */

use std::{str::FromStr, sync::Arc};

use db::Redb;
use fedimint_api_client::api::net::Connector;
use fedimint_bip39::{Bip39RootSecretStrategy, Mnemonic};
use fedimint_client::{
    module::init::ClientModuleInitRegistry,
    secret::{get_default_client_secret, RootSecretStrategy},
    Client, ClientHandleArc,
};
use fedimint_core::{db::Database, invite_code::InviteCode, secp256k1::rand::thread_rng};
use fedimint_ln_client::LightningClientInit;
use fedimint_mint_client::MintClientInit;
use fedimint_wallet_client::WalletClientInit;
use flutter_rust_bridge::frb;
use serde::Serialize;

#[derive(Serialize)]
pub struct JoinFederation {
    pub name: String,
    pub federation_id: String,
    pub balance: u64,
}

#[frb]
pub async fn join_federation(invite_code: String) -> anyhow::Result<JoinFederation> {
    let invite_code = InviteCode::from_str(&invite_code)?;
    let client = client_join(invite_code).await?;
    let config = client.config().await;
    let name = config.global.federation_name();
    let federation_id = client.federation_id();
    let balance = client.get_balance().await;
    Ok(JoinFederation {
        name: name.expect("No federation name").to_string(),
        federation_id: federation_id.to_string(),
        balance: balance.msats,
    })
}

async fn client_join(invite_code: InviteCode) -> anyhow::Result<ClientHandleArc> {
    let connector = Connector::default();
    let client_config = connector.download_from_invite_code(&invite_code).await?;
    let database: Database = Redb::open("fedimint.redb")?.into();
    let mut client_builder = Client::builder(database).await?;
    let mut modules = ClientModuleInitRegistry::new();
    modules.attach(LightningClientInit::default());
    modules.attach(MintClientInit);
    modules.attach(WalletClientInit::default());
    modules.attach(fedimint_lnv2_client::LightningClientInit::default());
    client_builder.with_module_inits(modules);
    client_builder.with_primary_module_kind(fedimint_mint_client::KIND);

    let mnemonic = load_or_generate_mnemonic(client_builder.db_no_decoders()).await?;

    let client = client_builder
        .join(
            get_default_client_secret(
                &Bip39RootSecretStrategy::<12>::to_root_secret(&mnemonic),
                &client_config.global.calculate_federation_id(),
            ),
            client_config.clone(),
            invite_code.api_secret(),
        )
        .await
        .map(Arc::new)?;

    Ok(client)
}

async fn load_or_generate_mnemonic(db: &Database) -> anyhow::Result<Mnemonic> {
    Ok(
        if let Ok(entropy) = Client::load_decodable_client_secret::<Vec<u8>>(db).await {
            Mnemonic::from_entropy(&entropy)?
        } else {
            let mnemonic = Bip39RootSecretStrategy::<12>::random(&mut thread_rng());
            Client::store_encodable_client_secret(db, mnemonic.to_entropy()).await?;
            mnemonic
        },
    )
}
