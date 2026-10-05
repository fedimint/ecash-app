//! LNURL support: LUD-01/06/16 (resolving a Lightning Address or bech32 LNURL
//! to a payable invoice) and LUD-03/17 (the withdraw flow behind Boltcards).
//!
//! `lnurl-rs` still owns bech32 and Lightning Address parsing, the tag dispatch,
//! and the typed response bodies. What lives here is what it gives us no hook
//! for: the HTTP fetch itself — so it goes through [`crate::net::http_client`]
//! and inherits its timeout — and the LUD-06 error envelope.
//!
//! The `#[frb]` entry points that call in here stay in `lib.rs`, which is where
//! the Flutter-facing surface lives.

use std::str::FromStr;

use anyhow::{anyhow, bail};
use flutter_rust_bridge::frb;
use lightning_invoice::Bolt11Invoice;

use crate::app_error::EcashAppError;

/// Longest server-supplied LNURL error reason we will carry in an error message.
///
/// The text is written by whoever runs the endpoint. It only reaches the app log
/// today, but an unbounded one would still be theirs to write there.
const REASON_MAX_LEN: usize = 160;

/// Pull the `reason` out of a LUD-06 error body: `{"status":"ERROR","reason":...}`.
///
/// Returns `None` for anything else, including an `ERROR` carrying no usable
/// reason.
///
/// The reason is sanitized here because this is the point that knows it is
/// untrusted: control characters are folded to spaces and runs of whitespace
/// collapsed (otherwise a server could forge line breaks in the log), then it is
/// capped at [`REASON_MAX_LEN`].
fn service_reason(json: &serde_json::Value) -> Option<String> {
    let obj = json.as_object()?;
    if !obj.get("status")?.as_str()?.eq_ignore_ascii_case("error") {
        return None;
    }

    let reason = obj
        .get("reason")?
        .as_str()?
        .split(|c: char| c.is_control() || c.is_whitespace())
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ");

    if reason.is_empty() {
        return None;
    }

    Some(match reason.char_indices().nth(REASON_MAX_LEN) {
        Some((cutoff, _)) => format!("{}\u{2026}", &reason[..cutoff]),
        None => reason,
    })
}

/// GET an LNURL endpoint and return the parsed JSON body, failing with the
/// server's own reason when it answers with a LUD-06 error.
///
/// We do the fetch because `lnurl-rs` gives us no hook for that check:
/// `AsyncClient::make_request` hands the body to `decode_ln_url_response`, which
/// requires a `tag` field, so a spec-compliant `200 {"status":"ERROR",...}` comes
/// back as a bare `InvalidResponse`. Both spellings fail closed, but only one of
/// them says why in the log. Anything that is *not* an error response is handed
/// to `lnurl-rs` unchanged, so its tag dispatch and typed responses still apply.
///
/// The error body is checked before the HTTP status so that servers answering
/// with the reason alongside a 4xx are covered too — `error_for_status()`, which
/// `lnurl-rs` calls first, discards the body in exactly that case.
async fn fetch_json(url: &str) -> Result<serde_json::Value, EcashAppError> {
    let response = crate::net::http_client()
        .get(url)
        .send()
        .await
        .map_err(|e| EcashAppError::other(format!("LNURL request failed: {e}")))?;

    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|e| EcashAppError::other(format!("LNURL response could not be read: {e}")))?;

    let json: serde_json::Value = match serde_json::from_str(&body) {
        Ok(json) => json,
        // A non-JSON body on a failing status is just the server's error page;
        // the status is the useful half of that.
        Err(_) if !status.is_success() => {
            return Err(EcashAppError::other(format!(
                "LNURL server returned HTTP {status}"
            )))
        }
        Err(e) => {
            return Err(EcashAppError::other(format!(
                "LNURL response was not JSON: {e}"
            )))
        }
    };

    if let Some(reason) = service_reason(&json) {
        return Err(EcashAppError::other(format!(
            "LNURL server rejected the request: {reason}"
        )));
    }

    if !status.is_success() {
        return Err(EcashAppError::other(format!(
            "LNURL server returned HTTP {status}"
        )));
    }

    Ok(json)
}

