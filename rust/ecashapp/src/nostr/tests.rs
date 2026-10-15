use super::{
    check_nwc_payment_limit, window_state, NostrClient, NostrProfile, NostrWalletConnectV2Config,
    NwcSpendWindow, PublicFederation, Timestamp, WalletConnectRequest, WalletConnectResponse,
    NWC_BUDGET_WINDOW, NWC_DEFAULT_MAX_PAYMENT_MSATS, NWC_SUPPORTED_METHODS,
};
use bitcoin::Network;
use fedimint_core::{config::FederationId, invite_code::InviteCode, PeerId};
use lightning_invoice::Bolt11Invoice;
use std::time::{Duration, SystemTime};

fn signed_invoice(amount_msats: Option<u64>) -> Bolt11Invoice {
    use bitcoin::hashes::{sha256, Hash as _};
    use bitcoin::secp256k1::{Secp256k1, SecretKey};
    use lightning_invoice::{Currency, InvoiceBuilder, PaymentSecret};

    let secret_key = SecretKey::from_slice(&[0x11; 32]).expect("valid key");
    let builder = InvoiceBuilder::new(Currency::Bitcoin)
        .description("nwc limit test".to_string())
        .payment_hash(sha256::Hash::hash(b"nwc limit test payment hash"))
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
fn test_budget_window_starts_empty_when_nothing_is_stored() {
    let (started, spent) = window_state(None, SystemTime::now());
    assert!(started.is_none(), "no window until the first payment");
    assert_eq!(spent, 0);
}

#[test]
fn test_budget_window_keeps_spend_inside_the_window() {
    let now = SystemTime::now();
    let started_at = now - Duration::from_secs(60 * 60);
    let (kept, spent) = window_state(
        Some(NwcSpendWindow {
            started_at: Timestamp(started_at),
            spent_msats: 7_000,
        }),
        now,
    );
    assert_eq!(kept, Some(started_at), "an open window must not be reset");
    assert_eq!(spent, 7_000);
}

#[test]
fn test_budget_window_resets_once_it_has_aged_out() {
    let now = SystemTime::now();
    let (kept, spent) = window_state(
        Some(NwcSpendWindow {
            started_at: Timestamp(now - NWC_BUDGET_WINDOW),
            spent_msats: 999_000,
        }),
        now,
    );
    assert!(kept.is_none(), "an expired window starts over");
    assert_eq!(spent, 0);
}

#[test]
fn test_budget_window_resets_when_the_clock_moved_backwards() {
    // A start time in the future means the clock changed under us. Ageing it
    // out costs one window of budget; trusting it would freeze wallet-connect
    // spending until the clock caught up.
    let now = SystemTime::now();
    let (kept, spent) = window_state(
        Some(NwcSpendWindow {
            started_at: Timestamp(now + Duration::from_secs(60 * 60)),
            spent_msats: 999_000,
        }),
        now,
    );
    assert!(kept.is_none());
    assert_eq!(spent, 0);
}

#[test]
fn test_nwc_limit_allows_payment_at_the_cap() {
    let invoice = signed_invoice(Some(NWC_DEFAULT_MAX_PAYMENT_MSATS));
    assert!(
        check_nwc_payment_limit(&invoice, NWC_DEFAULT_MAX_PAYMENT_MSATS).is_ok(),
        "the cap itself must be payable"
    );
}

#[test]
fn test_nwc_limit_rejects_payment_over_the_cap() {
    let invoice = signed_invoice(Some(NWC_DEFAULT_MAX_PAYMENT_MSATS + 1));
    let err = check_nwc_payment_limit(&invoice, NWC_DEFAULT_MAX_PAYMENT_MSATS).unwrap_err();
    assert!(err.to_string().contains("over the"), "got: {err}");
}

#[test]
fn test_nwc_limit_follows_a_lowered_setting() {
    // The invoice is fine against the default and must still be refused once
    // the user has chosen a smaller ceiling. Expressed relative to the
    // default so changing that value cannot quietly invalidate the case.
    let invoice = signed_invoice(Some(NWC_DEFAULT_MAX_PAYMENT_MSATS));
    assert!(check_nwc_payment_limit(&invoice, NWC_DEFAULT_MAX_PAYMENT_MSATS).is_ok());

    let err = check_nwc_payment_limit(&invoice, NWC_DEFAULT_MAX_PAYMENT_MSATS - 1).unwrap_err();
    assert!(err.to_string().contains("over the"), "got: {err}");
}

#[test]
fn test_nwc_limit_rejects_amountless_invoice_at_any_setting() {
    // An amountless invoice has no ceiling of its own, so raising the limit
    // must not turn it into something acceptable.
    let invoice = signed_invoice(None);
    for limit in [1, NWC_DEFAULT_MAX_PAYMENT_MSATS, u64::MAX] {
        assert!(
            check_nwc_payment_limit(&invoice, limit).is_err(),
            "amountless invoice accepted at limit {limit}"
        );
    }
}

#[test]
fn test_nwc_limit_rejects_amountless_invoice() {
    let invoice = signed_invoice(None);
    let err = check_nwc_payment_limit(&invoice, NWC_DEFAULT_MAX_PAYMENT_MSATS).unwrap_err();
    assert!(err.to_string().contains("no amount"), "got: {err}");
}

// ---- NWC pairing secrets -------------------------------------------------

/// Two arbitrary but valid, and importantly *distinct*, secp256k1 secrets to
/// stand in for the two halves of a pairing.
const SERVICE_SECRET_BYTES: [u8; 32] = [0x11; 32];
const CLIENT_SECRET_BYTES: [u8; 32] = [0x22; 32];

fn keys_from(bytes: &[u8; 32]) -> nostr_sdk::Keys {
    nostr_sdk::Keys::new_with_ctx(
        fedimint_core::secp256k1::SECP256K1,
        nostr_sdk::SecretKey::from_slice(bytes).expect("valid secp256k1 secret"),
    )
}

fn pairing_config() -> NostrWalletConnectV2Config {
    NostrWalletConnectV2Config {
        service_secret_key: SERVICE_SECRET_BYTES,
        client_secret_key: CLIENT_SECRET_BYTES,
        relay: "wss://relay.example.com".to_string(),
    }
}

#[test]
fn test_connection_info_hands_out_the_client_secret_and_never_the_service_secret() {
    // The V1 pairing record stored one keypair and used it as both
    // identities, so every connection URI ever copied into a third-party app
    // contained this wallet's own service secret — a paired app could sign as
    // the wallet, and the leak could not be walked back. V2 exists to keep
    // the two apart, and this assertion is the thing that keeps them apart:
    // regressing it re-issues the same leak silently, since a URI carrying
    // the wrong secret still pairs and still pays.
    let config = pairing_config();
    let info = NostrClient::connection_info(&config).expect("both keys are valid");

    let service_keys = keys_from(&SERVICE_SECRET_BYTES);
    let client_keys = keys_from(&CLIENT_SECRET_BYTES);

    assert_eq!(
        info.secret,
        client_keys.secret_key().to_secret_hex(),
        "the URI must carry the client secret"
    );
    assert_ne!(
        info.secret,
        service_keys.secret_key().to_secret_hex(),
        "the service secret must never leave the wallet"
    );

    // The counterpart: the pubkey in the URI is the address the client sends
    // requests *to*, so it is the service identity, not the client's own.
    assert_eq!(
        info.public_key,
        service_keys.public_key.to_hex(),
        "the URI must address the wallet service"
    );
    assert_ne!(info.public_key, client_keys.public_key.to_hex());

    assert_eq!(info.relay, "wss://relay.example.com");
}

#[test]
fn test_connection_info_is_stable_across_calls() {
    // Settings re-renders the pairing QR from the stored config every time it
    // is opened. If this were not a pure function of the record, a user who
    // reopened the screen would be shown a code their already-paired app no
    // longer matches.
    let config = pairing_config();
    let first = NostrClient::connection_info(&config).expect("valid config");
    let second = NostrClient::connection_info(&config).expect("valid config");
    assert_eq!(first.public_key, second.public_key);
    assert_eq!(first.secret, second.secret);
    assert_eq!(first.relay, second.relay);
}

#[test]
fn test_connection_info_declines_a_corrupt_record_instead_of_panicking() {
    // An all-zero scalar is not a valid secp256k1 secret. Records are decoded
    // straight out of RocksDB, so a truncated or partially written one has to
    // fall out as `None` — `get_nwc_connection_info` filters on that, and a
    // panic here would take down the settings screen instead.
    let corrupt_service = NostrWalletConnectV2Config {
        service_secret_key: [0u8; 32],
        ..pairing_config()
    };
    assert!(NostrClient::connection_info(&corrupt_service).is_none());

    let corrupt_client = NostrWalletConnectV2Config {
        client_secret_key: [0u8; 32],
        ..pairing_config()
    };
    assert!(NostrClient::connection_info(&corrupt_client).is_none());
}

// ---- NIP-47 wire format --------------------------------------------------

/// A request as an external NIP-47 client actually puts it on the wire.
///
/// Deserialization is tested from hand-written literals rather than by
/// round-tripping our own output because [`WalletConnectRequest`] is
/// deserialize-only — requests are inbound, and the peer, not us, decides the
/// bytes. A round-trip through our own `Serialize` would happily agree with
/// itself after a rename that no external client follows.
#[test]
fn test_parses_nip47_pay_invoice_request_from_the_wire() {
    let invoice = signed_invoice(Some(1_000)).to_string();
    let raw = format!(r#"{{"method":"pay_invoice","params":{{"invoice":"{invoice}"}}}}"#);
    let request: WalletConnectRequest =
        serde_json::from_str(&raw).expect("NIP-47 pay_invoice must parse");
    match request {
        WalletConnectRequest::PayInvoice { invoice: parsed } => assert_eq!(parsed, invoice),
        other => panic!("expected PayInvoice, got {}", other.method_name()),
    }
}

#[test]
fn test_parses_nip47_parameterless_requests_from_the_wire() {
    let balance: WalletConnectRequest =
        serde_json::from_str(r#"{"method":"get_balance","params":{}}"#)
            .expect("NIP-47 get_balance must parse");
    assert!(matches!(balance, WalletConnectRequest::GetBalance {}));

    let info: WalletConnectRequest = serde_json::from_str(r#"{"method":"get_info","params":{}}"#)
        .expect("NIP-47 get_info must parse");
    assert!(matches!(info, WalletConnectRequest::GetInfo {}));
}

#[test]
fn test_parameterless_requests_require_an_explicit_params_object() {
    // NIP-47 shows `"params": {}` even for the methods that take none, and
    // serde's adjacent tagging enforces that literally: a client that omits
    // the field entirely is rejected, and the listener's response to a
    // rejected request is silence. Pinned as an interop hazard rather than as
    // desired behaviour — it is a property of the derive, not of any code
    // here, so it can move under a serde bump without our source changing.
    let err = serde_json::from_str::<WalletConnectRequest>(r#"{"method":"get_balance"}"#)
        .expect_err("params is currently mandatory");
    assert!(err.to_string().contains("params"), "got: {err}");
}

#[test]
fn test_rejects_a_method_we_do_not_implement() {
    // `get_info` advertises exactly [`NWC_SUPPORTED_METHODS`]. Anything else
    // has to fail parsing rather than land on a neighbouring variant: the
    // listener's fallthrough is "ignore", and silently ignoring a
    // `make_invoice` is a far better failure than mistaking it for a spend.
    for method in ["make_invoice", "pay_keysend", "multi_pay_invoice", ""] {
        let raw = format!(r#"{{"method":"{method}","params":{{}}}}"#);
        assert!(
            serde_json::from_str::<WalletConnectRequest>(&raw).is_err(),
            "unsupported method {method:?} was accepted"
        );
    }
}

#[test]
fn test_every_advertised_method_is_one_we_can_parse() {
    // `NWC_SUPPORTED_METHODS` is a promise broadcast in the kind-13194 info
    // event. Adding a name there without a matching variant advertises a
    // capability that fails at parse time, which a paired client sees as the
    // wallet going silent.
    let invoice = signed_invoice(Some(1_000)).to_string();
    for method in NWC_SUPPORTED_METHODS {
        let params = if *method == "pay_invoice" {
            serde_json::json!({ "invoice": invoice })
        } else {
            serde_json::json!({})
        };
        let raw = serde_json::json!({ "method": method, "params": params }).to_string();
        let request: WalletConnectRequest = serde_json::from_str(&raw)
            .unwrap_or_else(|e| panic!("advertised method {method:?} does not parse: {e}"));
        assert_eq!(request.method_name(), *method);
    }
}

#[test]
fn test_response_wire_format_is_exactly_what_nip47_clients_expect() {
    // Exact strings, not a round-trip: a round-trip through our own serde
    // impls stays green through a rename, while the paired app — which we
    // never build or test against — silently stops understanding replies.
    // These literals are the contract with every external client.
    let info = WalletConnectResponse::GetInfo {
        network: "bitcoin".to_string(),
        methods: vec!["get_info".to_string(), "pay_invoice".to_string()],
    };
    assert_eq!(
        serde_json::to_string(&info).expect("serializes"),
        r#"{"result_type":"get_info","result":{"network":"bitcoin","methods":["get_info","pay_invoice"]}}"#
    );

    let balance = WalletConnectResponse::GetBalance { balance: 12_345 };
    assert_eq!(
        serde_json::to_string(&balance).expect("serializes"),
        r#"{"result_type":"get_balance","result":{"balance":12345}}"#
    );

    let pay = WalletConnectResponse::PayInvoice {
        preimage: "00ff".to_string(),
    };
    assert_eq!(
        serde_json::to_string(&pay).expect("serializes"),
        r#"{"result_type":"pay_invoice","result":{"preimage":"00ff"}}"#
    );
}

#[test]
fn test_response_round_trips_through_serde() {
    for response in [
        WalletConnectResponse::GetInfo {
            network: "signet".to_string(),
            methods: NWC_SUPPORTED_METHODS
                .iter()
                .map(|m| (*m).to_string())
                .collect(),
        },
        WalletConnectResponse::GetBalance { balance: 0 },
        WalletConnectResponse::PayInvoice {
            preimage: "deadbeef".to_string(),
        },
    ] {
        let encoded = serde_json::to_string(&response).expect("serializes");
        let decoded: WalletConnectResponse = serde_json::from_str(&encoded).expect("deserializes");
        assert_eq!(
            format!("{response:?}"),
            format!("{decoded:?}"),
            "response did not survive a round trip: {encoded}"
        );
    }
}

#[test]
fn test_method_name_is_log_safe_for_pay_invoice() {
    // The listener logs `method_name()` on every request, and those logs are
    // surfaced in the app and shared in bug reports. A bolt11 invoice carries
    // the amount, payment hash and description, so letting one reach a log —
    // which is exactly what using `Debug` here would do — is a privacy leak
    // that outlives the payment.
    let invoice = signed_invoice(Some(1_000)).to_string();
    let request = WalletConnectRequest::PayInvoice {
        invoice: invoice.clone(),
    };

    assert_eq!(request.method_name(), "pay_invoice");
    assert!(
        !request.method_name().contains(invoice.as_str()),
        "method_name leaked the invoice"
    );
    // Guards the reason the method exists at all: `Debug` really does carry
    // the invoice, so a future "simplification" to `{request:?}` is a leak,
    // not a cleanup.
    assert!(
        format!("{request:?}").contains(invoice.as_str()),
        "Debug no longer carries the invoice — re-check the log sites before \
             relaxing method_name"
    );

    assert_eq!(
        WalletConnectRequest::GetBalance {}.method_name(),
        "get_balance"
    );
    assert_eq!(WalletConnectRequest::GetInfo {}.method_name(), "get_info");
}

// ---- Federation announcements from relays --------------------------------

/// Kind of the federation announcement event we listen for on relays.
const FEDERATION_ANNOUNCEMENT_KIND: u16 = 38173;

fn letter_tag(letter: nostr_sdk::Alphabet, value: &str) -> nostr_sdk::Tag {
    nostr_sdk::Tag::custom(
        nostr_sdk::TagKind::SingleLetter(nostr_sdk::SingleLetterTag::lowercase(letter)),
        [value],
    )
}

fn network_tag(value: &str) -> nostr_sdk::Tags {
    nostr_sdk::Tags::from_list(vec![letter_tag(nostr_sdk::Alphabet::N, value)])
}

fn modules_tag(value: &str) -> nostr_sdk::Tags {
    nostr_sdk::Tags::from_list(vec![nostr_sdk::Tag::custom(
        nostr_sdk::TagKind::custom("modules".to_string()),
        [value],
    )])
}

/// A signed event of the kind Discover actually consumes.
///
/// Signed rather than hand-built because `try_from` takes a whole
/// `nostr_sdk::Event`; nothing here checks the signature.
fn announcement(tags: Vec<nostr_sdk::Tag>, content: &str) -> nostr_sdk::Event {
    nostr_sdk::EventBuilder::new(nostr_sdk::Kind::from(FEDERATION_ANNOUNCEMENT_KIND), content)
        .tags(tags)
        .sign_with_keys(&keys_from(&[0x33; 32]))
        .expect("event signs")
}

/// A real, parseable invite code that points at `federation_id`.
fn invite_for(federation_id: FederationId) -> String {
    InviteCode::new(
        "wss://foo.bar".parse().expect("valid url"),
        PeerId::from(0),
        federation_id,
        None,
    )
    .to_string()
}

/// A federation id guaranteed to differ from `FederationId::dummy()`.
fn other_federation_id() -> FederationId {
    let other: FederationId = "ab".repeat(32).parse().expect("valid federation id");
    assert_ne!(other, FederationId::dummy());
    other
}

#[test]
fn test_parse_network_accepts_the_nonstandard_mainnet_spelling() {
    // Announcers write "mainnet"; `Network::from_str` only knows "bitcoin".
    // Without the special case every mainnet federation on nostr — which is
    // to say every federation a user wants — is dropped from Discover.
    assert_eq!(
        PublicFederation::parse_network(&network_tag("mainnet")).expect("mainnet parses"),
        Network::Bitcoin
    );
    assert_eq!(
        PublicFederation::parse_network(&network_tag("bitcoin")).expect("bitcoin parses"),
        Network::Bitcoin
    );
}

#[test]
fn test_parse_network_accepts_the_test_networks() {
    for (tag, expected) in [
        ("signet", Network::Signet),
        ("regtest", Network::Regtest),
        ("testnet", Network::Testnet),
    ] {
        assert_eq!(
            PublicFederation::parse_network(&network_tag(tag)).expect("parses"),
            expected,
            "network tag {tag:?}"
        );
    }
}

#[test]
fn test_parse_network_rejects_garbage_from_a_relay() {
    // Tag content is attacker-controlled: anyone can publish a kind-38173
    // event. An unknown network has to be an error, because the value is
    // rendered as the chain badge and used to decide whether the invite is
    // safe to act on.
    for tag in ["", "mainnet ", "MAINNET", "liquid", "bitcoin\0", "42"] {
        assert!(
            PublicFederation::parse_network(&network_tag(tag)).is_err(),
            "network tag {tag:?} was accepted"
        );
    }
}

#[test]
fn test_parse_network_requires_the_tag_to_exist() {
    assert!(PublicFederation::parse_network(&nostr_sdk::Tags::new()).is_err());
    // An `n` tag with no value at all — `["n"]` — is a shape a relay can
    // serve, and indexing past the end of it would panic.
    let empty = nostr_sdk::Tags::from_list(vec![nostr_sdk::Tag::parse(["n"]).expect("parses")]);
    assert!(PublicFederation::parse_network(&empty).is_err());
}

#[test]
fn test_parse_content_reads_the_json_metadata_object() {
    let (name, about, picture) = PublicFederation::parse_content(
        r#"{"name":"Test Fed","about":"a federation","picture":"https://example.com/pic.png"}"#
            .to_string(),
    )
    .expect("well-formed metadata parses");
    assert_eq!(name, "Test Fed");
    assert_eq!(about.as_deref(), Some("a federation"));
    assert_eq!(picture.as_deref(), Some("https://example.com/pic.png"));
}

#[test]
fn test_parse_content_falls_back_to_treating_the_content_as_a_bare_name() {
    // Older announcers put the name straight in `content` with no JSON at
    // all. Losing this fallback silently empties Discover of every federation
    // still announcing that way.
    let (name, about, picture) =
        PublicFederation::parse_content("Bare Name Fed".to_string()).expect("bare name parses");
    assert_eq!(name, "Bare Name Fed");
    assert!(about.is_none());
    assert!(picture.is_none());
}

#[test]
fn test_public_federation_accepts_an_empty_name() {
    // Empty content is not valid JSON, so it takes the bare-name fallback and
    // becomes an empty federation name — the announcement is kept and shown
    // as a nameless row rather than dropped. A relay can publish this freely.
    // Pinned because the required-fields comment on `try_from` reads as if a
    // name were enforced, and it is not.
    let event = announcement(
        vec![
            nostr_sdk::Tag::identifier(FederationId::dummy().to_string()),
            letter_tag(nostr_sdk::Alphabet::U, &invite_for(FederationId::dummy())),
            letter_tag(nostr_sdk::Alphabet::N, "mainnet"),
        ],
        "",
    );
    let federation = PublicFederation::try_from(event).expect("empty content is accepted");
    assert_eq!(federation.federation_name, "");
}

#[test]
fn test_parse_content_treats_a_bare_name_that_happens_to_be_valid_json_as_a_name() {
    // Only a JSON object is read as metadata. A bare name that also parses as
    // a JSON scalar must still take the bare-name fallback, otherwise a
    // federation calling itself `2024` or `null` never appears in Discover.
    for content in ["2024", "null", "true", r#""Quoted Fed""#] {
        let (name, about, picture) = PublicFederation::parse_content(content.to_string())
            .unwrap_or_else(|e| panic!("{content:?} should parse as a bare name: {e}"));
        assert_eq!(name, content);
        assert!(about.is_none());
        assert!(picture.is_none());
    }
}

#[test]
fn test_parse_content_rejects_a_json_object_without_a_name() {
    // The fallback is only for non-objects: an object that is missing its
    // name is malformed metadata, not a bare name.
    assert!(PublicFederation::parse_content(r#"{"about":"no name"}"#.to_string()).is_err());
}

#[test]
fn test_parse_federation_name_prefers_name_over_federation_name() {
    let json: serde_json::Value =
        serde_json::from_str(r#"{"name":"Preferred","federation_name":"Legacy"}"#)
            .expect("valid json");
    assert_eq!(
        PublicFederation::parse_federation_name(&json).expect("parses"),
        "Preferred"
    );
}

#[test]
fn test_parse_federation_name_accepts_the_legacy_key_alone() {
    let json: serde_json::Value =
        serde_json::from_str(r#"{"federation_name":"Legacy Only"}"#).expect("valid json");
    assert_eq!(
        PublicFederation::parse_federation_name(&json).expect("parses"),
        "Legacy Only"
    );
}

#[test]
fn test_parse_federation_name_rejects_metadata_with_no_usable_name() {
    for raw in [r#"{}"#, r#"{"about":"no name here"}"#, r#"{"name":null}"#] {
        let json: serde_json::Value = serde_json::from_str(raw).expect("valid json");
        assert!(
            PublicFederation::parse_federation_name(&json).is_err(),
            "accepted {raw}"
        );
    }
}

#[test]
fn test_parse_federation_name_does_not_fall_back_when_name_is_the_wrong_type() {
    // `name` present but non-string is a hard error even though a perfectly
    // good `federation_name` sits next to it. Pinned because it decides
    // whether such an announcement shows up at all.
    let json: serde_json::Value =
        serde_json::from_str(r#"{"name":5,"federation_name":"Legacy"}"#).expect("valid json");
    assert!(PublicFederation::parse_federation_name(&json).is_err());
}

#[test]
fn test_parse_picture_rejects_anything_that_is_not_a_url() {
    // The value goes straight into an image widget. It is relay-supplied, so
    // "not a URL" has to come back as `None` rather than panic or reach the
    // network layer as garbage.
    for raw in [
        r#"{"picture":"not a url"}"#,
        r#"{"picture":"example.com/pic.png"}"#,
        r#"{"picture":""}"#,
        r#"{"picture":42}"#,
        r#"{"picture":null}"#,
        r#"{}"#,
    ] {
        let json: serde_json::Value = serde_json::from_str(raw).expect("valid json");
        assert!(
            PublicFederation::parse_picture(&json).is_none(),
            "accepted {raw}"
        );
    }
}

#[test]
fn test_parse_picture_preserves_query_string() {
    // The full URL (including query/fragment) is needed to fetch the
    // correct image — e.g. CDN sizing params or a signed query. Using
    // `SafeUrl`'s `Display` here previously truncated these away.
    let json: serde_json::Value =
        serde_json::from_str(r#"{"picture":"https://example.com/pic.png?w=64#frag"}"#)
            .expect("valid json");
    assert_eq!(
        PublicFederation::parse_picture(&json).as_deref(),
        Some("https://example.com/pic.png?w=64#frag")
    );
}

#[test]
fn test_parse_picture_redacts_embedded_credentials() {
    // `SafeUrl` exists to keep credentials out of rendered URLs, and this is
    // the one place a relay controls the string being rendered.
    let json: serde_json::Value =
        serde_json::from_str(r#"{"picture":"https://user:pw@example.com/pic.png"}"#)
            .expect("valid json");
    let picture = PublicFederation::parse_picture(&json).expect("valid url");
    assert!(!picture.contains("pw"), "password survived: {picture}");
    assert!(!picture.contains("user"), "username survived: {picture}");
}

#[test]
fn test_parse_invite_codes_returns_the_u_tag() {
    let federation_id = FederationId::dummy();
    let invite = invite_for(federation_id);
    let tags = nostr_sdk::Tags::from_list(vec![letter_tag(nostr_sdk::Alphabet::U, &invite)]);
    assert_eq!(
        PublicFederation::parse_invite_codes(&tags, &federation_id).expect("parses"),
        vec![invite]
    );
}

#[test]
fn test_parse_invite_codes_rejects_a_tag_that_is_not_an_invite_code() {
    // Like the recovery path, only a parseable invite code is kept, so a relay
    // cannot put an unjoinable string in front of the user.
    let tags = nostr_sdk::Tags::from_list(vec![letter_tag(
        nostr_sdk::Alphabet::U,
        "definitely-not-an-invite-code",
    )]);
    assert!(PublicFederation::parse_invite_codes(&tags, &FederationId::dummy()).is_err());
}

#[test]
fn test_parse_invite_codes_rejects_an_invite_for_a_different_federation() {
    // An announcement can claim a trusted federation's id (`d`) and name while
    // its invite (`u`) points somewhere else. Discover previews the invite
    // under the announced name, so the two must agree.
    let tags = nostr_sdk::Tags::from_list(vec![letter_tag(
        nostr_sdk::Alphabet::U,
        &invite_for(other_federation_id()),
    )]);
    assert!(PublicFederation::parse_invite_codes(&tags, &FederationId::dummy()).is_err());
}

#[test]
fn test_parse_invite_codes_requires_a_u_tag_with_content() {
    let federation_id = FederationId::dummy();
    assert!(PublicFederation::parse_invite_codes(&nostr_sdk::Tags::new(), &federation_id).is_err());
    let empty = nostr_sdk::Tags::from_list(vec![nostr_sdk::Tag::parse(["u"]).expect("parses")]);
    assert!(PublicFederation::parse_invite_codes(&empty, &federation_id).is_err());
}

#[test]
fn test_parse_modules_splits_on_commas() {
    assert_eq!(
        PublicFederation::parse_modules(&modules_tag("mint,lightning,wallet")).expect("parses"),
        vec![
            "mint".to_string(),
            "lightning".to_string(),
            "wallet".to_string()
        ]
    );
    assert_eq!(
        PublicFederation::parse_modules(&modules_tag("mint")).expect("parses"),
        vec!["mint".to_string()]
    );
}

#[test]
fn test_parse_modules_does_not_trim_or_drop_empty_entries() {
    // Splitting is literal, so a tag written with spaces after the commas
    // yields module names with a leading space, and an empty tag yields one
    // empty name rather than none. Pinned because the list is rendered as-is.
    assert_eq!(
        PublicFederation::parse_modules(&modules_tag("mint, lightning")).expect("parses"),
        vec!["mint".to_string(), " lightning".to_string()]
    );
    assert_eq!(
        PublicFederation::parse_modules(&modules_tag("")).expect("parses"),
        vec![String::new()]
    );
    assert_eq!(
        PublicFederation::parse_modules(&modules_tag("mint,,wallet")).expect("parses"),
        vec!["mint".to_string(), String::new(), "wallet".to_string()]
    );
}

#[test]
fn test_parse_modules_errors_when_the_tag_is_absent() {
    // The error is what `try_from` turns into an empty list; `modules` is a
    // non-standard tag most announcers omit, so this path is the common one.
    assert!(PublicFederation::parse_modules(&nostr_sdk::Tags::new()).is_err());
}

#[test]
fn test_public_federation_parses_a_complete_announcement() {
    let federation_id = FederationId::dummy();
    let invite = invite_for(federation_id);
    let event = announcement(
        vec![
            nostr_sdk::Tag::identifier(federation_id.to_string()),
            letter_tag(nostr_sdk::Alphabet::U, &invite),
            letter_tag(nostr_sdk::Alphabet::N, "mainnet"),
            nostr_sdk::Tag::custom(
                nostr_sdk::TagKind::custom("modules".to_string()),
                ["mint,lightning"],
            ),
        ],
        r#"{"name":"Complete Fed","about":"everything set","picture":"https://example.com/f.png"}"#,
    );

    let federation = PublicFederation::try_from(event).expect("complete announcement parses");
    assert_eq!(federation.federation_id, federation_id);
    assert_eq!(federation.federation_name, "Complete Fed");
    assert_eq!(federation.invite_codes, vec![invite]);
    assert_eq!(federation.about.as_deref(), Some("everything set"));
    assert_eq!(
        federation.picture.as_deref(),
        Some("https://example.com/f.png")
    );
    assert_eq!(
        federation.modules,
        vec!["mint".to_string(), "lightning".to_string()]
    );
    // Stored as the canonical spelling, not the "mainnet" that came in.
    assert_eq!(federation.network, "bitcoin");
}

#[test]
fn test_public_federation_tolerates_a_minimal_announcement() {
    // Only `d`, `u`, `n` and a name are required; `modules` and the metadata
    // extras are best-effort, and demanding them would hide federations that
    // are perfectly joinable.
    let federation_id = FederationId::dummy();
    let event = announcement(
        vec![
            nostr_sdk::Tag::identifier(federation_id.to_string()),
            letter_tag(nostr_sdk::Alphabet::U, &invite_for(federation_id)),
            letter_tag(nostr_sdk::Alphabet::N, "signet"),
        ],
        "Minimal Fed",
    );

    let federation = PublicFederation::try_from(event).expect("minimal announcement parses");
    assert_eq!(federation.federation_name, "Minimal Fed");
    assert_eq!(federation.network, "signet");
    assert!(federation.modules.is_empty());
    assert!(federation.about.is_none());
    assert!(federation.picture.is_none());
}

#[test]
fn test_public_federation_rejects_malformed_announcements_without_panicking() {
    let id = FederationId::dummy().to_string();
    let invite = invite_for(FederationId::dummy());
    let d = || nostr_sdk::Tag::identifier(id.clone());
    let u = || letter_tag(nostr_sdk::Alphabet::U, &invite);
    let n = || letter_tag(nostr_sdk::Alphabet::N, "mainnet");

    // Every one of these is something a hostile or merely broken relay can
    // publish, and Discover parses whatever arrives. `Err` is the only
    // acceptable outcome — a panic here happens inside a background task and
    // takes the whole discovery pass with it.
    let cases: Vec<(&str, nostr_sdk::Event)> = vec![
        ("no tags at all", announcement(vec![], "Fed")),
        ("no d tag", announcement(vec![u(), n()], "Fed")),
        (
            "d tag is not a federation id",
            announcement(vec![nostr_sdk::Tag::identifier("nope"), u(), n()], "Fed"),
        ),
        (
            "d tag is truncated hex",
            announcement(vec![nostr_sdk::Tag::identifier(&id[..16]), u(), n()], "Fed"),
        ),
        ("no u tag", announcement(vec![d(), n()], "Fed")),
        (
            "u tag is not an invite code",
            announcement(
                vec![
                    d(),
                    letter_tag(nostr_sdk::Alphabet::U, "definitely-not-an-invite-code"),
                    n(),
                ],
                "Fed",
            ),
        ),
        (
            // A trusted federation's id and name, fronting someone else's invite.
            "u tag invites to a different federation than the d tag",
            announcement(
                vec![
                    d(),
                    letter_tag(nostr_sdk::Alphabet::U, &invite_for(other_federation_id())),
                    n(),
                ],
                "Trusted Fed",
            ),
        ),
        ("no n tag", announcement(vec![d(), u()], "Fed")),
        (
            "unknown network",
            announcement(
                vec![d(), u(), letter_tag(nostr_sdk::Alphabet::N, "liquid")],
                "Fed",
            ),
        ),
        (
            "metadata object with no name",
            announcement(vec![d(), u(), n()], r#"{"about":"nameless"}"#),
        ),
    ];

    for (description, event) in cases {
        assert!(
            PublicFederation::try_from(event).is_err(),
            "malformed announcement accepted: {description}"
        );
    }
}

// ---- Contact profiles from relays ----------------------------------------

fn metadata_event(kind: nostr_sdk::Kind, content: &str) -> nostr_sdk::Event {
    nostr_sdk::EventBuilder::new(kind, content)
        .sign_with_keys(&keys_from(&[0x44; 32]))
        .expect("event signs")
}

#[test]
fn test_nostr_profile_reads_the_kind_zero_metadata_fields() {
    let event = metadata_event(
        nostr_sdk::Kind::Metadata,
        r#"{"name":"alice","display_name":"Alice","picture":"https://example.com/a.png",
                "lud16":"alice@example.com","nip05":"alice@example.com","about":"hi"}"#,
    );
    let pubkey = event.pubkey;

    let profile = NostrProfile::try_from(event).expect("metadata parses");
    assert_eq!(
        profile.npub,
        nostr_sdk::ToBech32::to_bech32(&pubkey).expect("encodes")
    );
    assert_eq!(profile.name.as_deref(), Some("alice"));
    assert_eq!(profile.display_name.as_deref(), Some("Alice"));
    assert_eq!(
        profile.picture.as_deref(),
        Some("https://example.com/a.png")
    );
    assert_eq!(profile.lud16.as_deref(), Some("alice@example.com"));
    assert_eq!(profile.nip05.as_deref(), Some("alice@example.com"));
    assert_eq!(profile.about.as_deref(), Some("hi"));
}

#[test]
fn test_nostr_profile_leaves_missing_and_mistyped_fields_empty() {
    // Every field is optional in practice and none of them is validated by a
    // relay, so a non-string value has to read as absent rather than abort
    // the whole profile — losing a contact's name over a bad `picture` is a
    // worse outcome than showing no picture.
    let event = metadata_event(
        nostr_sdk::Kind::Metadata,
        r#"{"name":"bob","picture":42,"about":null}"#,
    );
    let profile = NostrProfile::try_from(event).expect("partial metadata parses");
    assert_eq!(profile.name.as_deref(), Some("bob"));
    assert!(profile.display_name.is_none());
    assert!(profile.picture.is_none());
    assert!(profile.about.is_none());
}

#[test]
fn test_nostr_profile_rejects_events_that_are_not_metadata() {
    // The kind check is what stops a note's body being rendered as somebody's
    // profile; subscriptions can return more than they were asked for.
    let event = metadata_event(nostr_sdk::Kind::TextNote, r#"{"name":"mallory"}"#);
    assert!(NostrProfile::try_from(event).is_err());
}

#[test]
fn test_nostr_profile_rejects_content_that_is_not_json() {
    let event = metadata_event(nostr_sdk::Kind::Metadata, "not json at all");
    assert!(NostrProfile::try_from(event).is_err());
}
