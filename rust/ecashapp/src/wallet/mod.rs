use std::{
    collections::{BTreeMap, BTreeSet},
    str::FromStr,
    sync::Arc,
    time::Duration,
};

use anyhow::anyhow;
use fedimint_client::{ClientHandleArc, ClientModuleInstance, OperationId};
use fedimint_core::{
    config::FederationId,
    db::{Database, IDatabaseTransactionOpsCoreTyped},
    encoding::Encodable,
    task::TaskGroup,
    Amount,
};
use fedimint_eventlog::Event;
use fedimint_wallet_client::{
    api::WalletFederationApi, client_db::TweakIdx, DepositStateV2, WalletClientModule,
    WalletOperationMeta, WalletOperationMetaVariant, WithdrawState,
};
use fedimint_walletv2_client::{
    events::ReceivePaymentEvent as V2ReceivePaymentEvent, FinalReceiveOperationState,
    FinalSendOperationState, ReceiveProgress, WalletClientModule as WalletV2Module,
    WalletOperationMeta as WalletV2OperationMeta,
};
use futures_util::StreamExt;
use tokio::{
    sync::{
        mpsc::{UnboundedReceiver, UnboundedSender},
        RwLock,
    },
    time::sleep,
};

use crate::{
    app_error::{classify_anyhow, EcashAppError, EcashAppResult},
    db::{WalletV2PendingDepositFederationPrefix, WalletV2PendingDepositKey},
    event_bus::EventBus,
    get_event_bus, info_to_flutter,
    multimint::{
        AwaitingConfsEvent, ClaimedEvent, ConfirmedEvent, DepositEventKind, JoinedFederation,
        MempoolEvent, MultimintEvent, OnChainWithdrawalMeta, WithdrawFees, WithdrawFeesResponse,
    },
    payment_error_to_flutter,
};

/// Trailing event-log entries scanned by
/// [`WalletHandler::v2_recorded_deposits`] at startup. Reading the whole log
/// costs memory and startup time that grow without bound; the event looked for
/// was written in an earlier session and the reconcile re-runs every launch, so
/// overshooting this window takes hundreds of payments in one session.
const V2_DEPOSIT_LOG_SCAN_LIMIT: u64 = 1_000;

/// How often the walletv2 deposit poller asks the guardians for their view of
/// pending peg-ins.
///
/// Each guardian refreshes that view on its own bitcoin backend's cadence and
/// serves it from a cached value, so a request is cheap — cheap enough to poll
/// well inside a block interval and have a new confirmation show up promptly.
const V2_DEPOSIT_POLL_INTERVAL: Duration = Duration::from_secs(10);

#[allow(clippy::type_complexity)]
#[derive(Clone)]
pub(crate) struct WalletHandler {
    pegin_address_monitor_tx: UnboundedSender<(FederationId, TweakIdx)>,
    allocated_bitcoin_addresses:
        Arc<RwLock<BTreeMap<FederationId, BTreeMap<TweakIdx, (String, Option<u64>)>>>>,
    /// App-level database, used to persist in-flight walletv2 receive addresses
    /// (see [`WalletV2PendingDepositKey`]) so the poller can be restarted on app
    /// launch.
    db: Database,
    /// walletv2 addresses with a deposit poller already running.
    ///
    /// walletv2 hands out the same address until it receives a deposit, and the
    /// receive screen allocates on every open, so without this each visit
    /// stacked another poller onto the same address — every one of them querying
    /// the guardians and publishing the same deposit events. The startup
    /// rehydrate can overlap with a live poller for the same reason.
    watched_v2_addresses: Arc<RwLock<BTreeSet<(FederationId, String)>>>,
    /// App-wide task group, for the dispatchers that outlive any one
    /// federation.
    ///
    /// Per-federation work does not go here. Deposit watchers and pollers
    /// belong to the federation that handed the address out, so they are
    /// spawned on the [`JoinedFederation::tasks`] group their caller passes in
    /// and are cancelled when that federation is left.
    task_group: TaskGroup,
}

impl WalletHandler {
    pub(crate) fn new(
        monitor_tx: UnboundedSender<(FederationId, TweakIdx)>,
        db: Database,
        task_group: TaskGroup,
    ) -> Self {
        Self {
            pegin_address_monitor_tx: monitor_tx,
            allocated_bitcoin_addresses: Arc::new(RwLock::new(BTreeMap::new())),
            db,
            watched_v2_addresses: Arc::new(RwLock::new(BTreeSet::new())),
            task_group,
        }
    }

    /// Drops the in-memory deposit-monitoring state belonging to a federation
    /// the user has left.
    ///
    /// None of it is persisted — it is rebuilt from the client and from
    /// [`WalletV2PendingDepositKey`] if the federation is joined again. Leaving
    /// `watched_v2_addresses` populated would be actively harmful: the pollers
    /// it names are being cancelled, but a re-join would read those addresses as
    /// already watched and decline to start new ones.
    pub(crate) async fn forget_federation(&self, federation_id: &FederationId) {
        self.allocated_bitcoin_addresses
            .write()
            .await
            .remove(federation_id);
        self.watched_v2_addresses
            .write()
            .await
            .retain(|(fed, _)| fed != federation_id);
    }

