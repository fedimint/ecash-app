use std::{collections::BTreeMap, sync::Arc, time::Duration, str::FromStr};

use fedimint_client::ClientHandleArc;
use fedimint_core::{Amount, config::FederationId, task::TaskGroup};
use fedimint_wallet_client::{DepositStateV2, WalletClientModule, WalletOperationMeta, WalletOperationMetaVariant, api::WalletFederationApi, client_db::TweakIdx};
use futures_util::StreamExt;
use tokio::sync::{RwLock, mpsc::{UnboundedReceiver, UnboundedSender}};

use crate::{event_bus::EventBus, get_event_bus, info_to_flutter, multimint::{AwaitingConfsEvent, ClaimedEvent, ConfirmedEvent, DepositEventKind, MempoolEvent, MultimintEvent}};


#[derive(Clone)]
pub(crate) struct WalletHandler {
    pegin_address_monitor_tx: UnboundedSender<(FederationId, TweakIdx)>,
    allocated_bitcoin_addresses:
        Arc<RwLock<BTreeMap<FederationId, BTreeMap<TweakIdx, (String, Option<u64>)>>>>,
    task_group: TaskGroup,
}

impl WalletHandler {
    pub(crate) fn new(monitor_tx: UnboundedSender<(FederationId, TweakIdx)>, task_group: TaskGroup) -> Self { 
        Self {
            pegin_address_monitor_tx: monitor_tx,
            allocated_bitcoin_addresses: Arc::new(RwLock::new(BTreeMap::new())),
            task_group,
        }
    }

    pub(crate) fn spawn_pegin_address_watcher(
        &self,
        mut monitor_rx: UnboundedReceiver<(FederationId, TweakIdx)>,
        clients: Arc<RwLock<BTreeMap<FederationId, ClientHandleArc>>>,
    ) {
        let event_bus_clone = get_event_bus();
        let addresses_clone = self.allocated_bitcoin_addresses.clone();
        let task_group_clone = self.task_group.clone();

        self.task_group
            .spawn_cancellable("pegin address watcher", async move {
                while let Some((fed_id, tweak_idx)) = monitor_rx.recv().await {
                    let event_bus = event_bus_clone.clone();
                    // wrapping the clients in Arc<RwLock<..>> allows us to monitor using clients
                    // created after the background task is spawned
                    let client = clients
                        .read()
                        .await
                        .get(&fed_id)
                        .expect("No federation exists")
                        .clone();

                    let addresses_clone = addresses_clone.clone();
                    task_group_clone.spawn_cancellable("tweak index watcher", async move {
                        if let Err(e) = Self::watch_pegin_address(
                            fed_id,
                            client,
                            tweak_idx,
                            event_bus,
                            addresses_clone,
                        )
                        .await
                        {
                            info_to_flutter(format!(
                                "watch_pegin_address({}) failed: {:?}",
                                tweak_idx.0, e
                            ))
                            .await;
                        }
                    });
                }
            });
    }

    #[allow(clippy::type_complexity)]
    async fn watch_pegin_address(
        federation_id: FederationId,
        client: ClientHandleArc,
        tweak_idx: TweakIdx,
        event_bus: EventBus<MultimintEvent>,
        addresses: Arc<RwLock<BTreeMap<FederationId, BTreeMap<TweakIdx, (String, Option<u64>)>>>>,
    ) -> anyhow::Result<()> {
        let wallet_module = client.get_first_module::<WalletClientModule>()?;

        let data = match wallet_module.get_pegin_tweak_idx(tweak_idx).await {
            Ok(d) => d,
            Err(e) if e.to_string().contains("TweakIdx not found") => return Ok(()),
            Err(e) => return Err(e),
        };

        let mut updates = wallet_module
            .subscribe_deposit(data.operation_id)
            .await?
            .into_stream();

        while let Some(state) = updates.next().await {
            match state {
                DepositStateV2::WaitingForTransaction => {}
                DepositStateV2::WaitingForConfirmation {
                    btc_deposited,
                    btc_out_point,
                } => {
                    track_pegin_confirmation(
                        federation_id,
                        wallet_module.get_network(),
                        btc_deposited,
                        btc_out_point,
                        event_bus.clone(),
                        || async {
                            Ok(wallet_module.api.fetch_consensus_block_count().await?)
                        },
                    )
                    .await?;

                    // trigger another check of pegin monitor for faster claim
                    wallet_module.recheck_pegin_address(tweak_idx).await?;
                }
                DepositStateV2::Confirmed {
                    btc_deposited,
                    btc_out_point,
                } => {
                    let mut addresses = addresses.write().await;
                    if let Some(fed_addresses) = addresses.get_mut(&federation_id) {
                        if let Some((address, _)) = fed_addresses.remove(&tweak_idx) {
                            fed_addresses
                                .insert(tweak_idx, (address, Some(btc_deposited.to_sat())));
                        }
                    }

                    let deposit_event = MultimintEvent::Deposit((
                        federation_id,
                        DepositEventKind::Confirmed(ConfirmedEvent {
                            amount: Amount::from_sats(btc_deposited.to_sat()).msats,
                            outpoint: btc_out_point.to_string(),
                        }),
                    ));

                    event_bus.publish(deposit_event).await;
                }
                DepositStateV2::Claimed {
                    btc_deposited,
                    btc_out_point,
                } => {
                    let deposit_event = MultimintEvent::Deposit((
                        federation_id,
                        DepositEventKind::Claimed(ClaimedEvent {
                            amount: Amount::from_sats(btc_deposited.to_sat()).msats,
                            outpoint: btc_out_point.to_string(),
                        }),
                    ));

                    event_bus.publish(deposit_event).await;
                }
                DepositStateV2::Failed(e) => {
                    info_to_flutter(format!("deposit failed: {:?}", e)).await;
                    break;
                }
            };
        }

        Ok(())
    }

