use std::collections::BTreeMap;
use std::str::FromStr;

use anyhow::anyhow;
use async_trait::async_trait;
use bitcoin_payment_instructions::http_resolver::HTTPHrnResolver;
use bitcoin_payment_instructions::{
    ParseError, PaymentInstructions, PaymentMethod, PossiblyResolvedPaymentMethod,
};
use fedimint_core::{config::FederationId, invite_code::InviteCode};
use fedimint_mint_client::OOBNotes;

use crate::multimint::FederationSelector;
use crate::ParsedText;

/// Abstracts over the wallet state that the parser needs. Production supplies a
/// [`MultimintParseContext`] backed by the global `Multimint`; tests supply a
/// fake.
#[async_trait]
pub trait ParseContext: Sync + Send {
    async fn federations(&self) -> Vec<FederationSelector>;
    async fn balance(&self, federation_id: &FederationId) -> u64;
    async fn parse_ecash(
        &self,
        federation_id: &FederationId,
        notes: &OOBNotes,
    ) -> anyhow::Result<u64>;
    async fn get_invoice_network(&self, lnurl_or_address: &str)
        -> anyhow::Result<bitcoin::Network>;

    async fn parse_payment_instructions(
        &self,
        text: &str,
        network: bitcoin::Network,
    ) -> Result<PaymentInstructions, ParseError> {
        PaymentInstructions::parse(text, network, &HTTPHrnResolver, false).await
    }

    async fn log_error(&self, _msg: String) {}
}

/// Single stateless entry point for classifying scanned/pasted text.
///
/// When `selected` is `Some`, only that federation is considered (the
/// federation-context flow). When `selected` is `None`, all known federations
/// are considered and variants like `InviteCode`, `InviteCodeWithEcash`, and
/// `EcashNoFederation` become reachable.
pub async fn parse_text<C: ParseContext + ?Sized>(
    text: String,
    ctx: &C,
    selected: Option<FederationSelector>,
) -> anyhow::Result<(ParsedText, Option<FederationSelector>)> {
    if selected.is_none() && InviteCode::from_str(&text).is_ok() {
        return Ok((ParsedText::InviteCode(text), None));
    }

    let candidate_feds: Vec<FederationSelector> = match &selected {
        Some(f) => vec![f.clone()],
        None => ctx.federations().await,
    };

    let group_by_network: BTreeMap<bitcoin::Network, Vec<FederationSelector>> = candidate_feds
        .iter()
        .filter_map(|s| {
            let network_str = s.network.as_ref()?;
            let network = bitcoin::Network::from_str(network_str).ok()?;
            Some((network, s.clone()))
        })
        .fold(BTreeMap::new(), |mut acc, (network, s)| {
            acc.entry(network).or_default().push(s);
            acc
        });

    for (network, feds) in group_by_network.iter() {
        match ctx.parse_payment_instructions(&text, *network).await {
            Ok(instructions) => {
                for fed in feds {
                    if let Ok((parsed, resolved_fed)) =
                        handle_parsed_payment_instructions(fed, &instructions, text.clone(), ctx)
                            .await
                    {
                        return Ok((parsed, Some(resolved_fed)));
                    }
                }
                return Err(anyhow!("No federation found with sufficient balance"));
            }
            Err(e) => {
                ctx.log_error(format!(
                    "Error when trying to parse payment instructions: {e:?}"
                ))
                .await;
            }
        }
    }

    if lnurl::lnurl::LnUrl::from_str(&text).is_ok()
        || lnurl::lightning_address::LightningAddress::from_str(&text).is_ok()
    {
        if let Some(fed) = &selected {
            return Ok((ParsedText::LightningAddressOrLnurl(text), Some(fed.clone())));
        }

        let network = ctx.get_invoice_network(&text).await?;
        if let Some(feds) = group_by_network.get(&network) {
            if let Some(fed) = feds.first() {
                return Ok((ParsedText::LightningAddressOrLnurl(text), Some(fed.clone())));
            }
        }
    }

    if let Ok(notes) = OOBNotes::from_str(&text) {
        for fed in &candidate_feds {
            if let Ok(amount) = ctx.parse_ecash(&fed.federation_id, &notes).await {
                return Ok((ParsedText::Ecash(amount), Some(fed.clone())));
            }
        }

        if selected.is_none() {
            if let Some(invite_code) = notes.federation_invite() {
                return Ok((
                    ParsedText::InviteCodeWithEcash(invite_code.to_string(), text),
                    None,
                ));
            }
            return Ok((ParsedText::EcashNoFederation, None));
        }
    }

    Err(anyhow!("Payment method not supported"))
}

