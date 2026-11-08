#[derive(Default)]
pub struct Control {
    pub requests: std::sync::Mutex<Vec<syncstr_headless::catalog_client::ExactTrack>>,
    pub missing: std::sync::Mutex<Option<String>>,
    pub corrupt: std::sync::atomic::AtomicBool,
    pub declared_extra: std::sync::atomic::AtomicU64,
    pub hold: std::sync::atomic::AtomicBool,
    pub requested: tokio::sync::Notify,
    pub release: tokio::sync::Notify,
}

pub async fn serve(
    fixture: &super::Fixture,
    control: std::sync::Arc<Control>,
) -> anyhow::Result<(
    iroh::Endpoint,
    tokio::task::JoinHandle<anyhow::Result<()>>,
    syncstr_headless::catalog_client::Host,
)> {
    let (endpoint, lock) = fixture
        .identity
        .cluster_endpoint(&["127.0.0.1:0".parse()?])
        .await?;
    let host = syncstr_headless::catalog_client::Host {
        member: fixture.identity.id().to_string(),
        socket: *endpoint.addr().ip_addrs().next().unwrap(),
    };
    let enrollment: serde_json::Value =
        serde_json::from_slice(&std::fs::read(fixture.root.join("reader-enrollment.json"))?)?;
    let proof: syncstr_headless::enrollment::Proof =
        serde_json::from_value(enrollment["proof"].clone())?;
    let (listening, store) = (endpoint.clone(), fixture.store.clone());
    let task = tokio::spawn(async move {
        let _lock = lock;
        let mut connections = tokio::task::JoinSet::new();
        while let Some(incoming) = listening.accept().await {
            let (proof, store, control) = (proof.clone(), store.clone(), control.clone());
            connections.spawn(async move {
                let connection = incoming.await?;
                let (mut output, mut input) = connection.accept_bi().await?;
                let hello: syncstr_headless::shared_audio_net::Hello = receive(&mut input).await?;
                anyhow::ensure!(hello.version == 5 && hello.proof.root == proof.root, "unexpected hello");
                syncstr_headless::shared_audio_net::authorize(&proof, &connection.remote_id().to_string(), false)?;
                send(&mut output, &syncstr_headless::shared_audio_net::Hello { version: 5, proof, supported_operations: Vec::new() }).await?;
                output.finish()?;
                while let Ok((mut output, mut input)) = connection.accept_bi().await {
                    let request: syncstr_headless::shared_audio_net::Request = receive(&mut input).await?;
                    match request {
                        syncstr_headless::shared_audio_net::Request::Catalog => send(&mut output, &store.snapshot()?).await?,
                        syncstr_headless::shared_audio_net::Request::Audio { track, hash } => {
                            control.requests.lock().unwrap().push(syncstr_headless::catalog_client::ExactTrack { track_id: track.clone(), sha256: hash.clone() });
                            control.requested.notify_one();
                            if control.hold.load(std::sync::atomic::Ordering::Acquire) {
                                tokio::select! { _ = control.release.notified() => {}, _ = connection.closed() => return anyhow::Ok(()) }
                            }
                            if control.missing.lock().unwrap().as_ref() == Some(&hash) { output.finish()?; continue; }
                            use std::io::Read as _;
                            let mut bytes = Vec::new();
                            store.audio(&track, &hash)?.read_to_end(&mut bytes)?;
                            send(&mut output, &(bytes.len() as u64 + control.declared_extra.load(std::sync::atomic::Ordering::Acquire))).await?;
                            if control.corrupt.load(std::sync::atomic::Ordering::Acquire) { bytes[0] ^= 1; }
                            output.write_all(&bytes).await?;
                        },
                        _ => anyhow::bail!("unexpected client mutation"),
                    }
                    output.finish()?;
                }
                anyhow::Ok(())
            });
        }
        connections.abort_all();
        while connections.join_next().await.is_some() {}
        Ok(())
    });
    Ok((endpoint, task, host))
}

async fn receive<T: serde::de::DeserializeOwned>(
    stream: &mut iroh::endpoint::RecvStream,
) -> anyhow::Result<T> {
    let mut size = [0; 4];
    stream.read_exact(&mut size).await?;
    let size = u32::from_be_bytes(size) as usize;
    anyhow::ensure!(size > 0 && size <= 4 * 1024 * 1024, "invalid frame");
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

pub fn add_track(
    f: &super::Fixture,
    name: &str,
    bytes: &[u8],
) -> anyhow::Result<syncstr_headless::catalog_client::ExactTrack> {
    use sha2::Digest as _;
    let hash = hex::encode(sha2::Sha256::digest(bytes));
    f.store.put_audio(&hash, &mut std::io::Cursor::new(bytes))?;
    let catalog = f.store.catalog()?;
    let album = catalog.legacy_organization["albums"][0]["id"]
        .as_str()
        .unwrap();
    f.store.commit(
        &f.identity,
        syncstr_headless::shared_audio::Request {
            id: format!("register-{name}"),
            expected: Default::default(),
            action: syncstr_headless::shared_audio::Action::Register {
                source: syncstr_headless::shared_audio::Source {
                    library: "LIB-A".into(),
                    track: name.into(),
                },
                track: syncstr_headless::shared_audio::Track {
                    id: String::new(),
                    metadata: std::collections::BTreeMap::from([("title".into(), name.into())]),
                    album_id: Some(album.into()),
                    added_at: None,
                    retired: false,
                    audio: vec![hash.clone()],
                    preferred: Some(hash.clone()),
                },
                evidence: syncstr_headless::shared_audio::Evidence {
                    snapshot: "a".repeat(64),
                    catalog: hex::encode(sha2::Sha256::digest(serde_json::to_vec(&catalog)?)),
                    reason: "Synthetic verification".into(),
                    audio_eligible: true,
                    source_confirmation: None,
                },
            },
        },
    )?;
    let catalog = f.store.catalog()?;
    let track = catalog
        .tracks
        .values()
        .find(|track| track.metadata.get("title").and_then(|v| v.as_str()) == Some(name))
        .unwrap();
    Ok(syncstr_headless::catalog_client::ExactTrack {
        track_id: track.id.clone(),
        sha256: hash,
    })
}
