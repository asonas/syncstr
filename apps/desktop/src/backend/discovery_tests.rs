#[allow(dead_code)]
#[path = "../../../../headless/fixtures/create_shared_audio.rs"]
mod fixture;

#[test]
#[ignore = "Browses real LAN interfaces; run on the Windows validation host"]
fn discovery_result_remains_visible_for_an_enrolled_profile() -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let data = root.path().join("fixture");
    let profile = root.path().join("profile");
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async {
        fixture::create(data.clone()).await?;
        let enrollment: serde_json::Value =
            serde_json::from_slice(&std::fs::read(data.join("reader-enrollment.json"))?)?;
        let reader = syncstr_headless::peer::Identity::open(&data.join("reader"))?;
        let host = syncstr_headless::peer::Identity::open(&data.join("host"))?;
        let store = syncstr_headless::store::Store::open(&profile)?;
        store
            .join_cluster(
                &reader,
                host.id(),
                enrollment["grant"].as_str().unwrap().into(),
                serde_json::from_value(enrollment["proof"].clone())?,
            )
            .await?;
        anyhow::Ok(())
    })?;
    drop(runtime);
    let (commands, receive) = std::sync::mpsc::channel();
    let (events, responses) = std::sync::mpsc::channel();
    let (audio, player) = std::sync::mpsc::channel();
    commands.send(super::Command::Discover)?;
    commands.send(super::Command::Shutdown)?;
    let worker = std::thread::spawn(move || {
        super::worker::run(
            super::configuration::Config {
                root: profile,
                copy_from: None,
                host: None,
                muted: true,
            },
            receive,
            events,
            Default::default(),
            audio,
            std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
        )
    });
    // Only the native-player shutdown boundary is replaced; browsing and catalog snapshots are real.
    if let super::audio::Command::Stop(Some(ack)) =
        player.recv_timeout(std::time::Duration::from_secs(10))?
    {
        ack.send(())?;
    }
    worker.join().expect("catalog worker panicked")?;
    let mut displayed = String::new();
    for event in responses.try_iter() {
        match event {
            super::Event::Library { message, .. } | super::Event::Message(message) => {
                displayed = message
            }
            _ => {}
        }
    }
    anyhow::ensure!(
        displayed.contains("host(s) discovered"),
        "Discovery result was replaced: {displayed}"
    );
    Ok(())
}