async fn handle_parsed_payment_instructions<C: ParseContext + ?Sized>(
    fed: &FederationSelector,
    instructions: &PaymentInstructions,
    text: String,
    ctx: &C,
) -> anyhow::Result<(ParsedText, FederationSelector)> {
    match instructions {
        PaymentInstructions::ConfigurableAmount(configurable) => {
            for method in configurable.methods() {
                match method {
                    PossiblyResolvedPaymentMethod::Resolved(resolved) => {
                        if let PaymentMethod::OnChain(address) = resolved {
                            return Ok((
                                ParsedText::BitcoinAddress(address.to_string(), None),
                                fed.clone(),
                            ));
                        }
                    }
                    PossiblyResolvedPaymentMethod::LNURLPay { .. } => {
                        return Ok((ParsedText::LightningAddressOrLnurl(text), fed.clone()));
                    }
                }
            }
        }
        PaymentInstructions::FixedAmount(fixed) => {
            let balance = ctx.balance(&fed.federation_id).await;
            let mut found_payment_method = None;
            for method in fixed.methods() {
                match method {
                    PaymentMethod::LightningBolt11(invoice) => {
                        if let Some(lightning_amount) = fixed.ln_payment_amount() {
                            if balance >= lightning_amount.milli_sats() {
                                found_payment_method = Some((
                                    ParsedText::LightningInvoice(invoice.to_string()),
                                    fed.clone(),
                                ));
                            }
                        }
                    }
                    PaymentMethod::OnChain(address) => {
                        if let Some(onchain_amount) = fixed.onchain_payment_amount() {
                            if balance >= onchain_amount.milli_sats()
                                && found_payment_method.is_none()
                            {
                                found_payment_method = Some((
                                    ParsedText::BitcoinAddress(
                                        address.to_string(),
                                        Some(onchain_amount.milli_sats()),
                                    ),
                                    fed.clone(),
                                ));
                            }
                        }
                    }
                    _ => {}
                }
            }

            if let Some(pm) = found_payment_method {
                return Ok(pm);
            }
        }
    }

    Err(anyhow!("Cannot find payment method"))
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use bitcoin::hashes::{sha256, Hash as _};
    use bitcoin::secp256k1::{Secp256k1, SecretKey};
    use bitcoin_payment_instructions::hrn_resolution::DummyHrnResolver;
    use fedimint_core::encoding::Decodable;
    use fedimint_core::module::registry::ModuleDecoderRegistry;
    use fedimint_core::{Amount, PeerId, TieredMulti};
    use fedimint_mint_client::SpendableNote;
    use lightning_invoice::{Currency, InvoiceBuilder, PaymentSecret};

    use super::*;

    // Plain mainnet bitcoin address — no amount attached.
    const BTC_ADDRESS_MAINNET: &str = "1andreas3batLhQa2FawWjeyjCqyBzypd";

    // BIP21 URI with an explicit amount.
    const BIP21_WITH_AMOUNT: &str =
        "bitcoin:BC1QYLH3U67J673H6Y6ALV70M0PL2YZ53TZHVXGG7U?amount=0.00001";

    // Lightning address — syntactically valid, doesn't actually resolve.
    const LIGHTNING_ADDRESS: &str = "satoshi@example.com";

    // Hex-encoded SpendableNote taken from fedimint-mint-client's own tests.
    // Used purely to satisfy the non-empty invariant of OOBNotes decoding —
    // no real federation is ever contacted.
    const TEST_SPENDABLE_NOTE_HEX: &str =
        "a5dd3ebacad1bc48bd8718eed5a8da1d68f91323bef2848ac4fa2e6f8eed710f3178fd4aef047cc234e6b1127086f33cc408b39818781d9521475360de6b205f3328e490a6d99d5e2553a4553207c8bd";

    /// Build a fresh, signed mainnet BOLT11 invoice at runtime. We can't check
    /// a hardcoded invoice into the test because the underlying parser rejects
    /// expired invoices.
    fn make_test_bolt11(amount_msats: u64) -> String {
        let secp = Secp256k1::new();
        let private_key = SecretKey::from_slice(&[0x11u8; 32]).unwrap();
        let payment_hash = sha256::Hash::hash(&[0x22u8; 32]);
        let payment_secret = PaymentSecret([0x33u8; 32]);

        InvoiceBuilder::new(Currency::Bitcoin)
            .description("test".to_string())
            .payment_hash(payment_hash)
            .payment_secret(payment_secret)
            .current_timestamp()
            .min_final_cltv_expiry_delta(144)
            .amount_milli_satoshis(amount_msats)
            .build_signed(|msg| secp.sign_ecdsa_recoverable(msg, &private_key))
            .unwrap()
            .to_string()
    }

    fn federation_id_from(byte: u8) -> FederationId {
        let hex = format!("{:02x}", byte).repeat(32);
        FederationId::from_str(&hex).expect("valid federation id")
    }

    fn fed(id_byte: u8, name: &str, network: Option<&str>) -> FederationSelector {
        FederationSelector {
            federation_name: name.to_string(),
            federation_id: federation_id_from(id_byte),
            network: network.map(String::from),
        }
    }

    fn make_invite_code_string(federation_id: FederationId) -> String {
        InviteCode::new(
            "wss://foo.bar".parse().unwrap(),
            PeerId::from(0),
            federation_id,
            None,
        )
        .to_string()
    }

    fn make_oob_notes_string(federation_id: FederationId, with_invite: bool) -> String {
        let note = SpendableNote::consensus_decode_hex(
            TEST_SPENDABLE_NOTE_HEX,
            &ModuleDecoderRegistry::default(),
        )
        .expect("valid spendable note");
        let notes: TieredMulti<SpendableNote> =
            vec![(Amount::from_sats(1), note)].into_iter().collect();

        if with_invite {
            let invite = InviteCode::new(
                "wss://foo.bar".parse().unwrap(),
                PeerId::from(0),
                federation_id,
                None,
            );
            OOBNotes::new_with_invite(notes, &invite).to_string()
        } else {
            OOBNotes::new(federation_id.to_prefix(), notes).to_string()
        }
    }

    /// In-memory fake of [`ParseContext`]. Overrides `parse_payment_instructions`
    /// to use `DummyHrnResolver` so tests never touch the network.
    #[derive(Default)]
    struct FakeParseContext {
        feds: Vec<FederationSelector>,
        balances: HashMap<FederationId, u64>,
        invoice_network: Option<bitcoin::Network>,
    }

    #[async_trait]
    impl ParseContext for FakeParseContext {
        async fn federations(&self) -> Vec<FederationSelector> {
            self.feds.clone()
        }

        async fn balance(&self, federation_id: &FederationId) -> u64 {
            self.balances.get(federation_id).copied().unwrap_or(0)
        }

        async fn parse_ecash(
            &self,
            federation_id: &FederationId,
            notes: &OOBNotes,
        ) -> anyhow::Result<u64> {
            if federation_id.to_prefix() != notes.federation_id_prefix() {
                return Err(anyhow!("wrong federation for ecash"));
            }
            Ok(notes.total_amount().msats)
        }

        async fn get_invoice_network(&self, _: &str) -> anyhow::Result<bitcoin::Network> {
            self.invoice_network
                .ok_or_else(|| anyhow!("no network configured"))
        }

        async fn parse_payment_instructions(
            &self,
            text: &str,
            network: bitcoin::Network,
        ) -> Result<PaymentInstructions, ParseError> {
            PaymentInstructions::parse(text, network, &DummyHrnResolver, false).await
        }
    }

    #[tokio::test]
    async fn invite_code_returns_invite_code_variant() {
        let ctx = FakeParseContext::default();
        let code = make_invite_code_string(federation_id_from(0x21));

        let (parsed, selected) = parse_text(code.clone(), &ctx, None).await.unwrap();
        match parsed {
            ParsedText::InviteCode(c) => assert_eq!(c, code),
            other => panic!("expected InviteCode, got {other:?}"),
        }
        assert!(selected.is_none());
    }

    #[tokio::test]
    async fn bolt11_with_sufficient_balance_returns_lightning_invoice() {
        let fed_sel = fed(0x01, "fed-btc", Some("bitcoin"));
        let mut balances = HashMap::new();
        balances.insert(fed_sel.federation_id, 1_000_000_000_000);
        let ctx = FakeParseContext {
            feds: vec![fed_sel.clone()],
            balances,
            ..Default::default()
        };

        let invoice = make_test_bolt11(10_000_000);
        let (parsed, selected) = parse_text(invoice, &ctx, None).await.unwrap();
        assert!(matches!(parsed, ParsedText::LightningInvoice(_)));
        assert_eq!(selected.unwrap().federation_id, fed_sel.federation_id);
    }

    #[tokio::test]
    async fn bolt11_without_balance_errors() {
        let fed_sel = fed(0x01, "fed-btc", Some("bitcoin"));
        let ctx = FakeParseContext {
            feds: vec![fed_sel],
            ..Default::default()
        };

        let invoice = make_test_bolt11(10_000_000);
        let result = parse_text(invoice, &ctx, None).await;
        assert!(result.is_err(), "expected error for insufficient balance");
    }

    #[tokio::test]
    async fn plain_btc_address_returns_bitcoin_address_without_amount() {
        let fed_sel = fed(0x01, "fed-btc", Some("bitcoin"));
        let ctx = FakeParseContext {
            feds: vec![fed_sel.clone()],
            ..Default::default()
        };

        let (parsed, selected) = parse_text(BTC_ADDRESS_MAINNET.to_string(), &ctx, None)
            .await
            .unwrap();
        match parsed {
            ParsedText::BitcoinAddress(_, None) => {}
            other => panic!("expected BitcoinAddress(None), got {other:?}"),
        }
        assert_eq!(selected.unwrap().federation_id, fed_sel.federation_id);
    }

    #[tokio::test]
    async fn bip21_with_amount_returns_bitcoin_address_with_amount() {
        let fed_sel = fed(0x01, "fed-btc", Some("bitcoin"));
        let mut balances = HashMap::new();
        balances.insert(fed_sel.federation_id, 1_000_000_000_000);
        let ctx = FakeParseContext {
            feds: vec![fed_sel.clone()],
            balances,
            ..Default::default()
        };

        let (parsed, selected) = parse_text(BIP21_WITH_AMOUNT.to_string(), &ctx, None)
            .await
            .unwrap();
        match parsed {
            ParsedText::BitcoinAddress(_, Some(msats)) => assert!(msats > 0),
            other => panic!("expected BitcoinAddress(Some), got {other:?}"),
        }
        assert_eq!(selected.unwrap().federation_id, fed_sel.federation_id);
    }

    #[tokio::test]
    async fn ecash_known_federation_returns_ecash_variant() {
        let fid = federation_id_from(0x21);
        let fed_sel = FederationSelector {
            federation_name: "ecash-fed".to_string(),
            federation_id: fid,
            network: Some("bitcoin".to_string()),
        };
        let ctx = FakeParseContext {
            feds: vec![fed_sel.clone()],
            ..Default::default()
        };

        let ecash = make_oob_notes_string(fid, false);
        let (parsed, selected) = parse_text(ecash, &ctx, None).await.unwrap();
        match parsed {
            // 1 sat worth of notes, reported in msats.
            ParsedText::Ecash(msats) => assert_eq!(msats, 1_000),
            other => panic!("expected Ecash, got {other:?}"),
        }
        assert_eq!(selected.unwrap().federation_id, fid);
    }

    #[tokio::test]
    async fn ecash_unknown_federation_without_invite_returns_ecash_no_federation() {
        let our_fid = federation_id_from(0x01);
        let stranger_fid = federation_id_from(0xFF);
        let ctx = FakeParseContext {
            feds: vec![FederationSelector {
                federation_name: "our-fed".to_string(),
                federation_id: our_fid,
                network: Some("bitcoin".to_string()),
            }],
            ..Default::default()
        };

        let ecash = make_oob_notes_string(stranger_fid, false);
        let (parsed, selected) = parse_text(ecash, &ctx, None).await.unwrap();
        assert!(matches!(parsed, ParsedText::EcashNoFederation));
        assert!(selected.is_none());
    }

    #[tokio::test]
    async fn ecash_unknown_federation_with_invite_returns_invite_code_with_ecash() {
        let our_fid = federation_id_from(0x01);
        let stranger_fid = federation_id_from(0xFF);
        let ctx = FakeParseContext {
            feds: vec![FederationSelector {
                federation_name: "our-fed".to_string(),
                federation_id: our_fid,
                network: Some("bitcoin".to_string()),
            }],
            ..Default::default()
        };

        let ecash = make_oob_notes_string(stranger_fid, true);
        let (parsed, selected) = parse_text(ecash.clone(), &ctx, None).await.unwrap();
        match parsed {
            ParsedText::InviteCodeWithEcash(invite, original) => {
                assert!(!invite.is_empty());
                assert_eq!(original, ecash);
            }
            other => panic!("expected InviteCodeWithEcash, got {other:?}"),
        }
        assert!(selected.is_none());
    }

    #[tokio::test]
    async fn lightning_address_with_federation_context_returns_ln_address_variant() {
        // With `selected = Some(...)`, the fallback branch short-circuits without
        // needing to resolve the network of the address.
        let fed_sel = fed(0x01, "fed-btc", Some("bitcoin"));
        let ctx = FakeParseContext {
            feds: vec![fed_sel.clone()],
            ..Default::default()
        };

        let (parsed, selected) =
            parse_text(LIGHTNING_ADDRESS.to_string(), &ctx, Some(fed_sel.clone()))
                .await
                .unwrap();
        match parsed {
            ParsedText::LightningAddressOrLnurl(t) => assert_eq!(t, LIGHTNING_ADDRESS),
            other => panic!("expected LightningAddressOrLnurl, got {other:?}"),
        }
        assert_eq!(selected.unwrap().federation_id, fed_sel.federation_id);
    }

    #[tokio::test]
    async fn lightning_address_without_context_uses_get_invoice_network() {
        let fed_sel = fed(0x01, "fed-btc", Some("bitcoin"));
        let ctx = FakeParseContext {
            feds: vec![fed_sel.clone()],
            invoice_network: Some(bitcoin::Network::Bitcoin),
            ..Default::default()
        };

        let (parsed, selected) = parse_text(LIGHTNING_ADDRESS.to_string(), &ctx, None)
            .await
            .unwrap();
        assert!(matches!(parsed, ParsedText::LightningAddressOrLnurl(_)));
        assert_eq!(selected.unwrap().federation_id, fed_sel.federation_id);
    }

    #[tokio::test]
    async fn garbage_text_returns_error() {
        let ctx = FakeParseContext {
            feds: vec![fed(0x01, "fed-btc", Some("bitcoin"))],
            ..Default::default()
        };

        let result = parse_text("not a real payment string".to_string(), &ctx, None).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn selected_federation_ignores_invite_code_branch() {
        // With a federation selected, an invite-code-shaped string should not
        // short-circuit — instead it falls through to "Payment method not supported".
        let fed_sel = fed(0x01, "fed-btc", Some("bitcoin"));
        let ctx = FakeParseContext {
            feds: vec![fed_sel.clone()],
            ..Default::default()
        };
        let invite = make_invite_code_string(federation_id_from(0x21));

        let result = parse_text(invite, &ctx, Some(fed_sel)).await;
        assert!(result.is_err());
    }

    // -- BIP321 test vectors ---------------------------------------------------
    //
    // Sample URIs below are derived from the example shapes shown in BIP-321
    // (https://bips.dev/321/), adapted with real addresses and freshly-signed
    // invoices so the underlying parser accepts them.

    // Mainnet SegWit address borrowed from bitcoin-payment-instructions' own
    // sample vectors — balanced against `0.00001 BTC` for BIP321 tests.
    const BTC_BECH32_MAINNET: &str = "BC1QYLH3U67J673H6Y6ALV70M0PL2YZ53TZHVXGG7U";

    fn bitcoin_fed_with_balance(balance_msats: u64) -> (FederationSelector, FakeParseContext) {
        let fed_sel = fed(0x01, "fed-btc", Some("bitcoin"));
        let mut balances = HashMap::new();
        if balance_msats > 0 {
            balances.insert(fed_sel.federation_id, balance_msats);
        }
        let ctx = FakeParseContext {
            feds: vec![fed_sel.clone()],
            balances,
            ..Default::default()
        };
        (fed_sel, ctx)
    }

    #[tokio::test]
    async fn bip21_with_label_only_returns_configurable_bitcoin_address() {
        // No `amount` → parser yields a ConfigurableAmount, which maps to
        // `BitcoinAddress(_, None)` regardless of balance.
        let (_, ctx) = bitcoin_fed_with_balance(0);
        let uri = format!("bitcoin:{BTC_ADDRESS_MAINNET}?label=Luke-Jr");

        let (parsed, selected) = parse_text(uri, &ctx, None).await.unwrap();
        match parsed {
            ParsedText::BitcoinAddress(_, None) => {}
            other => panic!("expected BitcoinAddress(None), got {other:?}"),
        }
        assert!(selected.is_some());
    }

    #[tokio::test]
    async fn bip21_with_amount_label_and_message_returns_bitcoin_address_with_amount() {
        // Full BIP21 query-string coverage: `amount`, `label`, url-encoded `message`.
        // 50 BTC == 5 * 10^12 msats — give the fed plenty of headroom.
        let (fed_sel, ctx) = bitcoin_fed_with_balance(10_000_000_000_000);
        let uri = format!(
            "bitcoin:{BTC_ADDRESS_MAINNET}?amount=50&label=Luke-Jr&message=Donation%20for%20project%20xyz"
        );

        let (parsed, selected) = parse_text(uri, &ctx, None).await.unwrap();
        match parsed {
            ParsedText::BitcoinAddress(_, Some(msats)) => {
                assert_eq!(msats, 5_000_000_000_000);
            }
            other => panic!("expected BitcoinAddress(Some), got {other:?}"),
        }
        assert_eq!(selected.unwrap().federation_id, fed_sel.federation_id);
    }

    #[tokio::test]
    async fn bip321_address_plus_lightning_prefers_lightning_when_balance_sufficient() {
        // When both an on-chain address AND a lightning invoice are present and
        // the federation has enough balance for both, the Lightning method wins
        // (see the iteration order in handle_parsed_payment_instructions).
        let (fed_sel, ctx) = bitcoin_fed_with_balance(1_000_000_000_000);
        // 1000 sats = 0.00001 BTC = 1_000_000 msats — amounts must agree or
        // the parser rejects the URI as inconsistent.
        let invoice = make_test_bolt11(1_000_000);
        let uri = format!("bitcoin:{BTC_BECH32_MAINNET}?amount=0.00001&lightning={invoice}");

        let (parsed, selected) = parse_text(uri, &ctx, None).await.unwrap();
        assert!(matches!(parsed, ParsedText::LightningInvoice(_)));
        assert_eq!(selected.unwrap().federation_id, fed_sel.federation_id);
    }

    #[tokio::test]
    async fn bip321_address_plus_lightning_with_zero_balance_errors() {
        // Same URI shape as above, but with no balance — neither method is
        // viable, so the caller gets the "no federation with balance" error.
        let (_, ctx) = bitcoin_fed_with_balance(0);
        let invoice = make_test_bolt11(1_000_000);
        let uri = format!("bitcoin:{BTC_BECH32_MAINNET}?amount=0.00001&lightning={invoice}");

        let result = parse_text(uri, &ctx, None).await;
        assert!(result.is_err(), "expected error for zero balance");
    }

    #[tokio::test]
    async fn bip321_lightning_only_uri_returns_lightning_invoice() {
        // `bitcoin:?lightning=<inv>` — no on-chain address, lightning-only.
        let (fed_sel, ctx) = bitcoin_fed_with_balance(1_000_000_000_000);
        let invoice = make_test_bolt11(1_000_000);
        let uri = format!("bitcoin:?lightning={invoice}");

        let (parsed, selected) = parse_text(uri, &ctx, None).await.unwrap();
        assert!(matches!(parsed, ParsedText::LightningInvoice(_)));
        assert_eq!(selected.unwrap().federation_id, fed_sel.federation_id);
    }

    #[tokio::test]
    async fn bip21_with_unknown_optional_parameters_is_accepted() {
        // Unknown non-`req-` params must be ignored per BIP21. Parser should
        // still return a BitcoinAddress with the specified amount.
        let (_, ctx) = bitcoin_fed_with_balance(1_000_000_000_000);
        let uri =
            format!("bitcoin:{BTC_ADDRESS_MAINNET}?amount=0.00001&somethingyoudontunderstand=50");

        let (parsed, _) = parse_text(uri, &ctx, None).await.unwrap();
        match parsed {
            ParsedText::BitcoinAddress(_, Some(msats)) => assert_eq!(msats, 1_000_000),
            other => panic!("expected BitcoinAddress(Some), got {other:?}"),
        }
    }

    #[tokio::test]
    async fn bip321_with_required_unknown_parameter_errors() {
        // `req-<name>` params indicate features the wallet MUST support. An
        // unknown `req-` parameter should cause parsing to fail per BIP21.
        let (_, ctx) = bitcoin_fed_with_balance(1_000_000_000_000);
        let uri = format!(
            "bitcoin:{BTC_ADDRESS_MAINNET}?amount=0.00001&req-somethingyoudontunderstand=50"
        );

        let result = parse_text(uri, &ctx, None).await;
        assert!(result.is_err(), "unknown req- param must reject URI");
    }
}
