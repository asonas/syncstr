#[tokio::test]
async fn legacy_catalog_migration_preserves_audio_and_does_not_enroll_peers() -> anyhow::Result<()>
{
    let root = tempfile::tempdir()?;
    let store = syncstr_headless::store::Store::open(root.path())?;
    let entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    let mut file = store.stage().await?;
    use std::io::Write as _;
    file.write_all(b"abc")?;
    let saved = store.commit(entry, file, false).await?;
    let catalog = store.catalog().await?;
    let legacy = serde_json::to_value(&catalog)?;
    drop(store);
    let connection = rusqlite::Connection::open(root.path().join("node.sqlite"))?;
    connection.execute_batch("DROP TABLE cluster_locations; DROP TABLE cluster_objects; DROP TABLE cluster_peers; DROP TABLE cluster_identity; DROP TABLE cluster_schema;")?;
    drop(connection);
    let store = syncstr_headless::store::Store::open(root.path())?;
    let identity = "11".repeat(32);
    let peer = syncstr_headless::cluster::KnownPeer {
        id: "22".repeat(32),
        name: "Other host".into(),
        address: None,
    };
    store.remember_cluster_peer(peer.clone()).await?;
    assert!(store.cluster_inventory().await?.cluster.is_none());
    let cluster = store.create_cluster(identity.clone()).await?;
    assert_ne!(cluster.id, catalog.id);
    drop(store);
    let store = syncstr_headless::store::Store::open(root.path())?;
    assert_eq!(store.create_cluster(identity).await?, cluster);
    assert_eq!(serde_json::to_value(store.catalog().await?)?, legacy);
    assert_eq!(std::fs::read(store.path(&saved))?, b"abc");
    let inventory = store.cluster_inventory().await?;
    assert_eq!(inventory.peers, vec![peer]);
    assert_eq!(inventory.objects.len(), 1);
    assert_eq!(inventory.objects[0].locations.len(), 1);
    assert!(inventory.objects[0].locations[0].member_id.is_none());
    Ok(())
}

#[tokio::test]
async fn identical_bytes_have_one_object_and_preserve_both_source_aliases() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let store = syncstr_headless::store::Store::open(root.path())?;
    let entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    let first = syncstr_headless::model::Catalog {
        id: "source-a".into(),
        name: "First".into(),
        entries: vec![entry.clone()],
        organization: Default::default(),
    };
    let mut second = first.clone();
    second.id = "source-b".into();
    second.entries[0].track.id = "another-track-id".into();
    second.entries[0].track.suffix = "mp3".into();
    store.observe_cluster_catalog(first.clone(), None).await?;
    store.observe_cluster_catalog(second.clone(), None).await?;
    store.observe_cluster_catalog(first, None).await?;
    let inventory = store.cluster_inventory().await?;
    assert_eq!(inventory.objects.len(), 1);
    assert_eq!(inventory.objects[0].locations.len(), 2);
    second.entries[0].track.size += 1;
    assert!(store.observe_cluster_catalog(second, None).await.is_err());
    assert_eq!(store.cluster_inventory().await?, inventory);
    Ok(())
}

#[tokio::test]
async fn pending_changes_and_interrupted_jobs_survive_restart_without_granting_access()
-> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let store = syncstr_headless::store::Store::open(root.path())?;
    let change = syncstr_headless::cluster::PendingChange {
        id: uuid::Uuid::new_v4().to_string(),
        author: "11".repeat(32),
        parents: vec![],
        operation: serde_json::json!({"kind":"import", "source":"source-a"}).to_string(),
    };
    store.save_pending_cluster_change(change.clone()).await?;
    store.save_pending_cluster_change(change.clone()).await?;
    let mut inconsistent = change.clone();
    inconsistent.operation = serde_json::json!({"kind":"delete"}).to_string();
    assert!(
        store
            .save_pending_cluster_change(inconsistent)
            .await
            .is_err()
    );
    let entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    store
        .observe_cluster_catalog(
            syncstr_headless::model::Catalog {
                id: "source-a".into(),
                name: "Fixture".into(),
                entries: vec![entry.clone()],
                organization: Default::default(),
            },
            None,
        )
        .await?;
    let job = syncstr_headless::cluster::TransferJob {
        id: uuid::Uuid::new_v4().to_string(),
        sha256: entry.sha256,
        source: "11".repeat(32),
        destination: "22".repeat(32),
        state: syncstr_headless::cluster::JobState::Queued,
    };
    store.enqueue_cluster_job(job.clone()).await?;
    store.begin_cluster_job(job.id.clone()).await?;
    drop(store);
    let store = syncstr_headless::store::Store::open(root.path())?;
    assert_eq!(store.pending_cluster_changes().await?, vec![change]);
    assert_eq!(store.cluster_jobs().await?, vec![job]);
    assert!(store.cluster_inventory().await?.cluster.is_none());
    assert!(!syncstr_headless::cluster::Capabilities::default().allows_automatic_writer());
    assert!(
        !syncstr_headless::cluster::Capabilities {
            version: 1,
            membership: true,
            deletions: false,
            conflicts: true
        }
        .allows_automatic_writer()
    );
    assert!(
        syncstr_headless::cluster::Capabilities {
            version: 1,
            membership: true,
            deletions: true,
            conflicts: true
        }
        .allows_automatic_writer()
    );
    Ok(())
}

#[tokio::test]
async fn failed_projection_rolls_back_and_can_be_retried_without_changing_legacy_data()
-> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let store = syncstr_headless::store::Store::open(root.path())?;
    let entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    let mut file = store.stage().await?;
    use std::io::Write as _;
    file.write_all(b"abc")?;
    let saved = store.commit(entry, file, false).await?;
    let catalog = store.catalog().await?;
    drop(store);
    let database = rusqlite::Connection::open(root.path().join("node.sqlite"))?;
    database.execute_batch("DELETE FROM cluster_locations; DELETE FROM cluster_objects; DROP TABLE cluster_schema; CREATE TRIGGER reject_cluster_object BEFORE INSERT ON cluster_objects BEGIN SELECT RAISE(ABORT, 'fixture interruption'); END;")?;
    assert!(syncstr_headless::store::Store::open(root.path()).is_err());
    let count: i64 = database.query_row(
        "SELECT count(*) FROM sqlite_master WHERE name = 'cluster_schema'",
        [],
        |row| row.get(0),
    )?;
    assert_eq!(count, 0);
    let payload: Vec<u8> =
        database.query_row("SELECT payload FROM tracks", [], |row| row.get(0))?;
    assert_eq!(
        serde_json::from_slice::<syncstr_headless::model::Entry>(&payload)?,
        saved
    );
    database.execute_batch("DROP TRIGGER reject_cluster_object")?;
    drop(database);
    let store = syncstr_headless::store::Store::open(root.path())?;
    assert_eq!(store.catalog().await?, catalog);
    assert_eq!(std::fs::read(store.path(&saved))?, b"abc");
    assert_eq!(store.cluster_inventory().await?.objects.len(), 1);
    Ok(())
}
