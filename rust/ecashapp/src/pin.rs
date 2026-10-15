//! Local PIN: storage, verification, and the failed-attempt lockout.
//!
//! Takes only a [`Database`] — nothing here touches federations — so `lib.rs`
//! builds one from the global `DATABASE` rather than through `Multimint`.
//!
//! `pub(crate)` throughout: FRB wires up every public item, and an unguarded
//! `set_pin`/`clear_pin` on the bridge would bypass the checks in `lib.rs`.

use std::time::UNIX_EPOCH;

use anyhow::{anyhow, bail};
use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use bitcoin::hashes::{sha256, Hash};
use bitcoin::key::rand::{thread_rng, RngCore};
use fedimint_core::db::{Database, IDatabaseTransactionOpsCoreTyped};
use subtle::ConstantTimeEq;

use crate::{
    db::{PinAttempts, PinAttemptsKey, PinCodeHashKey, PinCredentialKey, RequirePinForSpendingKey},
    error_to_flutter, info_to_flutter,
};

/// Wrong PINs tolerated before the backoff starts. Mistyping a PIN is common
/// enough that punishing the first few attempts only inconveniences the owner.
const FREE_ATTEMPTS: u32 = 4;
/// Wait imposed after each failure past [`FREE_ATTEMPTS`], in seconds. The last
/// entry repeats for every further failure.
///
/// Capped rather than escalating without bound, and never a wipe: this app may
/// hold the only copy of the user's funds, so locking its owner out permanently
/// is a worse outcome than slowing an attacker to ~4 guesses an hour. A stolen
/// device is defended by the seed being elsewhere, not by destroying the wallet.
const BACKOFF_SECS: [u64; 5] = [5, 15, 60, 300, 900];

/// When PIN entry reopens after `consecutive_failures` wrong guesses, as unix
/// milliseconds; `0` while entry is still free.
fn locked_until_ms(consecutive_failures: u32, now_ms: u64) -> u64 {
    let Some(over_limit) = consecutive_failures.checked_sub(FREE_ATTEMPTS) else {
        return 0;
    };
    if over_limit == 0 {
        return 0;
    }

    let step = (over_limit as usize - 1).min(BACKOFF_SECS.len() - 1);
    now_ms.saturating_add(BACKOFF_SECS[step] * 1000)
}

/// Wall-clock milliseconds since the unix epoch, `0` if the clock predates it.
fn unix_now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since_epoch| since_epoch.as_millis() as u64)
        .unwrap_or(0)
}

pub(crate) struct PinManager {
    db: Database,
}

impl PinManager {
    pub(crate) fn new(db: Database) -> Self {
        Self { db }
    }

