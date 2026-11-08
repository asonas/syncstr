#![cfg(feature = "p2p")]

#[path = "../fixtures/create_shared_audio.rs"]
mod fixture;
#[path = "catalog_audio/scripted.rs"]
mod scripted;

struct Fixture {
    _root: tempfile::TempDir,
    root: std::path::PathBuf,
    profile: std::path::PathBuf,
    store: syncstr_headless::shared_audio::Store,
    identity: std::sync::Arc<syncstr_headless::peer::Identity>,
    secret: [u8; 32],
    a: syncstr_headless::catalog_client::ExactTrack,
    b: syncstr_headless::catalog_client::ExactTrack,
}

impl Fixture {
    async fn new() -> anyhow::Result<Self> {
        let temporary = tempfile::tempdir()?;
        let root = temporary.path().join("fixture");
        fixture::create(root.clone()).await?;
        let enrollment: serde_json::Value =
            serde_json::from_slice(&std::fs::read(root.join("reader-enrollment.json"))?)?;
        let proof: syncstr_headless::enrollment::Proof =
            serde_json::from_value(enrollment["proof"].clone())?;
        let identity =
            std::sync::Arc::new(syncstr_headless::peer::Identity::open(&root.join("host"))?);
        let reader = syncstr_headless::peer::Identity::open(&root.join("reader"))?;
        let secret = std::fs::read(root.join("reader/device.key"))?
            .try_into()
            .unwrap();
        let profile = root.join("client-profile");
        let registration = syncstr_headless::store::Store::open(&profile)?;
        registration
            .join_cluster(
                &reader,
                identity.id(),
                enrollment["grant"].as_str().unwrap().into(),
                proof,
            )
            .await?;
        drop(registration);
        let store = syncstr_headless::shared_audio::Store::open(&root.join("host-data"))?;
        let catalog = store.catalog()?;
        let pin = |title: &str| {
            let track = catalog
                .tracks
                .values()
                .find(|track| track.metadata.get("title").and_then(|v| v.as_str()) == Some(title))
                .unwrap();
            syncstr_headless::catalog_client::ExactTrack {
                track_id: track.id.clone(),
                sha256: track.preferred.clone().unwrap(),
            }
        };
        let a = pin("TRACK-A");
        let b = pin("TRACK-B");
        Ok(Self {
            _root: temporary,
            root,
            profile,
            store,
            identity,
            secret,
            a,
            b,
        })
    }

    async fn serve(
        &self,
    ) -> anyhow::Result<(
        iroh::Endpoint,
        tokio::task::JoinHandle<anyhow::Result<()>>,
        syncstr_headless::catalog_client::Host,
    )> {
        let (endpoint, lock) = self
            .identity
            .cluster_endpoint(&["127.0.0.1:0".parse()?])
            .await?;
        let host = syncstr_headless::catalog_client::Host {
            member: self.identity.id().to_string(),
            socket: *endpoint.addr().ip_addrs().next().unwrap(),
        };
        let (serving, store, identity) =
            (endpoint.clone(), self.store.clone(), self.identity.clone());
        let task = tokio::spawn(async move {
            let _lock = lock;
            syncstr_headless::shared_audio_net::serve(serving, store, identity).await
        });
        Ok((endpoint, task, host))
    }
}

fn online(client: &syncstr_headless::catalog_client::Client) {
    client
        .policy()
        .update(syncstr_headless::catalog_client::TransferPolicy {
            online: true,
            ..Default::default()
        });
}