    pub(crate) fn spawn_pegin_address_watcher(
        &self,
        mut monitor_rx: UnboundedReceiver<(FederationId, TweakIdx)>,
        clients: Arc<RwLock<BTreeMap<FederationId, JoinedFederation>>>,
    ) {
        let event_bus_clone = get_event_bus();
        let addresses_clone = self.allocated_bitcoin_addresses.clone();

        self.task_group
            .spawn_cancellable("pegin address watcher", async move {
                while let Some((fed_id, tweak_idx)) = monitor_rx.recv().await {
                    let event_bus = event_bus_clone.clone();
                    // wrapping the clients in Arc<RwLock<..>> allows us to monitor using clients
                    // created after the background task is spawned
                    // This watcher outlives individual federations — a monitor
                    // request can still be queued when its federation is left.
                    // Skip that request and keep the loop alive; panicking here
                    // would take down deposit monitoring for every other
                    // federation too.
                    let Some(JoinedFederation { client, tasks }) =
                        clients.read().await.get(&fed_id).cloned()
                    else {
                        info_to_flutter(format!(
                            "Skipping peg-in watch for {fed_id}: federation was left"
                        ))
                        .await;
                        continue;
                    };

                    // Watching one address belongs to the federation that handed
                    // it out, so it goes on that federation's group rather than
                    // on this dispatcher's.
                    let addresses_clone = addresses_clone.clone();
                    tasks.spawn_cancellable("tweak index watcher", async move {
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
                        &wallet_module,
                        btc_deposited,
                        btc_out_point.txid,
                        btc_out_point.to_string(),
                        event_bus.clone(),
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
                            txid: Some(btc_out_point.txid.to_string()),
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
                            txid: Some(btc_out_point.txid.to_string()),
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

    /// Re-establishes pending-deposit monitoring for every federation on
    /// startup. Walletv1 and walletv2 are rehydrated from different sources, so
    /// each client is dispatched by module type:
    ///
    /// - **walletv1**: the Fedimint client DB holds a deposit operation per
    ///   handed-out address, so we scan tweak indices and re-subscribe to the
    ///   v1 deposit stream for unclaimed ones.
    /// - **walletv2**: there is no client operation to rediscover, so we
    ///   re-spawn the deposit poller from our own persisted addresses (see
    ///   [`Self::resume_pending_v2_deposits`]).
    pub(crate) fn monitor_all_pending_deposits(
        &self,
        clients: Arc<RwLock<BTreeMap<FederationId, JoinedFederation>>>,
    ) {
        let handler = self.clone();
        let pegin_address_monitor_tx_clone = self.pegin_address_monitor_tx.clone();
        let addresses_clone = self.allocated_bitcoin_addresses.clone();

        self.task_group
            .spawn_cancellable("pending deposit monitor", async move {
                let clients_guard = clients.read().await;
                for (fed_id, JoinedFederation { client, tasks }) in clients_guard.iter() {
                    // walletv2 federations have no v1 wallet module and no tweak
                    // indices to scan; rehydrate their pollers from our persisted
                    // addresses instead.
                    let Ok(wallet_module) = client.get_first_module::<WalletClientModule>() else {
                        handler
                            .resume_pending_v2_deposits(tasks, *fed_id, client)
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
        tasks: &TaskGroup,
        federation_id: FederationId,
        address: String,
        client: ClientHandleArc,
    ) -> anyhow::Result<Option<u64>> {
        // walletv2 has no tweak index: addresses are derived locally and the
        // module's background scanner detects and claims confirmed deposits. We
        // poll the guardians for mempool/confirmation progress on the way there,
        // and the event-log listener (see `spawn_v2_deposit_event_listener`)
        // surfaces confirmed and claimed. There is no tweak index to return.
        if client.get_first_module::<WalletV2Module>().is_ok() {
            info_to_flutter(format!(
                "monitor_deposit_address: walletv2 detected for fed {federation_id}, spawning deposit poller for address {address}"
            ))
            .await;
            // Persist the handed-out address so the poller can be restarted after
            // an app restart (walletv2 has no client operation to rediscover it
            // from). The entry is removed once the deposit is claimed.
            self.persist_pending_v2_deposit(federation_id, &address)
                .await;
            self.spawn_v2_deposit_poller(tasks, federation_id, address, client)
                .await;
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
        client: &ClientHandleArc,
    ) -> Vec<(String, Option<u64>, Option<u64>)> {
        // walletv2 has no in-memory tweak-index map; its addresses are the
        // source of truth in our own DB (see `WalletV2PendingDepositKey`).
        if client.get_first_module::<WalletV2Module>().is_ok() {
            return self.get_v2_addresses(*federation_id).await;
        }

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

    /// Builds the deposit-address list for a walletv2 federation from our
    /// persisted entries. The tweak index (middle element) is always `None` —
    /// walletv2 has none. The amount is `Some(sats)` once the federation has
    /// recorded the deposit, `None` while still unfunded.
    async fn get_v2_addresses(
        &self,
        federation_id: FederationId,
    ) -> Vec<(String, Option<u64>, Option<u64>)> {
        let mut res: Vec<(String, Option<u64>, Option<u64>)> = {
            let mut dbtx = self.db.begin_transaction_nc().await;
            dbtx.find_by_prefix(&WalletV2PendingDepositFederationPrefix { federation_id })
                .await
                .map(|(k, funded)| (k.address, None, funded))
                .collect()
                .await
        };
        // Funded addresses first, then deterministic by address.
        res.sort_by(|a, b| {
            b.2.is_some()
                .cmp(&a.2.is_some())
                .then_with(|| a.0.cmp(&b.0))
        });
        res
    }

    pub(crate) async fn allocate_deposit_address(
        &self,
        tasks: &TaskGroup,
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
            .monitor_deposit_address(tasks, federation_id, address.clone(), client)
            .await?;

        Ok((address, tweak_idx))
    }

    /// Persists a handed-out walletv2 receive address (as unfunded) so it shows
    /// in the deposit-address list and its poller can be restarted after an app
    /// restart (see [`WalletV2PendingDepositKey`]).
    async fn persist_pending_v2_deposit(&self, federation_id: FederationId, address: &str) {
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(
            &WalletV2PendingDepositKey {
                federation_id,
                address: address.to_string(),
            },
            &None,
        )
        .await;
        dbtx.commit_tx().await;
    }

    /// Records the deposited amount for a walletv2 receive address once the
    /// federation has recorded the deposit. Keeps the entry (rather than
    /// deleting it) so funded addresses stay in the deposit-address list, and so
    /// the rescan no longer treats it as pending.
    ///
    /// Takes `&Database` rather than `&self` so it can be called from the
    /// spawned event-listener tasks that only capture a cloned handle.
    async fn mark_v2_deposit_funded(
        db: &Database,
        federation_id: FederationId,
        address: &str,
        deposited_sats: u64,
    ) {
        let mut dbtx = db.begin_transaction().await;
        dbtx.insert_entry(
            &WalletV2PendingDepositKey {
                federation_id,
                address: address.to_string(),
            },
            &Some(deposited_sats),
        )
        .await;
        dbtx.commit_tx().await;
    }

    /// Returns the walletv2 receive addresses that already have a
    /// `ReceivePaymentEvent` in the client's event log, mapped to the deposited
    /// amount in sats — i.e. the federation has recorded the deposit, so the
    /// mempool/awaiting-confs poller has nothing left to do for them.
    ///
    /// Only the log's tail is scanned (see [`V2_DEPOSIT_LOG_SCAN_LIMIT`]); an
    /// older deposit is treated as still pending, re-spawning a poller that
    /// rediscovers it on-chain.
    async fn v2_recorded_deposits(client: &ClientHandleArc) -> BTreeMap<String, u64> {
        let mut deposits = BTreeMap::new();
        let end = client.get_next_event_log_id().await;
        let start = end.saturating_sub(V2_DEPOSIT_LOG_SCAN_LIMIT);
        let log = client
            .get_event_log(Some(start), V2_DEPOSIT_LOG_SCAN_LIMIT)
            .await;
        for event in &log {
            if event.module_kind() != Some(&fedimint_walletv2_client::common::KIND)
                || event.kind != V2ReceivePaymentEvent::KIND
            {
                continue;
            }
            if let Some(receive_event) = event.to_event::<V2ReceivePaymentEvent>() {
                deposits.insert(
                    receive_event.address.assume_checked().to_string(),
                    receive_event.value.to_sat(),
                );
            }
        }
        deposits
    }

    /// Re-spawns the walletv2 deposit poller for `client`'s
    /// persisted-but-unclaimed receive addresses. Called per federation by
    /// [`Self::monitor_all_pending_deposits`] for the walletv2 case: walletv2
    /// creates no client operation at address-allocation time, so there is
    /// nothing in the Fedimint client DB to rediscover in-flight deposits from
    /// on startup — we rely on our own [`WalletV2PendingDepositKey`] persistence
    /// instead.
    ///
    /// If a persisted address was already recorded by the federation while the
    /// app was closed (its `ReceivePaymentEvent` is already in the event log),
    /// the poller would have nothing to do, so we reconcile the entry to funded
    /// instead of re-spawning it.
    async fn resume_pending_v2_deposits(
        &self,
        tasks: &TaskGroup,
        federation_id: FederationId,
        client: &ClientHandleArc,
    ) {
        if client.get_first_module::<WalletV2Module>().is_err() {
            return;
        }

        // Only `None` (unfunded) entries need attention; funded ones are done.
        let unfunded: Vec<String> = {
            let mut dbtx = self.db.begin_transaction_nc().await;
            dbtx.find_by_prefix(&WalletV2PendingDepositFederationPrefix { federation_id })
                .await
                .filter_map(|(k, funded)| async move { funded.is_none().then_some(k.address) })
                .collect()
                .await
        };

        if unfunded.is_empty() {
            return;
        }

        let recorded = Self::v2_recorded_deposits(client).await;

        for address in unfunded {
            if let Some(&deposited_sats) = recorded.get(&address) {
                info_to_flutter(format!(
                    "resume_pending_v2_deposits: {address} on fed {federation_id} already recorded by federation ({deposited_sats} sats), marking funded"
                ))
                .await;
                Self::mark_v2_deposit_funded(&self.db, federation_id, &address, deposited_sats)
                    .await;
                continue;
            }

            info_to_flutter(format!(
                "resume_pending_v2_deposits: resuming deposit poller for {address} on fed {federation_id}"
            ))
            .await;
            self.spawn_v2_deposit_poller(tasks, federation_id, address, client.clone())
                .await;
        }
    }

    /// Starts watching a walletv2 receive `address` for deposits, unless
    /// something already is.
    ///
    /// Running two watchers for one address would double every published
    /// event, and both the receive screen (which allocates on every open) and
    /// the startup rehydrate can ask for the same address, so the guard is what
    /// this exists for.
    async fn spawn_v2_deposit_poller(
        &self,
        tasks: &TaskGroup,
        federation_id: FederationId,
        address: String,
        client: ClientHandleArc,
    ) {
        let key = (federation_id, address.clone());
        if !self.watched_v2_addresses.write().await.insert(key.clone()) {
            info_to_flutter(format!(
                "Already watching {address} for a deposit; not starting a second poller"
            ))
            .await;
            return;
        }

        let event_bus = get_event_bus();
        let watched = self.watched_v2_addresses.clone();
        let db = self.db.clone();
        tasks.spawn_cancellable("walletv2 deposit poller", async move {
            if let Err(e) =
                Self::watch_v2_pegin_address(federation_id, address.clone(), client, event_bus, db)
                    .await
            {
                info_to_flutter(format!("watch_v2_pegin_address({address}) failed: {e:?}")).await;
            }
            // Released on the way out so an address whose watcher ended
            // without finding a deposit can be picked up again later.
            watched.write().await.remove(&key);
        });
    }

    /// Follows every deposit to a walletv2 receive `address` through the
    /// guardians' own view of pending peg-ins, publishing `Mempool` and
    /// `AwaitingConfs` for each one.
    ///
    /// The guardians report the outputs they have seen paying the module's
    /// receive filter but have not yet acted on — mined ones always, and unmined
    /// ones from any guardian whose bitcoin backend can enumerate a mempool — so
    /// no block explorer is involved and the address never leaves the app.
    ///
    /// Each deposit is keyed by its real `txid:vout`, so two payments to the
    /// same address are two independent rows in the UI. That is only possible
    /// because the federation reports outpoints; the esplora polling this
    /// replaced could only ever describe an address as a whole.
    ///
    /// `Confirmed` and `Claimed` come from the event-log listener (see
    /// [`Self::spawn_v2_deposit_event_listener`]), so this stops once every
    /// deposit it has seen is deep enough for the federation to claim it.
    async fn watch_v2_pegin_address(
        federation_id: FederationId,
        address: String,
        client: ClientHandleArc,
        event_bus: EventBus<MultimintEvent>,
        db: Database,
    ) -> anyhow::Result<()> {
        let wallet_module = client.get_first_module::<WalletV2Module>()?;
        let network = wallet_module.get_network();
        let parsed = bitcoin::Address::from_str(&address)?.require_network(network)?;

        info_to_flutter(format!(
            "watch_v2_pegin_address: polling the guardians of fed {federation_id} for deposits to {address} (network {network})"
        ))
        .await;

        // The last state published per outpoint, so a poll that changes nothing
        // publishes nothing. The event bus keeps a bounded history that repeated
        // identical `AwaitingConfs` events would churn straight through, and
        // every publish costs the dashboard a rebuild.
        let mut published: BTreeMap<bitcoin::OutPoint, ReceiveProgress> = BTreeMap::new();
        // Every deposit this watcher has ever been told about. Unlike
        // `published` it only grows, so a deposit that drops back out of the
        // federation's view cannot make the loop forget it had work to do.
        let mut seen: BTreeSet<bitcoin::OutPoint> = BTreeSet::new();

        loop {
            // The address only resolves once the module's background scanner has
            // derived its index, which right after a restore it may not have done
            // yet, so treat a failure as transient rather than giving up on the
            // address.
            let deposits = match wallet_module.address_receive_progress(&parsed).await {
                Ok(deposits) => deposits,
                Err(e) => {
                    info_to_flutter(format!(
                        "watch_v2_pegin_address({address}): progress lookup failed, retrying: {e:#}"
                    ))
                    .await;
                    sleep(V2_DEPOSIT_POLL_INTERVAL).await;
                    continue;
                }
            };

            for (outpoint, progress) in &deposits {
                seen.insert(*outpoint);

                if published.get(outpoint).is_some_and(|last| last == progress) {
                    continue;
                }

                Self::publish_v2_deposit_progress(federation_id, *outpoint, progress, &event_bus)
                    .await;

                published.insert(*outpoint, progress.clone());
            }

            // A deposit can leave the federation's view without being claimed: a
            // reorg or a mempool eviction takes it back to unseen. The UI has no
            // state for a deposit that un-happens, so leave the row standing —
            // the same way an esplora-discovered deposit was never withdrawn —
            // and only drop our record of what it last showed, so that a deposit
            // which comes back is published afresh rather than deduped away.
            let vanished: Vec<bitcoin::OutPoint> = published
                .keys()
                .filter(|outpoint| !deposits.iter().any(|(seen, _)| seen == *outpoint))
                .copied()
                .collect();

            for outpoint in vanished {
                published.remove(&outpoint);

                info_to_flutter(format!(
                    "watch_v2_pegin_address({address}): deposit {outpoint} is no longer reported by the federation"
                ))
                .await;
            }

            // Stop once nothing is still gaining confirmations. A deposit
            // sitting at the depth the federation claims at belongs to the
            // event-log listener from here on, and so does one that has already
            // dropped out of the pending window — which is what the funded check
            // catches, including on a federation too old to serve the pending
            // view at all.
            let advancing = deposits.iter().any(|(_, progress)| match progress {
                ReceiveProgress::Mempool { .. } => true,
                ReceiveProgress::Confirming {
                    confirmations,
                    required,
                    ..
                } => confirmations < required,
                ReceiveProgress::Claimed => false,
            });

            if !advancing
                && (!seen.is_empty() || Self::v2_deposit_funded(&db, federation_id, &address).await)
            {
                info_to_flutter(format!(
                    "watch_v2_pegin_address({address}): nothing left to report, handing off to the event-log listener"
                ))
                .await;
                return Ok(());
            }

            sleep(V2_DEPOSIT_POLL_INTERVAL).await;
        }
    }

    /// Publishes one walletv2 deposit's progress as the matching deposit event.
    ///
    /// [`ReceiveProgress::Claimed`] is unreachable here — the guardians' pending
    /// view cannot report it, and the event-log listener owns that state — so it
    /// is deliberately not published rather than mapped to a `Claimed` event
    /// that would clear the row before the ecash exists.
    async fn publish_v2_deposit_progress(
        federation_id: FederationId,
        outpoint: bitcoin::OutPoint,
        progress: &ReceiveProgress,
        event_bus: &EventBus<MultimintEvent>,
    ) {
        let label = outpoint.to_string();
        let txid = Some(outpoint.txid.to_string());

        let kind = match progress {
            ReceiveProgress::Mempool { value } => {
                info_to_flutter(format!(
                    "walletv2 deposit {label} for fed {federation_id} is in the mempool ({} sats)",
                    value.to_sat()
                ))
                .await;

                DepositEventKind::Mempool(MempoolEvent {
                    amount: Amount::from_sats(value.to_sat()).msats,
                    outpoint: label,
                    txid,
                })
            }
            ReceiveProgress::Confirming {
                value,
                height,
                confirmations,
                required,
            } => {
                let needed = required.saturating_sub(*confirmations);

                info_to_flutter(format!(
                    "walletv2 deposit {label} for fed {federation_id} was mined at height {height} and has {confirmations}/{required} confirmations ({needed} needed)"
                ))
                .await;

                DepositEventKind::AwaitingConfs(AwaitingConfsEvent {
                    amount: Amount::from_sats(value.to_sat()).msats,
                    outpoint: label,
                    block_height: *height,
                    needed,
                    txid,
                })
            }
            ReceiveProgress::Claimed => return,
        };

        event_bus
            .publish(MultimintEvent::Deposit((federation_id, kind)))
            .await;
    }

    /// Whether the federation has already recorded a deposit to `address`.
    ///
    /// That is the point at which the event-log listener takes over, so it is
    /// also the point at which the poller has nothing left to report.
    async fn v2_deposit_funded(db: &Database, federation_id: FederationId, address: &str) -> bool {
        db.begin_transaction_nc()
            .await
            .get_value(&WalletV2PendingDepositKey {
                federation_id,
                address: address.to_string(),
            })
            .await
            .flatten()
            .is_some()
    }

    /// Watches the walletv2 event log for receive (peg-in) operations, surfacing
    /// `Confirmed` once the federation claims a confirmed deposit and `Claimed`
    /// once the claim finalizes. Mirrors `spawn_lnv2_event_listener`.
    ///
    /// Deposits are keyed by their on-chain outpoint, matching the key
    /// [`Self::watch_v2_pegin_address`] publishes, so the two halves of one
    /// deposit's progress land on the same row and two payments to the same
    /// address stay apart. The walletv2 event log only carries an outpoint from
    /// a federation new enough to record one; without it the address is the best
    /// key available, which collapses such a pair back into a single row.
    pub(crate) fn spawn_v2_deposit_event_listener(
        &self,
        tasks: &TaskGroup,
        client: ClientHandleArc,
        federation_id: FederationId,
    ) {
        // Nothing to do for federations without a walletv2 module.
        if client.get_first_module::<WalletV2Module>().is_err() {
            return;
        }

        let event_bus = get_event_bus();
        // The claim watchers this listener spawns belong to the same federation
        // as the listener itself.
        let task_group = tasks.clone();
        let db = self.db.clone();
        let mut log_event_added_rx = client.log_event_added_rx();
        tasks.spawn_cancellable("walletv2 deposit event listener", async move {
            // Start at the end of the log so we only react to new events.
            let mut position = client.get_next_event_log_id().await;

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
                    let deposited_sats = receive_event.value.to_sat();
                    let amount_msats = Amount::from_sats(deposited_sats).msats;
                    let operation_id = receive_event.operation_id;
                    let txid = receive_event.outpoint.map(|op| op.txid.to_string());
                    // Falling back to the address keeps a deposit the federation
                    // reported without an outpoint on a row of its own rather
                    // than dropping it; see this listener's doc comment.
                    let label = receive_event
                        .outpoint
                        .map_or_else(|| address.clone(), |op| op.to_string());

                    info_to_flutter(format!(
                        "spawn_v2_deposit_event_listener: ReceivePaymentEvent for fed {federation_id} address={address} outpoint={label} amount={amount_msats} msats op={operation_id:?}, publishing Confirmed"
                    ))
                    .await;

                    // The federation has recorded the deposit: persist the
                    // amount so the address shows as funded (and is no longer
                    // treated as pending) across restarts.
                    Self::mark_v2_deposit_funded(&db, federation_id, &address, deposited_sats)
                        .await;

                    // The federation has seen the confirmed deposit and is
                    // claiming it.
                    event_bus
                        .publish(MultimintEvent::Deposit((
                            federation_id,
                            DepositEventKind::Confirmed(ConfirmedEvent {
                                amount: amount_msats,
                                outpoint: label.clone(),
                                txid: txid.clone(),
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
                                // Reaching `Success` only means the claim tx
                                // was accepted into consensus; the ecash it
                                // mints is issued asynchronously by the mint
                                // module. Wait for those outputs before
                                // surfacing Claimed so the balance reflects the
                                // deposit (the same step walletv2's own
                                // `await_receive` performs after success).
                                // Otherwise the dashboard refreshes its balance
                                // before the ecash lands and shows a stale
                                // value until the next manual refresh.
                                if let Some(op) =
                                    client.operation_log().get_operation(operation_id).await
                                {
                                    if let WalletV2OperationMeta::Receive(receive) =
                                        op.meta::<WalletV2OperationMeta>()
                                    {
                                        if let Err(e) = client
                                            .await_primary_bitcoin_module_outputs(
                                                operation_id,
                                                receive
                                                    .change_outpoint_range
                                                    .into_iter()
                                                    .collect(),
                                            )
                                            .await
                                        {
                                            info_to_flutter(format!(
                                                "walletv2 await primary module outputs error: {e:?}"
                                            ))
                                            .await;
                                        }
                                    }
                                }

                                info_to_flutter(format!(
                                    "spawn_v2_deposit_event_listener: receive op {operation_id:?} succeeded for fed {federation_id} outpoint={label}, publishing Claimed"
                                ))
                                .await;
                                event_bus
                                    .publish(MultimintEvent::Deposit((
                                        federation_id,
                                        DepositEventKind::Claimed(ClaimedEvent {
                                            amount: amount_msats,
                                            outpoint: label,
                                            txid,
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

    // ---- On-chain send (peg-out) ----------------------------------------
    //
    // walletv1 uses a two-step, tx-specific fee model (`get_withdraw_fees` →
    // `withdraw`), while walletv2 uses a flat federation-determined fee
    // (`send_fee` → `send`). Each function below dispatches on the wallet
    // module present in the federation.

    /// Quotes the fee to send `amount_sats` on-chain to `address`. The returned
    /// [`WithdrawFees`] is round-tripped back into [`Self::withdraw_to_address`]
    /// so the user pays exactly the quoted fee.
    ///
    /// Rejects amounts above the bitcoin supply cap: such a withdrawal can never
    /// succeed, and quoting one anyway would show the user a plausible fee for
    /// an impossible payment.
    pub(crate) async fn calculate_withdraw_fees(
        &self,
        client: &ClientHandleArc,
        address: String,
        amount_sats: u64,
    ) -> EcashAppResult<WithdrawFeesResponse> {
        // `bitcoin::Amount::from_sat` does not range-check, and the
        // `amount + fee` sums below would wrap near `u64::MAX`, so bound the
        // amount once here for both the walletv1 and walletv2 paths.
        if amount_sats > bitcoin::Amount::MAX_MONEY.to_sat() {
            return Err(EcashAppError::other(format!(
                "withdrawal amount {amount_sats} sats exceeds the total bitcoin supply"
            )));
        }

        if let Ok(walletv2) = client.get_first_module::<WalletV2Module>() {
            // walletv2 charges a flat send fee; the on-chain tx is always
            // 1-in/1-out, so its vbytes are a per-federation constant taken from
            // the wallet config.
            let address = bitcoin::Address::from_str(&address)
                .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;
            address
                .require_network(walletv2.get_network())
                .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;

            let fee_sats = walletv2
                .send_fee()
                .await
                .map_err(EcashAppError::from_display)?
                .to_sat();
            let tx_size_vbytes = Self::walletv2_send_tx_vbytes(client).await?;
            let fee_rate_sats_per_vb = if tx_size_vbytes > 0 {
                fee_sats as f64 / f64::from(tx_size_vbytes)
            } else {
                0.0
            };

            // The amount is bounded above, but `fee_sats` is federation-reported
            // and could still push the sum past `u64::MAX`.
            let funded_sats = amount_sats.checked_add(fee_sats).ok_or_else(|| {
                EcashAppError::other(format!(
                    "withdrawal amount {amount_sats} sats plus network fee {fee_sats} sats is out of range"
                ))
            })?;

            // Federation fee for funding the on-chain output (withdrawal amount
            // plus the miner fee) from ecash. Display-only, so degrade to 0.
            let federation_fee_msats = walletv2
                .send_fee_quote(bitcoin::Amount::from_sat(funded_sats))
                .await
                .map(|q| q.total().get_bitcoin().msats)
                .unwrap_or(0);

            return Ok(WithdrawFeesResponse {
                fee_amount: fee_sats,
                fee_rate_sats_per_vb,
                tx_size_vbytes,
                federation_fee_msats,
                fees: WithdrawFees::V2 { fee_sats },
            });
        }

        let wallet_module = client
            .get_first_module::<WalletClientModule>()
            .map_err(|e| EcashAppError::other(format!("wallet module unavailable: {e:#}")))?;
        let address = bitcoin::Address::from_str(&address)
            .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;
        let address = address
            .require_network(wallet_module.get_network())
            .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;
        let amount = bitcoin::Amount::from_sat(amount_sats);
        let fees = wallet_module
            .get_withdraw_fees(&address, amount)
            .await
            .map_err(EcashAppError::from_display)?;
        let meta = OnChainWithdrawalMeta::from_peg_out_fees(&fees);

        // The amount is bounded above, but `fee_sats` is federation-reported and
        // could still push the sum past `u64::MAX`.
        let funded_sats = amount_sats.checked_add(meta.fee_sats).ok_or_else(|| {
            EcashAppError::other(format!(
                "withdrawal amount {amount_sats} sats plus network fee {} sats is out of range",
                meta.fee_sats
            ))
        })?;

        // Federation fee for funding the on-chain output (withdrawal amount plus
        // the miner fee) from ecash. Display-only, so degrade to 0.
        let federation_fee_msats = wallet_module
            .send_fee_quote(bitcoin::Amount::from_sat(funded_sats))
            .await
            .map(|q| q.total().get_bitcoin().msats)
            .unwrap_or(0);

        Ok(WithdrawFeesResponse {
            fee_amount: meta.fee_sats,
            fee_rate_sats_per_vb: meta.fee_rate_sats_per_vb,
            tx_size_vbytes: meta.tx_size_vb,
            federation_fee_msats,
            fees: WithdrawFees::V1(fees),
        })
    }

    /// Reads the federation's constant pegout transaction size (vbytes) from the
    /// walletv2 client config. walletv2 peg-outs are always 1-in/1-out, so this
    /// is a per-federation constant.
    pub(crate) async fn walletv2_send_tx_vbytes(client: &ClientHandleArc) -> EcashAppResult<u32> {
        let walletv2 = client
            .get_first_module::<WalletV2Module>()
            .map_err(|e| EcashAppError::other(format!("walletv2 module unavailable: {e:#}")))?;
        let config = client.config().await;
        let cfg = config
            .modules
            .get(&walletv2.id)
            .ok_or_else(|| EcashAppError::other("walletv2 config missing"))?
            .cast::<fedimint_walletv2_common::config::WalletClientConfig>()
            .map_err(EcashAppError::from_display)?;
        Ok(cfg.send_tx_vbytes as u32)
    }

    /// Broadcasts an on-chain send, paying the fee quoted by
    /// [`Self::calculate_withdraw_fees`] (carried in `fees`).
    pub(crate) async fn withdraw_to_address(
        &self,
        client: &ClientHandleArc,
        address: String,
        amount_sats: u64,
        fees: WithdrawFees,
        federation_fee_msats: u64,
    ) -> EcashAppResult<OperationId> {
        match fees {
            WithdrawFees::V2 { fee_sats } => {
                let walletv2 = client.get_first_module::<WalletV2Module>().map_err(|e| {
                    EcashAppError::other(format!("walletv2 module unavailable: {e:#}"))
                })?;
                // `send` takes an unchecked address and validates the network itself.
                let address = bitcoin::Address::from_str(&address)
                    .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;
                // walletv2's send op stores its own typed meta, so the federation
                // fee rides along in its custom_meta for the tx log to read back.
                let custom_meta = serde_json::json!({ "federation_fees": federation_fee_msats });
                let operation_id = walletv2
                    .send(
                        address,
                        bitcoin::Amount::from_sat(amount_sats),
                        Some(bitcoin::Amount::from_sat(fee_sats)),
                        custom_meta,
                    )
                    .await
                    .map_err(EcashAppError::from_display)?;
                Ok(operation_id)
            }
            WithdrawFees::V1(peg_out_fees) => {
                let wallet_module =
                    client
                        .get_first_module::<WalletClientModule>()
                        .map_err(|e| {
                            EcashAppError::other(format!("wallet module unavailable: {e:#}"))
                        })?;
                let address = bitcoin::Address::from_str(&address)
                    .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;
                let address = address
                    .require_network(wallet_module.get_network())
                    .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;
                let amount = bitcoin::Amount::from_sat(amount_sats);
                let meta = OnChainWithdrawalMeta {
                    federation_fee_msats,
                    ..OnChainWithdrawalMeta::from_peg_out_fees(&peg_out_fees)
                };

                let operation_id = wallet_module
                    .withdraw(&address, amount, peg_out_fees, meta)
                    .await
                    .map_err(EcashAppError::from_display)?;
                Ok(operation_id)
            }
        }
    }

    /// Awaits the final state of an on-chain send, returning the broadcast txid.
    pub(crate) async fn await_withdraw(
        &self,
        federation_id: FederationId,
        client: &ClientHandleArc,
        operation_id: OperationId,
    ) -> EcashAppResult<String> {
        if let Ok(walletv2) = client.get_first_module::<WalletV2Module>() {
            return match walletv2
                .await_final_send_operation_state(operation_id)
                .await
                .map_err(EcashAppError::from_display)?
            {
                FinalSendOperationState::Success(txid) => Ok(txid.consensus_encode_to_hex()),
                other => {
                    let err = classify_anyhow(&anyhow!("on-chain send failed: {other:?}"));
                    payment_error_to_flutter(federation_id, err.clone()).await;
                    Err(err)
                }
            };
        }

        let wallet_module = client
            .get_first_module::<WalletClientModule>()
            .map_err(|e| EcashAppError::other(format!("wallet module unavailable: {e:#}")))?;

        let mut updates = wallet_module
            .subscribe_withdraw_updates(operation_id)
            .await
            .map_err(EcashAppError::from_display)?
            .into_stream();

        let txid = loop {
            let update = updates.next().await.ok_or_else(|| {
                EcashAppError::other("on-chain withdraw stream ended without outcome")
            })?;

            match update {
                WithdrawState::Succeeded(txid) => {
                    // drive the update stream to completion so we get an outcome
                    while updates.next().await.is_some() {}
                    break txid.consensus_encode_to_hex();
                }
                WithdrawState::Failed(e) => {
                    let err = classify_anyhow(&anyhow!("on-chain withdraw failed: {e}"));
                    // Emit the structured event too so any background listener
                    // (e.g. screens that already navigated away) still sees it.
                    payment_error_to_flutter(federation_id, err.clone()).await;
                    return Err(err);
                }
                WithdrawState::Created => {
                    continue;
                }
            }
        };

        Ok(txid)
    }

    /// Returns the largest amount that can be sent to `address` after fees.
    pub(crate) async fn get_max_withdrawable_amount(
        &self,
        client: &ClientHandleArc,
        address: String,
    ) -> EcashAppResult<u64> {
        if let Ok(walletv2) = client.get_first_module::<WalletV2Module>() {
            let address = bitcoin::Address::from_str(&address)
                .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;
            address
                .require_network(walletv2.get_network())
                .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;

            let balance_sats = client
                .get_balance_for_btc()
                .await
                .map_err(EcashAppError::from_display)?
                .msats
                / 1000;
            let fee_sats = walletv2
                .send_fee()
                .await
                .map_err(EcashAppError::from_display)?
                .to_sat();
            let max = balance_sats
                .checked_sub(fee_sats)
                .ok_or_else(|| EcashAppError::other("Not enough funds to pay fees"))?;
            return Ok(max);
        }

        let wallet_module = client
            .get_first_module::<WalletClientModule>()
            .map_err(|e| EcashAppError::other(format!("wallet module unavailable: {e:#}")))?;
        let address = bitcoin::Address::from_str(&address)
            .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;
        let address = address
            .require_network(wallet_module.get_network())
            .map_err(|e| EcashAppError::InvalidBitcoinAddress(e.to_string()))?;
        let balance = bitcoin::Amount::from_sat(
            client
                .get_balance_for_btc()
                .await
                .map_err(EcashAppError::from_display)?
                .msats
                / 1000,
        );
        let fees = wallet_module
            .get_withdraw_fees(&address, balance)
            .await
            .map_err(EcashAppError::from_display)?;
        let max_withdrawable = balance
            .checked_sub(fees.amount())
            .ok_or_else(|| EcashAppError::other("Not enough funds to pay fees"))?;

        Ok(max_withdrawable.to_sat())
    }
}

/// Resolves the esplora/mempool.space API base URL for the given network.
///
/// Panicking is the intent for anything not listed: regtest has no public
/// explorer and has to be pointed at a local instance by hand, and the remaining
/// networks are not supported. Both are configuration errors rather than
/// conditions the app can recover from at runtime.
fn mempool_api_url(network: bitcoin::Network) -> String {
    match network {
        bitcoin::Network::Bitcoin => "https://mempool.space/api".to_string(),
        bitcoin::Network::Signet => "https://mutinynet.com/api".to_string(),
        bitcoin::Network::Regtest => {
            "http://127.0.0.1:16249".to_string()
            //panic!("Regtest requires manually setting the connection params")
        }
        network => {
            panic!("{network} is not a supported network")
        }
    }
}

/// Tracks a walletv1 peg-in deposit from mempool detection through consensus
/// confirmation, publishing `Mempool` and `AwaitingConfs` deposit events.
///
/// walletv1 has no federation-side view of an unclaimed deposit, so the only
/// way to describe one before the federation records it is to ask a block
/// explorer, at the cost of showing that explorer the address. walletv2 gets
/// the same states from its guardians instead (see
/// [`WalletHandler::watch_v2_pegin_address`]) and never comes through here.
///
/// `outpoint_label` is the `txid:vout` correlation key carried on every emitted
/// deposit event, so the UI can group the states of a single deposit together.
pub(crate) async fn track_pegin_confirmation(
    federation_id: FederationId,
    wallet_module: &ClientModuleInstance<'_, WalletClientModule>,
    btc_deposited: bitcoin::Amount,
    txid: bitcoin::Txid,
    outpoint_label: String,
    event_bus: EventBus<MultimintEvent>,
) -> anyhow::Result<()> {
    let network = wallet_module.get_network();
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
                txid: Some(txid.to_string()),
            }),
        )))
        .await;

    let api_url = mempool_api_url(network);
    let http = crate::net::http_client();

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
        let consensus_height = wallet_module
            .api
            .fetch_consensus_block_count()
            .await?
            .saturating_sub(1);

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
                    txid: Some(txid.to_string()),
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
