//! Tap-to-send ecash: authenticated ECIES over secp256k1.
//!
//! This is the cryptographic core of the NFC + BLE "tap to send" feature. The
//! receiver generates an *ephemeral* keypair and hands its public key to the
//! sender over NFC (a ~4 cm, proximity-authenticated channel). The sender
//! encrypts the ecash string to that public key and ships the ciphertext over
//! BLE, which is treated as a fully untrusted transport. Only the holder of the
//! receiver's ephemeral private key can decrypt, so an eavesdropper on BLE sees
//! an opaque blob.
//!
//! Scheme (ECIES / ephemeral-static ECDH):
//!   - Receiver ephemeral keypair `(r, R = r*G)`. `R` crosses NFC.
//!   - Sender generates a fresh ephemeral keypair `(e, E = e*G)` per transfer.
//!   - `shared = ECDH(e, R) = ECDH(r, E)` (secp256k1; the shared value is the
//!     SHA-256 of the compressed shared point, as returned by `SharedSecret`).
//!   - `key = HKDF-SHA256(ikm = shared, salt = R || E, info = HKDF_INFO)`.
//!   - `ciphertext = ChaCha20-Poly1305(key, nonce).encrypt(ecash, aad = header)`.
//!
//! Both ephemeral keys make each transfer forward-secret. Binding `R` and `E`
//! into the KDF salt (and the header into the AEAD associated data) prevents an
//! attacker from swapping the sender's ephemeral key without failing decryption.
//!
//! Wire format of the blob handed to BLE:
//!   `[ version (1) | E compressed (33) | nonce (12) | ciphertext+tag (N) ]`

use bitcoin::key::rand::rngs::OsRng;
use bitcoin::key::rand::RngCore;
use bitcoin::secp256k1::{ecdh::SharedSecret, PublicKey, Secp256k1, SecretKey};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use flutter_rust_bridge::frb;
use hkdf::Hkdf;
use sha2::Sha256;

use crate::app_error::{EcashAppError, EcashAppResult};

use anyhow::{anyhow, bail};

/// Blob format version. Bump when the wire layout or crypto changes.
const TAP_VERSION: u8 = 1;
/// Length of a compressed secp256k1 public key.
const PUBKEY_LEN: usize = 33;
/// ChaCha20-Poly1305 nonce length (96 bits).
const NONCE_LEN: usize = 12;
/// Poly1305 authentication tag length.
const TAG_LEN: usize = 16;
/// `version || ephemeral pubkey` — also used verbatim as the AEAD associated data.
const HEADER_LEN: usize = 1 + PUBKEY_LEN;
/// Smallest possible valid blob: header + nonce + an empty ciphertext (tag only).
const MIN_BLOB_LEN: usize = HEADER_LEN + NONCE_LEN + TAG_LEN;
/// Domain-separation string for the HKDF expansion.
const HKDF_INFO: &[u8] = b"ecashapp-tap-transfer-v1";

/// Derive the 32-byte AEAD key from the ECDH shared secret, binding both
/// ephemeral public keys into the salt for domain separation.
fn derive_key(
    shared: &[u8; 32],
    recipient_pub: &[u8; PUBKEY_LEN],
    ephemeral_pub: &[u8; PUBKEY_LEN],
) -> [u8; 32] {
    let mut salt = Vec::with_capacity(2 * PUBKEY_LEN);
    salt.extend_from_slice(recipient_pub);
    salt.extend_from_slice(ephemeral_pub);
    let hk = Hkdf::<Sha256>::new(Some(&salt), shared);
    let mut key = [0u8; 32];
    hk.expand(HKDF_INFO, &mut key)
        .expect("32 is a valid HKDF-SHA256 output length");
    key
}

