#![cfg(feature = "p2p")]

#[tokio::test]
async fn quic_sync_preserves_ids_pins_and_recovers_after_reconnection() -> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let replica = fixture.replica()?;
    let store = fixture.activate()?;
    for id in ["one", "two"] {
        store.commit(
            &fixture.host,
            crate::register(&store.catalog()?, id, &fixture.entry.sha256),
        )?;
    }
    let (host_endpoint, _host_lock) = fixture
        .host
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let (peer_endpoint, _peer_lock) = fixture
        .other
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(syncstr_headless::shared_audio_net::serve(
        host_endpoint.clone(),
        store.clone(),
        fixture.host.id().to_string(),
    ));
    let (discovered, receiver) = tokio::sync::mpsc::channel(16);
    tasks.spawn(syncstr_headless::shared_audio_net::synchronize(
        peer_endpoint.clone(),
        replica.clone(),
        receiver,
    ));
    discovered.send(host_endpoint.addr()).await?;
    tokio::time::timeout(std::time::Duration::from_secs(20), async {
        loop {
            if replica.catalog()?.tracks.len() == 3
                && replica
                    .audio(&fixture.logical, &fixture.entry.sha256)
                    .is_ok()
            {
                break anyhow::Ok(());
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    })
    .await??;
    let first = replica.catalog()?;
    let one = first.correspondences[&crate::source("one").subject()].clone();
    let two = first.correspondences[&crate::source("two").subject()].clone();
    assert_ne!(one, two);
    assert_eq!(
        std::fs::read_dir(fixture.root.path().join("replica/objects"))?.count(),
        1
    );
    assert_eq!(
        store.playlists()?[0].document,
        replica.playlists()?[0].document
    );
    let cursor = replica.cursor(&fixture.host.id().to_string())?;
    assert!(cursor > 0);
    let session = syncstr_headless::shared_audio_net::Session::connect(
        &peer_endpoint,
        host_endpoint.addr(),
        replica.membership()?,
    )
    .await?;
    session
        .reconcile(&replica, &fixture.host.id().to_string())
        .await?;
    assert_eq!(replica.cursor(&fixture.host.id().to_string())?, cursor);
    drop(session);
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    let catalog = store.catalog()?;
    let mut track = catalog.tracks[&one].clone();
    track
        .metadata
        .insert("title".into(), "Changed while disconnected".into());
    let subject = format!("track:{one}");
    store.commit(
        &fixture.host,
        syncstr_headless::shared_audio::Request {
            id: "disconnected-edit".into(),
            expected: std::collections::BTreeMap::from([(
                subject.clone(),
                catalog.heads[&subject].clone(),
            )]),
            action: syncstr_headless::shared_audio::Action::EditTrack {
                track,
                evidence: crate::evidence(&catalog),
            },
        },
    )?;
    drop(replica);
    let replica =
        syncstr_headless::shared_audio::Store::open(&fixture.root.path().join("replica"))?;
    assert_eq!(
        replica.catalog()?.tracks[&one].metadata["title"],
        "Same title"
    );
    tasks.spawn(syncstr_headless::shared_audio_net::serve(
        host_endpoint.clone(),
        store.clone(),
        fixture.host.id().to_string(),
    ));
    let (discovered, receiver) = tokio::sync::mpsc::channel(16);
    tasks.spawn(syncstr_headless::shared_audio_net::synchronize(
        peer_endpoint.clone(),
        replica.clone(),
        receiver,
    ));
    discovered.send(host_endpoint.addr()).await?;
    tokio::time::timeout(std::time::Duration::from_secs(20), async {
        loop {
            if replica.catalog()?.tracks[&one].metadata["title"] == "Changed while disconnected" {
                break anyhow::Ok(());
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    })
    .await??;
    assert_eq!(replica.catalog()?.tracks[&two], first.tracks[&two]);
    assert_eq!(replica.catalog()?.addresses, first.addresses);
    assert_eq!(
        std::io::Read::bytes(replica.audio(&fixture.entry.track.id, &fixture.entry.sha256)?)
            .collect::<Result<Vec<_>, _>>()?,
        b"abc"
    );
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    host_endpoint.close().await;
    peer_endpoint.close().await;
    Ok(())
}

#[tokio::test]
async fn quic_revocation_blocks_existing_sessions_and_propagates_without_resurrection()
-> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let replica = fixture.replica()?;
    let store = fixture.activate()?;
    let reader = syncstr_headless::peer::Identity::from_secret(
        &fixture.root.path().join("reader"),
        [43; 32],
    )?;
    let (host_endpoint, _host_lock) = fixture
        .host
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let (reader_endpoint, _reader_lock) =
        reader.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let (peer_endpoint, _peer_lock) = fixture
        .other
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(syncstr_headless::shared_audio_net::serve(
        host_endpoint.clone(),
        store.clone(),
        fixture.host.id().to_string(),
    ));
    let stale_proof = store.membership()?;
    let session = syncstr_headless::shared_audio_net::Session::connect(
        &reader_endpoint,
        host_endpoint.addr(),
        stale_proof.clone(),
    )
    .await?;
    let _: syncstr_headless::shared_audio_net::Snapshot = session
        .request(syncstr_headless::shared_audio_net::Request::Catalog)
        .await?;
    session
        .download(
            &fixture.logical,
            &fixture.entry.sha256,
            &fixture.root.path().join("reader.audio"),
        )
        .await?;
    let rejected_writer = syncstr_headless::shared_audio_net::Session::connect(
        &reader_endpoint,
        host_endpoint.addr(),
        stale_proof.clone(),
    )
    .await?;
    assert!(
        rejected_writer
            .request::<bool>(syncstr_headless::shared_audio_net::Request::Receive {
                records: vec![]
            })
            .await
            .is_err()
    );
    store.revoke_member(&fixture.host, &reader.id().to_string())?;
    assert!(
        session
            .download(
                &fixture.logical,
                &fixture.entry.sha256,
                &fixture.root.path().join("after-revocation.audio")
            )
            .await
            .is_err()
    );
    assert!(!fixture.root.path().join("after-revocation.audio").exists());
    assert!(
        syncstr_headless::shared_audio_net::Session::connect(
            &reader_endpoint,
            host_endpoint.addr(),
            stale_proof.clone()
        )
        .await
        .is_err()
    );
    let peer = syncstr_headless::shared_audio_net::Session::connect(
        &peer_endpoint,
        host_endpoint.addr(),
        replica.membership()?,
    )
    .await?;
    peer.reconcile(&replica, &fixture.host.id().to_string())
        .await?;
    assert!(
        syncstr_headless::shared_audio_net::authorize(
            &replica.membership()?,
            &reader.id().to_string(),
            false
        )
        .is_err()
    );
    replica.merge_membership(stale_proof)?;
    assert!(
        syncstr_headless::shared_audio_net::authorize(
            &replica.membership()?,
            &reader.id().to_string(),
            false
        )
        .is_err()
    );
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    host_endpoint.close().await;
    reader_endpoint.close().await;
    peer_endpoint.close().await;
    Ok(())
}

#[tokio::test]
async fn quic_rejects_legacy_protocol_wrong_capability_and_different_baseline() -> anyhow::Result<()>
{
    let fixture = crate::Fixture::new().await?;
    let store = fixture.activate()?;
    let (host_endpoint, _host_lock) = fixture
        .host
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let (peer_endpoint, _peer_lock) = fixture
        .other
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(syncstr_headless::shared_audio_net::serve(
        host_endpoint.clone(),
        store.clone(),
        fixture.host.id().to_string(),
    ));
    let legacy = peer_endpoint
        .connect(host_endpoint.addr(), syncstr_headless::cluster_sync::ALPN)
        .await?;
    tokio::time::timeout(std::time::Duration::from_secs(5), legacy.closed()).await?;
    let connection = peer_endpoint
        .connect(
            host_endpoint.addr(),
            syncstr_headless::shared_audio_net::ALPN,
        )
        .await?;
    let (mut output, mut input) = connection.open_bi().await?;
    let body = serde_json::to_vec(&syncstr_headless::shared_audio_net::Hello {
        version: 4,
        proof: store.membership()?,
    })?;
    output.write_all(&(body.len() as u32).to_be_bytes()).await?;
    output.write_all(&body).await?;
    output.finish()?;
    assert!(input.read_to_end(1024).await.is_err());
    let independent = crate::Fixture::new().await?;
    let other_store = independent.activate()?;
    let before = other_store.records()?;
    let session = syncstr_headless::shared_audio_net::Session::connect(
        &peer_endpoint,
        host_endpoint.addr(),
        store.membership()?,
    )
    .await?;
    assert!(
        session
            .reconcile(&other_store, &fixture.host.id().to_string())
            .await
            .is_err()
    );
    assert_eq!(other_store.records()?, before);
    assert_eq!(other_store.cursor(&fixture.host.id().to_string())?, 0);
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    host_endpoint.close().await;
    peer_endpoint.close().await;
    Ok(())
}

struct Fixture {
    root: tempfile::TempDir,
    host: syncstr_headless::peer::Identity,
    other: syncstr_headless::peer::Identity,
    entry: syncstr_headless::model::Entry,
    logical: String,
}

impl crate::Fixture {
    async fn new() -> anyhow::Result<Self> {
        let root = tempfile::tempdir()?;
        let host =
            syncstr_headless::peer::Identity::from_secret(&root.path().join("host"), [41; 32])?;
        let other =
            syncstr_headless::peer::Identity::from_secret(&root.path().join("other"), [42; 32])?;
        let data = root.path().join("data");
        let store = syncstr_headless::store::Store::open(&data)?;
        let cluster = store.create_cluster(host.id().to_string()).await?.id;
        let invitation = store
            .create_cluster_invitation(&host, true, 100, 600)
            .await?;
        store
            .redeem_cluster_invitation(&host, &invitation.secret, other.id().to_string(), 101)
            .await?;
        let reader =
            syncstr_headless::peer::Identity::from_secret(&root.path().join("reader"), [43; 32])?;
        let invitation = store
            .create_cluster_invitation(&host, false, 100, 600)
            .await?;
        store
            .redeem_cluster_invitation(&host, &invitation.secret, reader.id().to_string(), 101)
            .await?;
        let entry: syncstr_headless::model::Entry =
            serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
        let logical = entry.track.id.clone();
        let mut organization = syncstr_headless::organization::Organization::default();
        organization.import(&entry);
        organization
            .albums
            .push(syncstr_headless::organization::Album {
                id: "chosen-album".into(),
                title: "User choice".into(),
                releases: vec![],
            });
        organization
            .choices
            .push(syncstr_headless::organization::Choice {
                id: "retained-choice".into(),
                subject: logical.clone(),
                kind: "membership".into(),
                value: Some("chosen-album".into()),
                parents: vec![],
            });
        let mut staged = store.stage().await?;
        use std::io::Write as _;
        staged.write_all(b"abc")?;
        let entry = store
            .commit_organized(entry, staged, false, Some(organization))
            .await?;
        let document = syncstr_headless::playlists::Document {
            id: "source:mix".into(),
            source_library: "source".into(),
            source_playlist: "mix".into(),
            source_fingerprint: "a".repeat(64),
            name: "Fixture".into(),
            kind: "manual".into(),
            parent: None,
            definition: Default::default(),
            items: (0..3)
                .map(|i| syncstr_headless::playlists::Item {
                    id: format!("occurrence-{i}"),
                    source_track: "17".into(),
                    title: "Title".into(),
                    artist: None,
                    album: None,
                    track_id: Some(if i == 1 {
                        logical.clone()
                    } else {
                        entry.track.id.clone()
                    }),
                    sha256: Some(entry.sha256.clone()),
                })
                .collect(),
        };
        store
            .import_playlists(&host, cluster, vec![document])
            .await?;
        drop(store);
        Ok(Self {
            root,
            host,
            other,
            entry,
            logical,
        })
    }

    fn data(&self) -> std::path::PathBuf {
        self.root.path().join("data")
    }

    fn activate(&self) -> anyhow::Result<syncstr_headless::shared_audio::Store> {
        let baseline = syncstr_headless::shared_audio::Store::inspect(&self.data())?;
        syncstr_headless::shared_audio::Store::activate(&self.data(), &baseline)
    }

    fn replica(&self) -> anyhow::Result<syncstr_headless::shared_audio::Store> {
        let path = self.root.path().join("replica");
        std::fs::create_dir_all(path.join("objects"))?;
        std::fs::create_dir_all(path.join("staging"))?;
        std::fs::write(path.join("node.lock"), b"")?;
        std::fs::copy(self.data().join("node.sqlite"), path.join("node.sqlite"))?;
        let baseline = syncstr_headless::shared_audio::Store::inspect(&path)?;
        syncstr_headless::shared_audio::Store::activate(&path, &baseline)
    }
}

fn fingerprint(catalog: &syncstr_headless::shared_audio::Catalog) -> String {
    use sha2::Digest as _;
    hex::encode(sha2::Sha256::digest(serde_json::to_vec(catalog).unwrap()))
}

fn source(track: &str) -> syncstr_headless::shared_audio::Source {
    syncstr_headless::shared_audio::Source {
        library: "LIB-A".into(),
        track: track.into(),
    }
}

fn evidence(
    catalog: &syncstr_headless::shared_audio::Catalog,
) -> syncstr_headless::shared_audio::Evidence {
    syncstr_headless::shared_audio::Evidence {
        snapshot: "a".repeat(64),
        catalog: crate::fingerprint(catalog),
        reason: "Explicit fixture approval".into(),
        audio_eligible: true,
    }
}

fn register(
    catalog: &syncstr_headless::shared_audio::Catalog,
    id: &str,
    hash: &str,
) -> syncstr_headless::shared_audio::Request {
    syncstr_headless::shared_audio::Request {
        id: format!("register-{id}"),
        expected: Default::default(),
        action: syncstr_headless::shared_audio::Action::Register {
            source: crate::source(id),
            evidence: crate::evidence(catalog),
            track: syncstr_headless::shared_audio::Track {
                id: String::new(),
                metadata: std::collections::BTreeMap::from([("title".into(), "Same title".into())]),
                album_id: Some("album-a".into()),
                added_at: None,
                retired: false,
                audio: vec![hash.into()],
                preferred: Some(hash.into()),
            },
        },
    }
}

fn payloads(path: &std::path::Path) -> anyhow::Result<Vec<Vec<u8>>> {
    let db = rusqlite::Connection::open_with_flags(
        path.join("node.sqlite"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )?;
    let mut result = vec![];
    for table in [
        "tracks",
        "organization",
        "playlist_records",
        "cluster_changes",
    ] {
        let mut statement = db.prepare(&format!("SELECT payload FROM {table} ORDER BY rowid"))?;
        result.extend(
            statement
                .query_map([], |r| r.get::<_, Vec<u8>>(0))?
                .collect::<Result<Vec<_>, _>>()?,
        );
    }
    Ok(result)
}

#[tokio::test]
async fn migration_preserves_ids_aliases_signed_playlists_and_audio_across_reopen()
-> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let before = crate::payloads(&fixture.data())?;
    let expected = syncstr_headless::shared_audio::Store::inspect(&fixture.data())?;
    let inspected = std::process::Command::new(env!("CARGO_BIN_EXE_syncstr-headless"))
        .args(["shared-audio-inspect", "--data"])
        .arg(fixture.data())
        .output()?;
    assert!(
        inspected.status.success(),
        "{}",
        String::from_utf8_lossy(&inspected.stderr)
    );
    assert_eq!(String::from_utf8(inspected.stdout)?.trim(), expected);
    assert!(
        syncstr_headless::shared_audio::Store::activate(&fixture.data(), &"0".repeat(64)).is_err()
    );
    let legacy = syncstr_headless::store::Store::open(&fixture.data())?;
    drop(legacy);
    let store = syncstr_headless::shared_audio::Store::activate(&fixture.data(), &expected)?;
    assert_eq!(before, crate::payloads(&fixture.data())?);
    let catalog = store.catalog()?;
    assert_eq!(catalog.addresses[&fixture.entry.track.id], fixture.logical);
    assert_eq!(
        catalog.tracks[&fixture.logical].album_id.as_deref(),
        Some("chosen-album")
    );
    assert_eq!(
        catalog.legacy_organization["choices"][0]["id"],
        "retained-choice"
    );
    assert_eq!(
        catalog.tracks[&fixture.logical].added_at,
        fixture.entry.track.added_at
    );
    assert!(catalog.correspondences.is_empty());
    for id in [&fixture.entry.track.id, &fixture.logical] {
        use std::io::Read as _;
        let mut bytes = vec![];
        store
            .audio(id, &fixture.entry.sha256)?
            .read_to_end(&mut bytes)?;
        assert_eq!(bytes, b"abc");
    }
    drop(store);
    assert!(syncstr_headless::store::Store::open(&fixture.data()).is_err());
    let repeated = syncstr_headless::shared_audio::Store::activate(&fixture.data(), &expected)?;
    assert_eq!(
        serde_json::to_value(repeated.catalog()?)?,
        serde_json::to_value(catalog)?
    );
    assert_eq!(before, crate::payloads(&fixture.data())?);
    Ok(())
}

#[tokio::test]
async fn registrations_share_bytes_but_keep_metadata_ids_and_pinned_playback() -> anyhow::Result<()>
{
    let fixture = crate::Fixture::new().await?;
    let before = crate::payloads(&fixture.data())?;
    let store = fixture.activate()?;
    let request = crate::register(&store.catalog()?, "one", &fixture.entry.sha256);
    let accepted = store.commit(&fixture.host, request.clone())?;
    store.commit(
        &fixture.host,
        crate::register(&store.catalog()?, "two", &fixture.entry.sha256),
    )?;
    assert_eq!(store.commit(&fixture.host, request.clone())?, accepted);
    let catalog = store.catalog()?;
    let one = catalog.correspondences[&crate::source("one").subject()].clone();
    let two = catalog.correspondences[&crate::source("two").subject()].clone();
    assert_ne!(one, two);
    assert_eq!(catalog.objects.len(), 1);
    assert_eq!(
        std::fs::read_dir(fixture.data().join("objects"))?.count(),
        1
    );
    let mut edited = catalog.tracks[&one].clone();
    edited
        .metadata
        .insert("title".into(), "Independent edit".into());
    edited.album_id = Some("album-b".into());
    let subject = format!("track:{one}");
    let update = syncstr_headless::shared_audio::Request {
        id: "edit-one".into(),
        expected: std::collections::BTreeMap::from([(
            subject.clone(),
            catalog.heads[&subject].clone(),
        )]),
        action: syncstr_headless::shared_audio::Action::EditTrack {
            track: edited,
            evidence: crate::evidence(&catalog),
        },
    };
    store.commit(&fixture.host, update.clone())?;
    assert_eq!(store.catalog()?.tracks[&two], catalog.tracks[&two]);
    let mut stale = update;
    stale.id = "stale-edit".into();
    assert!(store.commit(&fixture.host, stale).is_err());
    use sha2::Digest as _;
    let second = hex::encode(sha2::Sha256::digest(b"encoding two"));
    store.put_audio(&second, &mut &b"encoding two"[..])?;
    let latest = store.catalog()?;
    let mut edited = latest.tracks[&one].clone();
    edited.audio.push(second.clone());
    edited.preferred = Some(second);
    store.commit(
        &fixture.host,
        syncstr_headless::shared_audio::Request {
            id: "encoding".into(),
            expected: std::collections::BTreeMap::from([(
                subject.clone(),
                latest.heads[&subject].clone(),
            )]),
            action: syncstr_headless::shared_audio::Action::EditTrack {
                track: edited,
                evidence: crate::evidence(&latest),
            },
        },
    )?;
    assert!(store.audio(&one, &fixture.entry.sha256).is_ok());
    assert!(
        store
            .audio(&fixture.entry.track.id, &fixture.entry.sha256)
            .is_ok()
    );
    assert_eq!(before, crate::payloads(&fixture.data())?);
    assert!(
        store
            .commit(
                &fixture.host,
                crate::register(&store.catalog()?, "one", &fixture.entry.sha256)
            )
            .is_err()
    );
    Ok(())
}

#[tokio::test]
async fn disconnected_hosts_retain_conflicting_approvals_and_resolve_without_retargeting_playlists()
-> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let replica = fixture.replica()?;
    let store = fixture.activate()?;
    let a = store.commit(
        &fixture.host,
        crate::register(&store.catalog()?, "same", &fixture.entry.sha256),
    )?;
    let b = replica.commit(
        &fixture.other,
        crate::register(&replica.catalog()?, "same", &fixture.entry.sha256),
    )?;
    store.receive(vec![b.clone()])?;
    replica.receive(vec![a.clone()])?;
    let conflict = store.catalog()?;
    let subject = crate::source("same").subject();
    assert!(conflict.conflicts.contains(&subject));
    assert!(!conflict.correspondences.contains_key(&subject));
    assert_eq!(conflict.tracks.len(), 3);
    assert_eq!(
        serde_json::to_value(&conflict)?,
        serde_json::to_value(replica.catalog()?)?
    );
    let target = conflict
        .tracks
        .keys()
        .find(|id| *id != &fixture.logical)
        .unwrap()
        .clone();
    let resolution = store.commit(
        &fixture.host,
        syncstr_headless::shared_audio::Request {
            id: "resolve".into(),
            expected: std::collections::BTreeMap::from([(
                subject.clone(),
                conflict.heads[&subject].clone(),
            )]),
            action: syncstr_headless::shared_audio::Action::Assign {
                source: crate::source("same"),
                target: Some(target.clone()),
                evidence: crate::evidence(&conflict),
            },
        },
    )?;
    replica.receive(vec![resolution])?;
    assert_eq!(replica.catalog()?.correspondences[&subject], target);
    assert_eq!(
        store.catalog()?.addresses[&fixture.entry.track.id],
        fixture.logical
    );
    assert!(
        store
            .audio(&fixture.entry.track.id, &fixture.entry.sha256)
            .is_ok()
    );
    Ok(())
}

#[tokio::test]
async fn incomplete_history_waits_for_parents_and_rejects_tampering() -> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let replica = fixture.replica()?;
    let store = fixture.activate()?;
    let request = crate::register(&store.catalog()?, "one", &fixture.entry.sha256);
    let first = store.commit(&fixture.host, request.clone())?;
    let catalog = store.catalog()?;
    let subject = crate::source("one").subject();
    let second = store.commit(
        &fixture.host,
        syncstr_headless::shared_audio::Request {
            id: "revoke".into(),
            expected: std::collections::BTreeMap::from([(
                subject.clone(),
                catalog.heads[&subject].clone(),
            )]),
            action: syncstr_headless::shared_audio::Action::Assign {
                source: crate::source("one"),
                target: None,
                evidence: crate::evidence(&catalog),
            },
        },
    )?;
    replica.receive(vec![second.clone()])?;
    assert_eq!(replica.catalog()?.incomplete, vec![second.id.clone()]);
    assert!(replica.catalog()?.correspondences.is_empty());
    let mut forged = first.clone();
    forged.signature = "00".repeat(64);
    assert!(replica.receive(vec![forged]).is_err());
    replica.receive(vec![first.clone()])?;
    assert_eq!(replica.commit(&fixture.other, request)?, first);
    assert!(replica.catalog()?.incomplete.is_empty());
    assert!(!replica.catalog()?.correspondences.contains_key(&subject));
    assert_eq!(replica.catalog()?.tracks.len(), 2);
    Ok(())
}

