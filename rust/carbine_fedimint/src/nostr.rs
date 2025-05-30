use std::{str::FromStr, time::Duration};

use crate::{
    anyhow,
    db::{NostrKey, NostrSecretKey},
};
use bitcoin::Network;
use fedimint_core::{
    config::FederationId,
    db::{Database, IDatabaseTransactionOpsCoreTyped},
    task::TaskGroup,
    util::{FmtCompact, SafeUrl},
};
use serde::Serialize;

pub const DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.nostr.band",
    "wss://nostr-pub.wellorder.net",
    "wss://relay.plebstr.com",
    "wss://relayer.fiatjaf.com",
    "wss://nostr-01.bolt.observer",
    "wss://nostr.bitcoiner.social",
    "wss://relay.nostr.info",
    "wss://relay.damus.io",
];

#[derive(Clone)]
pub(crate) struct NostrClient {
    nostr_client: nostr_sdk::Client,
    pub(crate) public_federations: Vec<PublicFederation>,
    task_group: TaskGroup,
}

impl NostrClient {
    pub async fn new(db: Database) -> anyhow::Result<NostrClient> {
        let mut dbtx = db.begin_transaction().await;
        let keys = match dbtx.get_value(&NostrKey).await {
            Some(nostr_key) => {
                let secret_key = nostr_sdk::SecretKey::from_hex(&nostr_key.secret_key_hex)?;
                nostr_sdk::Keys::new(secret_key)
            }
            None => {
                let keys = nostr_sdk::Keys::generate();
                dbtx.insert_new_entry(
                    &NostrKey,
                    &NostrSecretKey {
                        secret_key_hex: keys.secret_key().to_secret_hex(),
                    },
                )
                .await;
                dbtx.commit_tx().await;
                keys
            }
        };

        let client = nostr_sdk::Client::builder().signer(keys).build();

        for relay in DEFAULT_RELAYS {
            if let Err(err) = client.add_relay(*relay).await {
                println!("Could not add relay {}: {}", relay, err.fmt_compact());
            }
        }

        let nostr_client = NostrClient {
            nostr_client: client,
            public_federations: vec![],
            task_group: TaskGroup::new(),
        };

        let mut background_nostr = nostr_client.clone();
        nostr_client
            .task_group
            .spawn_cancellable("update nostr feds", async move {
                println!("Updating federations from nostr in the background...");
                background_nostr.update_federations_from_nostr().await;
            });

        Ok(nostr_client)
    }

    pub async fn update_federations_from_nostr(&mut self) {
        self.nostr_client.connect().await;

        let filter = nostr_sdk::Filter::new().kind(nostr_sdk::Kind::from(38173));
        match self
            .nostr_client
            .fetch_events(filter, Duration::from_secs(3))
            .await
        {
            Ok(events) => {
                let all_events = events.to_vec();
                let events = all_events
                    .iter()
                    .filter_map(|event| {
                        match PublicFederation::parse_network(&event.tags) {
                            Ok(network) if network == Network::Regtest => {
                                // Skip over regtest advertisements
                                return None;
                            }
                            _ => {}
                        }

                        PublicFederation::try_from(event.clone()).ok()
                    })
                    .collect::<Vec<_>>();

                println!("Public Federations: {events:?}");
                self.public_federations = events;
            }
            Err(e) => {
                println!("Failed to fetch events from nostr: {e}");
            }
        }
    }
}

#[derive(Clone, Eq, PartialEq, Serialize, Debug)]
pub struct PublicFederation {
    pub federation_name: String,
    pub federation_id: FederationId,
    pub invite_codes: Vec<String>,
    pub about: Option<String>,
    pub picture: Option<String>,
    pub modules: Vec<String>,
    pub network: String,
}

impl TryFrom<nostr_sdk::Event> for PublicFederation {
    type Error = anyhow::Error;