    pub(crate) async fn has_pin_code(&self) -> bool {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&PinCredentialKey).await.is_some()
            || dbtx.get_value(&PinCodeHashKey).await.is_some()
    }

    pub(crate) async fn set_pin(&self, pin: String) -> anyhow::Result<()> {
        let credential = Self::hash_pin(&pin)?;

        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(&PinCredentialKey, &credential).await;
        // Leaving a legacy digest behind would leave the *old* PIN working.
        dbtx.remove_entry(&PinCodeHashKey).await;
        dbtx.remove_entry(&PinAttemptsKey).await;
        dbtx.commit_tx().await;
        Ok(())
    }

    /// Check `pin`, and upgrade a legacy SHA-256 record while we hold the
    /// plaintext that makes the upgrade possible.
    ///
    /// Returns `false` both for a wrong PIN and for an attempt made during a
    /// lockout; callers tell the two apart with [`Self::lockout_secs`].
    pub(crate) async fn verify_pin(&self, pin: String) -> bool {
        // Checked before the PIN is looked at, so the backoff cannot be
        // sidestepped by driving this over the bridge instead of the UI.
        if self.lockout_secs().await > 0 {
            return false;
        }

        let mut dbtx = self.db.begin_transaction_nc().await;
        let credential = dbtx.get_value(&PinCredentialKey).await;
        let legacy = dbtx.get_value(&PinCodeHashKey).await;
        drop(dbtx);

        let correct = match (&credential, &legacy) {
            (Some(credential), _) => match PasswordHash::new(credential) {
                // `verify_password` compares in constant time internally.
                Ok(parsed) => Argon2::default()
                    .verify_password(pin.as_bytes(), &parsed)
                    .is_ok(),
                Err(e) => {
                    error_to_flutter(format!("Stored PIN credential is unreadable: {e}")).await;
                    false
                }
            },
            (None, Some(stored)) => {
                let stored = stored.to_byte_array();
                let input = sha256::Hash::hash(pin.as_bytes()).to_byte_array();
                bool::from(stored.ct_eq(&input))
            }
            // No PIN set: nothing to guess, so nothing to throttle either.
            (None, None) => return false,
        };

        if !correct {
            self.record_failure().await;
            return false;
        }

        if credential.is_none() {
            self.upgrade_legacy(&pin).await;
        }
        self.clear_attempts().await;
        true
    }

    pub(crate) async fn clear_pin(&self) {
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.remove_entry(&PinCredentialKey).await;
        dbtx.remove_entry(&PinCodeHashKey).await;
        dbtx.remove_entry(&PinAttemptsKey).await;
        dbtx.remove_entry(&RequirePinForSpendingKey).await;
        dbtx.commit_tx().await;
    }

    /// Seconds until PIN entry reopens; `0` when it is open.
    ///
    /// Wall-clock based, so it survives the app being force-quit — the case
    /// that matters, since an in-memory counter would reset on every relaunch.
    /// Moving the device clock forward does skip the wait; that trade is worth
    /// it, and someone who can change the system clock has the device anyway.
    pub(crate) async fn lockout_secs(&self) -> u64 {
        let mut dbtx = self.db.begin_transaction_nc().await;
        let Some(attempts) = dbtx.get_value(&PinAttemptsKey).await else {
            return 0;
        };

        // Rounded up so a partial second never reads as "unlocked".
        attempts
            .locked_until_ms
            .saturating_sub(unix_now_millis())
            .div_ceil(1000)
    }

    async fn record_failure(&self) {
        let mut dbtx = self.db.begin_transaction().await;
        let consecutive_failures = dbtx.get_value(&PinAttemptsKey).await.map_or(1, |attempts| {
            attempts.consecutive_failures.saturating_add(1)
        });

        let locked_until_ms = locked_until_ms(consecutive_failures, unix_now_millis());

        dbtx.insert_entry(
            &PinAttemptsKey,
            &PinAttempts {
                consecutive_failures,
                locked_until_ms,
            },
        )
        .await;
        dbtx.commit_tx().await;
    }

    async fn clear_attempts(&self) {
        let mut dbtx = self.db.begin_transaction().await;
        dbtx.remove_entry(&PinAttemptsKey).await;
        dbtx.commit_tx().await;
    }

    /// Rewrite a legacy SHA-256 PIN record as an Argon2id credential.
    ///
    /// Only reachable from [`Self::verify_pin`] once the PIN has been checked,
    /// because the plaintext is the one thing the old digest cannot give us —
    /// which is why this cannot be a startup migration. Both writes share a
    /// transaction: a crash here must leave exactly one of the two records.
    ///
    /// A hashing failure is logged and otherwise ignored. The legacy record
    /// stays, the user keeps a working PIN, and the upgrade retries on the next
    /// unlock. Failing the unlock over it would be far worse.
    async fn upgrade_legacy(&self, pin: &str) {
        let credential = match Self::hash_pin(pin) {
            Ok(credential) => credential,
            Err(e) => {
                error_to_flutter(format!("Could not upgrade stored PIN: {e}")).await;
                return;
            }
        };

        let mut dbtx = self.db.begin_transaction().await;
        dbtx.insert_entry(&PinCredentialKey, &credential).await;
        dbtx.remove_entry(&PinCodeHashKey).await;
        dbtx.commit_tx().await;
        info_to_flutter("Upgraded stored PIN hash to Argon2id").await;
    }

    /// Hash a PIN into an Argon2id PHC string.
    ///
    /// Parameters are the crate defaults (m = 19 MiB, t = 2, p = 1 — the OWASP
    /// baseline), which is the whole point: the cost is paid once per unlock by
    /// the owner, and 10^6 times by anyone working through the keyspace with a
    /// copy of the database. Raising them later needs no migration, since every
    /// PHC string carries the parameters it was written with.
    fn hash_pin(pin: &str) -> anyhow::Result<String> {
        if pin.len() < 4 || pin.len() > 6 || !pin.chars().all(|c| c.is_ascii_digit()) {
            bail!("PIN must be 4-6 digits");
        }

        let mut salt = [0u8; 16];
        thread_rng().fill_bytes(&mut salt);
        let salt = SaltString::encode_b64(&salt).map_err(|e| anyhow!("Bad PIN salt: {e}"))?;

        Argon2::default()
            .hash_password(pin.as_bytes(), &salt)
            .map(|credential| credential.to_string())
            .map_err(|e| anyhow!("Could not hash PIN: {e}"))
    }

    pub(crate) async fn get_require_pin_for_spending(&self) -> bool {
        let mut dbtx = self.db.begin_transaction_nc().await;
        dbtx.get_value(&RequirePinForSpendingKey).await.is_some()
    }

    pub(crate) async fn set_require_pin_for_spending(&self, require: bool) {
        let mut dbtx = self.db.begin_transaction().await;
        if require {
            dbtx.insert_entry(&RequirePinForSpendingKey, &()).await;
        } else {
            dbtx.remove_entry(&RequirePinForSpendingKey).await;
        }
        dbtx.commit_tx().await;
    }
}

#[cfg(test)]
mod tests;
