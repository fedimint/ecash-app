use std::collections::{BTreeMap, BTreeSet};
use std::str::FromStr;
use std::time::{Duration, UNIX_EPOCH};

use fedimint_client::module::module::recovery::RecoveryProgress;
use fedimint_core::config::FederationId;
use fedimint_core::core::ModuleKind;
use fedimint_core::db::mem_impl::MemDatabase;
use fedimint_core::db::{
    Database, DatabaseKeyPrefix, IDatabaseTransactionOpsCore, IDatabaseTransactionOpsCoreTyped,
};
use fedimint_core::encoding::Encodable;
use fedimint_core::invite_code::InviteCode;
use fedimint_core::module::registry::ModuleDecoderRegistry;
use fedimint_core::PeerId;
use fedimint_lnv2_common::gateway_api::PaymentFee;
use serde_json::json;

use crate::db::{
    FederationMetaKey, FederationMetaKeyPrefix, FederationMetaV1, GuardianSession, Timestamp,
};
use crate::multimint::{
    aggregate_recovery_progress, gross_invoice_for_contract, guardian_session_statuses,
    load_guardian_sessions, meta_fields_after_fetch, migrate_federation_meta_v3,
    record_guardian_session, recovery_module_for_kind, FederationMeta, FederationSelector,
    Guardian, GuardianSessionStatus, MetaFetch, MetaFields, Multimint, RecoveryModule, Transaction,
    TransactionKind, MAX_GATEWAY_PPM, TRANSACTION_PAGE_SIZE,
};

/// A cached entry from before the guardians went quiet: shutdown announced.
fn announced_meta() -> FederationMeta {
    FederationMeta {
        picture: Some("https://example.com/icon.png".to_string()),
        welcome: Some("closing soon".to_string()),
        guardians: vec![],
        selector: FederationSelector {
            federation_name: "Old Fed".to_string(),
            federation_id: FederationId::dummy(),
            network: Some("bitcoin".to_string()),
        },
        last_updated: 42,
        recurringd_api: Some("https://recurringd.example.com/".to_string()),
        lnaddress_api: None,
        expiry_timestamp: Some(1_767_225_600),
        successor_invite: Some("fed11successor".to_string()),
    }
}

#[test]
fn meta_refresh_keeps_the_announcement_while_guardians_are_unreachable() {
    let cached = announced_meta();
    let fields = meta_fields_after_fetch(&MetaFetch::Unavailable, Some(&cached));
    assert_eq!(fields.expiry_timestamp, cached.expiry_timestamp);
    assert_eq!(fields.successor_invite, cached.successor_invite);
    assert_eq!(fields.welcome, cached.welcome);
    assert_eq!(fields.picture, cached.picture);
    assert_eq!(fields.recurringd_api, cached.recurringd_api);
    assert_eq!(
        fields.federation_name.as_deref(),
        Some(cached.selector.federation_name.as_str())
    );

    // With nothing cached there is nothing to keep.
    assert_eq!(
        meta_fields_after_fetch(&MetaFetch::Unavailable, None),
        MetaFields::default()
    );
}

#[test]
fn meta_refresh_clears_the_announcement_only_when_the_guardians_say_so() {
    let cached = announced_meta();

    // The guardians answered and have no meta at all.
    assert_eq!(
        meta_fields_after_fetch(&MetaFetch::Unset, Some(&cached)),
        MetaFields::default()
    );

    // The guardians answered with a value that no longer announces one.
    let fetch = MetaFetch::Value(json!({ "welcome_message": "back to normal" }));
    let fields = meta_fields_after_fetch(&fetch, Some(&cached));
    assert_eq!(fields.expiry_timestamp, None);
    assert_eq!(fields.successor_invite, None);
    assert_eq!(fields.welcome.as_deref(), Some("back to normal"));
}

