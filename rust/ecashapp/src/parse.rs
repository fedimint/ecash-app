use std::collections::BTreeMap;
use std::str::FromStr;

use anyhow::anyhow;
use async_trait::async_trait;
use bitcoin_payment_instructions::http_resolver::HTTPHrnResolver;
use bitcoin_payment_instructions::{
    ParseError, PaymentInstructions, PaymentMethod, PossiblyResolvedPaymentMethod,
};
use fedimint_core::base32::{decode_prefixed, FEDIMINT_PREFIX};
use fedimint_core::{config::FederationId, invite_code::InviteCode};
use fedimint_mint_client::OOBNotes;
use fedimint_mintv2_client::ECash;

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
    // LUD-17: lnurlw:// is a raw-scheme Boltcard / LNURL-withdraw URI.
    // Convert to http(s) and return immediately — no balance needed (receive flow).
    if let Some(url) = crate::lnurl_client::withdraw_uri_to_http(&text) {
        let fed = match &selected {
            Some(f) => Some(f.clone()),
            None => ctx.federations().await.into_iter().next(),
        };
        return Ok((ParsedText::LnurlWithdraw(url), fed));
    }

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
                // Not a bitcoin payment instruction (e.g. ecash); fall through to
                // the LNURL/ecash parsing below.
                ctx.log_error(format!(
                    "Not a payment instruction ({e:?}); trying to parse as ecash"
                ))
                .await;
            }
        }
    }

    if crate::lnurl_client::is_lnurl_or_address(&text) {
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

    // mintv2 ecash first: it carries the full federation id (`mint()`) and the
    // amount, so we resolve it directly. Decoding is permissive (a v1 string can
    // decode into an `ECash` with `mint() == None`), so we only act when `mint()`
    // is set, otherwise fall through to v1.
    if let Ok(ecash) = decode_prefixed::<ECash>(FEDIMINT_PREFIX, &text) {
        if let Some(mint_fed_id) = ecash.mint() {
            if let Some(fed) = candidate_feds
                .iter()
                .find(|f| f.federation_id == mint_fed_id)
            {
                return Ok((ParsedText::Ecash(ecash.amount().msats), Some(fed.clone())));
            }
            // Recognized mintv2 ecash but not joined to its federation. If the
            // sender embedded the federation's invite code (our send path sets
            // `include_invite = true`), offer to join and redeem in one step,
            // mirroring the v1 OOBNotes branch below. Otherwise surface the
            // codeless outcome.
            if selected.is_none() {
                if let Some(invite_code) = ecash.federation_invite() {
                    return Ok((
                        ParsedText::InviteCodeWithEcash(invite_code.to_string(), text),
                        None,
                    ));
                }
                return Ok((ParsedText::EcashNoFederation, None));
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
mod tests;