#[tokio::test]
async fn shared_bytes_have_independent_receipts_and_active_playback_survives_removal()
-> anyhow::Result<()> {
    let f = Fixture::new().await?;
    let original = std::fs::read(f.root.join("tone.wav"))?;
    let (endpoint, server, host) = f.serve().await?;
    let hosts = [host];
    let mut client = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    client
        .refresh(&hosts[0], f.secret, &Default::default())
        .await?;
    online(&client);
    let job = client.save_tracks(&[f.a.clone(), f.b.clone()])?;
    assert_eq!(client.save_jobs()?[0], job);
    let saved = client
        .run_save(&job.id, &hosts, Some(f.secret), &Default::default())
        .await?;
    assert_eq!(
        saved.state,
        syncstr_headless::catalog_client::SaveState::Complete,
        "{saved:?}"
    );
    assert_eq!(client.saved_tracks()?.len(), 2);
    assert_eq!(
        std::fs::read_dir(f.profile.join("catalog-audio"))?.count(),
        1
    );
    let asset = client
        .prepare_playback(
            &f.b.track_id,
            Some(&f.b.sha256),
            &[],
            None,
            &Default::default(),
        )
        .await?;
    let path = asset.path().to_owned();
    client.remove_save(&f.a)?;
    assert_eq!(client.saved_tracks()?, vec![f.b.clone()]);
    client.trim_cache()?;
    assert_eq!(std::fs::read(&path)?, original);
    drop(asset);
    client.shutdown().await?;
    endpoint.close().await;
    server.await??;
    let mut offline = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    let asset = offline
        .prepare_playback(&f.b.track_id, None, &[], None, &Default::default())
        .await?;
    assert_eq!(asset.pin(), &f.b);
    offline.remove_save(&f.b)?;
    assert!(offline.saved_tracks()?.is_empty());
    assert!(path.exists());
    drop(asset);
    assert!(!path.exists());
    offline.shutdown().await?;
    assert_eq!(std::fs::read(f.root.join("tone.wav"))?, original);
    Ok(())
}

#[tokio::test]
async fn playback_cache_policy_and_shutdown_preserve_asset_lifetime_without_saves()
-> anyhow::Result<()> {
    let f = Fixture::new().await?;
    let (endpoint, server, host) = f.serve().await?;
    let mut client = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    client.refresh(&host, f.secret, &Default::default()).await?;
    let policy = client.policy();
    policy.update(syncstr_headless::catalog_client::TransferPolicy {
        online: true,
        cellular: true,
        cache_limit_bytes: 0,
        ..Default::default()
    });
    let job = client.save_tracks(std::slice::from_ref(&f.a))?;
    let waiting = client
        .run_save(
            &job.id,
            std::slice::from_ref(&host),
            Some(f.secret),
            &Default::default(),
        )
        .await?;
    assert_eq!(
        waiting.state,
        syncstr_headless::catalog_client::SaveState::Waiting
    );
    assert_eq!(
        waiting.items[0].error,
        Some(syncstr_headless::catalog_client::Error::PolicyRestricted)
    );
    let asset = client
        .prepare_playback(
            &f.a.track_id,
            None,
            &[host],
            Some(f.secret),
            &Default::default(),
        )
        .await?;
    let path = asset.path().to_owned();
    assert!(client.saved_tracks()?.is_empty());
    client.trim_cache()?;
    assert!(path.exists());
    let cloned = asset.clone();
    drop(asset);
    assert!(path.exists());
    let release = tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        drop(cloned);
    });
    let start = std::time::Instant::now();
    client.shutdown().await?;
    assert!(start.elapsed() >= std::time::Duration::from_millis(40));
    release.await?;
    assert!(!path.exists());
    client.shutdown().await?;
    endpoint.close().await;
    server.await??;
    let mut reopened = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    assert_eq!(reopened.save_jobs()?[0].id, job.id);
    assert!(reopened.saved_tracks()?.is_empty());
    reopened.cancel_save(&job.id)?;
    drop(reopened);
    let mut reopened = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    assert_eq!(
        reopened.save_jobs()?[0].state,
        syncstr_headless::catalog_client::SaveState::Cancelled
    );
    reopened.retry_save(&job.id)?;
    assert_eq!(
        reopened.save_jobs()?[0].state,
        syncstr_headless::catalog_client::SaveState::Waiting
    );
    Ok(())
}

