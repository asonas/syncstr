#![cfg(feature = "p2p")]

#[tokio::test]
async fn playback_client_selectively_saves_audio_and_restores_offline_state() -> anyhow::Result<()>
{
    let root = tempfile::tempdir()?;
    let host_key = root.path().join("host-identity");
    let host_id = syncstr_headless::peer::Identity::initialize(&host_key)?;
    let host = std::sync::Arc::new(syncstr_headless::peer::Identity::open(&host_key)?);
    let store = syncstr_headless::store::Store::open(&root.path().join("host-data"))?;
    store.create_cluster(host_id.to_string()).await?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();
    let invitation = store
        .create_cluster_invitation(&host, false, now, 600)
        .await?;
    let file = root.path().join("fixture.wav");
    std::fs::write(&file, b"abc")?;
    let entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    store
        .import_cluster_file(&host, entry.clone(), None, &file, false)
        .await?;
    let (endpoint, _lock) = host.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let address = endpoint.addr();
    let socket = *address.ip_addrs().next().unwrap();
    let serving = tokio::spawn(syncstr_headless::cluster_net::serve(
        host.clone(),
        endpoint.clone(),
        store.clone(),
    ));
    let data = root.path().join("client-data");
    let client = syncstr_headless::cluster_client::PlaybackClient::open(&data, [9; 32])?;
    let id = client.id();
    client
        .enroll(&serde_json::to_string(&invitation)?, socket)
        .await?;
    let catalog = client.refresh(address).await?;
    assert_eq!(catalog.catalog.entries.len(), 1);
    assert_eq!(catalog.catalog.entries[0].track.title, "夜の音楽");
    assert_eq!(catalog.catalog.entries[0].sha256, entry.sha256);
    assert!(client.local_file(&entry.sha256).await?.is_none());
    drop(client);
    let restored = syncstr_headless::cluster_client::PlaybackClient::open(&data, [9; 32])?;
    assert_eq!(restored.id(), id);
    assert_eq!(restored.hosts().await?, vec![host_id.to_string()]);
    assert_eq!(restored.catalog().await?.catalog.entries.len(), 1);
    let second_key = root.path().join("second-host");
    syncstr_headless::peer::Identity::initialize(&second_key)?;
    let second = std::sync::Arc::new(syncstr_headless::peer::Identity::open(&second_key)?);
    let second_store = syncstr_headless::store::Store::open(&root.path().join("second-data"))?;
    let (second_endpoint, _second_lock) =
        second.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let host_invite = store
        .create_cluster_invitation(&host, true, now, 600)
        .await?;
    syncstr_headless::cluster_net::enroll(
        &second,
        &second_endpoint,
        endpoint.addr(),
        &host_invite,
        &second_store,
    )
    .await?;
    let second_serving = tokio::spawn(syncstr_headless::cluster_net::serve(
        second,
        second_endpoint.clone(),
        second_store,
    ));
    restored.refresh(endpoint.addr()).await?;
    let saved = restored
        .download_from(vec![second_endpoint.addr(), endpoint.addr()], &entry.sha256)
        .await?;
    assert_eq!(std::fs::read(&saved)?, b"abc");
    drop(restored);
    endpoint.close().await;
    serving.abort();
    let _ = serving.await;
    second_endpoint.close().await;
    second_serving.abort();
    let _ = second_serving.await;
    let offline = syncstr_headless::cluster_client::PlaybackClient::open(&data, [9; 32])?;
    assert_eq!(offline.local_file(&entry.sha256).await?, Some(saved));
    assert_eq!(offline.catalog().await?.catalog.entries.len(), 1);
    assert!(!data.join("identity/device.key").exists());
    drop(offline);
    let wrong_key = syncstr_headless::cluster_client::PlaybackClient::open(&data, [8; 32])?;
    assert!(wrong_key.catalog().await.is_err());
    Ok(())
}