/// Resolve a Lightning Address (LUD-16) or a bech32 LNURL (LUD-01) to its
/// LNURL-pay parameters.
///
/// A malformed input is a distinct, user-actionable error. Everything past that
/// point is a reachability/protocol failure, which stays generic so the UI can
/// fall back to its "could not reach" message.
pub(crate) async fn fetch_pay_params(
    lnurl_or_address: &str,
) -> Result<lnurl::pay::PayResponse, EcashAppError> {
    let lnurl = match lnurl::lightning_address::LightningAddress::from_str(lnurl_or_address) {
        Ok(lightning_address) => lightning_address.lnurl(),
        _ => lnurl::lnurl::LnUrl::from_str(lnurl_or_address)
            .map_err(|e| EcashAppError::InvalidLightningAddress(e.to_string()))?,
    };

    let json = fetch_json(&lnurl.url).await?;

    // `lnurl-rs` still owns the tag dispatch and the typed response bodies; we
    // only took over the fetch.
    let response = lnurl::decode_ln_url_response_from_json(json)
        .map_err(|e| EcashAppError::other(format!("LNURL request failed: {e}")))?;

    match response {
        lnurl::LnUrlResponse::LnUrlPayResponse(pay_response) => Ok(pay_response),
        other => Err(EcashAppError::other(format!(
            "Unexpected response from lnurl: {other:?}"
        ))),
    }
}

/// Request an invoice from an LNURL-pay callback (LUD-06).
///
/// Mirrors `lnurl-rs`'s `AsyncClient::get_invoice` — same bounds check, same
/// callback URL construction — but routes the fetch through [`fetch_json`].
/// The callback is where servers report most of what went wrong ("amount below
/// minimum", "recipient is offline"), and it is also where `lnurl-rs` loses the
/// message most completely: it deserializes straight into `LnURLPayInvoice`, so
/// an error body fails on the missing `pr` field instead.
pub(crate) async fn fetch_invoice(
    pay_response: &lnurl::pay::PayResponse,
    amount_msats: u64,
) -> Result<Bolt11Invoice, EcashAppError> {
    if amount_msats < pay_response.min_sendable || amount_msats > pay_response.max_sendable {
        return Err(EcashAppError::other(format!(
            "LNURL server accepts {} to {} msat, but {amount_msats} msat was requested",
            pay_response.min_sendable, pay_response.max_sendable
        )));
    }

    let separator = if pay_response.callback.contains('?') {
        '&'
    } else {
        '?'
    };
    let callback_url = format!("{}{separator}amount={amount_msats}", pay_response.callback);

    let json = fetch_json(&callback_url).await?;
    let invoice: lnurl::pay::LnURLPayInvoice = serde_json::from_value(json)
        .map_err(|e| EcashAppError::other(format!("LNURL invoice fetch failed: {e}")))?;

    Bolt11Invoice::from_str(invoice.invoice())
        .map_err(|e| EcashAppError::InvalidInvoice(e.to_string()))
}

/// LUD-06 requires the wallet to check that the invoice an LNURL-pay server
/// hands back actually matches what was asked for. [`fetch_invoice`]
/// validates the *requested* amount against the server's `min/maxSendable` and
/// then returns the server's invoice verbatim, so nothing upstream of here
/// catches a server that answers a 10 sat request with a 10,000 sat invoice:
/// the fedimint modules fund a contract for the invoice's amount, while the fee
/// quote the user approved was computed on the requested amount.
///
/// `expected_network` is `None` when the federation's network is unknown, in
/// which case the network check is skipped — the amount check is not optional.
pub(crate) fn verify_invoice(
    bolt11: &Bolt11Invoice,
    requested_msats: u64,
    expected_network: Option<bitcoin::Network>,
) -> Result<(), EcashAppError> {
    match bolt11.amount_milli_satoshis() {
        Some(invoice_msats) if invoice_msats == requested_msats => {}
        Some(invoice_msats) => {
            return Err(EcashAppError::LnurlAmountMismatch {
                requested_msats,
                invoice_msats,
            })
        }
        // An amountless invoice would let the gateway settle for any value it
        // likes, so it is never acceptable as an answer to an amount request.
        None => {
            return Err(EcashAppError::InvalidInvoice(
                "LNURL server returned an invoice with no amount".to_string(),
            ))
        }
    }

    if let Some(expected) = expected_network {
        let invoice_network = bolt11.network();
        if invoice_network != expected {
            return Err(EcashAppError::InvalidInvoice(format!(
                "LNURL server returned a {invoice_network} invoice, but this federation is on {expected}"
            )));
        }
    }

    Ok(())
}