#[tokio::test]
async fn distinct_libraries_and_unavailable_registrations_never_share_logical_identity()
-> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let store = fixture.activate()?;
    store.commit(
        &fixture.host,
        crate::register(&store.catalog()?, "same-id", &fixture.entry.sha256),
    )?;
    let mut request = crate::register(&store.catalog()?, "same-id", &fixture.entry.sha256);
    request.id = "different-library".into();
    if let syncstr_headless::shared_audio::Action::Register {
        source,
        track,
        evidence,
    } = &mut request.action
    {
        source.library = "LIB-B".into();
        track.audio.clear();
        track.preferred = None;
        track.metadata.clear();
        evidence.audio_eligible = false;
        evidence.reason = "Protected or unavailable; preserve reference only".into();
    }
    store.commit(&fixture.host, request)?;
    let catalog = store.catalog()?;
    let first = &catalog.correspondences[&crate::source("same-id").subject()];
    let second_source = syncstr_headless::shared_audio::Source {
        library: "LIB-B".into(),
        track: "same-id".into(),
    };
    let second = &catalog.correspondences[&second_source.subject()];
    assert_ne!(first, second);
    assert!(catalog.tracks[second].audio.is_empty());
    assert!(store.audio(second, &fixture.entry.sha256).is_err());
    let before = store.records()?;
    let mut invalid = crate::register(&catalog, "", &fixture.entry.sha256);
    invalid.id = "invalid".into();
    assert!(store.commit(&fixture.host, invalid).is_err());
    assert_eq!(before, store.records()?);
    let assignment = syncstr_headless::shared_audio::Request {
        id: "collapsing-assignment".into(),
        expected: std::collections::BTreeMap::from([(
            second_source.subject(),
            catalog.heads[&second_source.subject()].clone(),
        )]),
        action: syncstr_headless::shared_audio::Action::Assign {
            source: second_source,
            target: Some(first.clone()),
            evidence: crate::evidence(&catalog),
        },
    };
    assert!(store.commit(&fixture.host, assignment).is_err());
    Ok(())
}