/// Encrypt `plaintext` to `recipient`'s public key, returning the wire blob.
pub(crate) fn encrypt(plaintext: &[u8], recipient: &PublicKey) -> anyhow::Result<Vec<u8>> {
    let secp = Secp256k1::new();
    let mut rng = OsRng;

    let (ephemeral_sk, ephemeral_pk) = secp.generate_keypair(&mut rng);
    let shared = SharedSecret::new(recipient, &ephemeral_sk);
    let recipient_bytes = recipient.serialize();
    let ephemeral_bytes = ephemeral_pk.serialize();
    let key = derive_key(&shared.secret_bytes(), &recipient_bytes, &ephemeral_bytes);

    let mut nonce = [0u8; NONCE_LEN];
    rng.fill_bytes(&mut nonce);

    // header = version || ephemeral pubkey; reused as AEAD associated data so
    // any tampering with it fails authentication.
    let mut blob = Vec::with_capacity(HEADER_LEN + NONCE_LEN + plaintext.len() + TAG_LEN);
    blob.push(TAP_VERSION);
    blob.extend_from_slice(&ephemeral_bytes);
    let aad = blob.clone();

    blob.extend_from_slice(&nonce);
    let cipher = ChaCha20Poly1305::new_from_slice(&key).expect("32-byte key is valid");
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| anyhow!("tap transfer: encryption failed"))?;
    blob.extend_from_slice(&ciphertext);
    Ok(blob)
}

/// Decrypt a wire blob using the recipient's ephemeral secret key.
pub(crate) fn decrypt(blob: &[u8], recipient_secret: &SecretKey) -> anyhow::Result<Vec<u8>> {
    if blob.len() < MIN_BLOB_LEN {
        bail!("tap transfer: blob too short");
    }
    if blob[0] != TAP_VERSION {
        bail!("tap transfer: unsupported blob version {}", blob[0]);
    }

    let ephemeral_pk = PublicKey::from_slice(&blob[1..HEADER_LEN])
        .map_err(|_| anyhow!("tap transfer: invalid ephemeral public key"))?;
    let nonce = &blob[HEADER_LEN..HEADER_LEN + NONCE_LEN];
    let ciphertext = &blob[HEADER_LEN + NONCE_LEN..];

    let secp = Secp256k1::new();
    let shared = SharedSecret::new(&ephemeral_pk, recipient_secret);
    let recipient_bytes = PublicKey::from_secret_key(&secp, recipient_secret).serialize();
    let ephemeral_bytes = ephemeral_pk.serialize();
    let key = derive_key(&shared.secret_bytes(), &recipient_bytes, &ephemeral_bytes);

    let cipher = ChaCha20Poly1305::new_from_slice(&key).expect("32-byte key is valid");
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: ciphertext,
                aad: &blob[0..HEADER_LEN],
            },
        )
        .map_err(|_| anyhow!("tap transfer: decryption failed"))?;
    Ok(plaintext)
}

/// Encrypt an ecash string for a tap-transfer recipient's public key.
///
/// `recipient_pubkey` is the 33-byte compressed key received over NFC. The
/// returned blob is delivered to the receiver over BLE.
pub(crate) fn encrypt_ecash(ecash: &str, recipient_pubkey: &[u8]) -> EcashAppResult<Vec<u8>> {
    let recipient = PublicKey::from_slice(recipient_pubkey)
        .map_err(|_| EcashAppError::other("tap transfer: invalid recipient public key"))?;
    encrypt(ecash.as_bytes(), &recipient).map_err(EcashAppError::from)
}

/// Receiver-side tap-transfer session.
///
/// Holds an ephemeral keypair whose private half never crosses the bridge:
/// Dart only ever sees the opaque handle and the 33-byte [`public_key`]. Create
/// one per incoming transfer, hand its public key to the sender over NFC, then
/// feed the BLE blob to [`decrypt`](TapRecipient::decrypt).
#[frb(opaque)]
pub struct TapRecipient {
    secret_key: SecretKey,
    public_key: PublicKey,
}