/// Does this text look like something LNURL can resolve?
///
/// Used by the scanner to classify pasted or scanned text before committing to a
/// network round trip. `lnurl-rs`'s address parser is strict (RFC-ish, via
/// `email_address`), which is what keeps arbitrary text containing an `@` from
/// being taken for a Lightning Address.
pub(crate) fn is_lnurl_or_address(text: &str) -> bool {
    lnurl::lnurl::LnUrl::from_str(text).is_ok()
        || lnurl::lightning_address::LightningAddress::from_str(text).is_ok()
}

// --- LNURL withdraw (LUD-03 / LUD-17) ---------------------------------------

/// Parameters returned by a LNURLw (LNURL Withdraw) endpoint.
/// Shown to the user before they confirm a Boltcard withdraw.
#[derive(Debug)]
#[frb]
pub struct LnurlWithdrawParams {
    pub callback: String,
    pub k1: String,
    pub min_withdrawable_msats: u64,
    pub max_withdrawable_msats: u64,
    pub default_description: String,
}

/// Fetch withdraw parameters from a LNURLw HTTPS endpoint (LUD-03 / LUD-17).
/// Pure read — no side effects. Call this before showing the user anything to
/// confirm, and well before any money moves.
pub(crate) async fn fetch_withdraw_params(url: &str) -> anyhow::Result<LnurlWithdrawParams> {
    let resp: serde_json::Value = crate::net::http_client()
        .get(url)
        .send()
        .await?
        .json()
        .await?;
    parse_withdraw_response(resp)
}

fn parse_withdraw_response(resp: serde_json::Value) -> anyhow::Result<LnurlWithdrawParams> {
    // LUD-03: the server may return an error before we even get to the withdraw params.
    if resp.get("status").and_then(|s| s.as_str()) == Some("ERROR") {
        let reason = resp
            .get("reason")
            .and_then(|r| r.as_str())
            .unwrap_or("unknown error");
        bail!("LNURLw service error: {reason}");
    }

    let tag = resp.get("tag").and_then(|t| t.as_str()).unwrap_or("");
    if tag != "withdrawRequest" {
        bail!("Expected LNURLw withdraw response (tag=withdrawRequest), got: {tag:?}");
    }

    Ok(LnurlWithdrawParams {
        callback: resp["callback"]
            .as_str()
            .ok_or_else(|| anyhow!("LNURLw response missing callback"))?
            .to_string(),
        k1: resp["k1"]
            .as_str()
            .ok_or_else(|| anyhow!("LNURLw response missing k1"))?
            .to_string(),
        min_withdrawable_msats: resp["minWithdrawable"]
            .as_u64()
            .ok_or_else(|| anyhow!("LNURLw response missing minWithdrawable"))?,
        max_withdrawable_msats: resp["maxWithdrawable"]
            .as_u64()
            .ok_or_else(|| anyhow!("LNURLw response missing maxWithdrawable"))?,
        default_description: resp["defaultDescription"]
            .as_str()
            .unwrap_or("")
            .to_string(),
    })
}

