#![cfg(feature = "p2p")]

#[cfg(unix)]
mod lock_lifetime {
    use std::io::{Read, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::{net::UnixStream, process::CommandExt};
    use std::process::{Command, Stdio};

    fn releases_before_child_exec<T: Clone>(
        owner: T,
        reopen: impl Fn() -> anyhow::Result<T>,
    ) -> anyhow::Result<()> {
        assert!(reopen().is_err(), "a live owner must exclude another store");
        let cloned_owner = owner.clone();
        let (mut parent, child_gate) = UnixStream::pair()?;
        parent.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
        let launch = std::thread::spawn(move || {
            let mut command = Command::new(env!("CARGO_BIN_EXE_syncstr-headless"));
            command
                .arg("--help")
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            // Only async-signal-safe calls run in the child before exec.
            unsafe {
                command.pre_exec(move || {
                    let fd = child_gate.as_raw_fd();
                    let pid = libc::getpid().to_ne_bytes();
                    if libc::write(fd, pid.as_ptr().cast(), pid.len()) != pid.len() as isize {
                        return Err(std::io::Error::last_os_error());
                    }
                    let mut release = 0u8;
                    if libc::read(fd, (&mut release as *mut u8).cast(), 1) != 1 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
            command.status()
        });
        let mut pid = [0u8; std::mem::size_of::<libc::pid_t>()];
        let ready = parent.read_exact(&mut pid);
        let started = std::time::Instant::now();
        drop(owner);
        let clone_still_excludes = reopen().is_err();
        drop(cloned_owner);
        let reopened = reopen();
        let elapsed = started.elapsed();
        // Release and join even on a failed assertion; never leave a blocked child.
        let released = parent.write_all(&[1]);
        let child = launch
            .join()
            .map_err(|_| anyhow::anyhow!("child launcher panicked"))??;
        ready?;
        released?;
        assert!(child.success());
        assert!(
            clone_still_excludes,
            "dropping one clone must retain ownership"
        );
        eprintln!(
            "node.lock inherited by child {} for {:?} before exec",
            libc::pid_t::from_ne_bytes(pid),
            elapsed
        );
        assert!(
            reopened.is_ok(),
            "last owner dropped while child retained its FD: {:?}",
            reopened.err()
        );
        Ok(())
    }

    #[tokio::test]
    async fn legacy_store_ownership_ends_before_a_child_execs() -> anyhow::Result<()> {
        let fixture = crate::Fixture::new().await?;
        releases_before_child_exec(
            syncstr_headless::store::Store::open(&fixture.data())?,
            || syncstr_headless::store::Store::open(&fixture.data()),
        )
    }

    #[tokio::test]
    async fn v5_store_ownership_ends_before_a_child_execs() -> anyhow::Result<()> {
        let fixture = crate::Fixture::new().await?;
        releases_before_child_exec(fixture.activate()?, || fixture.activate())
    }
}

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
        fixture.host.clone(),
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
        fixture.host.clone(),
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
async fn quic_catalog_and_unrelated_playlist_updates_survive_replicated_playlist_conflicts()
-> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let replica = fixture.replica()?;
    let store = fixture.activate()?;
    for id in ["one", "two"] {
        store.commit(
            &fixture.host,
            crate::register(&store.catalog()?, id, &fixture.entry.sha256),
        )?;
    }
    replica.receive(store.records()?)?;
    let original = store.playlists()?.remove(0);
    assert!(!original.conflicted);
    let mut unrelated = original.document.clone();
    unrelated.id = "source:unrelated".into();
    unrelated.source_playlist = "unrelated".into();
    store.update_playlists(
        &fixture.host,
        syncstr_headless::shared_audio::PlaylistUpdate {
            documents: vec![unrelated.clone()],
            expected: Default::default(),
            confirmed_replacements: false,
        },
    )?;
    let host_peer = format!("{}/playlists", fixture.host.id());
    let other_peer = format!("{}/playlists", fixture.other.id());
    replica.receive_playlist_page(&host_peer, 0, store.playlist_page(0)?)?;
    let before_conflict = replica.cursor(&host_peer)?;
    let catalog = store.catalog()?;
    let mut a = original.document.clone();
    a.items[0].track_id = Some(catalog.correspondences[&crate::source("one").subject()].clone());
    let mut b = original.document.clone();
    b.items[0].track_id = Some(catalog.correspondences[&crate::source("two").subject()].clone());
    let expected = std::collections::BTreeMap::from([(
        original.document.id.clone(),
        original.revisions.clone(),
    )]);
    let a = store.update_playlists(
        &fixture.host,
        syncstr_headless::shared_audio::PlaylistUpdate {
            documents: vec![a],
            expected: expected.clone(),
            confirmed_replacements: true,
        },
    )?;
    let b = replica.update_playlists(
        &fixture.other,
        syncstr_headless::shared_audio::PlaylistUpdate {
            documents: vec![b],
            expected,
            confirmed_replacements: true,
        },
    )?;
    store.receive_playlist_page(&other_peer, 0, replica.playlist_page(0)?)?;
    replica.receive_playlist_page(
        &host_peer,
        before_conflict,
        store.playlist_page(before_conflict)?,
    )?;
    let mut heads = vec![a[0].id.clone(), b[0].id.clone()];
    heads.sort();
    for node in [&store, &replica] {
        let snapshot = node.snapshot()?;
        assert_eq!(snapshot.catalog.tracks.len(), 3);
        assert_eq!(snapshot.playlists.len(), 2);
        let conflict = snapshot
            .playlists
            .iter()
            .find(|p| p.document.id == original.document.id)
            .unwrap();
        assert!(conflict.conflicted);
        assert_eq!(conflict.revisions, heads);
        for record in [&a[0], &b[0]] {
            assert!(snapshot.playlist_history.iter().any(|r| {
                r.id == record.id && r.payload == record.payload && r.signature == record.signature
            }));
        }
        let healthy = node
            .playlists()?
            .into_iter()
            .find(|p| p.document.id == unrelated.id)
            .unwrap();
        assert!(!healthy.conflicted);
        assert_eq!(healthy.document, unrelated);
    }
    let history = store.snapshot()?.playlist_history.len();
    assert!(
        store
            .update_playlists(
                &fixture.host,
                syncstr_headless::shared_audio::PlaylistUpdate {
                    documents: vec![original.document.clone()],
                    expected: std::collections::BTreeMap::from([(
                        original.document.id.clone(),
                        heads.clone(),
                    )]),
                    confirmed_replacements: true,
                },
            )
            .unwrap_err()
            .to_string()
            .contains("playlist conflict requires resolution")
    );
    assert_eq!(store.snapshot()?.playlist_history.len(), history);
    let healthy = store
        .playlists()?
        .into_iter()
        .find(|p| p.document.id == unrelated.id)
        .unwrap();
    unrelated.items[0].track_id =
        Some(catalog.correspondences[&crate::source("one").subject()].clone());
    store.update_playlists(
        &fixture.host,
        syncstr_headless::shared_audio::PlaylistUpdate {
            documents: vec![unrelated.clone()],
            expected: std::collections::BTreeMap::from([(unrelated.id.clone(), healthy.revisions)]),
            confirmed_replacements: true,
        },
    )?;
    assert_eq!(
        store
            .playlists()?
            .into_iter()
            .find(|p| p.document.id == unrelated.id)
            .unwrap()
            .document,
        unrelated
    );
    // Record replication does not copy audio into the replica's empty object store.
    let mut audio = store.audio(&fixture.logical, &fixture.entry.sha256)?;
    replica.put_audio(&fixture.entry.sha256, &mut audio)?;
    let reader = syncstr_headless::peer::Identity::from_secret(
        &fixture.root.path().join("reader"),
        [43; 32],
    )?;
    let (host_endpoint, _host_lock) = fixture
        .other
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let (reader_endpoint, _reader_lock) =
        reader.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(syncstr_headless::shared_audio_net::serve(
        host_endpoint.clone(),
        replica.clone(),
        fixture.other.clone(),
    ));
    let session = syncstr_headless::shared_audio_net::Session::connect(
        &reader_endpoint,
        host_endpoint.addr(),
        replica.membership()?,
    )
    .await?;
    let snapshot: syncstr_headless::shared_audio_net::Snapshot = session
        .request(syncstr_headless::shared_audio_net::Request::Catalog)
        .await?;
    assert_eq!(snapshot.catalog.tracks.len(), 3);
    assert!(snapshot.playlists.iter().any(|p| {
        p.document.id == original.document.id && p.conflicted && p.revisions == heads
    }));
    assert!(snapshot.playlists.iter().any(|p| {
        p.document.id == healthy.document.id && !p.conflicted && p.document == healthy.document
    }));
    let downloaded = fixture.root.path().join("during-playlist-conflict.audio");
    session
        .download(&fixture.logical, &fixture.entry.sha256, &downloaded)
        .await?;
    assert_eq!(std::fs::read(downloaded)?, b"abc");
    drop(session);
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    host_endpoint.close().await;
    reader_endpoint.close().await;
    Ok(())
}

#[tokio::test]
async fn unrelated_playlist_updates_do_not_validate_a_conflicted_source_structure()
-> anyhow::Result<()> {
    use sha2::Digest as _;
    let fixture = crate::Fixture::new().await?;
    let store = fixture.activate()?;
    let original = store.playlists()?.remove(0);
    let proof = store.membership()?;
    let mut page = Vec::new();
    for (sequence, signer) in [(1, &fixture.host), (2, &fixture.other)] {
        let mut document = original.document.clone();
        document.id = "source:conflicted".into();
        document.source_playlist = "conflicted".into();
        document.parent = Some(format!("source:missing-{sequence}"));
        let grant = proof
            .grants
            .iter()
            .find(|g| g.member == signer.id().to_string() && g.host)
            .unwrap();
        let body = syncstr_headless::playlists::Body {
            version: 1,
            cluster: grant.cluster.clone(),
            author: signer.id().to_string(),
            grant: grant.id.clone(),
            document,
            parents: vec![],
        };
        let payload = format!("syncstr-playlist-v1\n{}", serde_json::to_string(&body)?);
        page.push((
            sequence,
            syncstr_headless::playlists::Signed {
                id: hex::encode(sha2::Sha256::digest(payload.as_bytes())),
                signature: hex::encode(signer.sign(payload.as_bytes())),
                payload,
            },
        ));
    }
    store.receive_playlist_page(&format!("{}/playlists", fixture.other.id()), 0, page)?;
    let snapshot = store.snapshot()?;
    assert!(
        snapshot
            .playlists
            .iter()
            .any(|p| p.document.id == "source:conflicted" && p.conflicted)
    );
    store.update_playlists(
        &fixture.host,
        syncstr_headless::shared_audio::PlaylistUpdate {
            documents: vec![original.document.clone()],
            expected: std::collections::BTreeMap::from([(
                original.document.id,
                original.revisions,
            )]),
            confirmed_replacements: false,
        },
    )?;
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
        fixture.host.clone(),
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
async fn quic_authorizes_hello_before_persisting_new_membership() -> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let store = fixture.replica()?;
    let before = store.membership()?;
    let new_member = syncstr_headless::peer::Identity::from_secret(
        &fixture.root.path().join("new-member"),
        [44; 32],
    )?;
    let outsider = syncstr_headless::peer::Identity::from_secret(
        &fixture.root.path().join("outsider"),
        [45; 32],
    )?;
    let enrollment =
        syncstr_headless::store::Store::open(&fixture.root.path().join("enroller-data"))?;
    let authority = before
        .grants
        .iter()
        .find(|g| g.member == fixture.other.id().to_string())
        .unwrap();
    enrollment
        .join_cluster(
            &fixture.other,
            fixture.host.id(),
            authority.id.clone(),
            before.clone(),
        )
        .await?;
    let invitation = enrollment
        .create_cluster_invitation(&fixture.other, false, 200, 600)
        .await?;
    let grant = enrollment
        .redeem_cluster_invitation(
            &fixture.other,
            &invitation.secret,
            new_member.id().to_string(),
            201,
        )
        .await?;
    let reader = before
        .grants
        .iter()
        .find(|g| !g.host)
        .unwrap()
        .member
        .clone();
    let revocation = enrollment
        .revoke_cluster_member(&fixture.other, reader.clone())
        .await?;
    let incoming = enrollment.cluster_membership_proof().await?;
    assert_eq!(incoming.verify(&grant.id)?, &grant);
    assert!(
        syncstr_headless::shared_audio_net::authorize(&before, &new_member.id().to_string(), false)
            .is_err()
    );
    let (host_endpoint, _host_lock) = fixture
        .host
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let (outsider_endpoint, _outsider_lock) =
        outsider.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let (peer_endpoint, _peer_lock) = fixture
        .other
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let (new_endpoint, _new_lock) = new_member
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(syncstr_headless::shared_audio_net::serve(
        host_endpoint.clone(),
        store.clone(),
        fixture.host.clone(),
    ));
    assert!(
        syncstr_headless::shared_audio_net::Session::connect(
            &outsider_endpoint,
            host_endpoint.addr(),
            incoming.clone(),
        )
        .await
        .is_err()
    );
    let unchanged = store.membership()?;
    assert_eq!(unchanged.root, before.root);
    assert_eq!(unchanged.grants, before.grants);
    assert_eq!(unchanged.revocations, before.revocations);
    // The reader remains authorized until a member presents the revocation.
    syncstr_headless::shared_audio_net::authorize(&unchanged, &reader, false)?;
    let peer = syncstr_headless::shared_audio_net::Session::connect(
        &peer_endpoint,
        host_endpoint.addr(),
        before.clone(),
    )
    .await?;
    let _: syncstr_headless::shared_audio_net::Snapshot = peer
        .request(syncstr_headless::shared_audio_net::Request::Catalog)
        .await?;
    let member = syncstr_headless::shared_audio_net::Session::connect(
        &new_endpoint,
        host_endpoint.addr(),
        incoming,
    )
    .await?;
    let _: syncstr_headless::shared_audio_net::Snapshot = member
        .request(syncstr_headless::shared_audio_net::Request::Catalog)
        .await?;
    let merged = store.membership()?;
    assert!(merged.grants.contains(&grant));
    assert!(merged.revocations.contains(&revocation));
    assert!(syncstr_headless::shared_audio_net::authorize(&merged, &reader, false).is_err());
    let _: syncstr_headless::shared_audio_net::Snapshot = peer
        .request(syncstr_headless::shared_audio_net::Request::Catalog)
        .await?;
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    host_endpoint.close().await;
    outsider_endpoint.close().await;
    peer_endpoint.close().await;
    new_endpoint.close().await;
    Ok(())
}

#[tokio::test]
async fn quic_rejected_hello_does_not_persist_peer_or_host_revocations() -> anyhow::Result<()> {
    for revoke_host in [false, true] {
        let fixture = crate::Fixture::new().await?;
        let store = fixture.replica()?;
        let before = store.membership()?;
        let source = fixture.activate()?;
        let revoked = if revoke_host {
            fixture.host.id()
        } else {
            fixture.other.id()
        };
        source.revoke_member(&fixture.host, &revoked.to_string())?;
        let incoming = source.membership()?;
        if revoke_host {
            syncstr_headless::shared_audio_net::authorize(
                &incoming,
                &fixture.other.id().to_string(),
                false,
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
            fixture.host.clone(),
        ));
        assert!(
            syncstr_headless::shared_audio_net::Session::connect(
                &peer_endpoint,
                host_endpoint.addr(),
                incoming,
            )
            .await
            .is_err()
        );
        let unchanged = store.membership()?;
        assert_eq!(unchanged.root, before.root);
        assert_eq!(unchanged.grants, before.grants);
        assert_eq!(unchanged.revocations, before.revocations);
        tasks.abort_all();
        while tasks.join_next().await.is_some() {}
        host_endpoint.close().await;
        peer_endpoint.close().await;
    }
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
        fixture.host.clone(),
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
        supported_operations: vec![],
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

#[tokio::test]
async fn quic_mutation_replies_preserve_session_and_existing_requests() -> anyhow::Result<()> {
    use syncstr_headless::shared_audio_net::{
        MutationRejection, MutationReply, MutationRequest, Request,
    };
    let fixture = crate::Fixture::new().await?;
    let store = fixture.activate()?;
    let before = store.catalog()?;
    let records = store.records()?;
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
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(syncstr_headless::shared_audio_net::serve(
        host_endpoint.clone(),
        store.clone(),
        fixture.host.clone(),
    ));
    let session = syncstr_headless::shared_audio_net::Session::connect(
        &reader_endpoint,
        host_endpoint.addr(),
        store.membership()?,
    )
    .await?;
    assert_eq!(session.supported_operations, ["edit-track"]);
    let mutation = MutationRequest {
        request: "b6f1c0de-1f2a-4c3b-9d4e-5a6b7c8d9e0f".into(),
        cluster: before.cluster.clone(),
        baseline: before.baseline.clone(),
        operation: "edit-track".into(),
        expected: before.heads.clone(),
        payload: serde_json::json!({"track": fixture.logical, "metadata": {"title": "Example Song"}}),
        confirmed: vec![],
    };
    assert_eq!(
        serde_json::to_value(Request::Mutation {
            mutation: mutation.clone()
        })?,
        serde_json::json!({"operation": "mutation", "mutation": {
            "request": mutation.request, "cluster": before.cluster, "baseline": before.baseline,
            "operation": "edit-track", "expected": before.heads,
            "payload": mutation.payload, "confirmed": []
        }})
    );
    for operation in [
        "put-object",
        "register-track",
        "resolve-track",
        "assign-source",
        "update-playlists",
        "future-operation",
    ] {
        let mut unsupported = mutation.clone();
        unsupported.operation = operation.into();
        let reply: MutationReply = session
            .request(Request::Mutation {
                mutation: unsupported,
            })
            .await?;
        assert_eq!(
            reply,
            MutationReply::Unsupported {
                request: mutation.request.clone(),
                operation: operation.into(),
            }
        );
        let snapshot: syncstr_headless::shared_audio_net::Snapshot =
            session.request(Request::Catalog).await?;
        assert_eq!(
            crate::fingerprint(&snapshot.catalog),
            crate::fingerprint(&before)
        );
    }
    for (cluster_mismatch, baseline_mismatch, reason) in [
        (true, false, MutationRejection::ClusterMismatch),
        (false, true, MutationRejection::BaselineMismatch),
        (true, true, MutationRejection::ClusterMismatch),
    ] {
        let mut mismatched = mutation.clone();
        if cluster_mismatch {
            mismatched.cluster = "different-cluster".into();
        }
        if baseline_mismatch {
            mismatched.baseline = "0".repeat(64);
        }
        let reply: MutationReply = session
            .request(Request::Mutation {
                mutation: mismatched,
            })
            .await?;
        assert_eq!(
            reply,
            MutationReply::Rejected {
                request: mutation.request.clone(),
                reason
            }
        );
        let _: syncstr_headless::shared_audio_net::Snapshot =
            session.request(Request::Catalog).await?;
    }
    let db = rusqlite::Connection::open(fixture.data().join("node.sqlite"))?;
    for table in ["shared_baseline", "cluster_enrollment_grants"] {
        db.execute_batch(&format!(
            "ALTER TABLE {table} RENAME TO temporarily_unavailable"
        ))?;
        let reply: MutationReply = session
            .request(Request::Mutation {
                mutation: mutation.clone(),
            })
            .await?;
        db.execute_batch(&format!(
            "ALTER TABLE temporarily_unavailable RENAME TO {table}"
        ))?;
        assert_eq!(
            reply,
            MutationReply::Deferred {
                request: mutation.request.clone(),
                reason: "store-unavailable".into(),
            }
        );
        let _: syncstr_headless::shared_audio_net::Snapshot =
            session.request(Request::Catalog).await?;
    }
    let page: Vec<(i64, syncstr_headless::shared_audio::Signed)> =
        session.request(Request::Records { after: 0 }).await?;
    assert_eq!(page, store.page(0)?);
    let playlists: Vec<(i64, syncstr_headless::playlists::Signed)> = session
        .request(Request::PlaylistRecords { after: 0 })
        .await?;
    assert_eq!(
        serde_json::to_value(playlists)?,
        serde_json::to_value(store.playlist_page(0)?)?
    );
    let downloaded = fixture.root.path().join("after-mutations.audio");
    session
        .download(&fixture.logical, &fixture.entry.sha256, &downloaded)
        .await?;
    assert_eq!(std::fs::read(downloaded)?, b"abc");
    assert_eq!(store.records()?, records);
    assert_eq!(
        crate::fingerprint(&store.catalog()?),
        crate::fingerprint(&before)
    );
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    host_endpoint.close().await;
    reader_endpoint.close().await;
    Ok(())
}

fn metadata_edit(
    catalog: &syncstr_headless::shared_audio::Catalog,
    request: &str,
    track: &str,
    metadata: serde_json::Value,
) -> syncstr_headless::shared_audio_net::MutationRequest {
    let subject = format!("track:{track}");
    syncstr_headless::shared_audio_net::MutationRequest {
        request: request.into(),
        cluster: catalog.cluster.clone(),
        baseline: catalog.baseline.clone(),
        operation: "edit-track".into(),
        expected: std::collections::BTreeMap::from([(
            subject.clone(),
            catalog.heads.get(&subject).cloned().unwrap_or_default(),
        )]),
        payload: serde_json::json!({"track": track, "metadata": metadata}),
        confirmed: vec![],
    }
}

#[tokio::test]
async fn quic_member_metadata_edits_are_independent_atomic_and_record_origin() -> anyhow::Result<()>
{
    use syncstr_headless::shared_audio_net::{MutationRejection, MutationReply, Request, Session};
    let fixture = crate::Fixture::new().await?;
    let store = fixture.activate()?;
    for id in ["one", "two"] {
        store.commit(
            &fixture.host,
            crate::register(&store.catalog()?, id, &fixture.entry.sha256),
        )?;
    }
    let before = store.catalog()?;
    let one = before.correspondences[&crate::source("one").subject()].clone();
    let two = before.correspondences[&crate::source("two").subject()].clone();
    let subject = format!("track:{one}");
    for signed in store.records()? {
        let raw: serde_json::Value =
            serde_json::from_str(signed.payload.split_once('\n').unwrap().1)?;
        assert!(raw.get("origin").is_none());
        let body: syncstr_headless::shared_audio::Body = serde_json::from_value(raw)?;
        assert!(body.origin.is_none());
    }
    let reader = syncstr_headless::peer::Identity::from_secret(
        &fixture.root.path().join("reader"),
        [43; 32],
    )?;
    let proof = store.membership()?;
    let reader_grant = proof
        .grants
        .iter()
        .find(|g| g.member == reader.id().to_string())
        .unwrap();
    let (host_endpoint, _host_lock) = fixture
        .host
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let (reader_endpoint, _reader_lock) =
        reader.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(syncstr_headless::shared_audio_net::serve(
        host_endpoint.clone(),
        store.clone(),
        fixture.host.clone(),
    ));
    let session = Session::connect(&reader_endpoint, host_endpoint.addr(), proof.clone()).await?;
    let edit = metadata_edit(
        &before,
        "member-edit",
        &one,
        serde_json::json!({"artist": "Member artist"}),
    );
    let accepted = session.edit_track(edit.clone()).await?;
    let record = match &accepted {
        MutationReply::Accepted {
            record,
            host,
            heads,
            ..
        } => {
            assert_eq!(host, &fixture.host.id().to_string());
            assert_eq!(
                heads,
                &std::collections::BTreeMap::from([(subject.clone(), vec![record.clone()])])
            );
            record.clone()
        }
        other => anyhow::bail!("unexpected edit reply: {other:?}"),
    };
    let signed = store
        .records()?
        .into_iter()
        .find(|r| r.id == record)
        .unwrap();
    let body: syncstr_headless::shared_audio::Body =
        serde_json::from_str(signed.payload.split_once('\n').unwrap().1)?;
    assert_eq!(
        body.origin,
        Some(syncstr_headless::shared_audio::Origin {
            member: reader.id().to_string(),
            grant: reader_grant.id.clone()
        })
    );
    assert_eq!(body.edits.len(), 1);
    assert_eq!(body.edits[0].value.subject(), subject);
    assert_eq!(body.author, fixture.host.id().to_string());
    let signature: [u8; 64] = hex::decode(&signed.signature)?.try_into().unwrap();
    fixture.host.id().verify(
        signed.payload.as_bytes(),
        &iroh::Signature::from_bytes(&signature),
    )?;
    let after = store.catalog()?;
    assert_eq!(after.tracks[&one].metadata["artist"], "Member artist");
    assert_eq!(
        after.tracks[&one].metadata["title"],
        before.tracks[&one].metadata["title"]
    );
    assert_eq!(after.tracks[&two], before.tracks[&two]);
    assert_eq!(
        serde_json::to_value(&after.objects)?,
        serde_json::to_value(&before.objects)?
    );
    assert_eq!(after.pins, before.pins);
    assert_eq!(after.legacy_organization, before.legacy_organization);
    let records = store.records()?;
    let mut stale = edit.clone();
    stale.request = "stale-member-edit".into();
    stale.payload["metadata"] =
        serde_json::json!({"title": "Stale title", "artist": "Stale artist"});
    assert_eq!(
        session.edit_track(stale.clone()).await?,
        MutationReply::NeedsReview {
            request: stale.request,
            current: std::collections::BTreeMap::from([(subject, vec![record])]),
        }
    );
    assert_eq!(store.records()?, records);
    assert_eq!(
        crate::fingerprint(&store.catalog()?),
        crate::fingerprint(&after)
    );
    let mut invalid = metadata_edit(
        &after,
        "invalid-member-edit",
        &one,
        serde_json::json!({"title": "Invalid"}),
    );
    invalid.payload["retired"] = serde_json::json!(true);
    assert_eq!(
        session.edit_track(invalid).await?,
        MutationReply::Rejected {
            request: "invalid-member-edit".into(),
            reason: MutationRejection::Invalid,
        }
    );
    assert_eq!(store.records()?, records);
    let snapshot: syncstr_headless::shared_audio_net::Snapshot =
        session.request(Request::Catalog).await?;
    assert_eq!(
        crate::fingerprint(&snapshot.catalog),
        crate::fingerprint(&after)
    );
    store.revoke_member(&fixture.host, &reader.id().to_string())?;
    let revoked = metadata_edit(
        &after,
        "revoked-member-edit",
        &one,
        serde_json::json!({"title": "Revoked edit"}),
    );
    assert_eq!(
        session.edit_track(revoked).await?,
        MutationReply::Rejected {
            request: "revoked-member-edit".into(),
            reason: MutationRejection::Revoked,
        }
    );
    assert_eq!(store.records()?, records);
    assert_eq!(store.catalog()?.tracks, after.tracks);
    assert!(
        session
            .request::<syncstr_headless::shared_audio_net::Snapshot>(Request::Catalog)
            .await
            .is_err()
    );
    assert!(
        Session::connect(&reader_endpoint, host_endpoint.addr(), proof)
            .await
            .is_err()
    );
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    host_endpoint.close().await;
    reader_endpoint.close().await;
    Ok(())
}

#[tokio::test]
async fn quic_member_metadata_retry_after_lost_reply_returns_original_acceptance()
-> anyhow::Result<()> {
    use syncstr_headless::shared_audio_net::{
        Hello, MutationRejection, MutationReply, Request, Session,
    };
    let fixture = crate::Fixture::new().await?;
    let store = fixture.activate()?;
    let before = store.catalog()?;
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
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(syncstr_headless::shared_audio_net::serve(
        host_endpoint.clone(),
        store.clone(),
        fixture.host.clone(),
    ));
    let proof = store.membership()?;
    let connection = reader_endpoint
        .connect(
            host_endpoint.addr(),
            syncstr_headless::shared_audio_net::ALPN,
        )
        .await?;
    let _: Hello = crate::shared_exchange(
        &connection,
        &Hello {
            version: 5,
            proof: proof.clone(),
            supported_operations: vec![],
        },
    )
    .await?;
    let edit = metadata_edit(
        &before,
        "lost-metadata-reply",
        &fixture.logical,
        serde_json::json!({"title": "Accepted once", "artist": "Retained artist"}),
    );
    let (mut output, input) = connection.open_bi().await?;
    let bytes = serde_json::to_vec(&Request::Mutation {
        mutation: edit.clone(),
    })?;
    output
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .await?;
    output.write_all(&bytes).await?;
    output.finish()?;
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            if store.records()?.len() == 1 {
                break anyhow::Ok(());
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await??;
    // The record is durable, but this connection never reads its acknowledgment.
    drop(input);
    connection.close(0u32.into(), b"lost reply");
    let signed = store.records()?.into_iter().next().unwrap();
    let expected = MutationReply::Accepted {
        request: edit.request.clone(),
        record: signed.id.clone(),
        host: fixture.host.id().to_string(),
        heads: std::collections::BTreeMap::from([(
            format!("track:{}", fixture.logical),
            vec![signed.id.clone()],
        )]),
    };
    let session = Session::connect(&reader_endpoint, host_endpoint.addr(), proof).await?;
    assert_eq!(session.edit_track(edit.clone()).await?, expected);
    assert_eq!(store.records()?, [signed.clone()]);
    let (peer_endpoint, _peer_lock) = fixture
        .other
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let peer = Session::connect(&peer_endpoint, host_endpoint.addr(), store.membership()?).await?;
    assert_eq!(
        peer.edit_track(edit.clone()).await?,
        MutationReply::Rejected {
            request: edit.request.clone(),
            reason: MutationRejection::Invalid,
        }
    );
    assert_eq!(store.records()?, [signed.clone()]);
    let second = metadata_edit(
        &store.catalog()?,
        "later-member-edit",
        &fixture.logical,
        serde_json::json!({"title": "Later title"}),
    );
    assert!(matches!(
        session.edit_track(second).await?,
        MutationReply::Accepted { .. }
    ));
    let after = store.catalog()?;
    assert_eq!(
        after.tracks[&fixture.logical].metadata["artist"],
        "Retained artist"
    );
    assert_eq!(session.edit_track(edit.clone()).await?, expected);
    assert_eq!(store.records()?.len(), 2);
    assert_eq!(
        store
            .records()?
            .iter()
            .filter(|r| r.id == signed.id)
            .count(),
        1
    );
    let mut reused = edit;
    reused.payload["metadata"]["title"] = serde_json::json!("Different intent");
    assert_eq!(
        session.edit_track(reused).await?,
        MutationReply::Rejected {
            request: "lost-metadata-reply".into(),
            reason: MutationRejection::Invalid,
        }
    );
    assert_eq!(store.records()?.len(), 2);
    assert_eq!(
        crate::fingerprint(&store.catalog()?),
        crate::fingerprint(&after)
    );
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    host_endpoint.close().await;
    reader_endpoint.close().await;
    peer_endpoint.close().await;
    Ok(())
}

async fn shared_frame<T: serde::de::DeserializeOwned>(
    input: &mut iroh::endpoint::RecvStream,
) -> anyhow::Result<T> {
    let frame = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        input.read_to_end(4 * 1024 * 1024),
    )
    .await??;
    anyhow::ensure!(frame.len() >= 4, "missing frame length");
    anyhow::ensure!(
        u32::from_be_bytes(frame[..4].try_into()?) as usize == frame.len() - 4,
        "incorrect frame length"
    );
    Ok(serde_json::from_slice(&frame[4..])?)
}

async fn shared_exchange<T: serde::Serialize, R: serde::de::DeserializeOwned>(
    connection: &iroh::endpoint::Connection,
    request: &T,
) -> anyhow::Result<R> {
    let (mut output, mut input) = connection.open_bi().await?;
    let body = serde_json::to_vec(request)?;
    output.write_all(&(body.len() as u32).to_be_bytes()).await?;
    output.write_all(&body).await?;
    output.finish()?;
    crate::shared_frame(&mut input).await
}

#[tokio::test]
async fn quic_legacy_hello_and_invalid_mutations_keep_working_until_revoked() -> anyhow::Result<()>
{
    use syncstr_headless::shared_audio_net::{Hello, MutationRejection, MutationReply};
    #[derive(serde::Serialize, serde::Deserialize)]
    struct LegacyHello {
        version: u8,
        proof: syncstr_headless::enrollment::Proof,
    }
    let fixture = crate::Fixture::new().await?;
    let store = fixture.activate()?;
    let before = store.catalog()?;
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
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(syncstr_headless::shared_audio_net::serve(
        host_endpoint.clone(),
        store.clone(),
        fixture.host.clone(),
    ));
    let connection = reader_endpoint
        .connect(
            host_endpoint.addr(),
            syncstr_headless::shared_audio_net::ALPN,
        )
        .await?;
    let legacy = LegacyHello {
        version: 5,
        proof: store.membership()?,
    };
    let defaulted: Hello = serde_json::from_value(serde_json::to_value(&legacy)?)?;
    assert!(defaulted.supported_operations.is_empty());
    let hello: serde_json::Value = crate::shared_exchange(&connection, &legacy).await?;
    assert_eq!(
        hello["supported_operations"],
        serde_json::json!(["edit-track"])
    );
    let old_decoder: LegacyHello = serde_json::from_value(hello)?;
    assert_eq!(old_decoder.version, 5);
    assert_eq!(
        serde_json::to_value(old_decoder.proof)?,
        serde_json::to_value(legacy.proof)?
    );
    let valid = serde_json::json!({"operation": "mutation", "mutation": {
        "request": "invalid-test", "cluster": before.cluster, "baseline": before.baseline,
        "operation": "future-operation", "expected": {}, "payload": {}, "confirmed": []
    }});
    for field in [
        "request",
        "cluster",
        "baseline",
        "operation",
        "expected",
        "payload",
        "confirmed",
    ] {
        let mut invalid = valid.clone();
        invalid["mutation"].as_object_mut().unwrap().remove(field);
        let reply: MutationReply = crate::shared_exchange(&connection, &invalid).await?;
        assert_eq!(
            reply,
            MutationReply::Rejected {
                request: if field == "request" {
                    ""
                } else {
                    "invalid-test"
                }
                .into(),
                reason: MutationRejection::Invalid,
            }
        );
        let snapshot: syncstr_headless::shared_audio_net::Snapshot =
            crate::shared_exchange(&connection, &serde_json::json!({"operation": "catalog"}))
                .await?;
        assert_eq!(
            crate::fingerprint(&snapshot.catalog),
            crate::fingerprint(&before)
        );
    }
    let mut invalid = valid.clone();
    invalid["mutation"]["expected"] = serde_json::json!([]);
    let reply: MutationReply = crate::shared_exchange(&connection, &invalid).await?;
    assert_eq!(
        reply,
        MutationReply::Rejected {
            request: "invalid-test".into(),
            reason: MutationRejection::Invalid
        }
    );
    let mut spoofed = valid.clone();
    spoofed["mutation"]["member"] = serde_json::json!(fixture.host.id().to_string());
    let reply: MutationReply = crate::shared_exchange(&connection, &spoofed).await?;
    assert_eq!(
        reply,
        MutationReply::Rejected {
            request: "invalid-test".into(),
            reason: MutationRejection::Invalid
        }
    );
    let reply: MutationReply = crate::shared_exchange(&connection, &valid).await?;
    assert_eq!(
        reply,
        MutationReply::Unsupported {
            request: "invalid-test".into(),
            operation: "future-operation".into()
        }
    );
    store.revoke_member(&fixture.host, &reader.id().to_string())?;
    let mut impersonating = valid;
    impersonating["mutation"]["payload"] =
        serde_json::json!({"member": fixture.host.id().to_string(), "grant": "host-grant"});
    let reply: MutationReply = crate::shared_exchange(&connection, &impersonating).await?;
    assert_eq!(
        reply,
        MutationReply::Rejected {
            request: "invalid-test".into(),
            reason: MutationRejection::Revoked
        }
    );
    tokio::time::timeout(std::time::Duration::from_secs(5), connection.closed()).await?;
    assert!(
        crate::shared_exchange::<_, serde_json::Value>(
            &connection,
            &serde_json::json!({"operation": "catalog"})
        )
        .await
        .is_err()
    );
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    host_endpoint.close().await;
    reader_endpoint.close().await;
    Ok(())
}

#[tokio::test]
async fn quic_session_accepts_legacy_host_hello_without_operations() -> anyhow::Result<()> {
    let fixture = crate::Fixture::new().await?;
    let store = fixture.activate()?;
    let proof = store.membership()?;
    let (host_endpoint, _host_lock) = fixture
        .host
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let (peer_endpoint, _peer_lock) = fixture
        .other
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let endpoint = host_endpoint.clone();
    let host_proof = proof.clone();
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(async move {
        let connection = endpoint
            .accept()
            .await
            .ok_or_else(|| anyhow::anyhow!("missing connection"))?
            .await?;
        let (mut output, mut input) = connection.accept_bi().await?;
        let _: syncstr_headless::shared_audio_net::Hello = crate::shared_frame(&mut input).await?;
        let body = serde_json::to_vec(&serde_json::json!({"version": 5, "proof": host_proof}))?;
        output.write_all(&(body.len() as u32).to_be_bytes()).await?;
        output.write_all(&body).await?;
        output.finish()?;
        output.stopped().await?;
        let _ = connection.closed().await;
        anyhow::Ok(())
    });
    let session = syncstr_headless::shared_audio_net::Session::connect(
        &peer_endpoint,
        host_endpoint.addr(),
        proof.clone(),
    )
    .await?;
    assert!(session.supported_operations.is_empty());
    let mutation = metadata_edit(
        &store.catalog()?,
        "unsupported-metadata",
        &fixture.logical,
        serde_json::json!({"title": "Unavailable"}),
    );
    assert_eq!(
        session.edit_track(mutation).await?,
        syncstr_headless::shared_audio_net::MutationReply::Unsupported {
            request: "unsupported-metadata".into(),
            operation: "edit-track".into(),
        }
    );
    assert_eq!(
        serde_json::to_value(&session.proof)?,
        serde_json::to_value(proof)?
    );
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    host_endpoint.close().await;
    peer_endpoint.close().await;
    Ok(())
}

#[test]
fn mutation_reply_wire_has_all_five_typed_outcomes() -> anyhow::Result<()> {
    use syncstr_headless::shared_audio_net::{MutationRejection, MutationReply};
    let heads =
        std::collections::BTreeMap::from([("track:example".into(), vec!["revision".into()])]);
    for (reply, wire) in [
        (
            MutationReply::Accepted {
                request: "request".into(),
                record: "record".into(),
                host: "host".into(),
                heads: heads.clone(),
            },
            serde_json::json!({"status":"accepted", "request":"request", "record":"record", "host":"host", "heads": heads}),
        ),
        (
            MutationReply::NeedsReview {
                request: "request".into(),
                current: heads.clone(),
            },
            serde_json::json!({"status":"needs-review", "request":"request", "current": heads}),
        ),
        (
            MutationReply::Rejected {
                request: "request".into(),
                reason: MutationRejection::BaselineMismatch,
            },
            serde_json::json!({"status":"rejected", "request":"request", "reason":"baseline-mismatch"}),
        ),
        (
            MutationReply::Deferred {
                request: "request".into(),
                reason: "store-unavailable".into(),
            },
            serde_json::json!({"status":"deferred", "request":"request", "reason":"store-unavailable"}),
        ),
        (
            MutationReply::Unsupported {
                request: "request".into(),
                operation: "edit-track".into(),
            },
            serde_json::json!({"status":"unsupported", "request":"request", "operation":"edit-track"}),
        ),
    ] {
        assert_eq!(serde_json::to_value(&reply)?, wire);
        assert_eq!(serde_json::from_value::<MutationReply>(wire)?, reply);
    }
    Ok(())
}

struct Fixture {
    root: tempfile::TempDir,
    host: std::sync::Arc<syncstr_headless::peer::Identity>,
    other: std::sync::Arc<syncstr_headless::peer::Identity>,
    entry: syncstr_headless::model::Entry,
    logical: String,
}

impl crate::Fixture {
    async fn new() -> anyhow::Result<Self> {
        let root = tempfile::tempdir()?;
        let host = std::sync::Arc::new(syncstr_headless::peer::Identity::from_secret(
            &root.path().join("host"),
            [41; 32],
        )?);
        let other = std::sync::Arc::new(syncstr_headless::peer::Identity::from_secret(
            &root.path().join("other"),
            [42; 32],
        )?);
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