#[tokio::test]
async fn playback_client_reports_album_conflicts_and_keeps_unrelated_music() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let key = root.path().join("host");
    syncstr_headless::peer::Identity::initialize(&key)?;
    let host = std::sync::Arc::new(syncstr_headless::peer::Identity::open(&key)?);
    let store = syncstr_headless::store::Store::open(&root.path().join("host-data"))?;
    store.create_cluster(host.id().to_string()).await?;
    let a: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    let mut original = syncstr_headless::organization::Organization::default();
    original.import(&a);
    let mut b = a.clone();
    b.sha256 = "cb8379ac2098aa165029e3938a51da0bcecfc008fd6795f401178647f96c5b34".into();
    b.track.id = "competing-track".into();
    let mut competing = syncstr_headless::organization::Organization::default();
    competing.import(&b);
    competing.albums[0].id = original.albums[0].id.clone();
    competing.tracks[0].imported_album_id = original.albums[0].id.clone();
    competing.albums[0].title = "Competing title".into();
    let file = root.path().join("audio.wav");
    std::fs::write(&file, b"abc")?;
    store
        .import_cluster_file(&host, a.clone(), Some(original), &file, false)
        .await?;
    std::fs::write(&file, b"def")?;
    assert!(
        store
            .import_cluster_file(&host, b, Some(competing), &file, false)
            .await
            .is_err()
    );
    let mut c = a.clone();
    c.sha256 = "50ae61e841fac4e8f9e40baf2ad36ec868922ea48368c18f9535e47db56dd7fb".into();
    c.track.id = "unrelated-track".into();
    c.track.album_id = Some("unrelated-album".into());
    c.track.album = Some("Independent album".into());
    std::fs::write(&file, b"ghi")?;
    store
        .import_cluster_file(&host, c.clone(), None, &file, false)
        .await?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();
    let invite = store
        .create_cluster_invitation(&host, false, now, 600)
        .await?;
    let (endpoint, _lock) = host.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let serving = tokio::spawn(syncstr_headless::cluster_net::serve(
        host,
        endpoint.clone(),
        store,
    ));
    let data = root.path().join("client");
    let client = syncstr_headless::cluster_client::PlaybackClient::open(&data, [7; 32])?;
    client
        .enroll(
            &serde_json::to_string(&invite)?,
            *endpoint.addr().ip_addrs().next().unwrap(),
        )
        .await?;
    let library = client.refresh(endpoint.addr()).await?;
    assert_eq!(library.conflicts.len(), 2);
    assert!(
        library
            .catalog
            .entries
            .iter()
            .any(|entry| entry.sha256 == c.sha256)
    );
    endpoint.close().await;
    serving.abort();
    let _ = serving.await;
    Ok(())
}

#[tokio::test]
async fn album_visibility_survives_restart_and_syncs_between_clients_without_audio() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let host_key = root.path().join("host-identity");
    let host_id = syncstr_headless::peer::Identity::initialize(&host_key)?;
    let host = std::sync::Arc::new(syncstr_headless::peer::Identity::open(&host_key)?);
    let store = syncstr_headless::store::Store::open(&root.path().join("host-data"))?;
    store.create_cluster(host_id.to_string()).await?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();
    let invitation = store
        .create_cluster_invitation(&host, false, now, 600)
        .await?;
    let file = root.path().join("fixture.wav");
    std::fs::write(&file, b"abc")?;
    let entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    store
        .import_cluster_file(&host, entry.clone(), None, &file, false)
        .await?;
    let (endpoint, _lock) = host.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let address = endpoint.addr();
    let socket = *address.ip_addrs().next().unwrap();
    let serving = tokio::spawn(syncstr_headless::cluster_net::serve(
        host.clone(),
        endpoint.clone(),
        store.clone(),
    ));
    let data = root.path().join("client-data");
    let client = syncstr_headless::cluster_client::PlaybackClient::open(&data, [9; 32])?;
    client
        .enroll(&serde_json::to_string(&invitation)?, socket)
        .await?;
    let catalog = client.refresh(address.clone()).await?;
    assert_eq!(catalog.catalog.entries.len(), 1);
    assert_eq!(catalog.catalog.entries[0].track.title, "夜の音楽");
    assert_eq!(catalog.catalog.entries[0].sha256, entry.sha256);
    assert!(client.local_file(&entry.sha256).await?.is_none());

    let album = catalog.catalog.organization.albums[0].id.clone();
    let hidden = client.set_album_hidden(&album, true).await?;
    assert!(hidden.catalog.organization.is_hidden(&album));
    assert_eq!(hidden.catalog.entries.len(), 1);
    drop(client);
    let client = syncstr_headless::cluster_client::PlaybackClient::open(&data, [9; 32])?;
    assert!(client.catalog().await?.catalog.organization.is_hidden(&album));
    client.refresh(address.clone()).await?;
    let invite = store.create_cluster_invitation(&host, false, now, 600).await?;
    let other = syncstr_headless::cluster_client::PlaybackClient::open(&root.path().join("other"), [7; 32])?;
    other.enroll(&serde_json::to_string(&invite)?, socket).await?;
    assert!(other.refresh(address.clone()).await?.catalog.organization.is_hidden(&album));
    other.set_album_hidden(&album, false).await?;
    other.refresh(address.clone()).await?;
    assert!(!client.refresh(address).await?.catalog.organization.is_hidden(&album));
    assert!(client.local_file(&entry.sha256).await?.is_none());
    assert_eq!(std::fs::read(&file)?, b"abc");
    endpoint.close().await;
    serving.abort();
    let _ = serving.await;
    Ok(())
}