/// LUD-03: hand a freshly minted invoice to the withdraw callback so the service
/// (e.g. a Boltcard) can pay it.
///
/// Returns once the service has accepted the invoice; it settles asynchronously,
/// so the caller still has to await the receive operation.
pub(crate) async fn submit_withdraw_invoice(
    callback: &str,
    k1: &str,
    invoice: &str,
) -> anyhow::Result<()> {
    let callback_url = build_withdraw_callback_url(callback, k1, invoice);
    let resp = fetch_json(&callback_url).await?;
    check_withdraw_callback_response(&resp)
}

/// LUD-03: only an explicit `{"status":"OK"}` means the service took the invoice.
///
/// Anything else — `{}`, a proxy's `{"detail": ...}`, a rate limiter's body — must
/// fail here, or the caller waits out its receive timeout for a payment nobody
/// sent. Errors and non-2xx statuses are already rejected by [`fetch_json`].
fn check_withdraw_callback_response(resp: &serde_json::Value) -> anyhow::Result<()> {
    let status = resp.get("status").and_then(|s| s.as_str());
    if status.is_some_and(|s| s.eq_ignore_ascii_case("ok")) {
        return Ok(());
    }

    // serde_json escapes control characters, so the excerpt cannot forge log lines.
    let body = resp.to_string();
    let excerpt = match body.char_indices().nth(REASON_MAX_LEN) {
        Some((cutoff, _)) => format!("{}\u{2026}", &body[..cutoff]),
        None => body,
    };
    bail!("LNURLw service did not confirm the withdraw: {excerpt}");
}

/// LUD-03: append k1 and pr to the callback URL, respecting existing query params.
fn build_withdraw_callback_url(callback: &str, k1: &str, invoice: &str) -> String {
    let separator = if callback.contains('?') { '&' } else { '?' };
    format!("{}{}k1={}&pr={}", callback, separator, k1, invoice)
}

