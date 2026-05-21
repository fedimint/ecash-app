use flutter_rust_bridge::frb;
use serde::Serialize;

/// Typed error returned across the Flutter Rust Bridge to give the Dart layer
/// enough information to render a user-friendly toast.
///
/// New variants should map to a localized string in `lib/error_helper.dart`
/// (with l10n keys in `lib/l10n/app_en.arb`). Unknown / unmapped errors fall
/// through to [`EcashAppError::Other`].
#[derive(Clone, Eq, PartialEq, Serialize, Debug, thiserror::Error)]
pub enum EcashAppError {
    #[error("invoice is expired")]
    ExpiredInvoice,
    #[error("insufficient balance: need {needed_msats} msat, have {have_msats}")]
    InsufficientBalance { needed_msats: u64, have_msats: u64 },
    #[error("no route to recipient")]
    NoRouteFound,
    #[error("selected gateway is offline or unreachable")]
    GatewayOffline,
    #[error("no gateways available for this federation")]
    NoGatewaysAvailable,
    #[error("federation is offline or unreachable")]
    FederationOffline,
    #[error("invalid invoice: {0}")]
    InvalidInvoice(String),
    #[error("invalid address: {0}")]
    InvalidAddress(String),
    #[error("payment was refunded: {0}")]
    PaymentRefunded(String),
    #[error("operation timed out")]
    Timeout,
    #[error("{0}")]
    Other(String),
}

pub type EcashAppResult<T> = std::result::Result<T, EcashAppError>;

impl From<anyhow::Error> for EcashAppError {
    fn from(err: anyhow::Error) -> Self {
        classify_string(&format!("{err:#}"))
    }
}

/// Best-effort classification of an `anyhow::Error` into a typed variant.
///
/// Call sites with explicit context should prefer constructing the right
/// variant directly (e.g. `EcashAppError::InvalidInvoice(...)`) rather than
/// relying on this fallback.
#[frb(ignore)]
pub fn classify_anyhow(err: &anyhow::Error) -> EcashAppError {
    classify_string(&format!("{err:#}"))
}

/// Classify an arbitrary `Display`-able error (e.g. Fedimint client error
/// types that don't implement `StdError + 'static` cleanly into `anyhow`).
#[frb(ignore)]
pub fn classify_display<E: std::fmt::Display>(err: &E) -> EcashAppError {
    classify_string(&err.to_string())
}

fn classify_string(raw: &str) -> EcashAppError {
    let full = raw.to_lowercase();

    if full.contains("expired") && full.contains("invoice") {
        return EcashAppError::ExpiredInvoice;
    }
    if full.contains("insufficient") && (full.contains("balance") || full.contains("funds")) {
        return EcashAppError::InsufficientBalance {
            needed_msats: 0,
            have_msats: 0,
        };
    }
    if full.contains("no route") || full.contains("route not found") {
        return EcashAppError::NoRouteFound;
    }
    if full.contains("no available gateways") || full.contains("no gateways") {
        return EcashAppError::NoGatewaysAvailable;
    }
    if full.contains("gateway") && (full.contains("offline") || full.contains("unreachable")) {
        return EcashAppError::GatewayOffline;
    }
    if full.contains("federation") && (full.contains("offline") || full.contains("unreachable")) {
        return EcashAppError::FederationOffline;
    }
    if full.contains("timed out") || full.contains("timeout") {
        return EcashAppError::Timeout;
    }

    EcashAppError::Other(raw.to_string())
}

#[frb(ignore)]
impl EcashAppError {
    pub fn other(msg: impl Into<String>) -> Self {
        EcashAppError::Other(msg.into())
    }

    /// Convenience: classify any `Display` error into an EcashAppError.
    pub fn from_display<E: std::fmt::Display>(err: E) -> Self {
        classify_string(&err.to_string())
    }
}
