//! Disposable Windows audio verification. Never uses the everyday application profile.
#[cfg(windows)]
#[allow(dead_code)]
#[path = "../../../headless/fixtures/create_shared_audio.rs"]
mod fixture;
#[cfg(windows)]
#[path = "../src/profile.rs"]
mod profile;
#[cfg(windows)]
#[path = "../src/windows_identity.rs"]
mod windows_identity;
#[cfg(windows)]
#[path = "../src/windows_player.rs"]
mod windows_player;

#[cfg(windows)]
fn main() -> anyhow::Result<()> {
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(run())
}
#[cfg(not(windows))]
fn main() {
    eprintln!("Windows-only verification example");
}

#[cfg(windows)]
async fn run() -> anyhow::Result<()> {
    let root = std::env::args_os()
        .nth(1)
        .map(std::path::PathBuf::from)
        .ok_or_else(|| {
            anyhow::anyhow!("usage: windows_audio <new-fixture-directory> [--serve] [--audible]")
        })?;
    fixture::create_with_legacy_profile(root.clone(), true).await?;
    let enrollment: serde_json::Value =
        serde_json::from_slice(&std::fs::read(root.join("reader-enrollment.json"))?)?;
    let identity = std::sync::Arc::new(syncstr_headless::peer::Identity::open(&root.join("host"))?);
    let reader = syncstr_headless::peer::Identity::open(&root.join("reader"))?;
    let secret: [u8; 32] = std::fs::read(root.join("reader/device.key"))?
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid fixture key"))?;
    let source = root.join("win32-copy-source");
    let _ = enrollment;
    windows_identity::store(&source, secret)?;
    drop(reader);
    let original_database = std::fs::read(source.join("node.sqlite"))?;
    let protected_key = std::fs::read(source.join("device-key.dpapi"))?;
    let target = root.join("desktop-profile");
    profile::copy_win32(&source, &target).await?;
    assert_eq!(windows_identity::load(&target, false)?, secret);
    assert_eq!(
        std::fs::read(source.join("node.sqlite"))?,
        original_database
    );
    assert_eq!(
        std::fs::read(source.join("device-key.dpapi"))?,
        protected_key
    );
    println!("PASS: profile copied with DPAPI identity; original database/key unchanged");
    let store = syncstr_headless::shared_audio::Store::open(&root.join("host-data"))?;
    let serving = std::env::args().any(|a| a == "--serve");
    let (endpoint, lock) = identity
        .cluster_endpoint(&[if serving { "0.0.0.0:0" } else { "127.0.0.1:0" }.parse()?])
        .await?;
    let _discovery = if serving {
        Some(syncstr_headless::cluster_discovery::Discovery::start(
            &endpoint,
        )?)
    } else {
        None
    };
    let host = syncstr_headless::catalog_client::Host {
        member: identity.id().to_string(),
        socket: *endpoint.addr().ip_addrs().next().unwrap(),
    };
    let server_endpoint = endpoint.clone();
    let server = tokio::spawn(async move {
        let _lock = lock;
        syncstr_headless::shared_audio_net::serve(server_endpoint, store, identity).await
    });
    std::fs::write(
        root.join("desktop-host.txt"),
        format!("{}@{}", host.member, host.socket),
    )?;
    if std::env::args().any(|a| a == "--serve") {
        std::fs::rename(target.join("win32-saves.json"), target.join("win32-saves.test-pending.json"))?;
        println!(
            "Fixture host ready; use desktop-profile and Discover. Legacy imports are deferred to force actual network acquisition. Stop this example after closing the client."
        );
        std::future::pending::<()>().await;
    }
    let mut client = syncstr_headless::catalog_client::Client::open(&target)?;
    let view = client.refresh(&host, secret, &Default::default()).await?;
    assert_eq!(profile::restore_saves(&target, &mut client)?, 0);
    assert_eq!(
        client.saved_tracks()?.len(),
        1,
        "only the original ID/hash save is migrated, not every matching hash"
    );
    println!("PASS: original Win32-format saved audio imported by exact ID/hash");
    for pin in client.saved_tracks()? {
        client.remove_save(&pin)?;
    }
    assert_eq!(view.tracks.len(), 3);
    assert_eq!(view.playlists.values().next().unwrap().items.len(), 3);
    let pin = |title: &str| {
        view.tracks
            .values()
            .find(|t| t.title == title)
            .unwrap()
            .preferred
            .clone()
            .unwrap()
    };
    let a = pin("TRACK-A");
    let b = pin("TRACK-B");
    assert_ne!(a.track_id, b.track_id);
    assert_eq!(a.sha256, b.sha256);
    client
        .policy()
        .update(syncstr_headless::catalog_client::TransferPolicy {
            online: true,
            ..Default::default()
        });
    let job = client.save_tracks(&[a.clone(), b.clone()])?;
    let job = client
        .run_save(&job.id, &[host], Some(secret), &Default::default())
        .await?;
    assert_eq!(
        job.state,
        syncstr_headless::catalog_client::SaveState::Complete
    );
    assert_eq!(std::fs::read_dir(target.join("catalog-audio"))?.count(), 1);
    let asset = client
        .prepare_playback(&a.track_id, Some(&a.sha256), &[], None, &Default::default())
        .await?;
    let audible = std::env::args().any(|a| a == "--audible");
    tokio::task::spawn_blocking(move || check_player(asset, !audible)).await??;
    client.remove_save(&a)?;
    assert_eq!(client.saved_tracks()?, vec![b.clone()]);
    client.shutdown().await?;
    endpoint.close().await;
    server.await??;
    // Neither the host nor the protected identity is needed to play retained bytes.
    std::fs::rename(
        target.join("device-key.dpapi"),
        target.join("device-key.dpapi.test-hidden"),
    )?;
    let mut offline = syncstr_headless::catalog_client::Client::open(&target)?;
    let asset = offline
        .prepare_playback(&b.track_id, Some(&b.sha256), &[], None, &Default::default())
        .await?;
    let path = asset.path().to_owned();
    offline.remove_save(&b)?;
    assert!(path.exists());
    tokio::task::spawn_blocking(move || check_player(asset, true)).await??;
    assert!(!path.exists());
    offline.shutdown().await?;
    std::fs::rename(
        target.join("device-key.dpapi.test-hidden"),
        target.join("device-key.dpapi"),
    )?;
    println!(
        "PASS: authenticated v5 acquisition, distinct logical saves/one object, native playback, offline restart without host/key, lease-safe removal"
    );
    Ok(())
}

