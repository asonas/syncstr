#![cfg(feature = "p2p")]

async fn receive<T: serde::de::DeserializeOwned>(
    stream: &mut iroh::endpoint::RecvStream,
    limit: usize,
) -> anyhow::Result<T> {
    let mut size = [0; 4];
    stream.read_exact(&mut size).await?;
    let size = u32::from_be_bytes(size) as usize;
    anyhow::ensure!(size > 0 && size <= limit, "invalid fixture frame");
    let mut bytes = vec![0; size];
    stream.read_exact(&mut bytes).await?;
    Ok(serde_json::from_slice(&bytes)?)
}

async fn send<T: serde::Serialize>(
    stream: &mut iroh::endpoint::SendStream,
    value: &T,
) -> anyhow::Result<()> {
    let bytes = serde_json::to_vec(value)?;
    stream
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .await?;
    stream.write_all(&bytes).await?;
    Ok(())
}

struct Fixture {
    root: tempfile::TempDir,
    host: std::sync::Arc<syncstr_headless::peer::Identity>,
    proof: syncstr_headless::enrollment::Proof,
    store: syncstr_headless::shared_audio::Store,
    client_root: std::path::PathBuf,
}

impl Fixture {
    async fn new() -> anyhow::Result<Self> {
        let root = tempfile::tempdir()?;
        let host_key = root.path().join("host-key");
        syncstr_headless::peer::Identity::initialize(&host_key)?;
        let host = std::sync::Arc::new(syncstr_headless::peer::Identity::open(&host_key)?);
        let data = root.path().join("host-data");
        let legacy = syncstr_headless::store::Store::open(&data)?;
        let cluster = legacy.create_cluster(host.id().to_string()).await?.id;
        let invitation = legacy
            .create_cluster_invitation(&host, false, 100, 600)
            .await?;
        let client_root = root.path().join("client");
        let identity =
            syncstr_headless::peer::Identity::from_secret(&client_root.join("identity"), [9; 32])?;
        let grant = legacy
            .redeem_cluster_invitation(&host, &invitation.secret, identity.id().to_string(), 101)
            .await?;
        let proof = legacy.cluster_membership_proof().await?;
        let client_store = syncstr_headless::store::Store::open(&client_root)?;
        client_store
            .join_cluster(&identity, host.id(), grant.id, proof.clone())
            .await?;
        drop(client_store);
        let entry: syncstr_headless::model::Entry =
            serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
        let file = root.path().join("tone.wav");
        std::fs::write(&file, b"abc")?;
        legacy
            .import_cluster_file(&host, entry, None, &file, false)
            .await?;
        legacy
            .import_playlists(
                &host,
                cluster,
                vec![syncstr_headless::playlists::Document {
                    id: "LIB-A:PLAYLIST-A".into(),
                    source_library: "LIB-A".into(),
                    source_playlist: "PLAYLIST-A".into(),
                    source_fingerprint: "a".repeat(64),
                    name: "Exact occurrences".into(),
                    kind: "manual".into(),
                    parent: None,
                    definition: Default::default(),
                    items: (0..3)
                        .map(|i| syncstr_headless::playlists::Item {
                            id: format!("occurrence-{i}"),
                            source_track: "17".into(),
                            title: "Pinned A".into(),
                            artist: None,
                            album: None,
                            track_id: Some("fixture-track".into()),
                            sha256: Some(
                                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                                    .into(),
                            ),
                        })
                        .collect(),
                }],
            )
            .await?;
        drop(legacy);
        let baseline = syncstr_headless::shared_audio::Store::inspect(&data)?;
        let store = syncstr_headless::shared_audio::Store::activate(&data, &baseline)?;
        Ok(Self {
            root,
            host,
            proof,
            store,
            client_root,
        })
    }