#[tokio::test]
async fn partial_save_restarts_only_missing_bytes_and_album_snapshot_stays_fixed()
-> anyhow::Result<()> {
    let f = Fixture::new().await?;
    let c = scripted::add_track(&f, "TRACK-C", b"def")?;
    let control = std::sync::Arc::new(scripted::Control::default());
    *control.missing.lock().unwrap() = Some(c.sha256.clone());
    let (endpoint, server, host) = scripted::serve(&f, control.clone()).await?;
    let hosts = [host];
    let mut client = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    client
        .refresh(&hosts[0], f.secret, &Default::default())
        .await?;
    online(&client);
    let job = client.save_tracks(&[f.a.clone(), c.clone()])?;
    let partial = client
        .run_save(&job.id, &hosts, Some(f.secret), &Default::default())
        .await?;
    assert_eq!(
        partial.state,
        syncstr_headless::catalog_client::SaveState::Partial
    );
    assert_eq!(
        partial.items[0].state,
        syncstr_headless::catalog_client::SaveItemState::Saved
    );
    assert_eq!(
        partial.items[1].error,
        Some(syncstr_headless::catalog_client::Error::UnavailableSource)
    );
    client.shutdown().await?;
    drop(client);
    let mut client = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    assert_eq!(client.save_jobs()?[0], partial);
    assert_eq!(client.saved_tracks()?, vec![f.a.clone()]);
    *control.missing.lock().unwrap() = None;
    online(&client);
    assert_eq!(
        client
            .run_save(&job.id, &hosts, Some(f.secret), &Default::default())
            .await?
            .state,
        syncstr_headless::catalog_client::SaveState::Complete
    );
    assert_eq!(
        control
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|pin| pin.sha256 == f.a.sha256)
            .count(),
        1
    );
    assert_eq!(
        control
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|pin| pin.sha256 == c.sha256)
            .count(),
        2
    );
    let album = client.catalog()?.tracks[&c.track_id].album_id.clone();
    let snapshot = client.save_album(&album)?;
    assert_eq!(snapshot.items.len(), 2);
    assert_eq!(
        snapshot.state,
        syncstr_headless::catalog_client::SaveState::Complete
    );
    let d = scripted::add_track(&f, "TRACK-D", b"ghi")?;
    client
        .refresh(&hosts[0], f.secret, &Default::default())
        .await?;
    assert!(
        !client
            .save_jobs()?
            .into_iter()
            .find(|job| job.id == snapshot.id)
            .unwrap()
            .items
            .iter()
            .any(|item| item.pin == d)
    );
    assert_eq!(client.save_album(&album)?.items.len(), 3);
    client.shutdown().await?;
    endpoint.close().await;
    server.await??;
    Ok(())
}

