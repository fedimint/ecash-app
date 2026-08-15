use fedimint_core::base32::{decode_prefixed, encode_prefixed, FEDIMINT_PREFIX};
use fedimint_fountain::{FountainDecoder, FountainEncoder};
use fedimint_mint_client::OOBNotes;
use fedimint_mintv2_client::ECash;
use flutter_rust_bridge::frb;

use crate::multimint::{OOBNotesWrapper, WrappedEcash};

#[frb(opaque)]
pub struct OOBNotesEncoder(FountainEncoder);

impl OOBNotesEncoder {
    #[frb(sync)]
    pub fn new(notes: &OOBNotesWrapper) -> Self {
        // The encoder just serializes whatever Encodable it's given, so each
        // mint encoding (walletv1 OOBNotes / mintv2 ECash) works the same way.
        Self(match &notes.0 {
            WrappedEcash::V1(notes) => FountainEncoder::new(notes, 512),
            WrappedEcash::V2(ecash) => FountainEncoder::new(ecash, 512),
        })
    }

    #[frb]
    pub fn next_fragment(&mut self) -> String {
        encode_prefixed(FEDIMINT_PREFIX, &self.0.next_fragment())
    }
}

#[frb(opaque)]
pub struct OOBNotesDecoder {
    // We don't know upfront whether a scanned animated QR carries walletv1 or
    // mintv2 ecash, and the typed fountain decoder bakes in the output type. The
    // two decoders reassemble identical bytes and differ only in the final
    // decode, so we feed both and keep whichever succeeds.
    v1: FountainDecoder<OOBNotes>,
    v2: FountainDecoder<ECash>,
}

impl OOBNotesDecoder {
    #[frb(sync)]
    pub fn new() -> Self {
        Self {
            v1: FountainDecoder::default(),
            v2: FountainDecoder::default(),
        }
    }

    #[frb(sync)]
    pub fn add_fragment(&mut self, fragment: &str) -> Option<OOBNotesWrapper> {
        let fragment = decode_prefixed(FEDIMINT_PREFIX, fragment).ok()?;

        // mintv2 first: its decoder is permissive (a v1 byte stream can decode
        // to an `ECash` with `mint() == None`), so only accept it when it
        // carries a federation id, otherwise fall back to walletv1.
        let v2 = self.v2.add_fragment(&fragment);
        let v1 = self.v1.add_fragment(&fragment);

        if let Some(ecash) = v2 {
            if ecash.mint().is_some() {
                return Some(OOBNotesWrapper(WrappedEcash::V2(ecash)));
            }
        }
        v1.map(|notes| OOBNotesWrapper(WrappedEcash::V1(notes)))
    }
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use fedimint_core::config::FederationId;
    use fedimint_core::encoding::Decodable;
    use fedimint_core::module::registry::ModuleDecoderRegistry;
    use fedimint_core::{Amount, TieredMulti};
    use fedimint_mint_client::SpendableNote;

    use super::{OOBNotesDecoder, OOBNotesEncoder};
    use crate::multimint::{OOBNotesWrapper, WrappedEcash};

    // Hex-encoded SpendableNote taken from fedimint-mint-client's own tests.
    // Nothing here is ever spent; the note only has to be well-formed enough
    // for `OOBNotes` to encode and decode.
    const TEST_SPENDABLE_NOTE_HEX: &str =
        "a5dd3ebacad1bc48bd8718eed5a8da1d68f91323bef2848ac4fa2e6f8eed710f3178fd4aef047cc234e6b1127086f33cc408b39818781d9521475360de6b205f3328e490a6d99d5e2553a4553207c8bd";

    /// A fragment is only ever produced by the encoder, so anything shorter
    /// than a full transmission has to keep the decoder waiting.
    const GARBAGE_FRAGMENT: &str = "not a fountain fragment";

    fn federation_id() -> FederationId {
        FederationId::from_str(&"ab".repeat(32)).expect("valid federation id")
    }

    /// walletv1 ecash holding `note_count` notes. More notes means a longer
    /// payload, which is how we get a transmission that spans several
    /// fragments.
    fn v1_ecash(note_count: u64) -> OOBNotesWrapper {
        let note = SpendableNote::consensus_decode_hex(
            TEST_SPENDABLE_NOTE_HEX,
            &ModuleDecoderRegistry::default(),
        )
        .expect("valid spendable note");

        let notes: TieredMulti<SpendableNote> = (0..note_count)
            .map(|i| (Amount::from_sats(1 << i), note))
            .collect();

        OOBNotesWrapper(WrappedEcash::V1(fedimint_mint_client::OOBNotes::new(
            federation_id().to_prefix(),
            notes,
        )))
    }