    fn synthetic(&self) -> anyhow::Result<syncstr_headless::shared_audio_net::Snapshot> {
        let mut snapshot = self.store.snapshot()?;
        let catalog = &mut snapshot.catalog;
        let original = catalog.tracks.values().next().unwrap().clone();
        let pins = catalog.pins.values().next().unwrap().clone();
        catalog.tracks.clear();
        catalog.pins.clear();
        catalog.addresses.clear();
        for id in ["A", "B"] {
            let mut track = original.clone();
            track.id = id.into();
            track.metadata.insert("title".into(), id.into());
            catalog.tracks.insert(id.into(), track);
            catalog.pins.insert(id.into(), pins.clone());
        }
        catalog.addresses.insert("old-A".into(), "A".into());
        catalog.addresses.insert(original.id, "A".into());
        let other = "cb8379ac2098aa165029e3938a51da0bcecfc008fd6795f401178647f96c5b34".to_owned();
        catalog.objects.insert(
            other.clone(),
            syncstr_headless::shared_audio::Object {
                sha256: other.clone(),
                bytes: Some(3),
                locators: Vec::new(),
            },
        );
        for id in ["A", "B"] {
            catalog.pins.get_mut(id).unwrap().insert(other.clone());
            let track = catalog.tracks.get_mut(id).unwrap();
            track.audio.push(other.clone());
            let album = format!("edition-{id}");
            track.album_id = Some(album.clone());
            track.metadata.insert("organization".into(), serde_json::json!({
                "id": id, "sha256": track.preferred, "importedAlbumID": album,
                "imported": {"title": format!("Edition {id}"), "artist": "Track Artist", "albumArtist": "Album Artist",
                    "compilationValues": ["1"], "release": {"source": "tag:date", "value": "2020"}, "tagValues": {"edition": [id]}}
            }));
        }
        Ok(snapshot)
    }
}

async fn scripted_host(
    fixture: &Fixture,
    snapshot: std::sync::Arc<std::sync::Mutex<syncstr_headless::shared_audio_net::Snapshot>>,
) -> anyhow::Result<(
    iroh::Endpoint,
    tokio::task::JoinHandle<anyhow::Result<()>>,
    syncstr_headless::catalog_client::Host,
)> {
    let (endpoint, lock) = fixture
        .host
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let address = syncstr_headless::catalog_client::Host {
        member: fixture.host.id().to_string(),
        socket: *endpoint.addr().ip_addrs().next().unwrap(),
    };
    let serving_endpoint = endpoint.clone();
    let proof = fixture.proof.clone();
    let task = tokio::spawn(async move {
        let _lock = lock;
        while let Some(incoming) = serving_endpoint.accept().await {
            let connection = incoming.await?;
            let (mut output, mut input) = connection.accept_bi().await?;
            let hello: syncstr_headless::shared_audio_net::Hello =
                receive(&mut input, 4 * 1024 * 1024).await?;
            anyhow::ensure!(
                hello.version == 5 && hello.proof.root == proof.root,
                "wrong client hello"
            );
            syncstr_headless::shared_audio_net::authorize(
                &proof,
                &connection.remote_id().to_string(),
                false,
            )?;
            send(
                &mut output,
                &syncstr_headless::shared_audio_net::Hello {
                    version: 5,
                    proof: proof.clone(),
                    supported_operations: Vec::new(),
                },
            )
            .await?;
            output.finish()?;
            let (mut output, mut input) = connection.accept_bi().await?;
            let request: syncstr_headless::shared_audio_net::Request =
                receive(&mut input, 4096).await?;
            anyhow::ensure!(
                matches!(
                    request,
                    syncstr_headless::shared_audio_net::Request::Catalog
                ),
                "catalog-only request required"
            );
            let response = snapshot.lock().unwrap().clone();
            send(&mut output, &response).await?;
            output.finish()?;
            let _ = output.stopped().await;
        }
        Ok(())
    });
    Ok((endpoint, task, address))
}

#[tokio::test]
async fn authenticated_v5_catalog_restores_without_credentials_or_audio() -> anyhow::Result<()> {
    let fixture = Fixture::new().await?;
    let (endpoint, lock) = fixture
        .host
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let address = syncstr_headless::catalog_client::Host {
        member: fixture.host.id().to_string(),
        socket: *endpoint.addr().ip_addrs().next().unwrap(),
    };
    let server = tokio::spawn(syncstr_headless::shared_audio_net::serve(
        endpoint.clone(),
        fixture.store.clone(),
        fixture.host.clone(),
    ));
    let mut client = syncstr_headless::catalog_client::Client::open(&fixture.client_root)?;
    assert!(client.catalog()?.tracks.is_empty());
    let view = client
        .refresh(&address, [9; 32], &Default::default())
        .await?;
    assert_eq!(view.tracks.len(), 1);
    assert_eq!(view.tracks.values().next().unwrap().title, "夜の音楽");
    assert_eq!(view.playlists["LIB-A:PLAYLIST-A"].items.len(), 3);
    assert!(!fixture.client_root.join("identity/device.key").exists());
    assert_eq!(
        std::fs::read_dir(fixture.client_root.join("objects"))?.count(),
        0
    );
    assert!(matches!(
        syncstr_headless::catalog_client::Client::open(&fixture.client_root),
        Err(syncstr_headless::catalog_client::Error::ProfileBusy)
    ));
    client.shutdown();
    client.shutdown();
    assert_eq!(
        client.catalog(),
        Err(syncstr_headless::catalog_client::Error::Closed)
    );
    endpoint.close().await;
    server.await??;
    drop(lock);
    let restored = syncstr_headless::catalog_client::Client::open(&fixture.client_root)?;
    assert_eq!(restored.catalog()?, view);
    assert!(fixture.root.path().exists());
    Ok(())
}

