/// End-to-end test harness for the LNURLw / Boltcard withdraw feature.
///
/// Usage:
///   cargo run -- --gateway-url http://localhost:8175 --gateway-password <pass>
///   cargo run -- --gateway-url http://localhost:8175 --gateway-password <pass> --android
///
/// The binary:
///   1. Starts a local HTTP server on a random port.
///   2. Fires a deep link so the app receives a lnurlw:// URL.
///   3. Serves the LNURLw JSON params when the app GETs /lnurlw.
///   4. Validates the callback (k1 match + bolt11 format) when the app GETs /callback.
///   5. POSTs the invoice to the Fedimint gateway's /pay_invoice_for_operator endpoint.
///   6. Returns {"status":"OK"} to the app only after the gateway accepts payment.
///   7. Exits 0 on success, 1 on failure or timeout.
///
/// deep_link_handler.dart converts lnurlw://localhost → http://localhost
/// so no TLS is needed for local testing. For Android emulators the host
/// machine is reachable at 10.0.2.2.
use std::collections::HashMap;
use std::io::Read;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use clap::Parser;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

const TIMEOUT_SECS: u64 = 60;
const MIN_WITHDRAWABLE: u64 = 1_000;
const MAX_WITHDRAWABLE: u64 = 100_000;

#[derive(Parser, Debug)]
#[command(about = "LNURLw end-to-end test harness with real gateway payment")]
struct Args {
    /// Base URL of the Fedimint gateway (e.g. http://localhost:8175)
    #[arg(long)]
    gateway_url: String,

    /// Gateway password for Bearer authentication
    #[arg(long)]
    gateway_password: String,

    /// Fire the deep link via adb (Android emulator) instead of macOS `open`
    #[arg(long, default_value_t = false)]
    android: bool,
}

#[derive(Default)]
struct State {
    callback_received: bool,
    invoice: Option<String>,
    error: Option<String>,
}

#[tokio::main]
async fn main() {
    let args = Args::parse();

    // On Android emulators the host machine is at 10.0.2.2.
    let host = if args.android { "10.0.2.2" } else { "127.0.0.1" };

    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().unwrap().port();

    let k1 = random_hex(32);
    let callback = format!("http://{}:{}/callback", host, port);
    let lnurlw_url = format!("lnurlw://{}:{}/lnurlw", host, port);

    println!("Mock LNURLw server listening on port {port}");
    println!("k1              : {k1}");
    println!("LNURLw endpoint : http://{}:{}/lnurlw", host, port);
    println!("Callback        : {callback}");
    println!("Deep link       : {lnurlw_url}");
    println!("Gateway         : {}", args.gateway_url);
    println!();

    fire_deep_link(&lnurlw_url, args.android);
    println!("Deep link fired — waiting for app to respond (timeout: {TIMEOUT_SECS}s)…");

    let state = Arc::new(Mutex::new(State::default()));
    let state_srv = state.clone();
    let k1_srv = k1.clone();
    let gateway_url = args.gateway_url.clone();
    let gateway_password = args.gateway_password.clone();

    let result = tokio::time::timeout(Duration::from_secs(TIMEOUT_SECS), async move {
        loop {
            let (mut stream, peer) = listener.accept().await.expect("accept");

            let mut buf = vec![0u8; 8192];
            let n = stream.read(&mut buf).await.unwrap_or(0);
            let raw = String::from_utf8_lossy(&buf[..n]);

            let (path, query) = parse_request_line(&raw);
            let params = parse_query(query);

            let body = if path == "/lnurlw" {
                println!("← GET /lnurlw from {peer}");
                let json = serde_json::json!({
                    "tag": "withdrawRequest",
                    "callback": callback,
                    "k1": k1_srv,
                    "minWithdrawable": MIN_WITHDRAWABLE,
                    "maxWithdrawable": MAX_WITHDRAWABLE,
                    "defaultDescription": "LNURLw integration test"
                });
                println!("→ serving LNURLw params");
                json.to_string()
            } else if path == "/callback" {
                println!("← GET /callback from {peer}");
                let received_k1 = params.get("k1").map(|s| s.as_str()).unwrap_or("");
                let pr = params.get("pr").map(|s| s.as_str()).unwrap_or("");

                let mut st = state_srv.lock().unwrap();
                if received_k1 != k1_srv {
                    let msg = format!("k1 mismatch: expected {k1_srv}, got {received_k1}");
                    eprintln!("✗ {msg}");
                    st.error = Some(msg);
                    serde_json::json!({"status":"ERROR","reason":"k1 mismatch"}).to_string()
                } else if !is_bolt11(pr) {
                    let msg = format!("invalid bolt11 invoice: {pr}");
                    eprintln!("✗ {msg}");
                    st.error = Some(msg);
                    serde_json::json!({"status":"ERROR","reason":"invalid invoice"}).to_string()
                } else {
                    println!("✓ k1 matched");
                    println!("✓ bolt11 received: {}…", &pr[..pr.len().min(60)]);
                    println!("  paying invoice via gateway…");

                    // Drop the lock before the async gateway call.
                    let invoice = pr.to_string();
                    drop(st);

                    match pay_via_gateway(&gateway_url, &gateway_password, &invoice).await {
                        Ok(()) => {
                            println!("✓ gateway accepted payment");
                            let mut st = state_srv.lock().unwrap();
                            st.invoice = Some(invoice);
                            st.callback_received = true;
                            serde_json::json!({"status":"OK"}).to_string()
                        }
                        Err(e) => {
                            let msg = format!("gateway payment failed: {e}");
                            eprintln!("✗ {msg}");
                            let mut st = state_srv.lock().unwrap();
                            st.error = Some(msg);
                            serde_json::json!({"status":"ERROR","reason": e.to_string()}).to_string()
                        }
                    }
                }
            } else {
                println!("← unknown path {path} from {peer} — ignoring");
                continue;
            };

            let _ = stream.write_all(http_200(&body).as_bytes()).await;

            let st = state_srv.lock().unwrap();
            if st.callback_received || st.error.is_some() {
                break;
            }
        }
    })
    .await;

    println!();
    match result {
        Err(_) => {
            eprintln!("✗ Timed out after {TIMEOUT_SECS}s — app never completed the flow.");
            std::process::exit(1);
        }
        Ok(_) => {
            let st = state.lock().unwrap();
            if let Some(ref err) = st.error {
                eprintln!("✗ Test failed: {err}");
                std::process::exit(1);
            }
            println!("✓ Test passed — LNURLw withdraw flow completed successfully.");
            println!("  Invoice paid: {}…", {
                let inv = st.invoice.as_deref().unwrap_or("");
                &inv[..inv.len().min(60)]
            });
        }
    }
}