#[tokio::test]
async fn integrity_cancellation_and_policy_changes_never_publish_late_audio() -> anyhow::Result<()>
{
    let f = Fixture::new().await?;
    let c = scripted::add_track(&f, "TRACK-C", b"def")?;
    let control = std::sync::Arc::new(scripted::Control::default());
    let (endpoint, server, host) = scripted::serve(&f, control.clone()).await?;
    let mut client = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    client.refresh(&host, f.secret, &Default::default()).await?;
    online(&client);
    let unauthorized = syncstr_headless::catalog_client::Host {
        member: iroh::SecretKey::from_bytes(&[3; 32]).public().to_string(),
        socket: host.socket,
    };
    assert!(matches!(
        client
            .prepare_playback(
                &f.a.track_id,
                None,
                &[unauthorized],
                Some(f.secret),
                &Default::default()
            )
            .await,
        Err(syncstr_headless::catalog_client::Error::UnavailableSource)
    ));
    assert!(control.requests.lock().unwrap().is_empty());
    control
        .corrupt
        .store(true, std::sync::atomic::Ordering::Release);
    assert!(matches!(
        client
            .prepare_playback(
                &f.a.track_id,
                None,
                std::slice::from_ref(&host),
                Some(f.secret),
                &Default::default()
            )
            .await,
        Err(syncstr_headless::catalog_client::Error::Integrity)
    ));
    assert_eq!(
        std::fs::read_dir(f.profile.join("catalog-audio"))?.count(),
        0
    );
    control
        .corrupt
        .store(false, std::sync::atomic::Ordering::Release);
    control
        .declared_extra
        .store(1, std::sync::atomic::Ordering::Release);
    assert!(matches!(
        client
            .prepare_playback(
                &f.a.track_id,
                None,
                std::slice::from_ref(&host),
                Some(f.secret),
                &Default::default()
            )
            .await,
        Err(syncstr_headless::catalog_client::Error::Integrity)
    ));
    control
        .declared_extra
        .store(0, std::sync::atomic::Ordering::Release);
    control.requested.notified().await;
    control
        .hold
        .store(true, std::sync::atomic::Ordering::Release);
    let job = client.save_tracks(std::slice::from_ref(&f.a))?;
    let operation = syncstr_headless::catalog_client::Operation::default();
    let (cancel, delayed) = (operation.clone(), control.clone());
    let cancelling = tokio::spawn(async move {
        delayed.requested.notified().await;
        cancel.cancel();
        delayed.release.notify_one();
    });
    assert_eq!(
        client
            .run_save(
                &job.id,
                std::slice::from_ref(&host),
                Some(f.secret),
                &operation
            )
            .await,
        Err(syncstr_headless::catalog_client::Error::Cancelled)
    );
    cancelling.await?;
    assert!(client.saved_tracks()?.is_empty());
    assert_eq!(
        std::fs::read_dir(f.profile.join("catalog-audio"))?.count(),
        0
    );
    client.shutdown().await?;
    drop(client);
    let mut client = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    assert_eq!(
        client.save_jobs()?[0].state,
        syncstr_headless::catalog_client::SaveState::Waiting
    );
    online(&client);
    control
        .hold
        .store(false, std::sync::atomic::Ordering::Release);
    assert_eq!(
        client
            .run_save(
                &job.id,
                std::slice::from_ref(&host),
                Some(f.secret),
                &Default::default()
            )
            .await?
            .state,
        syncstr_headless::catalog_client::SaveState::Complete
    );
    control.requested.notified().await;
    control
        .hold
        .store(true, std::sync::atomic::Ordering::Release);
    let paused = client.save_tracks(std::slice::from_ref(&c))?;
    let (policy, delayed) = (client.policy(), control.clone());
    let pause = tokio::spawn(async move {
        delayed.requested.notified().await;
        policy.update(Default::default());
        delayed.release.notify_one();
    });
    let result = client
        .run_save(
            &paused.id,
            std::slice::from_ref(&host),
            Some(f.secret),
            &Default::default(),
        )
        .await?;
    pause.await?;
    assert_eq!(
        result.state,
        syncstr_headless::catalog_client::SaveState::Waiting
    );
    assert_eq!(
        result.items[0].error,
        Some(syncstr_headless::catalog_client::Error::PolicyRestricted)
    );
    assert_eq!(client.saved_tracks()?, vec![f.a.clone()]);
    assert_eq!(
        std::fs::read_dir(f.profile.join("catalog-audio"))?.count(),
        1
    );
    client.shutdown().await?;
    endpoint.close().await;
    server.await??;
    Ok(())
}

#[tokio::test]
async fn shutdown_drains_transfer_after_the_calling_future_is_dropped() -> anyhow::Result<()> {
    let f = Fixture::new().await?;
    let control = std::sync::Arc::new(scripted::Control::default());
    control
        .hold
        .store(true, std::sync::atomic::Ordering::Release);
    let (endpoint, server, host) = scripted::serve(&f, control.clone()).await?;
    let mut client = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    client.refresh(&host, f.secret, &Default::default()).await?;
    online(&client);
    let job = client.save_tracks(std::slice::from_ref(&f.a))?;
    let operation = syncstr_headless::catalog_client::Operation::default();
    let mut pending = Box::pin(client.run_save(
        &job.id,
        std::slice::from_ref(&host),
        Some(f.secret),
        &operation,
    ));
    tokio::select! {
        _ = control.requested.notified() => {},
        result = &mut pending => anyhow::bail!("save completed before shutdown: {result:?}"),
    }
    drop(pending);
    tokio::time::timeout(std::time::Duration::from_secs(10), client.shutdown()).await??;
    assert_eq!(
        std::fs::read_dir(f.profile.join("catalog-audio"))?.count(),
        0
    );
    let reopened = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    assert_eq!(reopened.save_jobs()?[0].id, job.id);
    assert_eq!(
        reopened.save_jobs()?[0].state,
        syncstr_headless::catalog_client::SaveState::Waiting
    );
    assert!(reopened.saved_tracks()?.is_empty());
    endpoint.close().await;
    server.await??;
    Ok(())
}