#[tokio::test]
async fn migration_v3_re_encodes_old_entries_and_drops_the_rest() {
    let db = Database::new(MemDatabase::new(), ModuleDecoderRegistry::default());
    let key = FederationMetaKey {
        federation_id: FederationId::dummy(),
    };
    let old = FederationMetaV1 {
        picture: Some("https://example.com/icon.png".to_string()),
        welcome: Some("welcome".to_string()),
        guardians: vec![Guardian {
            peer_id: 0,
            name: "alpha".to_string(),
            version: Some("0.12.0".to_string()),
        }],
        selector: FederationSelector {
            federation_name: "Old Fed".to_string(),
            federation_id: FederationId::dummy(),
            network: Some("bitcoin".to_string()),
        },
        last_updated: 42,
        recurringd_api: Some("https://recurringd.example.com/".to_string()),
        lnaddress_api: None,
    };
    // An entry in no known layout, under the same prefix.
    let mut junk_key = FederationMetaKeyPrefix.to_bytes();
    junk_key.push(0xff);

    let mut dbtx = db.begin_transaction().await;
    dbtx.raw_insert_bytes(&key.to_bytes(), &old.consensus_encode_to_vec())
        .await
        .expect("insert");
    dbtx.raw_insert_bytes(&junk_key, b"not a federation meta")
        .await
        .expect("insert");
    dbtx.commit_tx().await;

    let mut dbtx = db.begin_transaction().await;
    assert_eq!(migrate_federation_meta_v3(&mut dbtx).await, (1, 1));
    dbtx.commit_tx().await;

    let mut dbtx = db.begin_transaction_nc().await;
    let meta = dbtx
        .get_value(&key)
        .await
        .expect("the re-encoded entry reads with the derived decoder");
    assert_eq!(meta.picture, old.picture);
    assert_eq!(meta.welcome, old.welcome);
    assert_eq!(meta.guardians, old.guardians);
    assert_eq!(meta.selector, old.selector);
    assert_eq!(meta.last_updated, old.last_updated);
    assert_eq!(meta.recurringd_api, old.recurringd_api);
    assert_eq!(meta.lnaddress_api, old.lnaddress_api);
    assert_eq!(meta.expiry_timestamp, None);
    assert_eq!(meta.successor_invite, None);
    assert!(dbtx.raw_get_bytes(&junk_key).await.expect("read").is_none());

    // Entries already in the current layout are left as they are.
    let mut dbtx = db.begin_transaction().await;
    assert_eq!(migrate_federation_meta_v3(&mut dbtx).await, (0, 0));
}

#[tokio::test]
async fn guardian_session_clock_restarts_only_when_the_count_changes() {
    let db = Database::new(MemDatabase::new(), ModuleDecoderRegistry::default());
    let federation_id = FederationId::dummy();
    let first_seen = UNIX_EPOCH + Duration::from_secs(1_764_000_000);
    let hour_later = first_seen + Duration::from_secs(60 * 60);
    let day_later = first_seen + Duration::from_secs(60 * 60 * 24);

    let mut dbtx = db.begin_transaction().await;
    let session = record_guardian_session(&mut dbtx, federation_id, 0, 100, first_seen).await;
    assert_eq!(
        session,
        GuardianSession {
            session_count: 100,
            first_seen_at: Timestamp(first_seen),
        }
    );
    dbtx.commit_tx().await;

    // The same count an hour on: a stuck guardian keeps its original time.
    let mut dbtx = db.begin_transaction().await;
    let session = record_guardian_session(&mut dbtx, federation_id, 0, 100, hour_later).await;
    assert_eq!(session.first_seen_at, Timestamp(first_seen));
    dbtx.commit_tx().await;

    let mut dbtx = db.begin_transaction().await;
    let session = record_guardian_session(&mut dbtx, federation_id, 0, 101, hour_later).await;
    assert_eq!(
        session,
        GuardianSession {
            session_count: 101,
            first_seen_at: Timestamp(hour_later),
        }
    );
    dbtx.commit_tx().await;

    // A guardian restored from a backup reports fewer sessions than before.
    let mut dbtx = db.begin_transaction().await;
    let session = record_guardian_session(&mut dbtx, federation_id, 0, 90, day_later).await;
    assert_eq!(
        session,
        GuardianSession {
            session_count: 90,
            first_seen_at: Timestamp(day_later),
        }
    );
    dbtx.commit_tx().await;

    let mut dbtx = db.begin_transaction_nc().await;
    assert_eq!(
        load_guardian_sessions(&mut dbtx, federation_id).await,
        BTreeMap::from([(0, session)])
    );
}

