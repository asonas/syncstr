#[test]
fn device_identity_and_explicit_pairing_survive_restart() -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    let root = tempfile::tempdir()?;
    let id = syncstr_connectivity_probe::Identity::initialize(root.path())?;
    let bytes = std::fs::read(root.path().join("device.key"))?;
    assert_eq!(
        std::fs::metadata(root.path().join("device.key"))?
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert!(syncstr_connectivity_probe::Identity::initialize(root.path()).is_err());
    assert_eq!(bytes, std::fs::read(root.path().join("device.key"))?);
    let peer = iroh::SecretKey::generate().public();
    let identity = syncstr_connectivity_probe::Identity::open(root.path())?;
    assert_eq!(identity.id(), id);
    assert!(!identity.is_paired(peer));
    assert!(identity.pair(id).is_err());
    identity.pair(peer)?;
    let restored = syncstr_connectivity_probe::Identity::open(root.path())?;
    assert!(restored.is_paired(peer));
    restored.unpair(peer)?;
    assert!(!identity.is_paired(peer));
    Ok(())
}

#[tokio::test]
async fn direct_quic_checks_both_device_keys_and_rejects_unpaired_peers() -> anyhow::Result<()> {
    let roots = [
        tempfile::tempdir()?,
        tempfile::tempdir()?,
        tempfile::tempdir()?,
    ];
    for root in &roots {
        syncstr_connectivity_probe::Identity::initialize(root.path())?;
    }
    let server = syncstr_connectivity_probe::Identity::open(roots[0].path())?;
    let client = syncstr_connectivity_probe::Identity::open(roots[1].path())?;
    let stranger = syncstr_connectivity_probe::Identity::open(roots[2].path())?;
    server.pair(client.id())?;
    client.pair(server.id())?;
    stranger.pair(server.id())?;
    let (acceptor, _server_lock) = server
        .endpoint(syncstr_connectivity_probe::Mode::Direct)
        .await?;
    assert!(
        server
            .endpoint(syncstr_connectivity_probe::Mode::Direct)
            .await
            .is_err()
    );
    let address = roots[0].path().join("address.json");
    syncstr_connectivity_probe::Address::write(&acceptor, &address)?;
    assert!(syncstr_connectivity_probe::Address::read(&address, stranger.id()).is_err());
    let receiver = acceptor.clone();
    let server_task = tokio::spawn(async move {
        while let Some(incoming) = receiver.accept().await {
            let connection = incoming.await?;
            let _ = syncstr_connectivity_probe::serve_connection(&server, connection).await;
        }
        anyhow::Ok(())
    });
    let (initiator, _client_lock) = client
        .endpoint(syncstr_connectivity_probe::Mode::Direct)
        .await?;
    let report = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        syncstr_connectivity_probe::probe(
            &client,
            &initiator,
            syncstr_connectivity_probe::Address::read(&address, acceptor.id())?,
            true,
        ),
    )
    .await??;
    assert_eq!(report.peer_id, acceptor.id().to_string());
    assert_eq!(report.bytes, 65536);
    assert!(
        report
            .paths_before
            .iter()
            .any(|p| p.selected && p.kind == "direct")
    );
    assert!(
        report
            .paths_after
            .iter()
            .any(|p| p.selected && p.kind == "direct")
    );
    assert!(report.paths_after.iter().all(|p| p.kind != "relay"));
    let (untrusted, _stranger_lock) = stranger
        .endpoint(syncstr_connectivity_probe::Mode::Direct)
        .await?;
    let rejected = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        syncstr_connectivity_probe::probe(
            &stranger,
            &untrusted,
            syncstr_connectivity_probe::Address::read(&address, acceptor.id())?,
            false,
        ),
    )
    .await?;
    assert!(rejected.is_err());
    let restored_server = syncstr_connectivity_probe::Identity::open(roots[0].path())?;
    restored_server.unpair(client.id())?;
    let revoked = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        syncstr_connectivity_probe::probe(
            &client,
            &initiator,
            syncstr_connectivity_probe::Address::read(&address, acceptor.id())?,
            false,
        ),
    )
    .await?;
    assert!(revoked.is_err());
    initiator.close().await;
    untrusted.close().await;
    acceptor.close().await;
    server_task.await??;
    Ok(())
}