#[cfg(windows)]
fn check_player(
    asset: syncstr_headless::catalog_client::VerifiedAudio,
    muted: bool,
) -> anyhow::Result<()> {
    let mut player = windows_player::Player::new(muted)?;
    player.play(asset)?;
    let start = std::time::Instant::now();
    loop {
        let (playing, seconds, duration) = player.state()?;
        anyhow::ensure!(player.failure().is_none(), "MediaPlayer reported an error");
        let _ = player.ended();
        if playing && seconds > 0.2 && duration > 0.9 {
            player.pause()?;
            let paused = player.state()?.1;
            std::thread::sleep(std::time::Duration::from_millis(100));
            anyhow::ensure!(
                (player.state()?.1 - paused).abs() < 0.05,
                "pause did not stop the clock"
            );
            player.resume()?;
            std::thread::sleep(std::time::Duration::from_millis(200));
            anyhow::ensure!(
                player.state()?.1 > paused,
                "resume did not advance playback"
            );
            player.stop()?;
            println!(
                "PASS: Windows MediaPlayer decoded 1 s WAV, advanced position, paused/resumed/stopped (muted={muted})"
            );
            return Ok(());
        }
        anyhow::ensure!(
            start.elapsed() < std::time::Duration::from_secs(15),
            "Windows MediaPlayer did not start: playing={playing}, seconds={seconds}, duration={duration}"
        );
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
}
