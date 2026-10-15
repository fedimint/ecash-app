use std::time::{Duration, UNIX_EPOCH};

use fedimint_core::{
    encoding::{Decodable, Encodable},
    module::registry::ModuleDecoderRegistry,
};

use super::Timestamp;

/// The blanket `Encodable for SystemTime` that fedimint removed in
/// `b975ac4d` encoded `self.duration_since(UNIX_EPOCH)`, i.e. exactly a
/// `Duration`. Wallets in the field have timestamps on disk in that form, so
/// [`Timestamp`] must keep producing the identical bytes — if this ever
/// diverges, every stored price cache, relay entry, backup time and NWC
/// spend window becomes unreadable.
#[test]
fn timestamp_encodes_exactly_like_the_removed_system_time_codec() {
    for duration in [
        Duration::ZERO,
        Duration::from_secs(1),
        Duration::new(1_764_000_000, 123_456_789),
        Duration::new(u32::MAX as u64, 999_999_999),
    ] {
        assert_eq!(
            Timestamp(UNIX_EPOCH + duration).consensus_encode_to_vec(),
            duration.consensus_encode_to_vec(),
            "Timestamp must serialize as the bare duration since the epoch",
        );
    }
}

#[test]
fn timestamp_round_trips() {
    let time = Timestamp(UNIX_EPOCH + Duration::new(1_764_000_000, 123_456_789));
    let bytes = time.consensus_encode_to_vec();
    let decoded =
        Timestamp::consensus_decode_whole(&bytes, &ModuleDecoderRegistry::default()).unwrap();
    assert_eq!(decoded, time);
}
