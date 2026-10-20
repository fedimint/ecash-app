use argon2::{password_hash::PasswordHash, Argon2, PasswordVerifier};
use bitcoin::hashes::{sha256, Hash};
use fedimint_core::db::{mem_impl::MemDatabase, Database, IDatabaseTransactionOpsCoreTyped as _};
use subtle::ConstantTimeEq;

use super::{locked_until_ms, PinManager, FREE_ATTEMPTS};
use crate::db::{
    PinAttempts, PinAttemptsKey, PinCodeHashKey, PinCredentialKey, RequirePinForSpendingKey,
};

/// The first few slips cost nothing, then the wait climbs and settles on the
/// last rung rather than growing without bound.
#[test]
fn pin_backoff_escalates_then_caps() {
    const NOW: u64 = 1_700_000_000_000;

    for failures in 0..=FREE_ATTEMPTS {
        assert_eq!(
            locked_until_ms(failures, NOW),
            0,
            "failure {failures} should not lock"
        );
    }

    let expected = [5, 15, 60, 300, 900];
    for (step, secs) in expected.iter().enumerate() {
        let failures = FREE_ATTEMPTS + 1 + step as u32;
        assert_eq!(
            locked_until_ms(failures, NOW),
            NOW + secs * 1000,
            "failure {failures} should wait {secs}s"
        );
    }

    // Beyond the ladder the cap holds, so the owner is slowed, never locked
    // out for good.
    for failures in [20, 1_000, u32::MAX] {
        assert_eq!(locked_until_ms(failures, NOW), NOW + 900 * 1000);
    }
}

#[test]
fn pin_must_be_four_to_six_digits() {
    for bad in ["", "123", "1234567", "12a4", "12 4", "abcd"] {
        PinManager::hash_pin(bad).expect_err("{bad} should be rejected");
    }
    for good in ["1234", "12345", "123456"] {
        PinManager::hash_pin(good).expect("{good} should be accepted");
    }
}

#[test]
fn pin_hash_is_salted_and_verifies() {
    let credential = PinManager::hash_pin("1234").expect("valid PIN");
    // Memory-hard parameters are the entire defense here, so assert them
    // rather than trusting the crate default to stay put. Lowering these
    // silently would cost real security for a 4-6 digit secret.
    assert!(
        credential.starts_with("$argon2id$v=19$m=19456,t=2,p=1$"),
        "got: {credential}"
    );

    let parsed = PasswordHash::new(&credential).expect("PHC string round-trips");
    assert!(Argon2::default().verify_password(b"1234", &parsed).is_ok());
    assert!(Argon2::default().verify_password(b"4321", &parsed).is_err());

    // A random salt per credential is what stops one precomputed table from
    // covering the whole 4-6 digit keyspace at once.
    let other = PinManager::hash_pin("1234").expect("valid PIN");
    assert_ne!(credential, other);
}

/// The four PIN records have to be independently addressable: the upgrade
/// writes a credential and deletes a digest in one transaction, and a prefix
/// collision between any of them would either clobber the spending
/// preference or resurrect the old PIN. Also covers the [`PinAttempts`]
/// encoding, which the backoff silently depends on.
#[tokio::test]
async fn pin_records_round_trip_without_colliding() {
    let db: Database = MemDatabase::new().into();

    let legacy = sha256::Hash::hash(b"1234");
    let mut dbtx = db.begin_transaction().await;
    dbtx.insert_entry(&PinCodeHashKey, &legacy).await;
    dbtx.insert_entry(&RequirePinForSpendingKey, &()).await;
    dbtx.insert_entry(
        &PinAttemptsKey,
        &PinAttempts {
            consecutive_failures: 7,
            locked_until_ms: 1_700_000_060_000,
        },
    )
    .await;
    dbtx.commit_tx().await;

    // The swap `upgrade_legacy` performs, in one transaction.
    let credential = PinManager::hash_pin("1234").expect("valid PIN");
    let mut dbtx = db.begin_transaction().await;
    dbtx.insert_entry(&PinCredentialKey, &credential).await;
    dbtx.remove_entry(&PinCodeHashKey).await;
    dbtx.commit_tx().await;

    let mut dbtx = db.begin_transaction_nc().await;
    assert!(dbtx.get_value(&PinCodeHashKey).await.is_none());
    assert_eq!(
        dbtx.get_value(&PinCredentialKey).await.as_deref(),
        Some(credential.as_str())
    );
    // Untouched by the swap.
    assert!(dbtx.get_value(&RequirePinForSpendingKey).await.is_some());
    let attempts = dbtx
        .get_value(&PinAttemptsKey)
        .await
        .expect("attempts kept");
    assert_eq!(attempts.consecutive_failures, 7);
    assert_eq!(attempts.locked_until_ms, 1_700_000_060_000);
}

/// Pins the legacy digest format. Users upgrading from a release that stored
/// an unsalted SHA-256 can only unlock if this still matches what that code
/// wrote — and unlocking is the only thing that triggers the upgrade.
#[test]
fn legacy_pin_digest_format_is_unchanged() {
    let stored = sha256::Hash::hash("1234".as_bytes());
    assert_eq!(
        stored.to_string(),
        "03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4"
    );
    assert!(bool::from(
        stored
            .to_byte_array()
            .ct_eq(&sha256::Hash::hash("1234".as_bytes()).to_byte_array())
    ));
    assert!(!bool::from(
        stored
            .to_byte_array()
            .ct_eq(&sha256::Hash::hash("4321".as_bytes()).to_byte_array())
    ));
}
