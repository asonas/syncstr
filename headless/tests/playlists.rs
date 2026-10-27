#![cfg(feature = "p2p")]

fn document() -> syncstr_headless::playlists::Document {
    syncstr_headless::playlists::Document {
        id: "source:mix".into(),
        source_library: "source".into(),
        source_playlist: "mix".into(),
        source_fingerprint: "a".repeat(64),
        name: "Fixture mix".into(),
        kind: "snapshot".into(),
        parent: None,
        definition: std::collections::BTreeMap::from([("Smart Info".into(), "b3BhcXVl".into())]),
        items: vec![0, 1, 2]
            .into_iter()
            .map(|index| syncstr_headless::playlists::Item {
                id: index.to_string(),
                source_track: if index == 1 { "missing" } else { "one" }.into(),
                title: "Original title".into(),
                artist: None,
                album: None,
                track_id: None,
                sha256: None,
            })
            .collect(),
    }
}

#[tokio::test]
async fn selective_import_is_atomic_idempotent_and_rejects_overwrites() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let state = root.path().join("identity");
    syncstr_headless::peer::Identity::initialize(&state)?;
    let host = syncstr_headless::peer::Identity::open(&state)?;
    let data = root.path().join("data");
    let store = syncstr_headless::store::Store::open(&data)?;
    let cluster = store.create_cluster(host.id().to_string()).await?.id;
    let original = document();
    let mut stale = original.clone();
    stale.items[0].track_id = Some("absent-track".into());
    stale.items[0].sha256 = Some("b".repeat(64));
    assert!(
        store
            .import_playlists(&host, cluster.clone(), vec![stale])
            .await
            .is_err()
    );
    assert!(store.playlist_records().await?.is_empty());
    assert_eq!(
        store
            .import_playlists(&host, cluster.clone(), vec![original.clone()])
            .await?,
        1
    );
    assert_eq!(
        store
            .import_playlists(&host, cluster.clone(), vec![original.clone()])
            .await?,
        0
    );
    let mut changed = original.clone();
    changed.name = "Replacement".into();
    assert!(
        store
            .import_playlists(&host, cluster.clone(), vec![changed])
            .await
            .is_err()
    );
    let mut invalid = original.clone();
    invalid.id = "source:invalid".into();
    invalid.source_playlist = "invalid".into();
    invalid.parent = Some("missing:folder".into());
    let mut second = original.clone();
    second.id = "source:second".into();
    second.source_playlist = "second".into();
    assert!(
        store
            .import_playlists(&host, cluster, vec![second, invalid])
            .await
            .is_err()
    );
    assert_eq!(store.playlist_records().await?.len(), 1);
    assert!(store.catalog().await?.entries.is_empty());
    drop(store);
    let reopened = syncstr_headless::store::Store::open(&data)?;
    let records = reopened.playlist_records().await?;
    assert_eq!(
        records[0]
            .decode(&reopened.cluster_membership_proof().await?)?
            .document,
        original
    );
    let mut altered = records[0].clone();
    altered.payload = altered.payload.replace("Original title", "Forged title");
    assert!(
        altered
            .decode(&reopened.cluster_membership_proof().await?)
            .is_err()
    );
    Ok(())
}

#[tokio::test]
async fn authenticated_protocol_restores_playlists_without_downloading_audio() -> anyhow::Result<()>
{
    let root = tempfile::tempdir()?;
    let host_key = root.path().join("host-key");
    syncstr_headless::peer::Identity::initialize(&host_key)?;
    let host = std::sync::Arc::new(syncstr_headless::peer::Identity::open(&host_key)?);
    let store = syncstr_headless::store::Store::open(&root.path().join("host"))?;
    let cluster = store.create_cluster(host.id().to_string()).await?.id;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();
    let invitation = store
        .create_cluster_invitation(&host, false, now, 600)
        .await?;
    let (endpoint, _host_lock) = host.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let serving = tokio::spawn(syncstr_headless::cluster_net::serve(
        host.clone(),
        endpoint.clone(),
        store.clone(),
    ));
    let key = root.path().join("client-key");
    syncstr_headless::peer::Identity::initialize(&key)?;
    let client = syncstr_headless::peer::Identity::open(&key)?;
    let client_store = syncstr_headless::store::Store::open(&root.path().join("client"))?;
    let (client_endpoint, _client_lock) =
        client.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    syncstr_headless::cluster_net::enroll(
        &client,
        &client_endpoint,
        endpoint.addr(),
        &invitation,
        &client_store,
    )
    .await?;
    let session = syncstr_headless::playlist_sync::Session::connect(
        &client_endpoint,
        endpoint.addr(),
        &client_store,
    )
    .await?;
    let response = session
        .request(&syncstr_headless::playlist_sync::Request::Import {
            cluster: cluster.clone(),
            documents: vec![document()],
        })
        .await?;
    assert!(matches!(
        response,
        syncstr_headless::playlist_sync::Response::Imported { added: 1 }
    ));
    session.reconcile(&client_store).await?;
    session.reconcile(&client_store).await?;
    let records = client_store.playlist_records().await?;
    assert_eq!(records.len(), 1);
    assert_eq!(
        records[0]
            .decode(&client_store.cluster_membership_proof().await?)?
            .document,
        document()
    );
    assert!(client_store.catalog().await?.entries.is_empty());
    let wrong = session
        .request(&syncstr_headless::playlist_sync::Request::Import {
            cluster: "wrong".into(),
            documents: vec![document()],
        })
        .await?;
    assert!(matches!(
        wrong,
        syncstr_headless::playlist_sync::Response::Rejected { .. }
    ));
    drop(session);
    host.pair(client.id())?;
    store
        .revoke_cluster_member(&host, client.id().to_string())
        .await?;
    let fallback = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        let connection = client_endpoint
            .connect(endpoint.addr(), syncstr_headless::playlist_sync::ALPN)
            .await?;
        let (mut output, mut input) = connection.open_bi().await?;
        let payload = serde_json::to_vec(&serde_json::json!({"capabilities": {"version": 1}}))?;
        output
            .write_all(&(payload.len() as u32).to_be_bytes())
            .await?;
        output.write_all(&payload).await?;
        output.finish()?;
        input.read_exact(&mut [0u8; 4]).await?;
        anyhow::Ok(())
    })
    .await?;
    assert!(
        fallback.is_err(),
        "legacy pairing must not bypass a cluster revocation"
    );
    client_endpoint.close().await;
    endpoint.close().await;
    serving.abort();
    let _ = serving.await;
    Ok(())
}
