use std::{collections::BTreeMap, sync::Arc, time::Duration, str::FromStr};

use fedimint_client::ClientHandleArc;
use fedimint_core::{Amount, config::FederationId, task::TaskGroup};
use fedimint_eventlog::{Event, EventLogId};
use fedimint_wallet_client::{DepositStateV2, WalletClientModule, WalletOperationMeta, WalletOperationMetaVariant, api::WalletFederationApi, client_db::TweakIdx};
use fedimint_walletv2_client::{
    FinalReceiveOperationState, WalletClientModule as WalletV2Module,
    events::ReceivePaymentEvent as V2ReceivePaymentEvent,
};
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
                        btc_out_point.txid,
                        btc_out_point.to_string(),
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
                    // walletv2 federations have no v1 wallet module and no tweak
                    // indices to scan; their unused deposit addresses are tracked
                    // by the poller + event-log listener, so skip them here
                    // instead of panicking.
                    let Ok(wallet_module) = client.get_first_module::<WalletClientModule>() else {
                        info_to_flutter(format!(
                            "monitor_all_unused_pegin_addresses: skipping fed {fed_id} (no walletv1 module)"
                        ))
                        .await;
                        continue;
                    };

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
        // module's background scanner detects and claims confirmed deposits. The
        // federation has no mempool visibility for walletv2, so we poll esplora
        // ourselves to surface mempool/confirmation progress, and the event-log
        // listener (see `spawn_v2_deposit_event_listener`) surfaces confirmed and
        // claimed. There is no tweak index to return.
        if client.get_first_module::<WalletV2Module>().is_ok() {
            info_to_flutter(format!(
                "monitor_deposit_address: walletv2 detected for fed {federation_id}, spawning deposit poller for address {address}"
            ))
            .await;
            self.spawn_v2_deposit_poller(federation_id, address, client);
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
        let address = if let Ok(wallet_module) = client.get_first_module::<WalletV2Module>() {
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

    /// Spawns a background task that watches the chain for a deposit to a
    /// walletv2 receive `address`, surfacing mempool and confirmation progress.
    fn spawn_v2_deposit_poller(
        &self,
        federation_id: FederationId,
        address: String,
        client: ClientHandleArc,
    ) {
        let event_bus = get_event_bus();
        self.task_group
            .spawn_cancellable("walletv2 deposit poller", async move {
                if let Err(e) =
                    Self::watch_v2_pegin_address(federation_id, address.clone(), client, event_bus)
                        .await
                {
                    info_to_flutter(format!("watch_v2_pegin_address({address}) failed: {e:?}"))
                        .await;
                }
            });
    }

    /// Polls esplora for an incoming deposit to a walletv2 receive address and
    /// then tracks it through consensus confirmation.
    ///
    /// walletv2 deposits are claimed by the module's background scanner once
    /// confirmed, and the confirmed/claimed states are surfaced by the event-log
    /// listener (see `spawn_v2_deposit_event_listener`); this only drives the
    /// mempool and awaiting-confirmation states, which the federation cannot
    /// report itself.
    async fn watch_v2_pegin_address(
        federation_id: FederationId,
        address: String,
        client: ClientHandleArc,
        event_bus: EventBus<MultimintEvent>,
    ) -> anyhow::Result<()> {
        let wallet_module = client.get_first_module::<WalletV2Module>()?;
        let network = wallet_module.get_network();
        let api_url = mempool_api_url(network);
        let http = reqwest::Client::new();

        info_to_flutter(format!(
            "watch_v2_pegin_address: polling {api_url} for deposit to {address} (network {network})"
        ))
        .await;

        let (txid, value) = fedimint_core::util::retry(
            "discover walletv2 deposit",
            fedimint_core::util::backoff_util::background_backoff(),
            || async { discover_deposit(&http, &api_url, &address).await },
        )
        .await
        .expect("Never gives up");

        info_to_flutter(format!(
            "watch_v2_pegin_address: discovered deposit txid={txid} value={} sats to {address}, tracking confirmation",
            value.to_sat()
        ))
        .await;

        track_pegin_confirmation(
            federation_id,
            network,
            value,
            txid,
            address,
            event_bus,
            || async { Ok(wallet_module.block_count().await?) },
        )
        .await?;

        Ok(())
    }

    /// Watches the walletv2 event log for receive (peg-in) operations, surfacing
    /// `Confirmed` once the federation claims a confirmed deposit and `Claimed`
    /// once the claim finalizes. Mirrors `spawn_lnv2_event_listener`.
    ///
    /// Deposits are identified by their receive address (the correlation key
    /// also used by `watch_v2_pegin_address`), since the walletv2 event log
    /// carries the address rather than the on-chain outpoint.
    pub(crate) fn spawn_v2_deposit_event_listener(
        &self,
        client: ClientHandleArc,
        federation_id: FederationId,
    ) {
        // Nothing to do for federations without a walletv2 module.
        if client.get_first_module::<WalletV2Module>().is_err() {
            return;
        }

        let event_bus = get_event_bus();
        let task_group = self.task_group.clone();
        let mut log_event_added_rx = client.log_event_added_rx();
        self.task_group
            .spawn_cancellable("walletv2 deposit event listener", async move {
                // Start at the end of the log so we only react to new events.
                let existing = client.get_event_log(None, u64::MAX).await;
                let mut position = existing
                    .last()
                    .map(|e| e.id().saturating_add(1))
                    .unwrap_or(EventLogId::LOG_START);

                info_to_flutter(format!(
                    "spawn_v2_deposit_event_listener: started for fed {federation_id}, listening from log position {position:?}"
                ))
                .await;

                loop {
                    if log_event_added_rx.changed().await.is_err() {
                        info_to_flutter(format!(
                            "spawn_v2_deposit_event_listener: log_event_added_rx closed for fed {federation_id}, stopping"
                        ))
                        .await;
                        break;
                    }

                    let batch = client.get_event_log(Some(position), 100).await;
                    for event in &batch {
                        position = event.id().saturating_add(1);

                        // The "payment-receive" event kind is shared with lnv2,
                        // so filter on the walletv2 module before decoding.
                        if event.module_kind() != Some(&fedimint_walletv2_client::common::KIND)
                            || event.kind != V2ReceivePaymentEvent::KIND
                        {
                            continue;
                        }

                        let Some(receive_event) = event.to_event::<V2ReceivePaymentEvent>() else {
                            continue;
                        };

                        let address = receive_event.address.assume_checked().to_string();
                        let amount_msats = Amount::from_sats(receive_event.value.to_sat()).msats;
                        let operation_id = receive_event.operation_id;

                        info_to_flutter(format!(
                            "spawn_v2_deposit_event_listener: ReceivePaymentEvent for fed {federation_id} address={address} amount={amount_msats} msats op={operation_id:?}, publishing Confirmed"
                        ))
                        .await;

                        // The federation has seen the confirmed deposit and is
                        // claiming it.
                        event_bus
                            .publish(MultimintEvent::Deposit((
                                federation_id,
                                DepositEventKind::Confirmed(ConfirmedEvent {
                                    amount: amount_msats,
                                    outpoint: address.clone(),
                                }),
                            )))
                            .await;

                        // Await the claim, then surface Claimed.
                        let event_bus = event_bus.clone();
                        let client = client.clone();
                        task_group.spawn_cancellable("walletv2 await claim", async move {
                            let Ok(wallet_module) = client.get_first_module::<WalletV2Module>()
                            else {
                                return;
                            };
                            match wallet_module
                                .await_final_receive_operation_state(operation_id)
                                .await
                            {
                                Ok(FinalReceiveOperationState::Success) => {
                                    info_to_flutter(format!(
                                        "spawn_v2_deposit_event_listener: receive op {operation_id:?} succeeded for fed {federation_id} address={address}, publishing Claimed"
                                    ))
                                    .await;
                                    event_bus
                                        .publish(MultimintEvent::Deposit((
                                            federation_id,
                                            DepositEventKind::Claimed(ClaimedEvent {
                                                amount: amount_msats,
                                                outpoint: address,
                                            }),
                                        )))
                                        .await;
                                }
                                Ok(state) => {
                                    info_to_flutter(format!(
                                        "walletv2 receive ended in non-success state: {state:?}"
                                    ))
                                    .await;
                                }
                                Err(e) => {
                                    info_to_flutter(format!(
                                        "walletv2 await receive error: {e:?}"
                                    ))
                                    .await;
                                }
                            }
                        });
                    }
                }
            });
    }
}

/// Resolves the esplora/mempool.space API base URL for the given network.
fn mempool_api_url(network: bitcoin::Network) -> String {
    match network {
        bitcoin::Network::Bitcoin => "https://mempool.space/api".to_string(),
        bitcoin::Network::Signet => "https://mutinynet.com/api".to_string(),
        bitcoin::Network::Regtest => {
            // referencing devimint, uncomment for regtest
             "http://localhost:20744".to_string()
            //panic!("Regtest requires manually setting the connection params")
        }
        network => {
            panic!("{network} is not a supported network")
        }
    }
}

/// Queries esplora for the first transaction paying `address` and returns its
/// txid together with the total value sent to that address. Returns an error
/// (intended to be retried) while no such transaction exists yet.
async fn discover_deposit(
    http: &reqwest::Client,
    api_url: &str,
    address: &str,
) -> anyhow::Result<(bitcoin::Txid, bitcoin::Amount)> {
    let txs: serde_json::Value = http
        .get(format!("{}/address/{}/txs", api_url, address))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    let txs = txs
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("unexpected esplora response for {address}"))?;

    for tx in txs {
        let Some(txid) = tx.get("txid").and_then(|t| t.as_str()) else {
            continue;
        };
        let Some(vouts) = tx.get("vout").and_then(|v| v.as_array()) else {
            continue;
        };

        // Sum the value of every output in this tx that pays our address.
        let sats: u64 = vouts
            .iter()
            .filter(|o| o.get("scriptpubkey_address").and_then(|a| a.as_str()) == Some(address))
            .filter_map(|o| o.get("value").and_then(|v| v.as_u64()))
            .sum();

        if sats > 0 {
            return Ok((
                bitcoin::Txid::from_str(txid)?,
                bitcoin::Amount::from_sat(sats),
            ));
        }
    }

    Err(anyhow::anyhow!("no deposit to {address} found yet"))
}