#[tokio::test]
async fn guardian_sessions_are_kept_per_guardian_and_per_federation() {
    let db = Database::new(MemDatabase::new(), ModuleDecoderRegistry::default());
    let federation_id = FederationId::dummy();
    let other_federation_id =
        FederationId::from_str(&"11".repeat(32)).expect("valid federation id");
    let now = UNIX_EPOCH + Duration::from_secs(1_764_000_000);

    let mut dbtx = db.begin_transaction().await;
    let alpha = record_guardian_session(&mut dbtx, federation_id, 0, 100, now).await;
    let beta = record_guardian_session(&mut dbtx, federation_id, 1, 98, now).await;
    record_guardian_session(&mut dbtx, other_federation_id, 0, 7, now).await;
    dbtx.commit_tx().await;

    let mut dbtx = db.begin_transaction_nc().await;
    assert_eq!(
        load_guardian_sessions(&mut dbtx, federation_id).await,
        BTreeMap::from([(0, alpha), (1, beta)])
    );
}

const SESSION_FIRST_SEEN_SECS: u64 = 1_764_000_000;

fn stored_sessions(counts: &[(u16, u64)]) -> BTreeMap<u16, GuardianSession> {
    counts
        .iter()
        .map(|(peer_id, session_count)| {
            let session = GuardianSession {
                session_count: *session_count,
                first_seen_at: Timestamp(UNIX_EPOCH + Duration::from_secs(SESSION_FIRST_SEEN_SECS)),
            };
            (*peer_id, session)
        })
        .collect()
}

#[test]
fn guardian_is_behind_only_from_two_sessions() {
    // A round of requests that straddles the end of a session sees a
    // healthy guardian one short.
    let stored = stored_sessions(&[(0, 100), (1, 100), (2, 99), (3, 98)]);
    let statuses = guardian_session_statuses(0..4, &stored, &BTreeSet::from([0, 1, 2, 3]));

    let behind: Vec<(u64, bool)> = statuses
        .iter()
        .map(|status| (status.sessions_behind, status.is_behind))
        .collect();
    assert_eq!(behind, [(0, false), (0, false), (1, false), (2, true)]);
    assert!(statuses.iter().all(|status| status.fresh));
    assert_eq!(statuses[3].session_count, Some(98));
    assert_eq!(statuses[3].first_seen_at, Some(SESSION_FIRST_SEEN_SECS));
}

#[test]
fn guardians_that_did_not_answer_are_left_out_of_the_comparison() {
    // Guardian 2 was last seen long ago and guardian 3 on some other
    // occasion when it was ahead; neither answered this round.
    let stored = stored_sessions(&[(0, 100), (1, 100), (2, 5), (3, 500)]);
    let statuses = guardian_session_statuses(0..4, &stored, &BTreeSet::from([0, 1]));

    assert!(
        statuses.iter().all(|status| !status.is_behind),
        "a stale count is neither behind nor the mark the others are measured against"
    );
    assert_eq!(
        statuses[2],
        GuardianSessionStatus {
            peer_id: 2,
            session_count: Some(5),
            first_seen_at: Some(SESSION_FIRST_SEEN_SECS),
            fresh: false,
            sessions_behind: 0,
            is_behind: false,
        }
    );

    // The snapshot shown before the first round: nothing is fresh, so
    // nothing is compared however far apart the persisted counts are.
    let statuses = guardian_session_statuses(0..4, &stored, &BTreeSet::new());
    assert!(statuses
        .iter()
        .all(|status| !status.fresh && !status.is_behind && status.sessions_behind == 0));
}

#[test]
fn a_guardian_never_seen_still_gets_a_row() {
    let stored = stored_sessions(&[(0, 100)]);
    let statuses = guardian_session_statuses(0..2, &stored, &BTreeSet::from([0]));

    assert_eq!(
        statuses[1],
        GuardianSessionStatus {
            peer_id: 1,
            session_count: None,
            first_seen_at: None,
            fresh: false,
            sessions_behind: 0,
            is_behind: false,
        }
    );
}

