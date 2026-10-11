#[tokio::test]
#[ignore = "Build apple/ and set SYNCSTR_APPLE_PROBE; requires local multicast permission"]
async fn apple_bonjour_discovers_rust_and_transfers_without_a_relay() -> anyhow::Result<()> {
    let binary = std::env::var("SYNCSTR_APPLE_PROBE")?;
    let roots = [tempfile::tempdir()?, tempfile::tempdir()?];
    for root in &roots {
        syncstr_connectivity_probe::Identity::initialize(root.path())?;
    }
    let server = syncstr_connectivity_probe::Identity::open(roots[0].path())?;
    let client = syncstr_connectivity_probe::Identity::open(roots[1].path())?;
    server.pair(client.id())?;
    client.pair(server.id())?;
    let (endpoint, _lock) = server
        .endpoint(syncstr_connectivity_probe::Mode::Direct, None)
        .await?;
    let addr = endpoint.addr();
    let ip = addr
        .ip_addrs()
        .find(|a| a.is_ipv4() && !a.ip().is_loopback())
        .ok_or_else(|| anyhow::anyhow!("LAN IPv4 interface required"))?;
    let id = endpoint.id().to_string();
    let daemon = mdns_sd::ServiceDaemon::new()?;
    let service = mdns_sd::ServiceInfo::new(
        "_syncstr-probe._udp.local.",
        &id[..16],
        &format!("probe-{}.local.", &id[..16]),
        ip.ip(),
        ip.port(),
        &[("id", id.as_str()), ("version", "1")][..],
    )?;
    let name = service.get_fullname().to_owned();
    daemon.register(service)?;
    let receiver = endpoint.clone();
    let serving = tokio::spawn(async move {
        let connection = receiver.accept().await.unwrap().await?;
        syncstr_connectivity_probe::serve_connection(&server, connection).await
    });
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(35),
        tokio::process::Command::new(binary)
            .arg(roots[1].path().join("device.key"))
            .arg(&id)
            .arg("--lan")
            .kill_on_drop(true)
            .output(),
    )
    .await;
    daemon
        .unregister(&name)?
        .recv_timeout(std::time::Duration::from_secs(5))?;
    daemon
        .shutdown()?
        .recv_timeout(std::time::Duration::from_secs(5))?;
    let output = output??;
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
            .any(|p| p["selected"] == true && p["kind"] == "direct")
    );
    assert!(paths.iter().all(|p| p["kind"] != "relay"));
    println!("Bonjour: {report}");
    serving.await??;
    endpoint.close().await;
    Ok(())
}