/// Tracks a peg-in deposit from mempool detection through consensus
/// confirmation, publishing `Mempool` and `AwaitingConfs` deposit events.
///
/// This is shared by walletv1 and walletv2. The deposit's amount and on-chain
/// txid are surfaced differently by each module (the v1 deposit stream vs.
/// esplora polling for v2), and consensus block height is fetched differently
/// as well, so the caller supplies a `consensus_block_count` fetcher.
///
/// `outpoint_label` is the correlation key carried on every emitted deposit
/// event so the UI can group the states of a single deposit together. v1 uses
/// the full `txid:vout` string; v2 uses the receive address (the walletv2 event
/// log identifies deposits by address, not outpoint).
pub(crate) async fn track_pegin_confirmation<F, Fut>(
    federation_id: FederationId,
    network: bitcoin::Network,
    btc_deposited: bitcoin::Amount,
    txid: bitcoin::Txid,
    outpoint_label: String,
    event_bus: EventBus<MultimintEvent>,
    consensus_block_count: F,
) -> anyhow::Result<()>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = anyhow::Result<u64>>,
{
    let amount_msats = Amount::from_sats(btc_deposited.to_sat()).msats;

    info_to_flutter(format!(
        "track_pegin_confirmation: publishing Mempool event for fed {federation_id} outpoint={outpoint_label} amount={amount_msats} msats"
    ))
    .await;

    event_bus
        .publish(MultimintEvent::Deposit((
            federation_id,
            DepositEventKind::Mempool(MempoolEvent {
                amount: amount_msats,
                outpoint: outpoint_label.clone(),
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
                .get(format!("{}/tx/{}", api_url, txid))
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

    info_to_flutter(format!(
        "track_pegin_confirmation: tx {txid} confirmed at block height {tx_height}, polling consensus height for outpoint={outpoint_label}"
    ))
    .await;

    let every_10_secs = fedimint_core::util::backoff_util::custom_backoff(
        Duration::from_secs(10),
        Duration::from_secs(10),
        None,
    );
    fedimint_core::util::retry("consensus confirmation", every_10_secs, || async {
        let consensus_height = consensus_block_count().await?.saturating_sub(1);

        let needed = tx_height.saturating_sub(consensus_height);

        info_to_flutter(format!(
            "track_pegin_confirmation: publishing AwaitingConfs for fed {federation_id} outpoint={outpoint_label} consensus_height={consensus_height} tx_height={tx_height} needed={needed}"
        ))
        .await;

        event_bus
            .publish(MultimintEvent::Deposit((
                federation_id,
                DepositEventKind::AwaitingConfs(AwaitingConfsEvent {
                    amount: amount_msats,
                    outpoint: outpoint_label.clone(),
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

    info_to_flutter(format!(
        "track_pegin_confirmation: deposit fully confirmed for fed {federation_id} outpoint={outpoint_label}"
    ))
    .await;

    Ok(())
}