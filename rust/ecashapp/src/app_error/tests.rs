use super::{classify_anyhow, classify_display, classify_string, EcashAppError};

/// The zeroes the `InsufficientBalance` rule synthesizes: the message it
/// classifies never carries the real amounts.
const UNKNOWN_BALANCE: EcashAppError = EcashAppError::InsufficientBalance {
    needed_msats: 0,
    have_msats: 0,
};

#[test]
fn classifies_expired_invoices() {
    assert_eq!(
        classify_string("the invoice is expired"),
        EcashAppError::ExpiredInvoice
    );
    // Both words are required; either alone falls through.
    assert_eq!(
        classify_string("invoice rejected"),
        EcashAppError::Other("invoice rejected".to_string())
    );
    assert_eq!(
        classify_string("session expired"),
        EcashAppError::Other("session expired".to_string())
    );
}

#[test]
fn classifies_insufficient_balance_with_unknown_amounts() {
    // Either "balance" or "funds" pairs with "insufficient", and the
    // amounts are always synthesized as zero.
    assert_eq!(classify_string("insufficient balance"), UNKNOWN_BALANCE);
    assert_eq!(classify_string("insufficient funds"), UNKNOWN_BALANCE);
    assert_eq!(
        classify_string("insufficient"),
        EcashAppError::Other("insufficient".to_string())
    );
}

#[test]
fn classifies_missing_routes() {
    assert_eq!(
        classify_string("no route to destination"),
        EcashAppError::NoRouteFound
    );
    assert_eq!(
        classify_string("route not found"),
        EcashAppError::NoRouteFound
    );
}

#[test]
fn classifies_missing_gateways() {
    assert_eq!(
        classify_string("no available gateways"),
        EcashAppError::NoGatewaysAvailable
    );
    assert_eq!(
        classify_string("no gateways registered"),
        EcashAppError::NoGatewaysAvailable
    );
}

#[test]
fn classifies_unreachable_gateways() {
    assert_eq!(
        classify_string("gateway is offline"),
        EcashAppError::GatewayOffline
    );
    assert_eq!(
        classify_string("gateway unreachable"),
        EcashAppError::GatewayOffline
    );
}

#[test]
fn classifies_unreachable_federations() {
    assert_eq!(
        classify_string("federation is offline"),
        EcashAppError::FederationOffline
    );
    assert_eq!(
        classify_string("federation unreachable"),
        EcashAppError::FederationOffline
    );
}

#[test]
fn classifies_timeouts() {
    assert_eq!(classify_string("request timed out"), EcashAppError::Timeout);
    assert_eq!(
        classify_string("connection timeout"),
        EcashAppError::Timeout
    );
}

#[test]
fn unrecognized_errors_fall_through_to_other() {
    assert_eq!(
        classify_string("something went wrong"),
        EcashAppError::Other("something went wrong".to_string())
    );
}

/// The rules are ordered, and the order decides which toast the user sees
/// when a message satisfies more than one of them.
#[test]
fn earlier_rules_win_over_later_ones() {
    // "no gateways" must not be read as an offline gateway ...
    assert_eq!(
        classify_string("no gateways available, all gateways are offline"),
        EcashAppError::NoGatewaysAvailable
    );
    // ... and a gateway that is offline while talking to a federation is
    // reported as the gateway being down, not the federation.
    assert_eq!(
        classify_string("gateway for federation is unreachable"),
        EcashAppError::GatewayOffline
    );
    // The expired-invoice rule is checked first of all.
    assert_eq!(
        classify_string("insufficient balance for expired invoice"),
        EcashAppError::ExpiredInvoice
    );
    // The timeout rule is checked last.
    assert_eq!(
        classify_string("gateway unreachable: timed out"),
        EcashAppError::GatewayOffline
    );
}

/// Matching is case-insensitive, but an unclassified message is handed back
/// verbatim rather than lowercased.
#[test]
fn matching_ignores_case_but_other_keeps_the_raw_message() {
    assert_eq!(
        classify_string("Invoice EXPIRED"),
        EcashAppError::ExpiredInvoice
    );
    assert_eq!(
        classify_string("Gateway Is OFFLINE"),
        EcashAppError::GatewayOffline
    );

    let raw = "Unknown Failure: HTTP 500";
    assert_eq!(
        classify_string(raw),
        EcashAppError::Other(raw.to_string()),
        "Other must preserve the original message"
    );
}

/// The public entry points all funnel into the same rules.
#[test]
fn wrappers_share_the_classification() {
    assert_eq!(
        classify_display(&"federation is offline"),
        EcashAppError::FederationOffline
    );
    assert_eq!(
        EcashAppError::from_display("request timed out"),
        EcashAppError::Timeout
    );

    // `anyhow` errors are flattened with `{:#}`, so context added on the
    // way up still classifies against the root cause.
    let err = anyhow::anyhow!("gateway is offline").context("paying invoice");
    assert_eq!(classify_anyhow(&err), EcashAppError::GatewayOffline);
    assert_eq!(EcashAppError::from(err), EcashAppError::GatewayOffline);
}
