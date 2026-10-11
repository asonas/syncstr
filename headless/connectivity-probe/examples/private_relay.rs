#[derive(Debug)]
struct Allowed(Vec<iroh::EndpointId>);

impl iroh_relay::server::AccessControl for crate::Allowed {
    async fn on_connect(
        &self,
        request: &iroh_relay::server::ClientRequest,
    ) -> iroh_relay::server::Access {
        if self.0.contains(&request.endpoint_id()) {
            iroh_relay::server::Access::Allow
        } else {
            iroh_relay::server::Access::Deny {
                reason: Some("endpoint not permitted".into()),
            }
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    anyhow::ensure!(
        args.len() >= 3,
        "usage: private_relay LOOPBACK_BIND ALLOWED_ID..."
    );
    let bind: std::net::SocketAddr = args[1].parse()?;
    anyhow::ensure!(
        bind.ip().is_loopback(),
        "experimental relay must bind loopback"
    );
    let allowed: Result<Vec<iroh::EndpointId>, _> = args[2..].iter().map(|id| id.parse()).collect();
    let mut relay = iroh_relay::server::RelayConfig::new(bind);
    relay.access = std::sync::Arc::new(crate::Allowed(allowed?));
    let mut config = iroh_relay::server::ServerConfig::default();
    config.relay = Some(relay);
    let server = iroh_relay::server::Server::spawn(config).await?;
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    tokio::select! {
        result = tokio::signal::ctrl_c() => result?,
        _ = terminate.recv() => {},
    }
    server.shutdown().await?;
    Ok(())
}
