const DOMAIN: &str = "syncstr-rendezvous-v1\n";

#[derive(serde::Serialize, serde::Deserialize)]
pub struct Envelope {
    pub payload: String,
    pub signature: String,
}

pub fn service(value: &str) -> anyhow::Result<reqwest::Url> {
    let url = reqwest::Url::parse(value)?;
    anyhow::ensure!(
        url.scheme() == "https"
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.path() == "/",
        "Directory must be an HTTPS origin"
    );
    Ok(url)
}

pub fn signed(
    identity: &crate::peer::Identity,
    payload: serde_json::Value,
) -> anyhow::Result<crate::rendezvous::Envelope> {
    use base64::Engine as _;
    let payload = serde_json::to_string(&payload)?;
    let signature = identity.sign(format!("{DOMAIN}{payload}").as_bytes());
    Ok(crate::rendezvous::Envelope {
        payload,
        signature: base64::engine::general_purpose::STANDARD.encode(signature),
    })
}

pub fn now() -> anyhow::Result<u64> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_millis()
        .try_into()?)
}

pub async fn publish(
    identity: &crate::peer::Identity,
    endpoint: &iroh::Endpoint,
    origin: &reqwest::Url,
    listen: &[std::net::SocketAddr],
    public: Option<std::net::SocketAddr>,
) -> anyhow::Result<()> {
    let mut addresses: Vec<_> = endpoint
        .addr()
        .ip_addrs()
        .copied()
        .filter(|address| {
            listen.is_empty()
                || listen.iter().any(|bind| {
                    address.ip() == bind.ip()
                        || (bind.ip().is_unspecified() && bind.is_ipv4() == address.is_ipv4())
                })
        })
        .take(32)
        .collect();
    if let Some(public) = public
        && !addresses.contains(&public)
    {
        addresses.insert(0, public);
        addresses.truncate(32);
    }
    anyhow::ensure!(!addresses.is_empty(), "No P2P candidates available");
    let peers = identity.allowed_peers()?;
    anyhow::ensure!(peers.len() <= 256, "Too many allowed peers for directory");
    let time = crate::rendezvous::now()?;
    let envelope = crate::rendezvous::signed(
        identity,
        serde_json::json!({
            "kind": "announce", "id": identity.id(), "time": time, "expires": time + 180000,
            "peers": peers, "address": {"version": 1, "id": identity.id(), "addresses": addresses, "relay": null}
        }),
    )?;
    crate::rendezvous::client()?
        .post(origin.join("v1/announce")?)
        .json(&envelope)
        .send()
        .await?
        .error_for_status()?;
    Ok(())
}

fn client() -> anyhow::Result<reqwest::Client> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    Ok(reqwest::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(10))
        .build()?)
}

pub async fn resolve(
    identity: &crate::peer::Identity,
    origin: &reqwest::Url,
    target: iroh::EndpointId,
) -> anyhow::Result<crate::peer::Address> {
    use anyhow::Context as _;
    use base64::Engine as _;
    let request = crate::rendezvous::signed(
        identity,
        serde_json::json!({
            "kind": "lookup", "id": identity.id(), "time": crate::rendezvous::now()?, "target": target
        }),
    )?;
    let mut response = crate::rendezvous::client()?
        .post(origin.join("v1/lookup")?)
        .json(&request)
        .send()
        .await?
        .error_for_status()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        anyhow::ensure!(
            bytes.len() + chunk.len() <= 32768,
            "Directory response too large"
        );
        bytes.extend_from_slice(&chunk);
    }
    let envelope: crate::rendezvous::Envelope = serde_json::from_slice(&bytes)?;
    let signature: [u8; 64] = base64::engine::general_purpose::STANDARD
        .decode(&envelope.signature)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("Invalid signature size"))?;
    target.verify(
        format!("{DOMAIN}{}", envelope.payload).as_bytes(),
        &iroh::Signature::from_bytes(&signature),
    )?;
    let payload: serde_json::Value = serde_json::from_str(&envelope.payload)?;
    let now = crate::rendezvous::now()?;
    let time = payload["time"]
        .as_u64()
        .context("Missing announcement time")?;
    let expiry = payload["expires"]
        .as_u64()
        .context("Missing announcement expiry")?;
    anyhow::ensure!(
        payload["kind"] == "announce"
            && payload["id"] == target.to_string()
            && time <= now + 60000
            && expiry > now
            && time
                .checked_add(300000)
                .is_some_and(|limit| expiry <= limit),
        "Expired or mismatched directory record"
    );
    let address: crate::peer::Address = serde_json::from_value(payload["address"].clone())?;
    anyhow::ensure!(
        address.version == 1
            && address.id == target
            && address.relay.is_none()
            && address.directory.is_none()
            && !address.addresses.is_empty()
            && address.addresses.len() <= 32,
        "Invalid direct address record"
    );
    Ok(address)
}