#[tokio::test]
async fn https_client_replicates_tracks_and_verifies_pinned_bytes_while_legacy_writes_fail()
-> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let replica = fixture.replica()?;
    let store = fixture.activate()?;
    let tls_dir = fixture.root.path().join("tls");
    syncstr_headless::identity::initialize(&tls_dir, "localhost")?;
    let tls = syncstr_headless::identity::tls(&tls_dir).await?;
    let token = syncstr_headless::identity::token(&tls_dir.join("token"))?;
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let origin = format!("https://localhost:{}", listener.local_addr()?.port());
    let handle = axum_server::Handle::new();
    let signer = std::sync::Arc::new(syncstr_headless::peer::Identity::from_secret(
        &fixture.root.path().join("host"),
        [41; 32],
    )?);
    let task = tokio::spawn(
        axum_server::from_tcp_rustls(listener, tls)?
            .handle(handle.clone())
            .serve(
                syncstr_headless::shared_audio_api::router(store.clone(), signer, &token)
                    .into_make_service(),
            ),
    );
    handle.listening().await;
    let client = syncstr_headless::client::Client::new(
        &origin,
        &tls_dir.join("tls.crt"),
        &tls_dir.join("token"),
    )?;
    let http = reqwest::Client::builder()
        .https_only(true)
        .no_proxy()
        .tls_certs_only([reqwest::Certificate::from_pem(&std::fs::read(
            tls_dir.join("tls.crt"),
        )?)?])
        .build()?;
    assert_eq!(
        http.get(format!("{origin}/v5/catalog"))
            .send()
            .await?
            .status(),
        reqwest::StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        http.post(format!("{origin}/v4/tracks"))
            .bearer_auth(&token)
            .send()
            .await?
            .status(),
        reqwest::StatusCode::UPGRADE_REQUIRED
    );
    for id in ["one", "two"] {
        let preview = client.shared_catalog().await?;
        client
            .shared_commit(&crate::register(&preview, id, &fixture.entry.sha256))
            .await?;
    }
    let original = client.shared_playlists().await?.remove(0);
    let catalog = client.shared_catalog().await?;
    let target = catalog.correspondences[&crate::source("one").subject()].clone();
    let mut document = original.document.clone();
    document.items[0].track_id = Some(target);
    let mut update = syncstr_headless::shared_audio::PlaylistUpdate {
        documents: vec![document.clone()],
        expected: std::collections::BTreeMap::from([(
            document.id.clone(),
            original.revisions.clone(),
        )]),
        confirmed_replacements: false,
    };
    assert!(client.shared_update_playlists(&update).await.is_err());
    update.confirmed_replacements = true;
    let saved = client.shared_update_playlists(&update).await?;
    assert_eq!(
        client.shared_update_playlists(&update).await?.len(),
        saved.len()
    );
    let updated = client.shared_playlists().await?.remove(0);
    assert_eq!(updated.document.items[1..], original.document.items[1..]);
    assert_eq!(updated.document.items[0].id, original.document.items[0].id);
    assert_eq!(updated.document.id, original.document.id);
    assert_eq!(
        updated.document.source_fingerprint,
        original.document.source_fingerprint
    );
    client.shared_pull(&replica).await?;
    assert_eq!(replica.playlists()?[0].document, updated.document);
    assert_eq!(replica.catalog()?.tracks.len(), 3);
    let cursor = replica.cursor(&format!("{origin}/"))?;
    assert_eq!(cursor, 2);
    client.shared_pull(&replica).await?;
    assert_eq!(replica.cursor(&format!("{origin}/"))?, cursor);
    let catalog = replica.catalog()?;
    for id in catalog.correspondences.values() {
        client
            .shared_fetch_audio(id, &fixture.entry.sha256, &replica)
            .await?;
        use std::io::Read as _;
        let mut bytes = vec![];
        replica
            .audio(id, &fixture.entry.sha256)?
            .read_to_end(&mut bytes)?;
        assert_eq!(bytes, b"abc");
    }
    assert_eq!(
        std::fs::read_dir(fixture.root.path().join("replica/objects"))?.count(),
        1
    );
    let audio_url = format!(
        "{origin}/v5/tracks/{}/audio/{}",
        fixture.entry.track.id, fixture.entry.sha256
    );
    let range = http
        .get(&audio_url)
        .bearer_auth(&token)
        .header(reqwest::header::RANGE, "bytes=1-2")
        .send()
        .await?;
    assert_eq!(range.status(), reqwest::StatusCode::PARTIAL_CONTENT);
    assert_eq!(&range.bytes().await?[..], b"bc");
    assert_eq!(
        http.get(audio_url)
            .bearer_auth(&token)
            .header(reqwest::header::RANGE, "bytes=9-10")
            .send()
            .await?
            .status(),
        reqwest::StatusCode::RANGE_NOT_SATISFIABLE
    );
    handle.graceful_shutdown(Some(std::time::Duration::from_secs(1)));
    task.await??;
    Ok(())
}