#[tokio::test]
#[ignore = "subprocess entry point for interrupted-save recovery"]
async fn checkpoint_crash_worker() -> anyhow::Result<()> {
    let profile = std::path::PathBuf::from(std::env::var_os("ASO71_TEST_PROFILE").unwrap());
    let secret = std::fs::read(profile.parent().unwrap().join("reader/device.key"))?
        .try_into()
        .unwrap();
    let host = syncstr_headless::catalog_client::Host {
        member: std::env::var("ASO71_TEST_MEMBER")?,
        socket: std::env::var("ASO71_TEST_SOCKET")?.parse()?,
    };
    let mut client = syncstr_headless::catalog_client::Client::open(&profile)?;
    online(&client);
    client
        .run_save(
            &std::env::var("ASO71_TEST_JOB")?,
            &[host],
            Some(secret),
            &Default::default(),
        )
        .await?;
    anyhow::bail!("worker should have been terminated during acquisition")
}

#[tokio::test]
async fn killed_worker_restores_accepted_intent_and_removes_unverified_staging()
-> anyhow::Result<()> {
    let f = Fixture::new().await?;
    let control = std::sync::Arc::new(scripted::Control::default());
    control
        .hold
        .store(true, std::sync::atomic::Ordering::Release);
    let (endpoint, server, host) = scripted::serve(&f, control.clone()).await?;
    let mut client = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    client.refresh(&host, f.secret, &Default::default()).await?;
    let job = client.save_tracks(&[f.a.clone(), f.b.clone()])?;
    client.shutdown().await?;
    drop(client);
    let mut child = std::process::Command::new(std::env::current_exe()?)
        .args([
            "--ignored",
            "--exact",
            "checkpoint_crash_worker",
            "--nocapture",
        ])
        .env("ASO71_TEST_PROFILE", &f.profile)
        .env("ASO71_TEST_MEMBER", &host.member)
        .env("ASO71_TEST_SOCKET", host.socket.to_string())
        .env("ASO71_TEST_JOB", &job.id)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    let requested = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        control.requested.notified(),
    )
    .await;
    let killed = child.kill();
    let status = child.wait()?;
    requested?;
    killed?;
    assert!(!status.success());
    assert!(std::fs::read_dir(f.profile.join("catalog-audio"))?.count() > 0);
    let mut reopened = syncstr_headless::catalog_client::Client::open(&f.profile)?;
    let recovered = &reopened.save_jobs()?[0];
    assert_eq!(recovered.id, job.id);
    assert_eq!(
        recovered.state,
        syncstr_headless::catalog_client::SaveState::Waiting
    );
    assert_eq!(recovered.items, job.items);
    assert!(reopened.saved_tracks()?.is_empty());
    assert_eq!(
        std::fs::read_dir(f.profile.join("catalog-audio"))?.count(),
        0
    );
    control
        .hold
        .store(false, std::sync::atomic::Ordering::Release);
    online(&reopened);
    assert_eq!(
        reopened
            .run_save(&job.id, &[host], Some(f.secret), &Default::default())
            .await?
            .state,
        syncstr_headless::catalog_client::SaveState::Complete
    );
    assert_eq!(reopened.saved_tracks()?.len(), 2);
    reopened.shutdown().await?;
    endpoint.close().await;
    server.await??;
    Ok(())
}