impl TapRecipient {
    #[frb(sync)]
    pub fn new() -> Self {
        let secp = Secp256k1::new();
        let (secret_key, public_key) = secp.generate_keypair(&mut OsRng);
        Self {
            secret_key,
            public_key,
        }
    }

    /// The 33-byte compressed public key to hand to the sender over NFC.
    #[frb(sync)]
    pub fn public_key(&self) -> Vec<u8> {
        self.public_key.serialize().to_vec()
    }

    /// Decrypt a blob produced by [`encrypt_ecash`], returning the original
    /// ecash string ready to pass to `reissue_ecash`.
    #[frb(sync)]
    pub fn decrypt(&self, blob: Vec<u8>) -> Result<String, EcashAppError> {
        let plaintext = decrypt(&blob, &self.secret_key).map_err(EcashAppError::from)?;
        String::from_utf8(plaintext).map_err(|_| {
            EcashAppError::other("tap transfer: decrypted payload was not valid UTF-8")
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keypair() -> (SecretKey, PublicKey) {
        Secp256k1::new().generate_keypair(&mut OsRng)
    }

    #[test]
    fn round_trip() {
        let (sk, pk) = keypair();
        let msg = b"fed11qgqrsdtest-ecash-token-string";
        let blob = encrypt(msg, &pk).unwrap();
        assert_eq!(blob[0], TAP_VERSION);
        assert!(blob.len() >= MIN_BLOB_LEN);
        assert_eq!(decrypt(&blob, &sk).unwrap(), msg);
    }

    #[test]
    fn empty_plaintext_round_trip() {
        let (sk, pk) = keypair();
        let blob = encrypt(b"", &pk).unwrap();
        assert_eq!(blob.len(), MIN_BLOB_LEN);
        assert_eq!(decrypt(&blob, &sk).unwrap(), b"");
    }

    #[test]
    fn wrong_key_fails() {
        let (_sk, pk) = keypair();
        let (other_sk, _) = keypair();
        let blob = encrypt(b"secret notes", &pk).unwrap();
        assert!(decrypt(&blob, &other_sk).is_err());
    }

    #[test]
    fn tampered_ciphertext_detected() {
        let (sk, pk) = keypair();
        let mut blob = encrypt(b"secret notes", &pk).unwrap();
        let last = blob.len() - 1;
        blob[last] ^= 0x01;
        assert!(decrypt(&blob, &sk).is_err());
    }

    #[test]
    fn tampered_header_detected() {
        let (sk, pk) = keypair();
        let mut blob = encrypt(b"secret notes", &pk).unwrap();
        blob[1] ^= 0x01; // corrupt the ephemeral pubkey (feeds the KDF and AAD)
        assert!(decrypt(&blob, &sk).is_err());
    }

    #[test]
    fn short_blob_rejected() {
        let (sk, _) = keypair();
        assert!(decrypt(&[TAP_VERSION, 0, 0], &sk).is_err());
    }

    #[test]
    fn bad_version_rejected() {
        let (sk, pk) = keypair();
        let mut blob = encrypt(b"x", &pk).unwrap();
        blob[0] = 0xFF;
        assert!(decrypt(&blob, &sk).is_err());
    }

    #[test]
    fn distinct_ephemeral_keys_per_encrypt() {
        // Two encryptions of the same message must differ (fresh ephemeral + nonce).
        let (_sk, pk) = keypair();
        let a = encrypt(b"same", &pk).unwrap();
        let b = encrypt(b"same", &pk).unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn recipient_public_key_is_compressed() {
        assert_eq!(TapRecipient::new().public_key().len(), PUBKEY_LEN);
    }

    #[test]
    fn recipient_decrypts_encrypt_ecash() {
        let recipient = TapRecipient::new();
        let blob = encrypt_ecash("fed1testtoken", &recipient.public_key()).unwrap();
        assert_eq!(recipient.decrypt(blob).unwrap(), "fed1testtoken");
    }
}