#[tokio::test]
async fn logical_identity_exact_pins_scoped_conflicts_and_incomplete_restart() -> anyhow::Result<()>
{
    let fixture = Fixture::new().await?;
    let snapshot = std::sync::Arc::new(std::sync::Mutex::new(fixture.synthetic()?));
    let (endpoint, server, address) = scripted_host(&fixture, snapshot.clone()).await?;
    let mut client = syncstr_headless::catalog_client::Client::open(&fixture.client_root)?;
    let operation = syncstr_headless::catalog_client::Operation::default();
    let initial = client.refresh(&address, [9; 32], &operation).await?;
    assert_eq!(initial.tracks.len(), 2);
    assert_ne!(initial.tracks["A"].album_id, initial.tracks["B"].album_id);
    assert_eq!(
        initial.tracks["A"].album_artist.as_deref(),
        Some("Album Artist")
    );
    assert_eq!(
        initial.tracks["A"].release,
        Some(("tag:date".into(), "2020".into()))
    );
    assert_eq!(initial.tracks["A"].imported_tags["edition"], ["A"]);
    let playlist = &initial.playlists["LIB-A:PLAYLIST-A"];
    assert_eq!(
        playlist
            .items
            .iter()
            .map(|i| i.id.as_str())
            .collect::<Vec<_>>(),
        ["occurrence-0", "occurrence-1", "occurrence-2"]
    );
    let exact = playlist.items[0].pin.as_ref().unwrap();
    assert_ne!(exact.track_id, "A");
    assert_eq!(initial.aliases["old-A"], "A");
    assert_eq!(initial.exact_track(exact).unwrap().id, "A");
    assert_eq!(initial.audio_bytes(exact), Some(3));
    {
        let mut snapshot = snapshot.lock().unwrap();
        snapshot.catalog.tracks.get_mut("A").unwrap().preferred =
            Some("cb8379ac2098aa165029e3938a51da0bcecfc008fd6795f401178647f96c5b34".into());
    }
    let changed = client.refresh(&address, [9; 32], &operation).await?;
    assert_ne!(
        changed.tracks["A"].preferred.as_ref().unwrap().sha256,
        exact.sha256
    );
    assert_eq!(changed.playlists, initial.playlists);
    assert_eq!(changed.audio_bytes(exact), Some(3));
    {
        let mut snapshot = snapshot.lock().unwrap();
        snapshot.catalog.conflicts.insert("track:A".into());
    }
    let conflicted = client.refresh(&address, [9; 32], &operation).await?;
    assert!(conflicted.tracks["A"].conflicted);
    assert!(!conflicted.tracks["B"].conflicted);
    assert_eq!(conflicted.audio_bytes(exact), None);
    assert_eq!(conflicted.playlists, initial.playlists);
    {
        let mut snapshot = snapshot.lock().unwrap();
        snapshot.catalog.incomplete = vec!["c".repeat(64)];
        snapshot.catalog.tracks.clear();
    }
    let incomplete = client.refresh(&address, [9; 32], &operation).await?;
    assert_eq!(incomplete.tracks, conflicted.tracks);
    assert_eq!(incomplete.incomplete_records, vec!["c".repeat(64)]);
    drop(client);
    let restored = syncstr_headless::catalog_client::Client::open(&fixture.client_root)?;
    assert_eq!(restored.catalog()?, incomplete);
    drop(restored);
    *snapshot.lock().unwrap() = fixture.synthetic()?;
    let mut recovered = syncstr_headless::catalog_client::Client::open(&fixture.client_root)?;
    assert!(
        recovered
            .refresh(&address, [9; 32], &operation)
            .await?
            .incomplete_records
            .is_empty()
    );
    endpoint.close().await;
    server.await??;
    Ok(())
}

