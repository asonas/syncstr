//! Mutate only a disposable fixture while its server is stopped.
use sha2::Digest as _;
use syncstr_headless::shared_audio::{Action, Evidence, Request, Source, Store};

fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let root = std::path::PathBuf::from(
        args.next()
            .ok_or_else(|| anyhow::anyhow!("fixture directory required"))?,
    );
    let operation = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("update or revoke required"))?;
    anyhow::ensure!(
        root.join("expected.json").is_file(),
        "requires a generated disposable fixture"
    );
    let host = syncstr_headless::peer::Identity::open(&root.join("host"))?;
    let store = Store::open(&root.join("host-data"))?;
    if operation == "revoke" {
        let reader: serde_json::Value =
            serde_json::from_slice(&std::fs::read(root.join("reader-enrollment.json"))?)?;
        store.revoke_member(
            &host,
            reader["member"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("reader missing"))?,
        )?;
    } else {
        anyhow::ensure!(operation == "update", "unknown operation");
        let mut wav = std::fs::read(root.join("tone.wav"))?;
        anyhow::ensure!(wav.len() > 44, "invalid tone");
        wav[44] ^= 1;
        let hash = hex::encode(sha2::Sha256::digest(&wav));
        store.put_audio(&hash, &mut std::io::Cursor::new(wav))?;
        let catalog = store.catalog()?;
        let mut track = catalog.tracks[&catalog.addresses["legacy-tone"]].clone();
        track
            .metadata
            .insert("title".into(), "Updated fixture tone".into());
        track
            .metadata
            .insert("album".into(), "Changed Album".into());
        track.album_id = Some("changed-album".into());
        track.audio.push(hash.clone());
        track.preferred = Some(hash.clone());
        let subject = format!("track:{}", track.id);
        store.commit(
            &host,
            Request {
                id: "fixture-update".into(),
                expected: std::collections::BTreeMap::from([(
                    subject.clone(),
                    catalog.heads.get(&subject).cloned().unwrap_or_default(),
                )]),
                action: Action::EditTrack {
                    track,
                    evidence: Evidence {
                        snapshot: "b".repeat(64),
                        catalog: hex::encode(sha2::Sha256::digest(serde_json::to_vec(&catalog)?)),
                        reason: "Synthetic fixture update".into(),
                        audio_eligible: true,
                    },
                },
            },
        )?;
        let catalog = store.catalog()?;
        let source = Source {
            library: "LIB-A".into(),
            track: "TRACK-A".into(),
        };
        store.commit(
            &host,
            Request {
                id: "fixture-correspondence-update".into(),
                expected: std::collections::BTreeMap::from([(
                    source.subject(),
                    catalog
                        .heads
                        .get(&source.subject())
                        .cloned()
                        .unwrap_or_default(),
                )]),
                action: Action::Assign {
                    source,
                    target: None,
                    evidence: Evidence {
                        snapshot: "c".repeat(64),
                        catalog: hex::encode(sha2::Sha256::digest(serde_json::to_vec(&catalog)?)),
                        reason: "Synthetic correspondence update".into(),
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
    Ok(())
}
