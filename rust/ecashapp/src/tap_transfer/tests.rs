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
    let blob = encrypt_ecash_for_tap("fed1testtoken".into(), recipient.public_key()).unwrap();
    assert_eq!(recipient.decrypt(blob).unwrap(), "fed1testtoken");
}
