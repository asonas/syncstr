#![cfg(feature = "p2p")]

#[tokio::test]
async fn incompatible_album_titles_remain_in_history_until_consistent_edits() -> anyhow::Result<()>
{
    let root = tempfile::tempdir()?;
    let state = root.path().join("identity");
    syncstr_headless::peer::Identity::initialize(&state)?;
    let identity = syncstr_headless::peer::Identity::open(&state)?;
    let store = syncstr_headless::store::Store::open(&root.path().join("data"))?;
    store.create_cluster(identity.id().to_string()).await?;
    let a = crate::fixture(b"first audio");
    let b = crate::fixture(b"second audio");
    let first = root.path().join("first.mp3");
    let second = root.path().join("second.mp3");
    std::fs::write(&first, b"first audio")?;
    std::fs::write(&second, b"second audio")?;
    let mut original = syncstr_headless::organization::Organization::default();
    original.import(&a);
    let mut competing = syncstr_headless::organization::Organization::default();
    competing.import(&b);
    competing.albums[0].id = original.albums[0].id.clone();
    competing.tracks[0].imported_album_id = original.albums[0].id.clone();
    competing.albums[0].title = "Alternative title".into();
    store
        .import_cluster_file(&identity, a.clone(), Some(original.clone()), &first, false)
        .await?;
    let error = store
        .import_cluster_file(
            &identity,
            b.clone(),
            Some(competing.clone()),
            &second,
            false,
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("album metadata conflict"));
    assert_eq!(store.cluster_changes().await?.len(), 2);
    assert_eq!(
        store.catalog().await?.organization.albums[0].title,
        original.albums[0].title
    );
    let heads = store.cluster_object_states().await?.into_iter()
        .map(|state| (state.object, state.heads[0].id.clone())).collect();
    store.resolve_cluster_album_title(&identity, &original.albums[0].id, "Alternative title", heads).await?;
    store.project_cluster_metadata(a.sha256).await?;
    store.project_cluster_metadata(b.sha256).await?;
    assert_eq!(
        store.catalog().await?.organization.albums[0].title,
        "Alternative title"
    );
    assert_eq!(store.cluster_changes().await?.len(), 4);
    assert_eq!(std::fs::read(first)?, b"first audio");
    Ok(())
}

#[tokio::test]
async fn client_restore_requires_confirmation_and_keeps_concurrent_deletion() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let state = root.path().join("identity");
    syncstr_headless::peer::Identity::initialize(&state)?;
    let identity = syncstr_headless::peer::Identity::open(&state)?;
    let store = syncstr_headless::store::Store::open(&root.path().join("data"))?;
    store.create_cluster(identity.id().to_string()).await?;
    let bytes = b"restore fixture";
    let mut entry = crate::fixture(bytes);
    entry.track.added_at = Some(1);
    let source = root.path().join("source.mp3");
    std::fs::write(&source, bytes)?;
    let mut organization = syncstr_headless::organization::Organization::default();
    organization.import(&entry);
    store.import_cluster_file(&identity, entry.clone(), Some(organization.clone()), &source, false).await?;
    let imported = store.cluster_selected_change(&entry.sha256).await?.unwrap();
    let added_at = store.catalog().await?.entries[0].track.added_at;
    assert!(added_at.is_some_and(|value| value > 1));
    let mut edited = organization.clone();
    edited.albums[0].title = "Edited without uploading audio".into();
    let revision = store.receive_cluster_metadata(&identity, entry.clone(), edited.clone(), vec![imported.id.clone()]).await?;
    assert_eq!(store.receive_cluster_metadata(&identity, entry.clone(), edited, vec![imported.id]).await?, revision);
    assert_eq!(store.cluster_changes().await?.len(), 2);
    assert_eq!(store.catalog().await?.entries[0].track.added_at, added_at);
    let removed = store.publish_cluster_change(&identity, entry.sha256.clone(), syncstr_headless::cluster_changes::Action::Delete).await?;
    assert!(store.receive_cluster_metadata(&identity, entry.clone(), organization.clone(), vec![removed.id.clone()]).await.is_err());
    let stage = || -> anyhow::Result<tempfile::NamedTempFile> {
        let file = tempfile::NamedTempFile::new()?;
        std::fs::write(file.path(), bytes)?;
        file.as_file().sync_all()?;
        Ok(file)
    };
    assert!(store.receive_cluster_import(&identity, entry.clone(), organization.clone(), vec![removed.id.clone()], false, stage()?).await.is_err());
    assert!(store.cluster_selected_change(&entry.sha256).await?.is_none());
    store.receive_cluster_import(&identity, entry.clone(), organization.clone(), vec![removed.id.clone()], true, stage()?).await?;
    assert_eq!(store.catalog().await?.entries[0].track.added_at, added_at);
    assert!(matches!(store.cluster_selected_change(&entry.sha256).await?.unwrap().action, syncstr_headless::cluster_changes::Action::Restore { .. }));
    store.publish_cluster_change(&identity, entry.sha256.clone(), syncstr_headless::cluster_changes::Action::Delete).await?;
    assert!(store.receive_cluster_import(&identity, entry.clone(), organization, vec![removed.id], true, stage()?).await.is_err());
    assert!(store.cluster_object_states().await?[0].conflicted());
    assert_eq!(std::fs::read(source)?, bytes);
    Ok(())
}

