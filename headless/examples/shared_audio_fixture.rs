#[tokio::main]
async fn main() -> anyhow::Result<()> {
    use sha2::Digest as _;
    use std::io::Write as _;
    let root = std::env::args_os()
        .nth(1)
        .map(std::path::PathBuf::from)
        .ok_or_else(|| anyhow::anyhow!("usage: shared_audio_fixture <new-output-directory>"))?;
    anyhow::ensure!(!root.exists(), "fixture output must not exist");
    std::fs::create_dir_all(&root)?;
    for name in ["host", "replica", "reader"] {
        syncstr_headless::peer::Identity::initialize(&root.join(name))?;
    }
    let host = syncstr_headless::peer::Identity::open(&root.join("host"))?;
    let replica = syncstr_headless::peer::Identity::open(&root.join("replica"))?;
    let reader = syncstr_headless::peer::Identity::open(&root.join("reader"))?;
    let data = root.join("host-data");
    let legacy = syncstr_headless::store::Store::open(&data)?;
    let cluster = legacy.create_cluster(host.id().to_string()).await?.id;
    let mut reader_grant = String::new();
    for (member, is_host) in [(replica.id(), true), (reader.id(), false)] {
        let invitation = legacy
            .create_cluster_invitation(&host, is_host, 100, 600)
            .await?;
        let grant = legacy
            .redeem_cluster_invitation(&host, &invitation.secret, member.to_string(), 101)
            .await?;
        if !is_host {
            reader_grant = grant.id;
        }
    }
    let mut wav = Vec::new();
    let sample_rate = 8000u32;
    let length = sample_rate * 2;
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + length).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&length.to_le_bytes());
    for sample in 0..sample_rate {
        let value = ((f64::from(sample) * 440.0 * std::f64::consts::TAU / f64::from(sample_rate))
            .sin()
            * 2000.0) as i16;
        wav.extend_from_slice(&value.to_le_bytes());
    }
    std::fs::write(root.join("tone.wav"), &wav)?;
    let hash = hex::encode(sha2::Sha256::digest(&wav));
    let mut entry: syncstr_headless::model::Entry =
        serde_json::from_slice(include_bytes!("../fixtures/local-entry.json"))?;
    entry.track.id = "legacy-tone".into();
    entry.track.title = "Fixture tone".into();
    entry.track.artist = Some("Example Artist".into());
    entry.track.album = Some("Example Album".into());
    entry.track.suffix = "wav".into();
    entry.track.size = wav.len() as u64;
    entry.track.duration = Some(1.0);
    entry.sha256 = hash.clone();
    entry.artwork = None;
    entry.imported_album = None;
    let mut organization = syncstr_headless::organization::Organization::default();
    organization.import(&entry);
    let mut staged = legacy.stage().await?;
    staged.write_all(&wav)?;
    let saved = legacy
        .commit_organized(entry, staged, false, Some(organization))
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
                name: "Pinned fixture".into(),
                kind: "manual".into(),
                parent: None,
                definition: Default::default(),
                items: ["legacy-tone", saved.track.id.as_str(), "legacy-tone"]
                    .iter()
                    .enumerate()
                    .map(|(i, id)| syncstr_headless::playlists::Item {
                        id: format!("occurrence-{i}"),
                        source_track: "17".into(),
                        title: "Fixture tone".into(),
                        artist: None,
                        album: None,
                        track_id: Some((*id).into()),
                        sha256: Some(hash.clone()),
                    })
                    .collect(),
            }],
        )
        .await?;
    let proof = legacy.cluster_membership_proof().await?;
    std::fs::write(
        root.join("reader-enrollment.json"),
        serde_json::to_vec_pretty(
            &serde_json::json!({ "grant": reader_grant, "proof": proof, "member": reader.id().to_string() }),
        )?,
    )?;
    drop(legacy);
    let replica_data = root.join("replica-data");
    std::fs::create_dir_all(replica_data.join("objects"))?;
    std::fs::create_dir_all(replica_data.join("staging"))?;
    std::fs::write(replica_data.join("node.lock"), b"")?;
    std::fs::copy(data.join("node.sqlite"), replica_data.join("node.sqlite"))?;
    let baseline = syncstr_headless::shared_audio::Store::inspect(&data)?;
    let store = syncstr_headless::shared_audio::Store::activate(&data, &baseline)?;
    drop(syncstr_headless::shared_audio::Store::activate(
        &replica_data,
        &baseline,
    )?);
    for name in ["TRACK-A", "TRACK-B"] {
        let catalog = store.catalog()?;
        store.commit(
            &host,
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
                        metadata: std::collections::BTreeMap::from([
                            ("title".into(), name.into()),
                            ("artist".into(), "Example Artist".into()),
                            ("suffix".into(), "wav".into()),
                        ]),
                        album_id: None,
                        added_at: None,
                        retired: false,
                        audio: vec![hash.clone()],
                        preferred: Some(hash.clone()),
                    },
                    evidence: syncstr_headless::shared_audio::Evidence {
                        snapshot: "a".repeat(64),
                        catalog: hex::encode(sha2::Sha256::digest(serde_json::to_vec(&catalog)?)),
                        reason: "Synthetic fixture approval".into(),
                        audio_eligible: true,
                    },
                },
            },
        )?;
    }
    std::fs::write(
        root.join("snapshot.json"),
        serde_json::to_vec_pretty(&store.snapshot()?)?,
    )?;
    std::fs::write(
        root.join("records.json"),
        serde_json::to_vec_pretty(&store.records()?)?,
    )?;
    std::fs::write(
        root.join("expected.json"),
        serde_json::to_vec_pretty(
            &serde_json::json!({ "baseline": baseline, "sha256": hash, "legacy_id": "legacy-tone", "legacy_alias": saved.track.id, "logical_track_count": 3, "object_count": 1, "playlists": store.playlists()? }),
        )?,
    )?;
    syncstr_headless::identity::initialize(&root.join("host-tls"), "localhost")?;
    syncstr_headless::identity::initialize(&root.join("replica-tls"), "localhost")?;
    println!(
        "Created disposable fixture. Keys and bearer tokens are local test credentials; do not publish the output directory."
    );
    Ok(())
}
