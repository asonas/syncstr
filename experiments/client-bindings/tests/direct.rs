#[test]
fn direct_client_preserves_identity_cancels_late_work_and_releases_profile() {
    let path =
        std::env::temp_dir().join(format!("syncstr-binding-{}.lockfile", std::process::id()));
    let client = syncstr_binding_probe::Client::open(path.to_string_lossy().into()).unwrap();
    let catalog = client.catalog().unwrap();
    assert_eq!(catalog.revision, 7);
    assert_eq!(catalog.tracks.len(), 2);
    assert_eq!(catalog.tracks[0].track_id, "logical-track-a");
    assert_eq!(catalog.tracks[1].track_id, "logical-track-b");
    assert_eq!(catalog.tracks[0].audio_hash, catalog.tracks[1].audio_hash);
    assert!(matches!(
        syncstr_binding_probe::Client::open(path.to_string_lossy().into()),
        Err(syncstr_binding_probe::ProbeError::ProfileUnavailable)
    ));
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let operation = client.clone().prepare(catalog.tracks[0].clone()).unwrap();
        let pending = tokio::spawn(operation.clone().complete());
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !operation.has_started() {
            assert!(std::time::Instant::now() < deadline);
            tokio::task::yield_now().await;
        }
        operation.cancel();
        assert!(matches!(
            pending.await.unwrap(),
            Err(syncstr_binding_probe::ProbeError::Cancelled)
        ));
        let operation = client.clone().prepare(catalog.tracks[1].clone()).unwrap();
        assert_eq!(
            operation.clone().complete().await.unwrap(),
            catalog.tracks[1]
        );
        client.shutdown();
        let reopened = syncstr_binding_probe::Client::open(path.to_string_lossy().into()).unwrap();
        assert!(matches!(
            operation.complete().await,
            Err(syncstr_binding_probe::ProbeError::Closed)
        ));
        drop(reopened);
        let after_drop =
            syncstr_binding_probe::Client::open(path.to_string_lossy().into()).unwrap();
        after_drop.shutdown();
    });
    drop(client);
    std::fs::remove_file(path).unwrap();
}