/// POST the bolt11 invoice to the gateway's operator endpoint and return Ok
/// only if the gateway responds with a 2xx status.
async fn pay_via_gateway(
    gateway_url: &str,
    password: &str,
    invoice: &str,
) -> anyhow::Result<()> {
    let endpoint = format!(
        "{}/pay_invoice_for_operator",
        gateway_url.trim_end_matches('/')
    );

    let client = reqwest::Client::new();
    let resp = client
        .post(&endpoint)
        .bearer_auth(password)
        .json(&serde_json::json!({ "invoice": invoice }))
        .send()
        .await?;

    let status = resp.status();
    if status.is_success() {
        return Ok(());
    }

    let body = resp.text().await.unwrap_or_default();
    Err(anyhow::anyhow!("gateway returned {status}: {body}"))
}

fn fire_deep_link(url: &str, is_android: bool) {
    if is_android {
        let status = Command::new("adb")
            .args([
                "shell",
                "am",
                "start",
                "-a",
                "android.intent.action.VIEW",
                "-d",
                url,
            ])
            .status();
        match status {
            Ok(s) if s.success() => {}
            _ => eprintln!("Warning: adb command failed — is the device connected?"),
        }
    } else {
        let status = Command::new("open").arg(url).status();
        match status {
            Ok(s) if s.success() => {}
            _ => eprintln!("Warning: `open` command failed — is the app running?"),
        }
    }
}

fn parse_request_line(raw: &str) -> (&str, &str) {
    let path_query = raw
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .unwrap_or("/");
    match path_query.split_once('?') {
        Some((p, q)) => (p, q),
        None => (path_query, ""),
    }
}

fn parse_query(query: &str) -> HashMap<String, String> {
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .map(|(k, v)| (k.to_string(), percent_decode(v)))
        .collect()
}

fn percent_decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '%' {
            let h1 = chars.next().and_then(|c| c.to_digit(16));
            let h2 = chars.next().and_then(|c| c.to_digit(16));
            if let (Some(h1), Some(h2)) = (h1, h2) {
                out.push(char::from(((h1 << 4) | h2) as u8));
            }
        } else if c == '+' {
            out.push(' ');
        } else {
            out.push(c);
        }
    }
    out
}

fn is_bolt11(s: &str) -> bool {
    s.len() > 10 && s.to_lowercase().starts_with("ln")
}

fn http_200(body: &str) -> String {
    format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
}

fn random_hex(n: usize) -> String {
    let mut bytes = vec![0u8; n];
    std::fs::File::open("/dev/urandom")
        .expect("open /dev/urandom")
        .read_exact(&mut bytes)
        .expect("read /dev/urandom");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
