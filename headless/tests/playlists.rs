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
async fn reconciliation_preserves_occurrences_retries_and_rejects_stale_or_changed_sources()
-> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let key = root.path().join("key");
    syncstr_headless::peer::Identity::initialize(&key)?;
    let host = syncstr_headless::peer::Identity::open(&key)?;
    let store = syncstr_headless::store::Store::open(&root.path().join("data"))?;
    let cluster = store.create_cluster(host.id().to_string()).await?.id;
    let mut file = store.stage().await?;
    use std::io::Write as _;
    file.write_all(b"abc")?;
    let entry = store
        .commit(
            serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?,
            file,
            false,
        )
        .await?;
    let mut folder = document();
    folder.id = "source:folder".into();
    folder.source_playlist = "folder".into();
    folder.kind = "folder".into();
    folder.items.clear();
    let mut original = document();
    original.parent = Some(folder.id.clone());
    original.items = (0..73)
        .map(|i| {
            let mut item = original.items[i % 3].clone();
            item.id = i.to_string();
            if i < 44 {
                item.track_id = Some(entry.track.id.clone());
                item.sha256 = Some(entry.sha256.clone());
            }
            item
        })
        .collect();
    store
        .import_playlists(
            &host,
            cluster.clone(),
            vec![folder.clone(), original.clone()],
        )
        .await?;
    let proof = store.cluster_membership_proof().await?;
    let snapshots = syncstr_headless::playlists::project(&store.playlist_records().await?, &proof)?;
    let expected = std::collections::BTreeMap::from([(
        original.id.clone(),
        snapshots[&original.id].revisions.clone(),
    )]);
    let mut incoming = original.clone();
    for (i, item) in incoming.items.iter_mut().enumerate() {
        item.track_id = (44..65).contains(&i).then(|| entry.track.id.clone());
        item.sha256 = (44..65).contains(&i).then(|| entry.sha256.clone());
    }
    assert_eq!(
        store
            .reconcile_playlists(
                &host,
                cluster.clone(),
                vec![incoming.clone()],
                expected.clone()
            )
            .await?,
        1
    );
    assert_eq!(
        store
            .reconcile_playlists(
                &host,
                cluster.clone(),
                vec![incoming.clone()],
                expected.clone()
            )
            .await?,
        0
    );
    let records = store.playlist_records().await?;
    assert_eq!(records.len(), 3);
    let current = syncstr_headless::playlists::project(&records, &proof)?;
    let updated = &current[&original.id].document;
    assert_eq!(
        updated
            .items
            .iter()
            .filter(|item| item.track_id.is_some())
            .count(),
        65
    );
    assert_eq!(updated.items[..44], original.items[..44]);
    assert_eq!(
        updated
            .items
            .iter()
            .map(|item| (&item.id, &item.source_track))
            .collect::<Vec<_>>(),
        original
            .items
            .iter()
            .map(|item| (&item.id, &item.source_track))
            .collect::<Vec<_>>()
    );
    assert_eq!(updated.parent, original.parent);
    assert_eq!(current[&folder.id].document, folder);
    let mut reversed = records.clone();
    reversed.reverse();
    assert_eq!(
        syncstr_headless::playlists::project(&reversed, &proof)?[&original.id].document,
        *updated
    );

    let retry = incoming.clone();
    let retry_expected = expected.clone();
    incoming.items[65].track_id = Some(entry.track.id.clone());
    incoming.items[65].sha256 = Some(entry.sha256.clone());
    assert!(
        store
            .reconcile_playlists(&host, cluster.clone(), vec![incoming.clone()], expected)
            .await
            .unwrap_err()
            .to_string()
            .contains("stale")
    );
    let expected = std::collections::BTreeMap::from([(
        original.id.clone(),
        current[&original.id].revisions.clone(),
    )]);
    let next = incoming.clone();
    incoming.items.swap(0, 1);
    assert!(
        store
            .reconcile_playlists(&host, cluster.clone(), vec![incoming], expected.clone())
            .await
            .unwrap_err()
            .to_string()
            .contains("source changed")
    );
    assert_eq!(store.playlist_records().await?.len(), 3);
    assert_eq!(
        store
            .reconcile_playlists(&host, cluster.clone(), vec![next], expected)
            .await?,
        1
    );
    assert_eq!(
        store
            .reconcile_playlists(&host, cluster, vec![retry], retry_expected)
            .await?,
        0
    );
    assert_eq!(store.playlist_records().await?.len(), 4);
    let latest = syncstr_headless::playlists::project(&store.playlist_records().await?, &proof)?;
    assert_eq!(
        latest[&original.id]
            .document
            .items
            .iter()
            .filter(|item| item.track_id.is_some())
            .count(),
        66
    );
    drop(store);
    let reopened = syncstr_headless::store::Store::open(&root.path().join("data"))?;
    assert_eq!(
        syncstr_headless::playlists::project(&reopened.playlist_records().await?, &proof)?
            [&original.id]
            .document,
        latest[&original.id].document
    );
    Ok(())
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
    let mut file = store.stage().await?;
    use std::io::Write as _;
    file.write_all(b"abc")?;
    let entry = store
        .commit(
            serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?,
            file,
            false,
        )
        .await?;
    let preview = session
        .request(&syncstr_headless::playlist_sync::Request::Preview)
        .await?;
    let syncstr_headless::playlist_sync::Response::Preview { playlists, .. } = preview else {
        anyhow::bail!("missing preview")
    };
    let expected =
        std::collections::BTreeMap::from([(document().id, playlists[0].revisions.clone())]);
    let mut updated = document();
    updated.items[0].track_id = Some(entry.track.id.clone());
    updated.items[0].sha256 = Some(entry.sha256.clone());
    store
        .reconcile_playlists(
            &host,
            cluster.clone(),
            vec![updated.clone()],
            expected.clone(),
        )
        .await?;
    session.reconcile(&client_store).await?;
    session.reconcile(&client_store).await?;
    let records = client_store.playlist_records().await?;
    assert_eq!(records.len(), 2);
    assert_eq!(
        syncstr_headless::playlists::project(
            &records,
            &client_store.cluster_membership_proof().await?
        )?[&updated.id]
            .document,
        updated
    );
    assert!(client_store.catalog().await?.entries.is_empty());
    let retried = session
        .request(&syncstr_headless::playlist_sync::Request::Reconcile {
            cluster: cluster.clone(),
            documents: vec![updated],
            expected,
        })
        .await?;
    assert!(matches!(
        retried,
        syncstr_headless::playlist_sync::Response::Imported { added: 0 }
    ));
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
