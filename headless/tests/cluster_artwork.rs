#![cfg(feature = "p2p")]

fn fixture() -> (syncstr_headless::model::Entry, syncstr_headless::organization::Organization, String, String) {
    let value: serde_json::Value = serde_json::from_str(include_str!("../fixtures/album-artwork.json")).unwrap();
    let mut entry: syncstr_headless::model::Entry = serde_json::from_str(include_str!("../fixtures/local-entry.json")).unwrap();
    entry.sha256 = "a".repeat(64);
    entry.track.id = "track-a".into();
    (entry, serde_json::from_value(value["organization"].clone()).unwrap(),
        value["blue"].as_str().unwrap().into(), value["red"].as_str().unwrap().into())
}

#[tokio::test]
async fn reachable_host_recovers_raw_tags_without_sending_audio() -> anyhow::Result<()> {
    use lofty::tag::TagExt as _;
    use sha2::Digest as _;
    let root = tempfile::tempdir()?;
    let mut nodes = Vec::new();
    for name in ["host", "client"] {
        let path = root.path().join(name);
        syncstr_headless::peer::Identity::initialize(&path.join("identity"))?;
        nodes.push((std::sync::Arc::new(syncstr_headless::peer::Identity::open(&path.join("identity"))?),
            syncstr_headless::store::Store::open(&path.join("data"))?));
    }
    let (host, store) = &nodes[0];
    let (client, replica) = &nodes[1];
    store.create_cluster(host.id().to_string()).await?;
    let invitation = store.create_cluster_invitation(host, true, 1000, 600).await?;
    let grant = store.redeem_cluster_invitation(host, &invitation.secret, client.id().to_string(), 1100).await?;
    replica.join_cluster(client, host.id(), grant.id, store.cluster_membership_proof().await?).await?;
    let mut temporary = tempfile::NamedTempFile::new()?;
    std::io::Write::write_all(&mut temporary, include_bytes!("../../apps/macos/Tests/Fixtures/untagged.mp3"))?;
    let mut tags = lofty::id3::v2::Id3v2Tag::default();
    for (id, value) in [("TALB", "Collection"), ("TPE1", "Artist"), ("TCMP", "unrecognized")] {
        tags.insert(lofty::id3::v2::Frame::Text(lofty::id3::v2::TextInformationFrame::new(
            lofty::id3::v2::FrameId::Valid(std::borrow::Cow::Borrowed(id)),
            lofty::TextEncoding::UTF8, value.to_owned())));
    }
    tags.save_to_path(temporary.path(), lofty::config::WriteOptions::default())?;
    let bytes = std::fs::read(temporary.path())?;
    let (mut entry, mut organization, _, _) = crate::fixture();
    entry.sha256 = hex::encode(sha2::Sha256::digest(&bytes));
    entry.track.size = bytes.len() as u64;
    entry.track.suffix = "mp3".into();
    entry.imported_album = None;
    organization.tracks[0].sha256 = entry.sha256.clone();
    organization.tracks[0].imported.tag_values = None;
    let context = organization.tracks[0].import_context.clone();
    store.receive_cluster_import(host, entry.clone(), organization.clone(), vec![], false, temporary).await?;
    let (endpoint, _lock) = host.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let (receiver, _receiver_lock) = client.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let server = tokio::spawn(syncstr_headless::cluster_net::serve(host.clone(), endpoint.clone(), store.clone()));
    let session = syncstr_headless::cluster_sync::Session::connect(&receiver, endpoint.addr(), replica).await?;
    session.reconcile(replica).await?;
    let mut corrupted = bytes.clone();
    corrupted[0] ^= 1;
    std::fs::write(store.path(&entry), &corrupted)?;
    assert!(!session.recover_evidence(entry.sha256.clone()).await?);
    std::fs::write(store.path(&entry), &bytes)?;
    assert!(session.recover_evidence(entry.sha256.clone()).await?);
    session.reconcile(replica).await?;
    replica.project_cluster_metadata(entry.sha256.clone()).await?;
    let catalog = replica.catalog().await?;
    assert_eq!(catalog.organization.tracks[0].imported.compilation_values, ["unrecognized"]);
    assert_eq!(catalog.organization.tracks[0].imported.title.as_deref(), Some("Collection"));
    assert_eq!(catalog.organization.tracks[0].import_context, context);
    assert!(replica.cluster_receipts().await?.is_empty());
    assert!(!replica.path(&entry).exists());
    assert!(!session.recover_evidence(entry.sha256.clone()).await?);
    assert_eq!(std::fs::read(store.path(&entry))?, bytes);
    store.publish_cluster_change(host, entry.sha256.clone(), syncstr_headless::cluster_changes::Action::Delete).await?;
    assert!(!session.recover_evidence(entry.sha256).await?);
    drop(session);
    endpoint.close().await;
    server.await?;
    receiver.close().await;
    Ok(())
}