#[tokio::test]
async fn failed_migration_rolls_back_schema_and_preserves_legacy_payloads() -> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let before = crate::payloads(&fixture.data())?;
    let expected = syncstr_headless::shared_audio::Store::inspect(&fixture.data())?;
    let db = rusqlite::Connection::open(fixture.data().join("node.sqlite"))?;
    db.execute_batch("CREATE TABLE shared_baseline (singleton INTEGER PRIMARY KEY, fingerprint TEXT, payload BLOB);
        CREATE TRIGGER reject_migration BEFORE INSERT ON shared_baseline BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")?;
    assert!(syncstr_headless::shared_audio::Store::activate(&fixture.data(), &expected).is_err());
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))?,
        4
    );
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE name='shared_records'",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    assert_eq!(before, crate::payloads(&fixture.data())?);
    db.execute_batch("DROP TRIGGER reject_migration; DROP TABLE shared_baseline;")?;
    drop(db);
    assert!(syncstr_headless::shared_audio::Store::activate(&fixture.data(), &expected).is_ok());
    Ok(())
}

#[tokio::test]
async fn competing_sources_cannot_claim_one_legacy_track_after_replication() -> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let replica = fixture.replica()?;
    let store = fixture.activate()?;
    let claim = |catalog: &syncstr_headless::shared_audio::Catalog, name: &str| {
        syncstr_headless::shared_audio::Request {
            id: format!("claim-{name}"),
            expected: Default::default(),
            action: syncstr_headless::shared_audio::Action::Assign {
                source: crate::source(name),
                target: Some(fixture.logical.clone()),
                evidence: crate::evidence(catalog),
            },
        }
    };
    let a = store.commit(&fixture.host, claim(&store.catalog()?, "a"))?;
    let b = replica.commit(&fixture.other, claim(&replica.catalog()?, "b"))?;
    store.receive(vec![b])?;
    replica.receive(vec![a])?;
    let catalog = store.catalog()?;
    assert_eq!(catalog.conflicts.len(), 2);
    assert!(catalog.correspondences.is_empty());
    let subject = crate::source("a").subject();
    let revoked = store.commit(
        &fixture.host,
        syncstr_headless::shared_audio::Request {
            id: "release-conflicting-claim".into(),
            expected: std::collections::BTreeMap::from([(
                subject.clone(),
                catalog.heads[&subject].clone(),
            )]),
            action: syncstr_headless::shared_audio::Action::Assign {
                source: crate::source("a"),
                target: None,
                evidence: crate::evidence(&catalog),
            },
        },
    )?;
    replica.receive(vec![revoked])?;
    assert_eq!(
        store.catalog()?.correspondences[&crate::source("b").subject()],
        fixture.logical
    );
    assert!(store.catalog()?.conflicts.is_empty());
    assert_eq!(
        store.playlists()?[0].document,
        replica.playlists()?[0].document
    );
    assert!(
        store
            .audio(&fixture.entry.track.id, &fixture.entry.sha256)
            .is_ok()
    );
    Ok(())
}