/// Convert an `lnurlw://` URI to its `http(s)://` equivalent (LUD-17).
/// Local hosts and `.onion` addresses use plain `http`; everything else uses `https`.
pub(crate) fn withdraw_uri_to_http(uri: &str) -> Option<String> {
    // Must start with the lnurlw scheme (case-insensitive). `get` rather than a
    // slice so a multi-byte char straddling the prefix returns None, not a panic.
    const PREFIX: &str = "lnurlw://";
    if !uri.get(..PREFIX.len())?.eq_ignore_ascii_case(PREFIX) {
        return None;
    }
    let rest = &uri[PREFIX.len()..];
    // Extract host (everything before the first '/' or '?').
    let host = rest.split(['/', '?']).next().unwrap_or(rest);
    // Strip port if present. Hosts are case-insensitive, so compare lowercased.
    let host_no_port = host.split(':').next().unwrap_or(host).to_ascii_lowercase();
    const LOCAL_HOSTS: &[&str] = &["localhost", "127.0.0.1", "10.0.2.2"];
    let scheme = if host_no_port.ends_with(".onion") || LOCAL_HOSTS.contains(&host_no_port.as_str())
    {
        "http"
    } else {
        "https"
    };
    Some(format!("{scheme}://{rest}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // --- parse_withdraw_response ---

    #[test]
    fn test_parse_valid_withdraw_response() {
        let resp = json!({
            "tag": "withdrawRequest",
            "callback": "https://example.com/withdraw",
            "k1": "abc123",
            "minWithdrawable": 1000,
            "maxWithdrawable": 100000,
            "defaultDescription": "Test withdraw"
        });
        let params = parse_withdraw_response(resp).unwrap();
        assert_eq!(params.callback, "https://example.com/withdraw");
        assert_eq!(params.k1, "abc123");
        assert_eq!(params.min_withdrawable_msats, 1000);
        assert_eq!(params.max_withdrawable_msats, 100000);
        assert_eq!(params.default_description, "Test withdraw");
    }

    #[test]
    fn test_parse_withdraw_response_missing_description_defaults_empty() {
        let resp = json!({
            "tag": "withdrawRequest",
            "callback": "https://example.com/withdraw",
            "k1": "abc123",
            "minWithdrawable": 1000,
            "maxWithdrawable": 100000
        });
        let params = parse_withdraw_response(resp).unwrap();
        assert_eq!(params.default_description, "");
    }

    #[test]
    fn test_parse_withdraw_response_server_error() {
        let resp = json!({
            "status": "ERROR",
            "reason": "card not found"
        });
        let err = parse_withdraw_response(resp).unwrap_err();
        assert!(err.to_string().contains("card not found"));
    }

    #[test]
    fn test_parse_withdraw_response_wrong_tag() {
        let resp = json!({
            "tag": "payRequest",
            "callback": "https://example.com/pay",
            "k1": "abc123",
            "minWithdrawable": 1000,
            "maxWithdrawable": 100000
        });
        let err = parse_withdraw_response(resp).unwrap_err();
        assert!(err.to_string().contains("withdrawRequest"));
    }

    #[test]
    fn test_parse_withdraw_response_missing_callback() {
        let resp = json!({
            "tag": "withdrawRequest",
            "k1": "abc123",
            "minWithdrawable": 1000,
            "maxWithdrawable": 100000
        });
        let err = parse_withdraw_response(resp).unwrap_err();
        assert!(err.to_string().contains("missing callback"));
    }

    // --- build_withdraw_callback_url ---

    // --- check_withdraw_callback_response ---

    #[test]
    fn test_callback_response_ok_is_accepted() {
        assert!(check_withdraw_callback_response(&json!({"status": "OK"})).is_ok());
        assert!(check_withdraw_callback_response(&json!({"status": "ok"})).is_ok());
    }

    #[test]
    fn test_callback_response_without_ok_status_is_rejected() {
        for resp in [
            json!({}),
            json!({"detail": "Not Found"}),
            json!({"error": "Rate limit exceeded"}),
            json!({"status": "PENDING"}),
            json!({"status": 1}),
        ] {
            let err = check_withdraw_callback_response(&resp).unwrap_err();
            assert!(
                err.to_string().contains("did not confirm"),
                "{resp} should be rejected, got: {err}"
            );
        }
    }

    #[test]
    fn test_callback_response_excerpt_is_capped() {
        let resp = json!({"detail": "x".repeat(1000)});
        let err = check_withdraw_callback_response(&resp)
            .unwrap_err()
            .to_string();
        assert!(err.ends_with('\u{2026}'));
        assert!(err.len() < 300);
    }

    #[test]
    fn test_callback_url_no_existing_params() {
        let url =
            build_withdraw_callback_url("https://example.com/withdraw", "mykey", "lnbc1invoice");
        assert_eq!(url, "https://example.com/withdraw?k1=mykey&pr=lnbc1invoice");
    }

    #[test]
    fn test_callback_url_with_existing_params() {
        let url = build_withdraw_callback_url(
            "https://example.com/withdraw?foo=bar",
            "mykey",
            "lnbc1invoice",
        );
        assert_eq!(
            url,
            "https://example.com/withdraw?foo=bar&k1=mykey&pr=lnbc1invoice"
        );
    }

    // --- verify_invoice ---

    fn signed_invoice(
        amount_msats: Option<u64>,
        currency: lightning_invoice::Currency,
    ) -> Bolt11Invoice {
        use bitcoin::hashes::{sha256, Hash as _};
        use bitcoin::secp256k1::{Secp256k1, SecretKey};
        use lightning_invoice::{InvoiceBuilder, PaymentSecret};

        let secret_key = SecretKey::from_slice(&[0x11; 32]).expect("valid key");
        let builder = InvoiceBuilder::new(currency)
            .description("lnurl test".to_string())
            .payment_hash(sha256::Hash::hash(b"lnurl test payment hash"))
            .payment_secret(PaymentSecret([42u8; 32]))
            .current_timestamp()
            .min_final_cltv_expiry_delta(144);
        let builder = match amount_msats {
            Some(msats) => builder.amount_milli_satoshis(msats),
            None => builder,
        };
        builder
            .build_signed(|hash| Secp256k1::new().sign_ecdsa_recoverable(hash, &secret_key))
            .expect("invoice builds")
    }

    #[test]
    fn test_verify_invoice_accepts_exact_amount() {
        let invoice = signed_invoice(Some(10_000), lightning_invoice::Currency::Bitcoin);
        assert!(
            verify_invoice(&invoice, 10_000, Some(bitcoin::Network::Bitcoin)).is_ok(),
            "an invoice matching the request should be accepted"
        );
    }

    /// The H1 scenario: request 10 sats, server answers with an invoice for
    /// 1000x that amount.
    #[test]
    fn test_verify_invoice_rejects_overcharge() {
        let invoice = signed_invoice(Some(10_000_000), lightning_invoice::Currency::Bitcoin);
        let err = verify_invoice(&invoice, 10_000, None).unwrap_err();
        assert_eq!(
            err,
            EcashAppError::LnurlAmountMismatch {
                requested_msats: 10_000,
                invoice_msats: 10_000_000,
            }
        );
    }

    #[test]
    fn test_verify_invoice_rejects_undercharge() {
        let invoice = signed_invoice(Some(1_000), lightning_invoice::Currency::Bitcoin);
        let err = verify_invoice(&invoice, 10_000, None).unwrap_err();
        assert_eq!(
            err,
            EcashAppError::LnurlAmountMismatch {
                requested_msats: 10_000,
                invoice_msats: 1_000,
            }
        );
    }

    #[test]
    fn test_verify_invoice_rejects_amountless() {
        let invoice = signed_invoice(None, lightning_invoice::Currency::Bitcoin);
        let err = verify_invoice(&invoice, 10_000, None).unwrap_err();
        assert!(
            matches!(err, EcashAppError::InvalidInvoice(msg) if msg.contains("no amount")),
            "an amountless invoice lets the gateway settle for any value"
        );
    }

    #[test]
    fn test_verify_invoice_rejects_network_mismatch() {
        let invoice = signed_invoice(Some(10_000), lightning_invoice::Currency::Bitcoin);
        let err = verify_invoice(&invoice, 10_000, Some(bitcoin::Network::Signet)).unwrap_err();
        assert!(matches!(err, EcashAppError::InvalidInvoice(_)));
    }

    #[test]
    fn test_verify_invoice_skips_network_check_when_unknown() {
        let invoice = signed_invoice(Some(10_000), lightning_invoice::Currency::Bitcoin);
        assert!(
            verify_invoice(&invoice, 10_000, None).is_ok(),
            "an unknown federation network must not block a correct invoice"
        );
    }

    // --- service_reason ---

    #[test]
    fn test_service_reason_extracts_lud06_error() {
        let resp = json!({"status": "ERROR", "reason": "user not found"});
        assert_eq!(service_reason(&resp).as_deref(), Some("user not found"));
    }

    #[test]
    fn test_service_reason_ignores_status_case() {
        // LUD-06 spells it `ERROR`, but servers in the wild do not all shout.
        let resp = json!({"status": "Error", "reason": "recipient is offline"});
        assert_eq!(
            service_reason(&resp).as_deref(),
            Some("recipient is offline")
        );
    }

    #[test]
    fn test_service_reason_ignores_success_responses() {
        let pay = json!({
            "tag": "payRequest",
            "callback": "https://example.com/cb",
            "metadata": "[]",
            "minSendable": 1000,
            "maxSendable": 100000
        });
        assert_eq!(service_reason(&pay), None);

        // An explicit OK must not be mistaken for a failure either.
        let ok = json!({"status": "OK", "reason": "ignored"});
        assert_eq!(service_reason(&ok), None);
    }

    #[test]
    fn test_service_reason_needs_usable_text() {
        // Nothing worth reporting: the caller keeps its own generic message.
        for resp in [
            json!({"status": "ERROR"}),
            json!({"status": "ERROR", "reason": ""}),
            json!({"status": "ERROR", "reason": "   \n  "}),
            json!({"status": "ERROR", "reason": 42}),
        ] {
            assert_eq!(service_reason(&resp), None, "{resp}");
        }

        // Not an object at all.
        assert_eq!(service_reason(&json!("ERROR")), None);
    }

    #[test]
    fn test_service_reason_flattens_whitespace_and_control_chars() {
        // A server must not be able to forge line breaks in the app log.
        let resp = json!({"status": "ERROR", "reason": "  line one\n\n\tline two \r\n"});
        assert_eq!(service_reason(&resp).as_deref(), Some("line one line two"));
    }

    #[test]
    fn test_service_reason_truncates_long_text() {
        let resp = json!({"status": "ERROR", "reason": "x".repeat(REASON_MAX_LEN + 50)});
        let reason = service_reason(&resp).unwrap();
        assert_eq!(reason.chars().count(), REASON_MAX_LEN + 1);
        assert!(reason.ends_with('\u{2026}'));
    }

    #[test]
    fn test_service_reason_truncates_on_a_char_boundary() {
        // Cutting a multi-byte reason mid-character would panic on the slice.
        let resp = json!({"status": "ERROR", "reason": "é".repeat(REASON_MAX_LEN + 10)});
        let reason = service_reason(&resp).unwrap();
        assert_eq!(reason.chars().count(), REASON_MAX_LEN + 1);
    }

    // -- lnurlw:// tests -------------------------------------------------------

    #[test]
    fn withdraw_uri_to_http_normal_host_uses_https() {
        let result = withdraw_uri_to_http("lnurlw://pay.example.com/withdraw?k1=abc");
        assert_eq!(
            result,
            Some("https://pay.example.com/withdraw?k1=abc".to_string())
        );
    }

    #[test]
    fn withdraw_uri_to_http_localhost_uses_http() {
        let result = withdraw_uri_to_http("lnurlw://localhost:8080/withdraw?k1=abc");
        assert_eq!(
            result,
            Some("http://localhost:8080/withdraw?k1=abc".to_string())
        );
    }

    #[test]
    fn withdraw_uri_to_http_loopback_uses_http() {
        let result = withdraw_uri_to_http("lnurlw://127.0.0.1:9000/path?k1=abc");
        assert_eq!(
            result,
            Some("http://127.0.0.1:9000/path?k1=abc".to_string())
        );
    }

    #[test]
    fn withdraw_uri_to_http_android_emulator_uses_http() {
        let result = withdraw_uri_to_http("lnurlw://10.0.2.2:9000/path?k1=abc");
        assert_eq!(result, Some("http://10.0.2.2:9000/path?k1=abc".to_string()));
    }

    #[test]
    fn withdraw_uri_to_http_onion_uses_http() {
        let result = withdraw_uri_to_http("lnurlw://abc.onion/withdraw?k1=abc");
        assert_eq!(result, Some("http://abc.onion/withdraw?k1=abc".to_string()));
    }

    #[test]
    fn withdraw_uri_to_http_wrong_scheme_returns_none() {
        assert!(withdraw_uri_to_http("lnurl://example.com/withdraw").is_none());
        assert!(withdraw_uri_to_http("https://example.com/withdraw").is_none());
    }

    #[test]
    fn withdraw_uri_to_http_uppercase_scheme_is_accepted() {
        let result = withdraw_uri_to_http("LNURLW://Pay.Example.com/w?k1=abc");
        assert_eq!(result, Some("https://Pay.Example.com/w?k1=abc".to_string()));
    }

    #[test]
    fn withdraw_uri_to_http_uppercase_local_host_uses_http() {
        let result = withdraw_uri_to_http("LNURLW://LOCALHOST:8080/w?k1=abc");
        assert_eq!(result, Some("http://LOCALHOST:8080/w?k1=abc".to_string()));
    }

    #[test]
    fn withdraw_uri_to_http_short_input_returns_none() {
        assert!(withdraw_uri_to_http("lnurlw:").is_none());
        assert!(withdraw_uri_to_http("").is_none());
    }
}
