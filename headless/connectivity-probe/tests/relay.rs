#[tokio::test]
async fn custom_relay_bootstraps_by_identity_without_direct_addresses() -> anyhow::Result<()> {
    crate::exercise(syncstr_connectivity_probe::Mode::RelayOnly, None).await
}

#[tokio::test]
async fn custom_relay_bootstrap_finds_direct_path_without_stored_ips() -> anyhow::Result<()> {
    crate::exercise(syncstr_connectivity_probe::Mode::Auto, None).await
}

#[tokio::test]
#[ignore = "Build apple/ and set SYNCSTR_APPLE_PROBE to its executable"]
async fn apple_client_transfers_via_custom_relay_without_stored_ips() -> anyhow::Result<()> {
    let binary = std::env::var("SYNCSTR_APPLE_PROBE")?;
    crate::exercise(syncstr_connectivity_probe::Mode::RelayOnly, Some(binary)).await
}

#[derive(Debug)]
struct AllowedPeers([iroh::EndpointId; 2]);

impl iroh_relay::server::AccessControl for crate::AllowedPeers {
    async fn on_connect(
        &self,
        request: &iroh_relay::server::ClientRequest,
    ) -> iroh_relay::server::Access {
        if self.0.contains(&request.endpoint_id()) {
            iroh_relay::server::Access::Allow
        } else {
            iroh_relay::server::Access::Deny { reason: None }
        }
    }
}

async fn exercise(
    mode: syncstr_connectivity_probe::Mode,
    apple: Option<String>,
) -> anyhow::Result<()> {
    let roots = [tempfile::tempdir()?, tempfile::tempdir()?];
    for root in &roots {
        syncstr_connectivity_probe::Identity::initialize(root.path())?;
    }
    let server = syncstr_connectivity_probe::Identity::open(roots[0].path())?;
    let client = syncstr_connectivity_probe::Identity::open(roots[1].path())?;
    server.pair(client.id())?;
    client.pair(server.id())?;
    let mut config = iroh_relay::server::ServerConfig::default();
    let mut relay_config = iroh_relay::server::RelayConfig::new(([127, 0, 0, 1], 0));
    relay_config.access = std::sync::Arc::new(crate::AllowedPeers([server.id(), client.id()]));
    config.relay = Some(relay_config);
    let relay = iroh_relay::server::Server::spawn(config).await?;
    let url: iroh::RelayUrl = format!("http://{}", relay.http_addr().unwrap()).parse()?;
    let (acceptor, _server_lock) = server.endpoint(mode, Some(url.clone())).await?;
    let peer = acceptor.id();
    let receiver = acceptor.clone();
    let serving = tokio::spawn(async move {
        let connection = receiver.accept().await.unwrap().await?;
        syncstr_connectivity_probe::serve_connection(&server, connection).await
    });
    if let Some(binary) = apple {
        let output = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            tokio::process::Command::new(binary)
                .arg(roots[1].path().join("device.key"))
                .arg(peer.to_string())
                .arg(url.to_string())
                .kill_on_drop(true)
                .output(),
        )
        .await??;
        anyhow::ensure!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let report: serde_json::Value = serde_json::from_slice(&output.stdout)?;
        assert_eq!(report["bytes"], 65536);
        let paths = report["paths_after"].as_array().unwrap();
        assert!(
            paths
                .iter()
                .any(|p| p["selected"] == true && p["kind"] == "relay")
        );
        assert!(paths.iter().all(|p| p["kind"] != "direct"));
        println!("Apple: {report}");
    } else {
        let (initiator, _client_lock) = client.endpoint(mode, Some(url.clone())).await?;
        let report = tokio::time::timeout(
            std::time::Duration::from_secs(20),
            syncstr_connectivity_probe::probe(
                &client,
                &initiator,
                syncstr_connectivity_probe::Address {
                    version: 1,
                    endpoint: iroh::EndpointAddr::new(peer).with_relay_url(url),
                },
                mode == syncstr_connectivity_probe::Mode::Auto,
            ),
        )
        .await??;
        assert_eq!(report.bytes, 65536);
        println!("Rust: {}", serde_json::to_string(&report)?);
        assert_eq!(report.peer_id, peer.to_string());
        let expected = if mode == syncstr_connectivity_probe::Mode::Auto {
            "direct"
        } else {
            "relay"
        };
        assert!(
            report
                .paths_after
                .iter()
                .any(|p| p.selected && p.kind == expected)
        );
        if mode == syncstr_connectivity_probe::Mode::RelayOnly {
            assert!(report.paths_after.iter().all(|p| p.kind != "direct"));
        }
        initiator.close().await;
    }
    serving.await??;
    acceptor.close().await;
    relay.shutdown().await?;
    Ok(())
}