#[tokio::test]
async fn catalog_keeps_images_without_audio_and_tombstones_remove_stale_evidence() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    syncstr_headless::peer::Identity::initialize(&root.path().join("identity"))?;
    let identity = syncstr_headless::peer::Identity::open(&root.path().join("identity"))?;
    let store = syncstr_headless::store::Store::open(&root.path().join("data"))?;
    store.create_cluster(identity.id().to_string()).await?;
    let (entry, organization, blue, _) = crate::fixture();
    store.publish_cluster_change(&identity, entry.sha256.clone(), syncstr_headless::cluster_changes::Action::Import {
        entry: Box::new(entry.clone()), organization: Box::new(organization.clone()),
    }).await?;
    store.project_cluster_metadata(entry.sha256.clone()).await?;
    let catalog = store.catalog().await?;
    assert_eq!(catalog.entries.len(), 1);
    assert!(catalog.organization.artwork.unwrap().assets.contains_key(&blue));
    assert!(store.cluster_receipts().await?.is_empty());
    assert!(!store.has_cluster_replica(&entry.sha256).await?);
    store.publish_cluster_change(&identity, entry.sha256.clone(), syncstr_headless::cluster_changes::Action::Delete).await?;
    store.project_cluster_metadata(entry.sha256.clone()).await?;
    let catalog = store.catalog().await?;
    assert!(catalog.entries.is_empty());
    assert!(catalog.organization.tracks.is_empty());
    assert!(catalog.organization.artwork.unwrap().assets.is_empty());
    assert!(store.publish_cluster_change(&identity, entry.sha256.clone(), syncstr_headless::cluster_changes::Action::Import {
        entry: Box::new(entry.clone()), organization: Box::new(organization.clone()),
    }).await.is_err());
    store.publish_cluster_change(&identity, entry.sha256.clone(), syncstr_headless::cluster_changes::Action::Restore {
        entry: Box::new(entry.clone()), organization: Box::new(organization),
    }).await?;
    store.project_cluster_metadata(entry.sha256).await?;
    assert_eq!(store.catalog().await?.entries.len(), 1);
    Ok(())
}

#[tokio::test]
async fn parallel_cover_choices_remain_resolvable_without_blocking_audio() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    syncstr_headless::peer::Identity::initialize(&root.path().join("identity"))?;
    let identity = syncstr_headless::peer::Identity::open(&root.path().join("identity"))?;
    let store = syncstr_headless::store::Store::open(&root.path().join("data"))?;
    store.create_cluster(identity.id().to_string()).await?;
    let (entry, original, blue, red) = crate::fixture();
    let imported = store.publish_cluster_change(&identity, entry.sha256.clone(), syncstr_headless::cluster_changes::Action::Import {
        entry: Box::new(entry.clone()), organization: Box::new(original.clone()),
    }).await?;
    for (id, asset) in [("blue-choice", blue.clone()), ("red-choice", red.clone())] {
        let mut organization = original.clone();
        organization.choices.push(syncstr_headless::organization::Choice {
            id: id.into(), subject: "album-a".into(), kind: "artwork".into(), value: Some(asset), parents: vec![],
        });
        store.receive_cluster_metadata(&identity, entry.clone(), organization, vec![imported.id.clone()]).await?;
    }
    assert!(!store.recover_cluster_evidence(&identity, &entry.sha256).await?);
    store.reconcile_cluster_organization(&identity).await?;
    assert!(!store.cluster_object_states().await?[0].conflicted());
    store.project_cluster_metadata(entry.sha256.clone()).await?;
    let mut organization = store.catalog().await?.organization;
    assert_eq!(organization.choices.len(), 2);
    assert!(organization.artwork.as_ref().unwrap().assets.contains_key(&red));
    organization.choices.push(syncstr_headless::organization::Choice {
        id: "resolved-cover".into(), subject: "album-a".into(), kind: "artwork".into(), value: Some(red),
        parents: vec!["blue-choice".into(), "red-choice".into()],
    });
    let selected = store.cluster_selected_change(&entry.sha256).await?.unwrap();
    store.receive_cluster_metadata(&identity, entry.clone(), organization, vec![selected.id]).await?;
    store.project_cluster_metadata(entry.sha256).await?;
    assert_eq!(store.catalog().await?.organization.choices.len(), 3);
    Ok(())
}