    pub(crate) fn monitor_all_unused_pegin_addresses(
        &self,
        clients: Arc<RwLock<BTreeMap<FederationId, ClientHandleArc>>>,
    ) {
        let pegin_address_monitor_tx_clone = self.pegin_address_monitor_tx.clone();
        let addresses_clone = self.allocated_bitcoin_addresses.clone();

        self.task_group
            .spawn_cancellable("unused address monitor", async move {
                let clients_guard = clients.read().await;
                for (fed_id, client) in clients_guard.iter() {
                    let wallet_module = client
                        .get_first_module::<WalletClientModule>()
                        .expect("No wallet module exists");

                    let operation_log = client.operation_log();

                    let mut tweak_idx = TweakIdx(0);
                    while let Ok(data) = wallet_module.get_pegin_tweak_idx(tweak_idx).await {
                        let operation = operation_log.get_operation(data.operation_id).await;
                        if let Some(wallet_op) = operation {
                            if data.claimed.is_empty() {
                                // we found an allocated, unused address so we need to monitor
                                if pegin_address_monitor_tx_clone
                                    .send((*fed_id, tweak_idx))
                                    .is_err()
                                {
                                    info_to_flutter(format!(
                                        "failed to monitor tweak index {:?} for fed {:?}",
                                        tweak_idx, fed_id
                                    ))
                                    .await;
                                }
                            }

                            let wallet_meta = wallet_op.meta::<WalletOperationMeta>();
                            if let WalletOperationMetaVariant::Deposit {
                                address,
                                tweak_idx,
                                expires_at: _,
                            } = wallet_meta.variant
                            {
                                let mut addresses = addresses_clone.write().await;
                                let fed_addresses =
                                    addresses.entry(*fed_id).or_insert(BTreeMap::new());
                                if let Some(DepositStateV2::Claimed { btc_deposited, .. }) =
                                    wallet_op.outcome()
                                {
                                    fed_addresses.insert(
                                        tweak_idx.expect("Tweak cannot be None"),
                                        (
                                            address.assume_checked().to_string(),
                                            Some(btc_deposited.to_sat()),
                                        ),
                                    );
                                } else {
                                    fed_addresses.insert(
                                        tweak_idx.expect("Tweak cannot be None"),
                                        (address.assume_checked().to_string(), None),
                                    );
                                }
                            }
                        }

                        tweak_idx = tweak_idx.next();
                    }
                }
            });
    }

    async fn monitor_deposit_address(
        &self,
        federation_id: FederationId,
        address: String,
        client: ClientHandleArc,
    ) -> anyhow::Result<Option<u64>> {
        // walletv2 has no tweak index: addresses are derived locally and the
        // module's background scanner detects and claims deposits. Mempool and
        // confirmation tracking is driven off the event log (wired up
        // separately via `track_pegin_confirmation`), so there is nothing to
        // register here yet.
        if client
            .get_first_module::<fedimint_walletv2_client::WalletClientModule>()
            .is_ok()
        {
            return Ok(None);
        }

        let wallet_module = client.get_first_module::<WalletClientModule>()?;
        let address = bitcoin::Address::from_str(&address)?;
        let tweak_idx = wallet_module
            .find_tweak_idx_by_address(address.clone())
            .await?;
        let mut addresses = self.allocated_bitcoin_addresses.write().await;
        let fed_addresses = addresses.entry(federation_id).or_insert(BTreeMap::new());
        fed_addresses.insert(tweak_idx, (address.assume_checked().to_string(), None));

        self.pegin_address_monitor_tx
            .send((federation_id, tweak_idx))
            .map_err(|e| anyhow::anyhow!("failed to monitor tweak index: {}", e))?;

        Ok(Some(tweak_idx.0))
    }