#[test]
fn expiry_timestamp_accepts_number_and_string() {
    // The guardian dashboard writes the timestamp as a string while the
    // fedimint client helper reads a number; both spellings must parse.
    let as_string = json!({ "federation_expiry_timestamp": "1767225600" });
    assert_eq!(
        Multimint::get_expiry_timestamp(&as_string),
        Some(1_767_225_600)
    );
    let as_number = json!({ "federation_expiry_timestamp": 1767225600 });
    assert_eq!(
        Multimint::get_expiry_timestamp(&as_number),
        Some(1_767_225_600)
    );
}

#[test]
fn expiry_timestamp_rejects_dates_the_ui_cannot_render() {
    // The boundary is Dart's DateTime limit, in seconds; one past it would
    // throw in the dashboard header.
    let at_limit = json!({ "federation_expiry_timestamp": 8_640_000_000_000_u64 });
    assert_eq!(
        Multimint::get_expiry_timestamp(&at_limit),
        Some(8_640_000_000_000)
    );
    for value in [
        json!(8_640_000_000_001_u64),
        json!("18446744073709551615"),
        json!(u64::MAX),
    ] {
        let meta = json!({ "federation_expiry_timestamp": value });
        assert_eq!(Multimint::get_expiry_timestamp(&meta), None, "{meta}");
    }
}

#[test]
fn expiry_timestamp_rejects_garbage() {
    for value in [
        json!("soon"),
        json!(-1),
        json!(1.5),
        json!(true),
        json!(null),
    ] {
        let meta = json!({ "federation_expiry_timestamp": value });
        assert_eq!(Multimint::get_expiry_timestamp(&meta), None, "{meta}");
    }
    assert_eq!(Multimint::get_expiry_timestamp(&json!({})), None);
}

#[test]
fn successor_invite_requires_valid_invite_code() {
    let invite = InviteCode::new(
        "wss://foo.bar".parse().unwrap(),
        PeerId::from(0),
        FederationId::dummy(),
        None,
    )
    .to_string();
    let meta = json!({ "federation_successor": invite });
    assert_eq!(Multimint::get_successor_invite(&meta), Some(invite));

    let bogus = json!({ "federation_successor": "fed11notaninvite" });
    assert_eq!(Multimint::get_successor_invite(&bogus), None);
    assert_eq!(
        Multimint::get_successor_invite(&json!({ "federation_successor": 42 })),
        None
    );
    assert_eq!(Multimint::get_successor_invite(&json!({})), None);
}

fn payment_fee(base_msats: u64, ppm: u64) -> PaymentFee {
    PaymentFee {
        base: fedimint_core::Amount::from_msats(base_msats),
        parts_per_million: ppm,
    }
}

#[test]
fn verify_gross_invoice_for_contract() {
    let fee = payment_fee(1_000, 5_000);

    // The invoice must fund the contract with at least its amount, ...
    let contract = 1_000_000;
    let invoice = gross_invoice_for_contract(contract, &fee).expect("solvable fee");
    assert!(fee.subtract_from(invoice).msats >= contract);
    // ... and be the smallest such invoice (one msat less falls short).
    assert!(fee.subtract_from(invoice - 1).msats < contract);

    // A zero-fee gateway (e.g. loopback) leaves the contract unchanged.
    let zero = payment_fee(0, 0);
    assert_eq!(
        gross_invoice_for_contract(contract, &zero).expect("solvable fee"),
        contract
    );
}

/// The H2 case. `subtract_from` saturates at zero, so at exactly 100% no
/// invoice can ever satisfy the walk — it used to spin forever with no
/// `.await`, pinning a tokio worker. The closed form is a divide by zero
/// here too, and `f64::INFINITY as u64` saturates rather than wrapping, so
/// the walk would have started at `u64::MAX`.
#[test]
fn gross_invoice_rejects_fee_at_one_hundred_percent() {
    let err = gross_invoice_for_contract(1_000_000, &payment_fee(0, MAX_GATEWAY_PPM))
        .expect_err("100% fee is not invertible");
    assert!(err.to_string().contains("entire payment"), "got: {err}");
}