fn fixture(bytes: &[u8]) -> syncstr_headless::model::Entry {
    use sha2::Digest as _;
    let mut entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json")).unwrap();
    entry.sha256 = hex::encode(sha2::Sha256::digest(bytes));
    entry.track.size = bytes.len() as u64;
    entry.track.id = uuid::Uuid::new_v4().to_string();
    entry
}

#[tokio::test]
async fn two_hosts_replicate_verified_audio_and_a_client_uses_the_surviving_host()
-> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let mut nodes = Vec::new();
    for name in ["a", "b", "client"] {
        let state = root.path().join(name).join("identity");
        syncstr_headless::peer::Identity::initialize(&state)?;
        nodes.push((
            std::sync::Arc::new(syncstr_headless::peer::Identity::open(&state)?),
            syncstr_headless::store::Store::open(&root.path().join(name).join("data"))?,
        ));
    }
    let (a, a_store) = &nodes[0];
    a_store.create_cluster(a.id().to_string()).await?;
    for (index, (identity, store)) in nodes.iter().enumerate().skip(1) {
        let invitation = a_store
            .create_cluster_invitation(a, index == 1, 1000, 600)
            .await?;
        let grant = a_store
            .redeem_cluster_invitation(a, &invitation.secret, identity.id().to_string(), 1100)
            .await?;
        store
            .join_cluster(
                identity,
                a.id(),
                grant.id,
                a_store.cluster_membership_proof().await?,
            )
            .await?;
    }
    let (b, b_store) = &nodes[1];
    b_store
        .merge_cluster_membership(a_store.cluster_membership_proof().await?)
        .await?;
    let (client, client_store) = &nodes[2];
    let (a_endpoint, _a_lock) = a.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let (b_endpoint, _b_lock) = b.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let (client_endpoint, _client_lock) =
        client.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let a_server = tokio::spawn(syncstr_headless::cluster_net::serve(
        a.clone(),
        a_endpoint.clone(),
        a_store.clone(),
    ));
    let b_server = tokio::spawn(syncstr_headless::cluster_net::serve(
        b.clone(),
        b_endpoint.clone(),
        b_store.clone(),
    ));
    let bytes = vec![73; 190000];
    let entry = crate::fixture(&bytes);
    let source = root.path().join("source.mp3");
    std::fs::write(&source, &bytes)?;
    let mut organization = syncstr_headless::organization::Organization::default();
    organization.import(&entry);
    organization
        .choices
        .push(syncstr_headless::organization::Choice {
            id: "user-classification".into(),
            subject: organization.albums[0].id.clone(),
            kind: "classification".into(),
            value: Some("true".into()),
            parents: Vec::new(),
        });
    a_store
        .import_cluster_file(a, entry.clone(), Some(organization.clone()), &source, false)
        .await?;
    let session =
        syncstr_headless::cluster_sync::Session::connect(&b_endpoint, a_endpoint.addr(), b_store)
            .await?;
    session.reconcile(b_store).await?;
    assert!(b_store.cluster_receipts().await?.is_empty());
    session.download(b, b_store, &entry.sha256).await?;
    session.reconcile(b_store).await?;
    session.download(b, b_store, &entry.sha256).await?;
    assert_eq!(b_store.catalog().await?.entries.len(), 1);
    assert_eq!(
        b_store.cluster_receipts().await?,
        vec![entry.sha256.clone()]
    );
    assert_eq!(
        b_store.catalog().await?.organization.choices,
        organization.choices
    );
    assert_eq!(std::fs::read(&source)?, bytes);
    let mut corrected = entry.clone();
    corrected.track.title = "Corrected imported title".into();
    a_store
        .import_cluster_file(a, corrected.clone(), None, &source, false)
        .await?;
    session.reconcile(b_store).await?;
    let jobs = b_store.cluster_jobs().await?.len();
    b_store
        .project_cluster_metadata(entry.sha256.clone())
        .await?;
    assert_eq!(
        b_store.catalog().await?.entries[0].track.title,
        corrected.track.title
    );
    assert_eq!(
        b_store.catalog().await?.organization.choices,
        organization.choices
    );
    assert_eq!(b_store.cluster_jobs().await?.len(), jobs);
    assert_eq!(b_store.cluster_changes().await?.len(), 2);
    a_store
        .import_cluster_file(a, corrected, None, &source, false)
        .await?;
    assert_eq!(a_store.cluster_changes().await?.len(), 2);
    let mut renamed = organization.clone();
    renamed.albums[0].title = "Corrected album title".into();
    let updated_entry = a_store.catalog().await?.entries[0].clone();
    a_store
        .import_cluster_file(a, updated_entry, Some(renamed.clone()), &source, false)
        .await?;
    session.reconcile(b_store).await?;
    b_store
        .project_cluster_metadata(entry.sha256.clone())
        .await?;
    assert_eq!(
        a_store.catalog().await?.organization.albums[0].title,
        "Corrected album title"
    );
    assert_eq!(
        b_store.catalog().await?.organization.albums[0].title,
        "Corrected album title"
    );
    drop(session);
    let second_bytes = b"different complete audio";
    let mut second = crate::fixture(second_bytes);
    second.track.album_id = Some(uuid::Uuid::new_v4().to_string());
    let source2 = root.path().join("second.mp3");
    std::fs::write(&source2, second_bytes)?;
    b_store
        .import_cluster_file(b, second.clone(), None, &source2, false)
        .await?;
    let session =
        syncstr_headless::cluster_sync::Session::connect(&a_endpoint, b_endpoint.addr(), a_store)
            .await?;
    session.reconcile(a_store).await?;
    session.download(a, a_store, &second.sha256).await?;
    assert_eq!(a_store.catalog().await?.entries.len(), 2);
    drop(session);
    a_endpoint.close().await;
    a_server.await?;
    let session = syncstr_headless::cluster_sync::Session::connect(
        &client_endpoint,
        b_endpoint.addr(),
        client_store,
    )
    .await?;
    session.reconcile(client_store).await?;
    session
        .download(client, client_store, &entry.sha256)
        .await?;
    let local = client_store
        .cluster_local_file(&entry.sha256)
        .await?
        .unwrap();
    assert_eq!(std::fs::read(client_store.path(&local))?, bytes);
    // Corruption cannot produce a receipt on the playback device.
    let damaged = b_store.cluster_local_file(&second.sha256).await?.unwrap();
    std::fs::write(b_store.path(&damaged), b"corrupt")?;
    assert!(
        session
            .download(client, client_store, &second.sha256)
            .await
            .is_err()
    );
    assert_eq!(client_store.cluster_receipts().await?, vec![entry.sha256]);
    assert!(!b_store.cluster_receipts().await?.contains(&second.sha256));
    assert!(
        client_store
            .cluster_jobs()
            .await?
            .iter()
            .any(|job| job.sha256 == second.sha256
                && job.state == syncstr_headless::cluster::JobState::Queued)
    );
    assert!(
        client_store
            .publish_cluster_change(
                client,
                second.sha256.clone(),
                syncstr_headless::cluster_changes::Action::Delete
            )
            .await
            .is_err()
    );
    b_store
        .revoke_cluster_member(b, client.id().to_string())
        .await?;
    assert!(session.reconcile(client_store).await.is_err());
    drop(session);
    assert!(
        syncstr_headless::cluster_sync::Session::connect(
            &client_endpoint,
            b_endpoint.addr(),
            client_store
        )
        .await
        .is_err()
    );
    let unknown_state = root.path().join("unknown/identity");
    syncstr_headless::peer::Identity::initialize(&unknown_state)?;
    let unknown = syncstr_headless::peer::Identity::open(&unknown_state)?;
    let unknown_store = syncstr_headless::store::Store::open(&root.path().join("unknown/data"))?;
    unknown_store
        .create_cluster(unknown.id().to_string())
        .await?;
    unknown_store
        .create_cluster_invitation(&unknown, true, 1000, 600)
        .await?;
    let (unknown_endpoint, _unknown_lock) =
        unknown.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    assert!(
        syncstr_headless::cluster_sync::Session::connect(
            &unknown_endpoint,
            b_endpoint.addr(),
            &unknown_store
        )
        .await
        .is_err()
    );
    unknown_endpoint.close().await;
    client_endpoint.close().await;
    b_endpoint.close().await;
    b_server.await?;
    Ok(())
}

