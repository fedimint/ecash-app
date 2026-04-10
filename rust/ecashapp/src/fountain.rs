use fedimint_core::base32::{decode_prefixed, encode_prefixed, FEDIMINT_PREFIX};
use fedimint_fountain::{FountainDecoder, FountainEncoder};
use fedimint_mint_client::OOBNotes;
use flutter_rust_bridge::frb;

use crate::multimint::OOBNotesWrapper;

#[frb(opaque)]
pub struct OOBNotesEncoder(FountainEncoder);

impl OOBNotesEncoder {
    #[frb(sync)]
    pub fn new(notes: &OOBNotesWrapper) -> Self {
        Self(FountainEncoder::new(&notes.0, 512))
    }

    #[frb]
    pub fn next_fragment(&mut self) -> String {
        encode_prefixed(FEDIMINT_PREFIX, &self.0.next_fragment())
    }
}

#[frb(opaque)]
pub struct OOBNotesDecoder(FountainDecoder<OOBNotes>);

impl OOBNotesDecoder {
    #[frb(sync)]
    pub fn new() -> Self {
        Self(FountainDecoder::default())
    }

    #[frb(sync)]
    pub fn add_fragment(&mut self, fragment: &str) -> Option<OOBNotesWrapper> {
        decode_prefixed(FEDIMINT_PREFIX, fragment)
            .ok()
            .and_then(|fragment| self.0.add_fragment(&fragment))
            .map(OOBNotesWrapper)
    }
}
