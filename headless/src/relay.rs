#[derive(Debug)]
struct Allowed(std::path::PathBuf);

#[derive(serde::Serialize, serde::Deserialize)]
pub struct Health {
    pub status: String,
    pub version: String,
}

pub async fn health(url: &str) -> anyhow::Result<crate::relay::Health> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let url = crate::cluster_remote::validate_url(url)?.join("healthz")?;
    let response = reqwest::Client::builder()
        .no_proxy()
        .timeout(std::time::Duration::from_secs(3))
        .build()?
        .get(url)
        .send()
        .await?
        .error_for_status()?;
    let value: crate::relay::Health = response.json().await?;
    anyhow::ensure!(
        value.status == "ok" && value.version == "1.3.0",
        "relay health or protocol version mismatch"
    );
    Ok(value)
}

fn read_allowed(path: &std::path::Path) -> anyhow::Result<Vec<iroh::EndpointId>> {
    use std::io::Read as _;
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    anyhow::ensure!(bytes.len() <= 1024 * 1024, "relay admission file too large");
    let ids: Vec<iroh::EndpointId> = serde_json::from_slice(&bytes)?;
    anyhow::ensure!(
        !ids.is_empty() && ids.len() <= 4096,
        "relay requires 1 to 4096 permitted endpoint IDs"
    );
    Ok(ids)
}

impl iroh_relay::server::AccessControl for crate::relay::Allowed {
    async fn on_connect(
        &self,
        request: &iroh_relay::server::ClientRequest,
    ) -> iroh_relay::server::Access {
        if crate::relay::read_allowed(&self.0).is_ok_and(|ids| ids.contains(&request.endpoint_id()))
        {
            iroh_relay::server::Access::Allow
        } else {
            iroh_relay::server::Access::Deny {
                reason: Some("endpoint not permitted".into()),
            }
        }
    }
}

pub async fn run(listen: std::net::SocketAddr, allowed: std::path::PathBuf) -> anyhow::Result<()> {
    crate::relay::read_allowed(&allowed)?;
    let mut relay = iroh_relay::server::RelayConfig::new(listen);
    relay.access = std::sync::Arc::new(crate::relay::Allowed(allowed));
    let mut config = iroh_relay::server::ServerConfig::default();
    config.relay = Some(relay);
    let server = iroh_relay::server::Server::spawn(config).await?;
    println!(
        "{}",
        serde_json::json!({"version": "1.3.0", "listen": server.http_addr()})
    );
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! { result = tokio::signal::ctrl_c() => result?, _ = terminate.recv() => {} }
    }
    #[cfg(windows)]
    tokio::signal::ctrl_c().await?;
    server.shutdown().await?;
    Ok(())
}
