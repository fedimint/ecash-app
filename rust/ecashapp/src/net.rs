use std::sync::OnceLock;
use std::time::Duration;

/// Timeout applied to every outbound HTTP request, covering the whole exchange
/// including body download.
///
/// Neither `reqwest::Client::new()` nor `reqwest::get()` sets any timeout, so
/// without this a stalled or black-holed endpoint produces a future that never
/// resolves. Whatever awaits it hangs with it — a UI call the user is watching,
/// or a background loop with other work queued behind it.
pub(crate) const HTTP_TIMEOUT: Duration = Duration::from_secs(30);

static SHARED: OnceLock<reqwest::Client> = OnceLock::new();

/// Shared HTTP client carrying [`HTTP_TIMEOUT`].
///
/// Use this in place of `reqwest::Client::new()`. Cloning is cheap and shares
/// the underlying connection pool, so there is no reason for callers to cache
/// the returned client.
pub(crate) fn http_client() -> reqwest::Client {
    SHARED
        .get_or_init(|| {
            http_client_builder()
                .build()
                .expect("Could not build shared HTTP client")
        })
        .clone()
}

/// Builder pre-loaded with [`HTTP_TIMEOUT`], for the callers that need to
/// customize it — a user agent, or a deadline tighter than the default.
///
/// Shorten the timeout freely; do not remove it.
pub(crate) fn http_client_builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder().timeout(HTTP_TIMEOUT)
}