#[test]
fn gross_invoice_rejects_fee_above_one_hundred_percent() {
    let err = gross_invoice_for_contract(1_000_000, &payment_fee(0, MAX_GATEWAY_PPM + 1))
        .expect_err("over-100% fee is not invertible");
    assert!(err.to_string().contains("entire payment"), "got: {err}");
}

/// Just below the ceiling must still work — the guard bounds the hostile
/// case without rejecting an expensive but legitimate gateway.
#[test]
fn gross_invoice_accepts_fee_just_below_the_ceiling() {
    let steep = payment_fee(0, MAX_GATEWAY_PPM - 1);
    let contract = 1_000;
    let invoice = gross_invoice_for_contract(contract, &steep).expect("solvable fee");
    assert!(steep.subtract_from(invoice).msats >= contract);
}

/// A gateway can also push the required invoice past `u64` with a large
/// base fee rather than a large ppm.
#[test]
fn gross_invoice_rejects_unrepresentable_amount() {
    let err = gross_invoice_for_contract(u64::MAX, &payment_fee(u64::MAX, 0))
        .expect_err("overflowing base fee has no solution");
    assert!(
        err.to_string().contains("overflows") || err.to_string().contains("too large"),
        "got: {err}"
    );
}

/// The bug this replaced: the UI hardcoded lightning=0, ecash=1, onchain=2,
/// which is only the *legacy* layout. Guardians number modules by
/// enumerating the enabled ones alphabetically by kind, so this table is
/// what has to be consulted instead of a fixed id.
#[test]
fn maps_both_module_generations_to_one_bar() {
    let cases = [
        ("ln", Some(RecoveryModule::Lightning)),
        ("lnv2", Some(RecoveryModule::Lightning)),
        ("mint", Some(RecoveryModule::Ecash)),
        ("mintv2", Some(RecoveryModule::Ecash)),
        ("wallet", Some(RecoveryModule::Onchain)),
        ("walletv2", Some(RecoveryModule::Onchain)),
        // `meta` recovers alongside the rest but has no bar; on a v2-only
        // federation it lands on instance id 1, exactly where the old code
        // looked for ecash.
        ("meta", None),
        ("unknown", None),
    ];

    for (kind, expected) in cases {
        assert_eq!(
            recovery_module_for_kind(&ModuleKind::clone_from_str(kind)),
            expected,
            "kind {kind}"
        );
    }
}

fn progress(complete: u32, total: u32) -> RecoveryProgress {
    RecoveryProgress { complete, total }
}

/// `RecoveryProgress` is a foreign type with no `PartialEq`.
fn assert_progress(actual: RecoveryProgress, complete: u32, total: u32) {
    assert_eq!(
        (actual.complete, actual.total),
        (complete, total),
        "recovery progress"
    );
}

/// Instance ids here are the alphabetical layout a v2-only federation gets:
/// lnv2=0, meta=1, mintv2=2, walletv2=3.
#[test]
fn aggregates_only_the_modules_behind_the_requested_bar() {
    let cache = BTreeMap::from([
        (0, (RecoveryModule::Lightning, progress(0, 0))),
        (2, (RecoveryModule::Ecash, progress(30, 100))),
        (3, (RecoveryModule::Onchain, progress(0, 0))),
    ]);

    assert_progress(
        aggregate_recovery_progress(&cache, RecoveryModule::Ecash),
        30,
        100,
    );
    // Reading id 2 as "onchain", as the old hardcoded map did, is what
    // showed ecash progress under the On-chain tab.
    assert_progress(
        aggregate_recovery_progress(&cache, RecoveryModule::Onchain),
        0,
        0,
    );
    assert_progress(
        aggregate_recovery_progress(&cache, RecoveryModule::Lightning),
        0,
        0,
    );
}