    /// mintv2 ecash. An empty note set is enough: the encoder serializes
    /// whatever it is given and the decoder only inspects `mint()`.
    fn v2_ecash() -> OOBNotesWrapper {
        OOBNotesWrapper(WrappedEcash::V2(fedimint_mintv2_client::ECash::new(
            federation_id(),
            vec![],
        )))
    }

    /// Emits fragments until the decoder has seen enough of them, and returns
    /// the fragments it took. Panics rather than looping forever if the
    /// transmission never completes.
    fn fragments_to_decode(ecash: &OOBNotesWrapper) -> Vec<String> {
        let mut encoder = OOBNotesEncoder::new(ecash);
        let mut decoder = OOBNotesDecoder::new();
        let mut fragments = Vec::new();

        for _ in 0..64 {
            let fragment = encoder.next_fragment();
            fragments.push(fragment.clone());

            if decoder.add_fragment(&fragment).is_some() {
                return fragments;
            }
        }

        panic!("decoder never completed within 64 fragments");
    }

    #[track_caller]
    fn assert_decodes_to(decoded: Option<OOBNotesWrapper>, expected: &OOBNotesWrapper) {
        let decoded = decoded.expect("fragments should have decoded");
        assert_eq!(decoded.to_string(), expected.to_string());
        assert_eq!(decoded.amount_msats(), expected.amount_msats());
        assert!(
            matches!(
                (&decoded.0, &expected.0),
                (WrappedEcash::V1(_), WrappedEcash::V1(_))
                    | (WrappedEcash::V2(_), WrappedEcash::V2(_))
            ),
            "decoded ecash changed encoding"
        );
    }

    /// The animated-QR round trip: every fragment the encoder emits, fed to the
    /// decoder in order, reproduces the original notes.
    #[test]
    fn v1_notes_survive_the_round_trip() {
        let original = v1_ecash(16);
        let fragments = fragments_to_decode(&original);
        assert!(
            fragments.len() > 1,
            "test needs a payload that spans several fragments, got {}",
            fragments.len()
        );

        let mut decoder = OOBNotesDecoder::new();
        let mut decoded = None;
        for fragment in &fragments {
            decoded = decoder.add_fragment(fragment);
        }

        assert_decodes_to(decoded, &original);
    }

    /// mintv2 ecash goes through the same path, and the decoder must hand back
    /// v2 rather than falling through to the permissive v1 branch.
    #[test]
    fn v2_ecash_survives_the_round_trip() {
        let original = v2_ecash();
        let fragments = fragments_to_decode(&original);

        let mut decoder = OOBNotesDecoder::new();
        let mut decoded = None;
        for fragment in &fragments {
            decoded = decoder.add_fragment(fragment);
        }

        assert_decodes_to(decoded, &original);
    }

    /// A scanner does not necessarily see the frames in the order they were
    /// drawn, so the decoder must not depend on it.
    #[test]
    fn fragments_decode_out_of_order() {
        let original = v1_ecash(16);
        let mut fragments = fragments_to_decode(&original);
        fragments.reverse();

        let mut decoder = OOBNotesDecoder::new();
        let mut decoded = None;
        for fragment in &fragments {
            decoded = decoder.add_fragment(fragment);
        }

        assert_decodes_to(decoded, &original);
    }

    /// An animated QR loops, so the same fragment is scanned repeatedly.
    /// Re-feeding one must not corrupt the partially decoded state.
    #[test]
    fn duplicate_fragments_do_not_corrupt_the_decoder() {
        let original = v1_ecash(16);
        let fragments = fragments_to_decode(&original);

        let mut decoder = OOBNotesDecoder::new();
        let mut decoded = None;
        for fragment in &fragments {
            let _ = decoder.add_fragment(fragment);
            decoded = decoder.add_fragment(fragment);
        }

        assert_decodes_to(decoded, &original);
    }

    /// Anything that is not a fragment is ignored rather than accepted as one.
    #[test]
    fn garbage_input_yields_nothing() {
        let mut decoder = OOBNotesDecoder::new();
        assert!(decoder.add_fragment(GARBAGE_FRAGMENT).is_none());
    }
}