#[tokio::test]
async fn incomplete_or_corrupt_staging_never_becomes_a_receipt() -> anyhow::Result<()> {
    use std::io::Write as _;
    let root = tempfile::tempdir()?;
    let state = root.path().join("identity");
    syncstr_headless::peer::Identity::initialize(&state)?;
    let identity = syncstr_headless::peer::Identity::open(&state)?;
    let store = syncstr_headless::store::Store::open(&root.path().join("data"))?;
    store.create_cluster(identity.id().to_string()).await?;
    let bytes = b"complete audio";
    let entry = crate::fixture(bytes);
    let mut organization = syncstr_headless::organization::Organization::default();
    organization.import(&entry);
    let change = store
        .publish_cluster_change(
            &identity,
            entry.sha256.clone(),
            syncstr_headless::cluster_changes::Action::Import {
                entry: Box::new(entry),
                organization: Box::new(organization),
            },
        )
        .await?;
    for bytes in [&b"partial"[..], &b"xxxxxxxxxxxxxx"[..]] {
        let mut temporary = store.stage().await?;
        temporary.write_all(bytes)?;
        assert!(
            store
                .commit_cluster_replica(&identity, change.clone(), temporary, None)
                .await
                .is_err()
        );
        assert!(store.cluster_receipts().await?.is_empty());
        assert!(store.catalog().await?.entries.is_empty());
    }
    Ok(())
}