    fn try_from(event: nostr_sdk::Event) -> Result<Self, Self::Error> {
        let tags = event.tags;
        let network = Self::parse_network(&tags)?;
        let (federation_name, about, picture) = Self::parse_content(event.content)?;
        let federation_id = Self::parse_federation_id(&tags)?;
        let invite_codes = Self::parse_invite_codes(&tags)?;
        let modules = Self::parse_modules(&tags)?;
        Ok(PublicFederation {
            federation_name,
            federation_id,
            invite_codes,
            about,
            picture,
            modules,
            network: network.to_string(),
        })
    }
}

impl PublicFederation {
    fn parse_network(tags: &nostr_sdk::Tags) -> anyhow::Result<Network> {
        let n_tag = tags
            .find(nostr_sdk::TagKind::SingleLetter(
                nostr_sdk::SingleLetterTag::lowercase(nostr_sdk::Alphabet::N),
            ))
            .ok_or(anyhow::anyhow!("n_tag not present"))?;
        let network = n_tag
            .content()
            .ok_or(anyhow::anyhow!("n_tag has no content"))?;
        match network {
            "mainnet" => Ok(Network::Bitcoin),
            network_str => {
                let network = Network::from_str(network_str)?;
                Ok(network)
            }
        }
    }

    fn parse_content(content: String) -> anyhow::Result<(String, Option<String>, Option<String>)> {
        let json: Result<serde_json::Value, serde_json::Error> = serde_json::from_str(&content);
        match json {
            Ok(json) => {
                let federation_name = Self::parse_federation_name(&json)?;
                let about = json
                    .get("about")
                    .map(|val| val.as_str().expect("about is not a string").to_string());

                let picture = Self::parse_picture(&json);
                Ok((federation_name, about, picture))
            }
            Err(_) => {
                // Just interpret the entire content as the federation name
                Ok((content, None, None))
            }
        }
    }

    fn parse_federation_name(json: &serde_json::Value) -> anyhow::Result<String> {
        // First try to parse using the "name" key
        let federation_name = json.get("name");
        match federation_name {
            Some(name) => Ok(name
                .as_str()
                .ok_or(anyhow!("name is not a string"))?
                .to_string()),
            None => {
                // Try to parse using "federation_name" key
                let federation_name = json
                    .get("federation_name")
                    .ok_or(anyhow!("Could not get federation name"))?;
                Ok(federation_name
                    .as_str()
                    .ok_or(anyhow!("federation name is not a string"))?
                    .to_string())
            }
        }
    }

    fn parse_picture(json: &serde_json::Value) -> Option<String> {
        let picture = json.get("picture");
        match picture {
            Some(picture) => {
                match picture.as_str() {
                    Some(pic_url) => {
                        // Verify that the picture is a URL
                        let safe_url = SafeUrl::parse(pic_url).ok()?;
                        return Some(safe_url.to_string());
                    }
                    None => {}
                }
            }
            None => {}
        }
        None
    }

    fn parse_federation_id(tags: &nostr_sdk::Tags) -> anyhow::Result<FederationId> {
        let d_tag = tags.identifier().ok_or(anyhow!("d_tag is not present"))?;
        let federation_id = FederationId::from_str(d_tag)?;
        Ok(federation_id)
    }

    fn parse_invite_codes(tags: &nostr_sdk::Tags) -> anyhow::Result<Vec<String>> {
        let u_tag = tags
            .find(nostr_sdk::TagKind::SingleLetter(
                nostr_sdk::SingleLetterTag::lowercase(nostr_sdk::Alphabet::U),
            ))
            .ok_or(anyhow!("u_tag does not exist"))?;
        let invite = u_tag
            .content()
            .ok_or(anyhow!("No content for u_tag"))?
            .to_string();
        Ok(vec![invite])
    }

    fn parse_modules(tags: &nostr_sdk::Tags) -> anyhow::Result<Vec<String>> {
        let modules = tags
            .find(nostr_sdk::TagKind::custom("modules".to_string()))
            .ok_or(anyhow!("No modules tag"))?
            .content()
            .ok_or(anyhow!("modules should have content"))?
            .split(",")
            .map(|m| m.to_string())
            .collect::<Vec<_>>();
        Ok(modules)
    }
}