#[tokio::test]
async fn cover_history_larger_than_legacy_metadata_limit_is_retained() -> anyhow::Result<()> {
    use sha2::Digest as _;
    let root = tempfile::tempdir()?;
    syncstr_headless::peer::Identity::initialize(&root.path().join("identity"))?;
    let identity = syncstr_headless::peer::Identity::open(&root.path().join("identity"))?;
    let store = syncstr_headless::store::Store::open(&root.path().join("data"))?;
    store.create_cluster(identity.id().to_string()).await?;
    let (entry, mut organization, _, _) = crate::fixture();
    for index in 0..5 {
        let mut bytes = vec![0xff, 0xd8];
        for _ in 0..7 {
            bytes.extend_from_slice(&[0xff, 0xfe, 0xff, 0xff]);
            bytes.extend(std::iter::repeat_n(index, 65533));
        }
        bytes.extend_from_slice(&include_bytes!("../fixtures/blue.jpg")[2..]);
        assert!(bytes.len() < 512 * 1024);
        let asset = hex::encode(sha2::Sha256::digest(&bytes));
        organization.artwork.as_mut().unwrap().assets.insert(asset.clone(), bytes);
        organization.choices.push(syncstr_headless::organization::Choice {
            id: format!("cover-{index}"), subject: "album-a".into(), kind: "artwork".into(),
            value: Some(asset), parents: if index == 0 { vec![] } else { vec![format!("cover-{}", index - 1)] },
        });
    }
    organization.validate()?;
    assert!(serde_json::to_vec(&organization)?.len() > 1024 * 1024);
    store.publish_cluster_change(&identity, entry.sha256.clone(), syncstr_headless::cluster_changes::Action::Import {
        entry: Box::new(entry.clone()), organization: Box::new(organization.clone()),
    }).await?;
    store.project_cluster_metadata(entry.sha256.clone()).await?;
    assert_eq!(store.catalog().await?.organization.artwork, organization.artwork);
    let identity = std::sync::Arc::new(identity);
    syncstr_headless::peer::Identity::initialize(&root.path().join("second-identity"))?;
    let second = syncstr_headless::peer::Identity::open(&root.path().join("second-identity"))?;
    let replica = syncstr_headless::store::Store::open(&root.path().join("second-data"))?;
    let invitation = store.create_cluster_invitation(&identity, true, 1000, 600).await?;
    let grant = store.redeem_cluster_invitation(&identity, &invitation.secret, second.id().to_string(), 1100).await?;
    replica.join_cluster(&second, identity.id(), grant.id, store.cluster_membership_proof().await?).await?;
    let (endpoint, _lock) = identity.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let (client, _client_lock) = second.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let server = tokio::spawn(syncstr_headless::cluster_net::serve(identity, endpoint.clone(), store.clone()));
    let session = syncstr_headless::cluster_sync::Session::connect(&client, endpoint.addr(), &replica).await?;
    session.reconcile(&replica).await?;
    session.reconcile(&replica).await?;
    replica.project_cluster_metadata(entry.sha256.clone()).await?;
    assert_eq!(replica.catalog().await?.organization.artwork, organization.artwork);
    assert!(replica.cluster_receipts().await?.is_empty());
    drop(session);
    endpoint.close().await;
    server.await?;
    client.close().await;
    drop(replica);
    let reopened = syncstr_headless::store::Store::open(&root.path().join("second-data"))?;
    assert_eq!(reopened.catalog().await?.organization.artwork, organization.artwork);
    Ok(())
}

