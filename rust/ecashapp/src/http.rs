//! Shared HTTP clients and the timeout policy for every outbound request the
//! Rust core makes.
//!
//! `reqwest` sets neither a default request timeout nor a default connect
//! timeout, so a bare `reqwest::Client::new()` can hang for as long as the OS
//! TCP stack allows — minutes on a stalled mobile radio, and effectively
//! forever against a black-holed (silently dropped) connection. That matters
//! well beyond the individual call: `Multimint::spawn_cache_task` runs its
//! steps strictly serially, so one hung request there blocks the federation
//! ecash backup that runs later in the same loop, and the esplora deposit
//! pollers only advance their retry backoff when a request returns `Err`.
//!
//! Everything routes through the clients below so the policy lives in one
//! place, and so connections and TLS sessions are actually pooled rather than
//! renegotiated per call.

use std::sync::LazyLock;
use std::time::Duration;

/// Cap on TCP connect + TLS handshake, applied to every request.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Default total-request budget: mutating calls and background tasks.
///
/// Mutating calls get the longest budget deliberately — abandoning a
/// POST/DELETE early leaves ambiguous server-side state.
pub const BACKGROUND: Duration = Duration::from_secs(30);

/// Read-only calls made with the user waiting on a spinner.
pub const INTERACTIVE: Duration = Duration::from_secs(15);

/// Calls that fire repeatedly, or whose failure is not user-visible and must
/// not delay the caller (price fetch, availability probes, version check).
pub const QUICK: Duration = Duration::from_secs(10);

static CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(BACKGROUND)
        .build()
        .expect("reqwest client with static config always builds")
});

/// Shared, connection-pooled HTTP client.
///
/// Deliberately sets no `User-Agent`: most call sites talk to user- or
/// federation-supplied hosts, and a version string would fingerprint the
/// wallet. `Multimint::check_for_update` sets one per-request, since the
/// GitHub API rejects requests without it.
///
/// Requests inherit [`BACKGROUND`]; override with `.timeout(http::INTERACTIVE)`
/// or `.timeout(http::QUICK)` where a tighter bound fits better.
pub fn client() -> &'static reqwest::Client {
    &CLIENT
}

static LNURL_CLIENT: LazyLock<lnurl::AsyncClient> = LazyLock::new(|| {
    lnurl::AsyncClient::from_client(
        reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(INTERACTIVE)
            .build()
            .expect("reqwest client with static config always builds"),
    )
});

/// Shared client for LNURL flows.
///
/// `lnurl-rs`'s `make_request` / `get_invoice` accept no per-request timeout,
/// so the bound has to live on the client itself — hence a second client
/// rather than a `.timeout()` override on [`client`]. A full LNURL flow is two
/// round trips, so its worst case is `2 * INTERACTIVE`.
pub fn lnurl_client() -> &'static lnurl::AsyncClient {
    &LNURL_CLIENT
}
