# LNURLw Testing Guide

This document covers how the LNURLw (Boltcard / LUD-17) feature works, what is tested automatically, and how to run a full end-to-end test manually.

---

## How LNURLw works in this app

A Boltcard tap produces a raw-scheme URI like:

```
lnurlw://pay.example.com/withdraw?k1=<random-hex>
```

The app handles this via two paths:

### Path 1 — Deep link (NFC / tapped URL)

`deep_link_handler.dart` catches `lnurlw://` URLs from the OS and converts them to `https://` (or `http://` for local/onion hosts) before passing them to `LnurlWithdrawScreen`.

### Path 2 — Scanner / paste (new)

`parse.rs` (`lnurlw_to_http`) now detects `lnurlw://` in scanned or pasted text, performs the same scheme conversion, and returns `ParsedText::LnurlWithdraw(url)`. `scan.dart` handles this variant by navigating to `LnurlWithdrawScreen`. This path works on Linux desktop as well as Android.

### Scheme conversion rules

| Host | Scheme used |
|---|---|
| `localhost` | `http` |
| `127.0.0.1` | `http` |
| `10.0.2.2` (Android emulator) | `http` |
| `*.onion` | `http` |
| Everything else | `https` |

### Flow once the URL is received

1. App GETs `{url}` — server responds with withdraw params JSON (`tag`, `callback`, `k1`, `minWithdrawable`, `maxWithdrawable`)
2. User confirms the amount
3. App creates a Lightning invoice via the Fedimint federation + gateway
4. App GETs `{callback}?k1={k1}&pr={invoice}`
5. Server pays the invoice and responds `{"status":"OK"}`
6. App calls `await_receive` and shows success when ecash lands

---

## What is tested automatically (CI)

### Rust unit tests — `cargo test`

**`rust/ecashapp/src/lib.rs`** (existing):
- `test_parse_valid_withdraw_response` — valid params JSON parsed correctly
- `test_parse_withdraw_response_missing_description_defaults_empty`
- `test_parse_withdraw_response_server_error`
- `test_parse_withdraw_response_wrong_tag`
- `test_parse_withdraw_response_missing_callback`
- `test_callback_url_no_existing_params` — `build_lnurlw_callback_url` appends `?k1=&pr=`
- `test_callback_url_with_existing_params` — appends `&k1=&pr=` when query string exists

**`rust/ecashapp/src/parse.rs`** (new):
- `lnurlw_to_http_normal_host_uses_https`
- `lnurlw_to_http_localhost_uses_http`
- `lnurlw_to_http_loopback_uses_http`
- `lnurlw_to_http_android_emulator_uses_http`
- `lnurlw_to_http_onion_uses_http`
- `lnurlw_to_http_wrong_scheme_returns_none`
- `lnurlw_uri_returns_lnurl_withdraw_variant` — scanner returns `LnurlWithdraw` with correct URL
- `lnurlw_uri_with_selected_federation_uses_it`

### Flutter unit tests — `flutter test`

**`test/deep_link_parser_test.dart`** (existing):
- `lnurlw: scheme (LUD-17)` group — 6 cases covering scheme conversion for all host types

### What is NOT covered automatically

- The full payment flow (invoice creation → gateway payment → ecash receipt) requires a live Fedimint federation and gateway. See the manual test section below.

---

## Manual end-to-end testing

### Prerequisites

1. App built and running (Linux desktop or Android device/emulator)
2. At least one Fedimint federation joined with a working Lightning gateway
3. A Fedimint gateway accessible from your machine with its URL and password

### Option A — Scanner / paste (no boltcard, no NFC)

This tests the new scanner path and works on Linux desktop.

1. Run the app (`just run` for Linux)
2. Open the scanner or paste field
3. Paste any `lnurlw://` URI — you can use the test server below to generate one, or any real LNURLw endpoint

### Option B — Full end-to-end with real payment via test server

`scripts/test-lnurlw/` is a standalone Rust binary that:
- Starts a local LNURLw mock server
- Fires a `lnurlw://` deep link to the running app
- Validates the protocol handshake (k1 match, bolt11 format)
- Pays the invoice through your Fedimint gateway's `/pay_invoice_for_operator` endpoint
- Exits 0 if ecash is on its way, 1 on any failure

#### Build and run (macOS desktop app)

```bash
cd scripts/test-lnurlw
cargo run -- \
  --gateway-url http://localhost:8175 \
  --gateway-password <your-gateway-password>
```

#### Build and run (Android — device connected via ADB)

```bash
cd scripts/test-lnurlw
cargo run -- \
  --gateway-url http://localhost:8175 \
  --gateway-password <your-gateway-password> \
  --android
```

The `--android` flag fires the deep link via `adb shell am start` and substitutes `10.0.2.2` as the server host so the emulator can reach your machine.

#### What to expect

```
Mock LNURLw server listening on port 54321
k1              : a3f8...
LNURLw endpoint : http://127.0.0.1:54321/lnurlw
Callback        : http://127.0.0.1:54321/callback
Deep link       : lnurlw://127.0.0.1:54321/lnurlw
Gateway         : http://localhost:8175

Deep link fired — waiting for app to respond (timeout: 60s)…
← GET /lnurlw from 127.0.0.1:...
→ serving LNURLw params
← GET /callback from 127.0.0.1:...
✓ k1 matched
✓ bolt11 received: lnbcrt100n1p...
  paying invoice via gateway…
✓ gateway accepted payment

✓ Test passed — LNURLw withdraw flow completed successfully.
  Invoice paid: lnbcrt100n1p...
```

The app should transition from the "Waiting for payment…" screen to the success screen and ecash should appear in your balance.

### Finding your gateway URL and password

If you're running `devimint` locally:

```bash
# Gateway URL is typically:
http://localhost:8175

# Password is set when starting gatewayd, or found via:
cat /tmp/devimint-env/gatewayd.env | grep FM_GATEWAY_PASSWORD
```

---

## Code locations

| File | What it does |
|---|---|
| `rust/ecashapp/src/parse.rs` | `lnurlw_to_http()` + `ParsedText::LnurlWithdraw` detection in `parse_text` |
| `rust/ecashapp/src/lib.rs` | `ParsedText::LnurlWithdraw(String)` variant + `fetch_lnurl_withdraw` + `execute_lnurl_withdraw` |
| `lib/deep_link_handler.dart` | OS deep link → `DeepLinkType.lnurlWithdraw` (NFC / tapped URL path) |
| `lib/lnurl_withdraw.dart` | `LnurlWithdrawScreen` UI — shared by both paths |
| `lib/scan.dart` | `ParsedText_LnurlWithdraw` case → navigates to `LnurlWithdrawScreen` |
| `test/deep_link_parser_test.dart` | Deep link scheme conversion tests |
| `scripts/test-lnurlw/` | End-to-end test harness with real gateway payment |