#[tokio::test]
async fn shared_import_context_repairs_compilation_without_the_original_path() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let mut nodes = Vec::new();
    for name in ["first", "second"] {
        let path = root.path().join(name);
        syncstr_headless::peer::Identity::initialize(&path.join("identity"))?;
        nodes.push((std::sync::Arc::new(syncstr_headless::peer::Identity::open(&path.join("identity"))?),
            syncstr_headless::store::Store::open(&path.join("data"))?));
    }
    let (a, a_store) = &nodes[0];
    let (b, b_store) = &nodes[1];
    a_store.create_cluster(a.id().to_string()).await?;
    let invitation = a_store.create_cluster_invitation(a, true, 1000, 600).await?;
    let grant = a_store.redeem_cluster_invitation(a, &invitation.secret, b.id().to_string(), 1100).await?;
    b_store.join_cluster(b, a.id(), grant.id, a_store.cluster_membership_proof().await?).await?;
    let mut objects = Vec::new();
    for index in (0..20).rev() {
        let (mut entry, mut metadata, _, _) = crate::fixture();
        entry.sha256 = format!("{index:064x}");
        entry.track.id = format!("track-{index}");
        metadata.albums[0].id = format!("album-{index}");
        let track = &mut metadata.tracks[0];
        track.id = entry.track.id.clone();
        track.sha256 = entry.sha256.clone();
        track.imported_album_id = metadata.albums[0].id.clone();
        track.imported.artist = Some(format!("Artist {index}"));
        track.imported.album_artist = None;
        track.import_context = Some(syncstr_headless::membership::ImportContext { source_id: "shared-import".into(), folder: "Collection".into() });
        track.track_number = Some(index + 1);
        metadata.artwork.as_mut().unwrap().candidates[0].track = entry.track.id.clone();
        metadata.artwork.as_mut().unwrap().candidates[0].id = format!("music-{index}");
        metadata.artwork.as_mut().unwrap().candidates[0].source = "music".into();
        a_store.publish_cluster_change(a, entry.sha256.clone(), syncstr_headless::cluster_changes::Action::Import {
            entry: Box::new(entry.clone()), organization: Box::new(metadata),
        }).await?;
        objects.push(entry.sha256);
    }
    let (endpoint, _lock) = a.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let (client, _client_lock) = b.cluster_endpoint(&["127.0.0.1:0".parse()?]).await?;
    let server = tokio::spawn(syncstr_headless::cluster_net::serve(a.clone(), endpoint.clone(), a_store.clone()));
    let session = syncstr_headless::cluster_sync::Session::connect(&client, endpoint.addr(), b_store).await?;
    session.reconcile(b_store).await?;
    session.reconcile(b_store).await?;
    drop(session);
    endpoint.close().await;
    server.await?;
    for object in &objects { b_store.project_cluster_metadata(object.clone()).await?; }
    let catalog = b_store.catalog().await?;
    assert_eq!(catalog.entries.len(), 20);
    let albums: std::collections::BTreeSet<_> = catalog.organization.tracks.iter()
        .map(|track| catalog.organization.canonical(&track.imported_album_id)).collect::<anyhow::Result<_>>()?;
    assert_eq!(albums.len(), 1);
    assert!(catalog.organization.tracks.iter().all(|track| track.import_context.as_ref().unwrap().source_id == "shared-import"));
    assert_eq!(catalog.organization.artwork.as_ref().unwrap().candidates.len(), 20);
    assert!(b_store.cluster_receipts().await?.is_empty());
    let before = catalog.organization;
    // Transfer the already consolidated catalog one object at a time. Former
    // album records must survive so repair can recompute automatic aliases.
    let mut received = syncstr_headless::organization::Organization::default();
    for object in &objects { received.merge(&before.for_object(object)?)?; }
    assert_eq!(received.tracks.len(), 20);
    let albums: std::collections::BTreeSet<_> = received.tracks.iter().map(|track| received.canonical(&track.imported_album_id))
        .collect::<anyhow::Result<_>>()?;
    assert_eq!(albums.len(), 1);
    for object in objects { b_store.project_cluster_metadata(object).await?; }
    assert_eq!(b_store.catalog().await?.organization, before);
    client.close().await;
    Ok(())
}