#[tokio::test]
async fn mismatches_and_cancellation_never_replace_verified_catalog() -> anyhow::Result<()> {
    let fixture = Fixture::new().await?;
    let snapshot = std::sync::Arc::new(std::sync::Mutex::new(fixture.synthetic()?));
    let (endpoint, server, address) = scripted_host(&fixture, snapshot.clone()).await?;
    let mut client = syncstr_headless::catalog_client::Client::open(&fixture.client_root)?;
    let initial = client
        .refresh(&address, [9; 32], &Default::default())
        .await?;
    assert_eq!(
        client.refresh(&address, [8; 32], &Default::default()).await,
        Err(syncstr_headless::catalog_client::Error::IdentityMismatch)
    );
    let operation = syncstr_headless::catalog_client::Operation::default();
    operation.cancel();
    assert_eq!(
        client.refresh(&address, [9; 32], &operation).await,
        Err(syncstr_headless::catalog_client::Error::Cancelled)
    );
    let silent = std::net::UdpSocket::bind("127.0.0.1:0")?;
    let unresponsive = syncstr_headless::catalog_client::Host {
        member: address.member.clone(),
        socket: silent.local_addr()?,
    };
    let running = syncstr_headless::catalog_client::Operation::default();
    let cancel = running.clone();
    let cancelling = tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        cancel.cancel();
    });
    assert_eq!(
        client.refresh(&unresponsive, [9; 32], &running).await,
        Err(syncstr_headless::catalog_client::Error::Cancelled)
    );
    cancelling.await?;
    assert_eq!(client.catalog()?, initial);
    for (field, expected) in [
        (
            "baseline",
            syncstr_headless::catalog_client::Error::BaselineMismatch,
        ),
        (
            "cluster",
            syncstr_headless::catalog_client::Error::MembershipMismatch,
        ),
        (
            "version",
            syncstr_headless::catalog_client::Error::ProtocolMismatch,
        ),
    ] {
        let clean = fixture.synthetic()?;
        {
            let mut next = snapshot.lock().unwrap();
            *next = clean;
            match field {
                "baseline" => next.catalog.baseline = "b".repeat(64),
                "cluster" => next.catalog.cluster = uuid::Uuid::new_v4().to_string(),
                _ => next.catalog.version = 2,
            }
        }
        assert_eq!(
            client.refresh(&address, [9; 32], &Default::default()).await,
            Err(expected)
        );
        assert_eq!(client.catalog()?, initial);
    }
    *snapshot.lock().unwrap() = fixture.synthetic()?;
    snapshot.lock().unwrap().playlists[0].document.items[0].track_id = Some("B".into());
    assert_eq!(
        client.refresh(&address, [9; 32], &Default::default()).await,
        Err(syncstr_headless::catalog_client::Error::InvalidCatalog)
    );
    assert_eq!(client.catalog()?, initial);
    endpoint.close().await;
    server.await??;
    Ok(())
}

#[tokio::test]
async fn apple_artwork_fixture_preserves_organization_and_ignores_empty_image_references()
-> anyhow::Result<()> {
    let fixture = Fixture::new().await?;
    let artwork: serde_json::Value =
        serde_json::from_slice(include_bytes!("../fixtures/album-artwork.json"))?;
    let mut organization: syncstr_headless::organization::Organization =
        serde_json::from_value(artwork["organization"].clone())?;
    organization.set_hidden("album-a", true)?;
    organization
        .aliases
        .insert("former-album".into(), "album-a".into());
    let mut source = fixture.synthetic()?;
    source.catalog.legacy_organization = serde_json::to_value(&organization)?;
    let snapshot = std::sync::Arc::new(std::sync::Mutex::new(source));
    let (endpoint, server, address) = scripted_host(&fixture, snapshot.clone()).await?;
    let mut client = syncstr_headless::catalog_client::Client::open(&fixture.client_root)?;
    let view = client
        .refresh(&address, [9; 32], &Default::default())
        .await?;
    assert!(view.albums["album-a"].hidden);
    assert_eq!(view.album_aliases["former-album"], "album-a");
    assert!(
        view.artwork_assets
            .contains_key(artwork["blue"].as_str().unwrap())
    );
    assert!(!view.artwork_candidates.is_empty());
    assert_eq!(view.organization_choices.len(), organization.choices.len());
    for bytes in organization.artwork.as_mut().unwrap().assets.values_mut() {
        bytes.clear();
    }
    snapshot.lock().unwrap().catalog.legacy_organization = serde_json::to_value(&organization)?;
    let empty = client
        .refresh(&address, [9; 32], &Default::default())
        .await?;
    assert!(empty.artwork_assets.is_empty());
    assert!(empty.artwork_candidates.is_empty());
    assert!(empty.albums["album-a"].hidden);
    assert_eq!(empty.tracks, view.tracks);
    drop(client);
    assert_eq!(
        syncstr_headless::catalog_client::Client::open(&fixture.client_root)?.catalog()?,
        empty
    );
    endpoint.close().await;
    server.await??;
    Ok(())
}