#[test]
fn sums_a_federation_running_both_mint_generations() {
    let cache = BTreeMap::from([
        (0, (RecoveryModule::Ecash, progress(40, 100))),
        (1, (RecoveryModule::Ecash, progress(10, 50))),
    ]);

    // One bar, both modules: 50/150 rather than whichever reported last.
    assert_progress(
        aggregate_recovery_progress(&cache, RecoveryModule::Ecash),
        50,
        150,
    );
}

#[test]
fn a_bar_with_no_modules_reports_nothing_rather_than_complete() {
    // total == 0 is what the UI keys on to leave the bar alone, so an empty
    // cache must not come back looking like a finished recovery.
    let empty = BTreeMap::new();
    let result = aggregate_recovery_progress(&empty, RecoveryModule::Ecash);

    assert_progress(result, 0, 0);
    assert!(result.is_none());
    assert!(!result.is_done());
}

fn history_row(kind: TransactionKind, timestamp: u64) -> Transaction {
    Transaction {
        kind,
        amount: 1_000,
        timestamp,
        operation_id: vec![0; 32],
    }
}

fn operation(timestamp: u64) -> Transaction {
    history_row(
        TransactionKind::EcashSend {
            oob_notes: String::new(),
            fees: 0,
        },
        timestamp,
    )
}

/// Pages through `operations` (newest first) the way the UI does, feeding
/// each page's last row back as the cursor until a short page ends it.
fn page_through(operations: &[u64], recovered_at: u64) -> Vec<Vec<Transaction>> {
    let mut pages = Vec::new();
    let mut cursor = None;
    loop {
        let mut page: Vec<Transaction> = operations
            .iter()
            .filter(|&&timestamp| cursor.is_none_or(|cursor| timestamp < cursor))
            .take(TRANSACTION_PAGE_SIZE)
            .map(|&timestamp| operation(timestamp))
            .collect();
        Multimint::insert_recovery_row(
            &mut page,
            history_row(TransactionKind::Recovery, recovered_at),
            cursor,
        );

        let done = page.len() < TRANSACTION_PAGE_SIZE;
        cursor = page.last().map(|tx| tx.timestamp);
        pages.push(page);
        if done {
            return pages;
        }
    }
}

fn is_recovery(tx: &Transaction) -> bool {
    matches!(tx.kind, TransactionKind::Recovery)
}

fn recovery_count(pages: &[Vec<Transaction>]) -> usize {
    pages.iter().flatten().filter(|tx| is_recovery(tx)).count()
}

#[test]
fn a_recovery_with_no_operations_is_the_whole_history() {
    let pages = page_through(&[], 50);

    assert_eq!(pages.len(), 1);
    assert_eq!(recovery_count(&pages), 1);
}

#[test]
fn a_recovery_older_than_every_operation_comes_last() {
    let operations: Vec<u64> = (100..125).rev().collect();
    let pages = page_through(&operations, 50);

    assert_eq!(recovery_count(&pages), 1);
    assert!(is_recovery(pages.last().unwrap().last().unwrap()));
}

#[test]
fn a_recovery_on_a_full_page_slots_in_by_time_and_is_not_repeated() {
    let operations: Vec<u64> = (100..125).rev().collect();
    let pages = page_through(&operations, 117);

    assert_eq!(recovery_count(&pages), 1);
    assert_eq!(
        pages[0].iter().map(|tx| tx.timestamp).collect::<Vec<_>>(),
        vec![124, 123, 122, 121, 120, 119, 118, 117, 117, 116, 115]
    );
    // Ahead of the operation from the same millisecond, not behind it.
    assert!(is_recovery(&pages[0][7]));
    assert_eq!(pages[1][0].timestamp, 114);
}

#[test]
fn a_recovery_that_fills_the_last_page_is_not_repeated() {
    // Nine operations plus the recovery make a full page, so the UI asks
    // for another with the recovery row itself as the cursor.
    let operations: Vec<u64> = (100..109).rev().collect();
    let pages = page_through(&operations, 50);

    assert_eq!(pages.len(), 2);
    assert!(pages[1].is_empty());
    assert_eq!(recovery_count(&pages), 1);
}
