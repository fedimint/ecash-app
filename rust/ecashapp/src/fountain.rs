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
