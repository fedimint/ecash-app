use flutter_rust_bridge::frb;
use regex::Regex;

#[frb]
pub struct LnurlWrapper(pub(crate) String);

impl LnurlWrapper {
    #[frb(sync)]
    pub fn encode(&self) -> String {
        fedimint_lnurl::encode_lnurl(&self.0)
    }
}

/// Strict URI encode adhering to RFC 3986
fn strict_uri_encode(input: &str) -> String {
    input
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{:02X}", byte),
        })
        .collect()
}

/// Merchant patterns following blink-client approach (MoneyBadger)
const MERCHANT_PATTERNS: &[&str] = &[
    r"(?i)za\.co\.electrum\.picknpay",
    r"(?i)za\.co\.ecentric",
    r"(wigroup\.co|yoyogroup\.co)",
    r"(zapper\.com|\d+\.zap\.pe)",
    r"payat\.io",
    r"paynow\.netcash\.co\.za",
    r"paynow\.sagepay\.co\.za",
    r"^SK-\d{1,}-\d{23}$",
    r"transactionjunction\.co\.za",
    r"^CRSTPC-\d+-\d+-\d+-\d+-\d+$",
    r"scantopay\.io",
    r"snapscan",
    r"^\d{10}$",
    r"^.{2}/.{4}/.{20}$",
];

#[frb(sync)]
pub fn parse_lnurl(request: &str) -> Option<LnurlWrapper> {
    if let Some(stripped) = request.strip_prefix("lightning:") {
        return parse_lnurl(stripped);
    }

    if let Some(stripped) = request.strip_prefix("lnurl:") {
        return parse_lnurl(stripped);
    }

    // Try to parse as URL and extract LNURL from query parameters
    if let Ok(url) = url::Url::parse(&request.to_lowercase()) {
        for (key, value) in url.query_pairs() {
            if key == "lightning" || key == "lnurl" {
                if let Some(result) = parse_lnurl(&value) {
                    return Some(result);
                }
            }
        }
    }

    if let Some(url) = fedimint_lnurl::parse_lnurl(request) {
        return Some(LnurlWrapper(url));
    }

    if let Some(url) = fedimint_lnurl::parse_address(&request.to_lowercase()) {
        return Some(LnurlWrapper(url));
    }

    // Check if input matches MoneyBadger merchant pattern
    if MERCHANT_PATTERNS
        .iter()
        .any(|pattern| Regex::new(pattern).unwrap().is_match(request))
    {
        let address = format!("{}@cryptoqr.net", strict_uri_encode(request));

        return fedimint_lnurl::parse_address(&address).map(LnurlWrapper);
    }

    None
}

#[frb(opaque)]
pub struct PayResponseWrapper(fedimint_lnurl::PayResponse);

impl PayResponseWrapper {
    #[frb(sync, getter)]
    pub fn min_sats(&self) -> i64 {
        self.0.min_sendable as i64 / 1000
    }

    #[frb(sync, getter)]
    pub fn max_sats(&self) -> i64 {
        self.0.max_sendable as i64 / 1000
    }

    #[frb(sync)]
    pub fn is_fixed_amount(&self) -> bool {
        self.0.min_sendable == self.0.max_sendable
    }
}

#[frb]
pub async fn lnurl_fetch_limits(lnurl: &LnurlWrapper) -> Result<PayResponseWrapper, String> {
    fedimint_lnurl::request(&lnurl.0)
        .await
        .map(PayResponseWrapper)
}

#[frb]
pub async fn lnurl_resolve(
    pay_response: &PayResponseWrapper,
    amount_sats: i64,
) -> Result<String, String> {
    fedimint_lnurl::get_invoice(&pay_response.0, amount_sats as u64 * 1000)
        .await
        .map(|response| response.pr.to_string())
}
