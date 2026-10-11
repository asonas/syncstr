#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    anyhow::ensure!(
        args.len() == 4,
        "usage: lan_node serve|discover STATE PEER_ID"
    );
    let identity = syncstr_connectivity_probe::Identity::open(std::path::Path::new(&args[2]))?;
    let peer: iroh::EndpointId = args[3].parse()?;
    anyhow::ensure!(identity.is_paired(peer), "fixture peer is not paired");
    let (endpoint, _lock) = identity
        .endpoint(syncstr_connectivity_probe::Mode::Direct, None)
        .await?;
    let daemon = mdns_sd::ServiceDaemon::new()?;
    let outcome = tokio::time::timeout(std::time::Duration::from_secs(30), async {
        match args[1].as_str() {
            "serve" => {
                let address = endpoint.addr();
                let ip = address
                    .ip_addrs()
                    .find(|addr| addr.is_ipv4() && !addr.ip().is_loopback())
                    .ok_or_else(|| anyhow::anyhow!("missing LAN interface"))?;
                let id = identity.id().to_string();
                daemon.register(mdns_sd::ServiceInfo::new(
                    "_syncstr-probe._udp.local.",
                    &id[..16],
                    &format!("probe-{}.local.", &id[..16]),
                    ip.ip(),
                    ip.port(),
                    &[("id", id.as_str()), ("version", "1")][..],
                )?)?;
                let connection = endpoint
                    .accept()
                    .await
                    .ok_or_else(|| anyhow::anyhow!("endpoint closed"))?
                    .await?;
                syncstr_connectivity_probe::serve_connection(&identity, connection).await?;
            }
            "discover" => {
                let events = daemon.browse("_syncstr-probe._udp.local.")?;
                let address = loop {
                    if let mdns_sd::ServiceEvent::ServiceResolved(service) =
                        events.recv_async().await?
                    {
                        if service.get_property_val_str("id") != Some(peer.to_string().as_str())
                            || service.get_property_val_str("version") != Some("1")
                        {
                            continue;
                        }
                        let ips = service.get_addresses_v4();
                        if let Some(ip) = ips.iter().next() {
                            break std::net::SocketAddr::from((*ip, service.get_port()));
                        }
                    }
                };
                let report = syncstr_connectivity_probe::probe(
                    &identity,
                    &endpoint,
                    syncstr_connectivity_probe::Address {
                        version: 1,
                        endpoint: iroh::EndpointAddr::new(peer).with_ip_addr(address),
                    },
                    true,
                )
                .await?;
                anyhow::ensure!(
                    report.paths_after.iter().all(|path| path.kind != "relay"),
                    "unexpected relay"
                );
                println!("{}", serde_json::to_string(&report)?);
            }
            _ => anyhow::bail!("unknown role"),
        }
        anyhow::Ok(())
    })
    .await;
    daemon
        .shutdown()?
        .recv_timeout(std::time::Duration::from_secs(5))?;
    endpoint.close().await;
    outcome??;
    Ok(())
}
