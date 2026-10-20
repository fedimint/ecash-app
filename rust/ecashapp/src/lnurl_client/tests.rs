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
    let url = build_withdraw_callback_url("https://example.com/withdraw", "mykey", "lnbc1invoice");
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