    pub(crate) async fn get_addresses(
        &self,
        federation_id: &FederationId,
    ) -> Vec<(String, Option<u64>, Option<u64>)> {
        let addresses = self.allocated_bitcoin_addresses.read().await;
        if let Some(fed_addresses) = addresses.get(federation_id) {
            let mut res: Vec<_> = fed_addresses
                .iter()
                .map(|(k, v)| (v.0.clone(), Some(k.0), v.1))
                .collect();
            res.sort_by_key(|entry| entry.1);
            res
        } else {
            Vec::new()
        }
    }

    pub(crate) async fn allocate_deposit_address(
        &self,
        federation_id: FederationId,
        client: ClientHandleArc,
    ) -> anyhow::Result<(String, Option<u64>)> {
        let address = if let Ok(wallet_module) =
            client.get_first_module::<fedimint_walletv2_client::WalletClientModule>()
        {
            // walletv2 derives the next unused receive address locally; there is
            // no tweak index and the background scanner handles claiming.
            wallet_module.receive().await.to_string()
        } else {
            let wallet_module =
                client.get_first_module::<fedimint_wallet_client::WalletClientModule>()?;
            wallet_module
                .safe_allocate_deposit_address(())
                .await?
                .address
                .to_string()
        };

        let tweak_idx = self
            .monitor_deposit_address(federation_id, address.clone(), client)
            .await?;

        Ok((address, tweak_idx))
    }
}

/// Resolves the esplora/mempool.space API base URL for the given network.
fn mempool_api_url(network: bitcoin::Network) -> String {
    match network {
        bitcoin::Network::Bitcoin => "https://mempool.space/api".to_string(),
        bitcoin::Network::Signet => "https://mutinynet.com/api".to_string(),
        bitcoin::Network::Regtest => {
            // referencing devimint, uncomment for regtest
            // "http://localhost:{FM_PORT_ESPLORA}".to_string()
            panic!("Regtest requires manually setting the connection params")
        }
        network => {
            panic!("{network} is not a supported network")
        }
    }
}

/// Tracks a peg-in deposit from mempool detection through consensus
/// confirmation, publishing `Mempool` and `AwaitingConfs` deposit events.
///
/// This is shared by walletv1 and walletv2. The deposit's outpoint and amount
/// are surfaced differently by each module (the v1 deposit stream vs. the v2
/// event log), and consensus block height is fetched differently as well, so
/// the caller supplies a `consensus_block_count` fetcher.
pub(crate) async fn track_pegin_confirmation<F, Fut>(
    federation_id: FederationId,
    network: bitcoin::Network,
    btc_deposited: bitcoin::Amount,
    btc_out_point: bitcoin::OutPoint,
    event_bus: EventBus<MultimintEvent>,
    consensus_block_count: F,
) -> anyhow::Result<()>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = anyhow::Result<u64>>,
{
    let amount_msats = Amount::from_sats(btc_deposited.to_sat()).msats;

    event_bus
        .publish(MultimintEvent::Deposit((
            federation_id,
            DepositEventKind::Mempool(MempoolEvent {
                amount: amount_msats,
                outpoint: btc_out_point.to_string(),
            }),
        )))
        .await;

    let api_url = mempool_api_url(network);
    let http = reqwest::Client::new();

    let tx_height = fedimint_core::util::retry(
        "get confirmed block height",
        fedimint_core::util::backoff_util::background_backoff(),
        || async {
            let resp = http
                .get(format!("{}/tx/{}", api_url, btc_out_point.txid))
                .send()
                .await?
                .error_for_status()?
                .text()
                .await?;

            serde_json::from_str::<serde_json::Value>(&resp)?
                .get("status")
                .and_then(|s| s.get("block_height"))
                .and_then(|h| h.as_u64())
                .ok_or_else(|| anyhow::anyhow!("no confirmation height yet, still in mempool"))
        },
    )
    .await
    .expect("Never gives up");

    let every_10_secs = fedimint_core::util::backoff_util::custom_backoff(
        Duration::from_secs(10),
        Duration::from_secs(10),
        None,
    );
    fedimint_core::util::retry("consensus confirmation", every_10_secs, || async {
        let consensus_height = consensus_block_count().await?.saturating_sub(1);

        let needed = tx_height.saturating_sub(consensus_height);

        event_bus
            .publish(MultimintEvent::Deposit((
                federation_id,
                DepositEventKind::AwaitingConfs(AwaitingConfsEvent {
                    amount: amount_msats,
                    outpoint: btc_out_point.to_string(),
                    block_height: tx_height,
                    needed,
                }),
            )))
            .await;
        anyhow::ensure!(needed == 0, "{} more confs needed", needed);

        Ok(())
    })
    .await
    .expect("Never gives up");

    Ok(())
}